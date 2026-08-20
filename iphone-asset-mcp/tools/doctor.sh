#!/usr/bin/env bash
#
# 연결이 왜 안 되는지 한 번에 본다.
#
#   bash tools/doctor.sh
#
# 아무것도 바꾸지 않는다. 읽고, 서버를 찔러 보고, 결과를 클립보드에 넣는다.
# 몇 번을 다시 돌려도 똑같이 안전하다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

REPORT="${TMPDIR:-/tmp}/assetbridge-doctor.txt"
: > "$REPORT"

# 화면과 보고서에 동시에 남긴다. 화면만 보고 넘어가면 붙여넣을 게 없다.
say()  { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$REPORT"; }
head_() { printf '\n%s%s%s\n' "$BOLD" "$*" "$OFF"; printf '\n== %s\n' "$*" >> "$REPORT"; }
good() { printf '    %s✓%s %s\n' "$GREEN" "$OFF" "$*"; printf '    OK   %s\n' "$*" >> "$REPORT"; }
bad()  { printf '    %s✗%s %s\n' "$RED" "$OFF" "$*"; printf '    FAIL %s\n' "$*" >> "$REPORT"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$OFF" "$*"; printf '    WARN %s\n' "$*" >> "$REPORT"; }
line() { printf '      %s%s%s\n' "$DIM" "$*" "$OFF"; printf '      %s\n' "$*" >> "$REPORT"; }

VERDICT=""
note_problem() { [[ -n "$VERDICT" ]] || VERDICT="$1"; }

# --- 1. 앱이 떠 있는가 --------------------------------------------------------

head_ "1. 시뮬레이터와 앱"

APP_PATH="build/Build/Products/Debug-iphonesimulator/AssetBridge.app"
BUNDLE_ID=""

if [[ -f "$APP_PATH/Info.plist" ]]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null)"
fi
if [[ -z "$BUNDLE_ID" ]]; then
    for config in Config/Local.xcconfig Config/Base.xcconfig; do
        [[ -f "$config" ]] || continue
        BUNDLE_ID="$(grep -E '^ASSETBRIDGE_BUNDLE_ID' "$config" \
            | tail -1 | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]')"
        [[ -n "$BUNDLE_ID" ]] && break
    done
fi

if [[ -z "$BUNDLE_ID" ]]; then
    bad "번들 ID 를 알아내지 못했습니다. 아직 한 번도 빌드하지 않았을 수 있습니다."
    note_problem "빌드부터 하세요:  bash go.sh"
else
    good "번들 ID $BUNDLE_ID"
fi

BOOTED="$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' | head -1)"

CONNECTION=""
if [[ -z "$BOOTED" ]]; then
    warn "켜져 있는 시뮬레이터가 없습니다 (실기기를 쓰는 중이면 정상입니다)."
elif [[ -n "$BUNDLE_ID" ]]; then
    good "시뮬레이터 $BOOTED"
    CONTAINER="$(xcrun simctl get_app_container "$BOOTED" "$BUNDLE_ID" data 2>/dev/null)"
    if [[ -z "$CONTAINER" ]]; then
        bad "이 시뮬레이터에 앱이 설치돼 있지 않습니다."
        note_problem "설치부터 하세요:  bash go.sh"
    else
        CONNECTION="$CONTAINER/Library/Application Support/connection.json"
        if [[ -s "$CONNECTION" ]]; then
            good "접속 정보 있음"
            line "쓰여진 시각: $(date -r "$CONNECTION" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '알 수 없음')"
        else
            bad "앱이 접속 정보를 쓰지 않았습니다 — 앱이 실행되지 않았다는 뜻입니다."
            note_problem "앱을 다시 띄우세요:  bash go.sh"
            CONNECTION=""
        fi
    fi
fi

# --- 2. 앱이 말하는 토큰 ------------------------------------------------------

head_ "2. 앱이 지금 쓰는 값"

json_field() {
    python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    print("")' "$1" "$2" 2>/dev/null
}

APP_URL=""; APP_TOKEN=""
if [[ -n "$CONNECTION" ]]; then
    APP_URL="$(json_field "$CONNECTION" url)"
    APP_TOKEN="$(json_field "$CONNECTION" token)"
fi

if [[ -n "$APP_TOKEN" ]]; then
    good "URL   $APP_URL"
    good "토큰  $APP_TOKEN"
else
    warn "앱에서 직접 읽지 못했습니다. 설정 파일에 적힌 값으로 대신 확인합니다."
fi

# --- 3. 저장된 설정 전부 ------------------------------------------------------

head_ "3. 토큰이 저장된 모든 위치"

GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"

CONFIG_DUMP="$(python3 - "$HOME/.claude.json" "$PWD/.mcp.json" "${GIT_ROOT:-/nonexistent}/.mcp.json" iphone <<'PY'
import json, os, sys

home, project, root, name = sys.argv[1:5]

def token_of(entry):
    header = ((entry or {}).get("headers") or {}).get("Authorization", "")
    return header.replace("Bearer ", "").strip() or "(헤더 없음)"

def rows(label, path, nested):
    if not os.path.exists(path):
        return [(label, "파일 없음", "", "")]
    try:
        with open(path) as handle:
            data = json.load(handle)
    except Exception as exc:
        return [(label, f"읽기 실패 — {exc}", "", "")]

    out = []
    entry = (data.get("mcpServers") or {}).get(name)
    if entry:
        out.append((label, "전역", token_of(entry), entry.get("url", "")))
    if nested:
        for where, blob in (data.get("projects") or {}).items():
            child = ((blob or {}).get("mcpServers") or {}).get(name)
            if child:
                out.append((label, where, token_of(child), child.get("url", "")))
    if not out:
        out.append((label, f"'{name}' 항목 없음", "", ""))
    return out

everything = []
everything += rows("~/.claude.json", home, True)
everything += rows("프로젝트 .mcp.json", project, False)
if root != project:
    everything += rows("저장소 .mcp.json", root, False)

tokens = set()
for label, where, token, url in everything:
    if token and token != "(헤더 없음)":
        tokens.add(token)
    detail = f"{label} [{where}]"
    print(f"{detail}|{token}|{url}")

print(f"__DISTINCT__|{len(tokens)}|{','.join(sorted(tokens))}")
PY
)"

