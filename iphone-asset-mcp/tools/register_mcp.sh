#!/usr/bin/env bash
#
# MCP 서버를 Claude Code 에 등록한다.
#
#   tools/register_mcp.sh <url> <token> [이름]
#
# 순서가 중요하다. 먼저 .mcp.json 을 쓴다 — CLI 버전과 무관하게 항상 되고,
# Claude Code 가 그 폴더에서 실행될 때 자동으로 읽는다. 그다음 전역 등록을
# 시도하되 **지원이 확인된 문법만** 쓴다.
#
# 확인 없이 claude 를 부르면 안 된다. 인자를 못 알아들은 CLI 는 그것을 프롬프트로
# 해석해 대화 세션을 띄워 버리고, 스크립트는 터미널을 빼앗긴 채 멈춘다.
# 그래서 --help 로 먼저 확인하고, 모든 호출에 </dev/null 을 붙인다.

set -uo pipefail

URL="${1:?사용법: register_mcp.sh <url> <token> [이름]}"
TOKEN="${2:?사용법: register_mcp.sh <url> <token> [이름]}"
NAME="${3:-iphone}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_JSON="$REPO_ROOT/.mcp.json"

# --- 1. 설정 파일: 항상, 무조건 ------------------------------------------------

python3 - "$NAME" "$URL" "$TOKEN" "$CONFIG_JSON" <<'PY'
import json, os, sys
name, url, token, path = sys.argv[1:5]

config = {}
if os.path.exists(path):
    try:
        with open(path) as handle:
            config = json.load(handle)
    except Exception:
        config = {}

config.setdefault("mcpServers", {})[name] = {
    "type": "http",
    "url": url,
    "headers": {"Authorization": f"Bearer {token}"},
}

with open(path, "w") as handle:
    json.dump(config, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY

if ! command -v claude >/dev/null 2>&1; then
    echo "file:$CONFIG_JSON"
    exit 0
fi

# --- 2. 전역 등록: 지원이 확인될 때만 ------------------------------------------

# 도움말 호출에도 </dev/null 을 붙인다. `mcp` 하위 명령이 없는 버전이면
# 이것조차 대화 세션으로 흘러갈 수 있다.
MCP_HELP="$(claude mcp --help </dev/null 2>&1)"
if [[ "$MCP_HELP" != *"add"* ]]; then
    echo "file:$CONFIG_JSON"
    exit 0
fi

# 등록을 시도하든 말든, 기존 항목은 **항상** 먼저 지운다.
#
# 설정은 두 군데에 있을 수 있다 — CLI 가 쓰는 ~/.claude.json 과 여기서 만드는
# .mcp.json. 앞의 것이 우선하므로, 낡은 토큰이 담긴 CLI 항목을 남겨두면
# 방금 갱신한 .mcp.json 이 무시되고 401 이 난다.
claude mcp remove "$NAME" </dev/null >/dev/null 2>&1
claude mcp remove "$NAME" --scope local </dev/null >/dev/null 2>&1
claude mcp remove "$NAME" --scope project </dev/null >/dev/null 2>&1
claude mcp remove "$NAME" --scope user </dev/null >/dev/null 2>&1

ADD_HELP="$(claude mcp add --help </dev/null 2>&1)"
registered=""

if [[ "$ADD_HELP" == *"--transport"* ]]; then
    if claude mcp add --transport http "$NAME" "$URL" \
            --header "Authorization: Bearer $TOKEN" </dev/null >/dev/null 2>&1; then
        registered="transport"
    fi
fi

if [[ -z "$registered" && "$MCP_HELP" == *"add-json"* ]]; then
    PAYLOAD="$(python3 -c '
import json, sys
print(json.dumps({
    "type": "http",
    "url": sys.argv[1],
    "headers": {"Authorization": "Bearer " + sys.argv[2]},
}))' "$URL" "$TOKEN")"

    if claude mcp add-json "$NAME" "$PAYLOAD" </dev/null >/dev/null 2>&1; then
        registered="add-json"
    fi
fi

if [[ -n "$registered" ]]; then
    echo "both:$CONFIG_JSON"
else
    echo "file:$CONFIG_JSON"
fi
