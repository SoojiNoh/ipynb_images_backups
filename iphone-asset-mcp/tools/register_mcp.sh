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
#
# 또한 `command` 를 앞에 붙인다. 사용자 셸에서 claude 가 함수나 별칭으로
# 래핑돼 있으면 하위 명령이 프롬프트로 넘어가 버린다. command 는 그 래핑을
# 건너뛰고 실제 실행 파일을 부른다.

set -uo pipefail

URL="${1:?사용법: register_mcp.sh <url> <token> [이름]}"
TOKEN="${2:?사용법: register_mcp.sh <url> <token> [이름]}"
NAME="${3:-iphone}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_JSON="$REPO_ROOT/.mcp.json"

# .mcp.json 은 claude 를 **실행한 폴더**에서만 읽힌다. 사용자가 저장소 최상위에서
# claude 를 띄우는 일이 흔하므로 거기에도 같이 써 둔다. 한쪽만 쓰면 CLI 전역 등록이
# 실패했을 때 정작 사용자가 있는 폴더에는 아무것도 없게 된다.
GIT_ROOT="$(cd "$REPO_ROOT" && git rev-parse --show-toplevel 2>/dev/null)"

TARGETS=("$CONFIG_JSON")
if [[ -n "$GIT_ROOT" && "$GIT_ROOT/.mcp.json" != "$CONFIG_JSON" ]]; then
    TARGETS+=("$GIT_ROOT/.mcp.json")
fi

# --- 1. 설정 파일: 항상, 무조건 ------------------------------------------------

for target in "${TARGETS[@]}"; do
python3 - "$NAME" "$URL" "$TOKEN" "$target" <<'PY'
import json, os, sys
name, url, token, path = sys.argv[1:5]

config = {}
if os.path.exists(path):
    try:
        with open(path) as handle:
            config = json.load(handle)
    except Exception:
        config = {}

servers = config.setdefault("mcpServers", {})

# 예전 버전이 남긴 쓰레기 항목을 걷어낸다. 이름이 비었거나 주소가 없는 항목이
# 하나라도 있으면 Claude Code 가 설정 전체를 못 읽을 수 있고, 그러면 방금 쓴
# 정상 항목까지 같이 무시된다. 남의 서버는 건드리지 않는다 — 망가진 것만 뺀다.
for key in [k for k, v in servers.items()
            if not k.strip() or not isinstance(v, dict) or not v.get("url")]:
    del servers[key]

servers[name] = {
    "type": "http",
    "url": url,
    "headers": {"Authorization": f"Bearer {token}"},
}

with open(path, "w") as handle:
    json.dump(config, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY
done

if ! command -v claude >/dev/null 2>&1; then
    echo "file:$CONFIG_JSON"
    exit 0
fi

# --- 2. 전역 등록: 지원이 확인될 때만 ------------------------------------------

# 도움말 호출에도 </dev/null 을 붙인다. `mcp` 하위 명령이 없는 버전이면
# 이것조차 대화 세션으로 흘러갈 수 있다.
MCP_HELP="$(command claude mcp --help </dev/null 2>&1)"
if [[ "$MCP_HELP" != *"add"* ]]; then
    echo "file:$CONFIG_JSON"
    exit 0
fi

# 등록을 시도하든 말든, 기존 항목은 **항상** 먼저 지운다.
#
# 설정은 두 군데에 있을 수 있다 — CLI 가 쓰는 ~/.claude.json 과 여기서 만드는
# .mcp.json. 앞의 것이 우선하므로, 낡은 토큰이 담긴 CLI 항목을 남겨두면
# 방금 갱신한 .mcp.json 이 무시되고 401 이 난다.
command claude mcp remove "$NAME" </dev/null >/dev/null 2>&1
command claude mcp remove "$NAME" --scope local </dev/null >/dev/null 2>&1
command claude mcp remove "$NAME" --scope project </dev/null >/dev/null 2>&1
command claude mcp remove "$NAME" --scope user </dev/null >/dev/null 2>&1

ADD_HELP="$(command claude mcp add --help </dev/null 2>&1)"
registered=""

if [[ "$ADD_HELP" == *"--transport"* ]]; then
    if command claude mcp add --transport http "$NAME" "$URL" \
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

    if command claude mcp add-json "$NAME" "$PAYLOAD" </dev/null >/dev/null 2>&1; then
        registered="add-json"
    fi
fi

# --- 3. 마지막 청소: ~/.claude.json 안에 남은 항목 전부 갱신 ---------------------

# CLI 의 remove 는 버전마다 아는 스코프가 다르다. 모르는 스코프에 있는 항목은
# 조용히 살아남아 방금 쓴 값을 가린다 — 그러면 401 이고, 화면만 봐서는
# 어느 파일이 범인인지 알 수 없다. 남아 있는 'iphone' 항목을 전부 찾아
# 같은 값으로 맞춘다. 지우지 않고 덮어쓰므로 되돌릴 것도 없다.
python3 - "$HOME/.claude.json" "$NAME" "$URL" "$TOKEN" <<'PY'
import json, os, sys

path, name, url, token = sys.argv[1:5]
if not os.path.exists(path):
    raise SystemExit(0)

try:
    with open(path) as handle:
        config = json.load(handle)
except Exception:
    # 읽을 수 없으면 손대지 않는다. 남의 설정을 추측으로 고치는 쪽이 더 나쁘다.
    raise SystemExit(0)

fresh = {"type": "http", "url": url, "headers": {"Authorization": f"Bearer {token}"}}

def refresh(servers):
    if isinstance(servers, dict) and name in servers:
        servers[name] = dict(fresh)
        return 1
    return 0

changed = refresh(config.get("mcpServers"))
for blob in (config.get("projects") or {}).values():
    if isinstance(blob, dict):
        changed += refresh(blob.get("mcpServers"))

if not changed:
    raise SystemExit(0)

# 원자적으로 바꾼다. 중간에 죽어도 원본이 반쪽짜리로 남지 않는다.
temp = path + ".assetbridge.tmp"
with open(temp, "w") as handle:
    json.dump(config, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
os.replace(temp, path)
PY

if [[ -n "$registered" ]]; then
    echo "both:$CONFIG_JSON"
else
    echo "file:$CONFIG_JSON"
fi
