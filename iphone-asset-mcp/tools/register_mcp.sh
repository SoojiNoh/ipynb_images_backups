#!/usr/bin/env bash
#
# MCP 서버를 Claude Code 에 등록한다.
#
#   tools/register_mcp.sh <url> <token> [이름]
#
# claude CLI 는 버전마다 등록 명령이 다르다. `--transport` 는 비교적 최근에
# 생겼고, 그 전에는 `add-json` 을 썼으며, 아예 없던 시절도 있다.
# 그래서 순서대로 시도하고, 전부 실패하면 저장소에 .mcp.json 을 써 둔다.
# (.mcp.json 은 해당 디렉터리에서 claude 를 띄울 때 자동으로 읽힌다.)

set -uo pipefail

URL="${1:?사용법: register_mcp.sh <url> <token> [이름]}"
TOKEN="${2:?사용법: register_mcp.sh <url> <token> [이름]}"
NAME="${3:-iphone}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_JSON="$REPO_ROOT/.mcp.json"

emit_json() {
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
}

if ! command -v claude >/dev/null 2>&1; then
    emit_json
    echo "fallback-json:$CONFIG_JSON"
    exit 0
fi

# 같은 이름이 이미 있으면 갈아끼운다. 스코프별로 지워 본다.
claude mcp remove "$NAME" >/dev/null 2>&1
claude mcp remove "$NAME" --scope user >/dev/null 2>&1
claude mcp remove "$NAME" --scope local >/dev/null 2>&1

# 1) 최신 문법
if claude mcp add --transport http "$NAME" "$URL" \
        --header "Authorization: Bearer $TOKEN" >/dev/null 2>&1; then
    echo "transport"
    exit 0
fi

# 2) add-json — --transport 가 생기기 전 버전
PAYLOAD="$(python3 -c '
import json, sys
print(json.dumps({
    "type": "http",
    "url": sys.argv[1],
    "headers": {"Authorization": "Bearer " + sys.argv[2]},
}))' "$URL" "$TOKEN")"

if claude mcp add-json "$NAME" "$PAYLOAD" >/dev/null 2>&1; then
    echo "add-json"
    exit 0
fi

# 3) 그래도 안 되면 설정 파일을 직접 쓴다.
emit_json
echo "fallback-json:$CONFIG_JSON"