DISTINCT_COUNT=0
CONFIG_TOKENS=""
while IFS='|' read -r detail token url; do
    [[ -z "$detail" ]] && continue
    if [[ "$detail" == "__DISTINCT__" ]]; then
        DISTINCT_COUNT="$token"
        CONFIG_TOKENS="$url"
        continue
    fi
    if [[ -n "$token" ]]; then
        line "$detail  →  $token   $url"
    else
        line "$detail"
    fi
done <<< "$CONFIG_DUMP"

if (( DISTINCT_COUNT > 1 )); then
    bad "설정마다 토큰이 다릅니다 ($CONFIG_TOKENS) — 하나만 맞고 나머지는 401 을 냅니다."
    note_problem "bash go.sh 를 다시 돌리면 전부 같은 값으로 맞춥니다."
elif (( DISTINCT_COUNT == 1 )); then
    good "저장된 토큰은 한 종류입니다 ($CONFIG_TOKENS)"
    [[ -z "$APP_TOKEN" ]] && APP_TOKEN="$CONFIG_TOKENS"
else
    bad "어디에도 'iphone' 항목이 없습니다 — Claude Code 는 이 서버를 모릅니다."
    note_problem "등록하세요:  bash go.sh"
fi

if [[ -n "$APP_TOKEN" && -n "$CONFIG_TOKENS" && "$CONFIG_TOKENS" != *"$APP_TOKEN"* ]]; then
    bad "앱의 토큰($APP_TOKEN)이 설정 어디에도 없습니다."
    note_problem "bash go.sh 를 다시 돌려 등록을 갱신하세요."
fi

# --- 4. 서버를 실제로 찔러 본다 -------------------------------------------------

head_ "4. 서버 응답"

if [[ -z "$APP_URL" ]]; then
    APP_URL="$(printf '%s\n' "$CONFIG_DUMP" | awk -F'|' '$3 ~ /^http/ {print $3; exit}')"
fi

if [[ -z "$APP_URL" ]]; then
    bad "찔러 볼 주소를 찾지 못했습니다."
    note_problem "bash go.sh 를 먼저 돌리세요."
else
    HEALTH_URL="${APP_URL%/mcp}/health"
    HEALTH_CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null)"

    if [[ "$HEALTH_CODE" == "200" ]]; then
        good "서버가 살아 있습니다 ($HEALTH_URL)"
    else
        bad "서버가 응답하지 않습니다 ($HEALTH_URL, HTTP ${HEALTH_CODE:-없음})"
        note_problem "앱이 떠 있는지 확인하고 bash go.sh 를 다시 돌리세요."
    fi

    if [[ "$HEALTH_CODE" == "200" && -n "$APP_TOKEN" ]]; then
        BODY="${TMPDIR:-/tmp}/assetbridge-doctor-body.json"
        AUTH_CODE="$(curl -sS -m 5 -o "$BODY" -w '%{http_code}' \
            -X POST "$APP_URL" \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            -H "Authorization: Bearer $APP_TOKEN" \
            -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null)"

        case "$AUTH_CODE" in
            200)
                COUNT="$(python3 -c 'import json,sys
try:
    print(len(json.load(open(sys.argv[1]))["result"]["tools"]))
except Exception:
    print("?")' "$BODY" 2>/dev/null)"
                good "토큰 통과 — 도구 ${COUNT}개가 보입니다"
                ;;
            401)
                bad "토큰이 거부됐습니다 (401). 설정의 값과 앱의 값이 다릅니다."
                line "응답: $(cat "$BODY" 2>/dev/null)"
                note_problem "bash go.sh 를 다시 돌리세요. 등록 전에 검증까지 합니다."
                ;;
            429)
                bad "인증 실패가 반복돼 차단된 상태입니다 (429)."
                note_problem "앱을 껐다 켜면 풀립니다. 그다음 bash go.sh."
                ;;
            *)
                bad "예상 밖의 응답입니다 (HTTP ${AUTH_CODE:-없음})"
                line "응답: $(cat "$BODY" 2>/dev/null)"
                ;;
        esac
    fi
fi

# --- 5. 결론 ------------------------------------------------------------------

head_ "결론"

if [[ -z "$VERDICT" ]]; then
    good "서버·토큰·설정 모두 정상입니다."
    line "여기서도 /mcp 가 실패한다면 claude 세션이 예전 설정을 쥐고 있는 것입니다."
    line "claude 를 완전히 종료했다가 다시 실행하세요."
else
    say ""
    say "  다음으로 할 일: $VERDICT"
fi

printf '\n'
if command -v pbcopy >/dev/null 2>&1 && pbcopy < "$REPORT" 2>/dev/null; then
    printf '    %s위 내용을 클립보드에 복사했습니다. 대화창에 ⌘V 로 붙여넣어 주세요.%s\n\n' "$BOLD" "$OFF"
else
    printf '    전체 내용: %s\n\n' "$REPORT"
fi
