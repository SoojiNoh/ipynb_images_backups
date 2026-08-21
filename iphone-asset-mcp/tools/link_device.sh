#!/usr/bin/env bash
#
# 실기기에 이미 설치된 AssetBridge 와 Claude Code 를 연결한다. 빌드하지 않는다.
#
#   bash tools/link_device.sh [기기ID] [번들ID]
#
# 인자를 생략하면 연결된 iOS 기기와 거기 설치된 AssetBridge 를 스스로 찾는다.
# run-device.sh 가 빌드 뒤에 이걸 부르고, 앱을 Xcode 로 직접 실행한 경우에는
# 사람이 이것만 따로 부르면 된다. 몇 번을 다시 돌려도 안전하다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

LOG="${TMPDIR:-/tmp}/assetbridge-link.log"
: > "$LOG"

step()  { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$1"; printf '==> %s\n' "$1" >> "$LOG"; }
ok()    { printf '    %s✓%s %s\n' "$GREEN" "$OFF" "$1"; printf '    OK: %s\n' "$1" >> "$LOG"; }
warn()  { printf '    %s!%s %s\n' "$YELLOW" "$OFF" "$1"; printf '    WARN: %s\n' "$1" >> "$LOG"; }
note()  { printf '      %s\n' "$1"; printf '      %s\n' "$1" >> "$LOG"; }

DEVICE_ID="${1:-}"
BUNDLE_ID="${2:-}"

DEVICE_JSON="${TMPDIR:-/tmp}/assetbridge-link-devices.json"

# --- 기기 찾기 ----------------------------------------------------------------

if [[ -z "$DEVICE_ID" ]]; then
    step "연결된 기기 찾기"
    xcrun devicectl list devices --json-output "$DEVICE_JSON" >>"$LOG" 2>&1

    DEVICE_ID="$(python3 - "$DEVICE_JSON" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        payload = json.load(handle)
except Exception:
    raise SystemExit(0)
for device in payload.get("result", {}).get("devices", []):
    if (device.get("hardwareProperties") or {}).get("platform") != "iOS":
        continue
    if (device.get("connectionProperties") or {}).get("tunnelState") == "unavailable":
        continue
    print(device.get("identifier", ""))
    break
PY
)"

    if [[ -z "$DEVICE_ID" ]]; then
        printf '\n    %s✗%s 연결된 iPhone 을 찾지 못했습니다.\n' "$RED" "$OFF"
        note "케이블을 꽂고 잠금을 푼 뒤 다시 실행하세요."
        exit 1
    fi
    ok "기기 $DEVICE_ID"
fi

# --- 번들 ID 찾기 -------------------------------------------------------------

# 팀을 옮기면 번들 ID 에 팀 ID 가 붙는다. 설정 파일의 값이 실제 설치된 것과
# 다를 수 있으므로, 기기에 실제로 설치된 앱에서 찾는 쪽을 먼저 본다.
if [[ -z "$BUNDLE_ID" ]]; then
    APPS_JSON="${TMPDIR:-/tmp}/assetbridge-link-apps.json"
    xcrun devicectl device info apps --device "$DEVICE_ID" \
        --json-output "$APPS_JSON" >>"$LOG" 2>&1

    BUNDLE_ID="$(python3 - "$APPS_JSON" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        payload = json.load(handle)
except Exception:
    raise SystemExit(0)
apps = (payload.get("result") or {}).get("apps") or []
for app in apps:
    identifier = app.get("bundleIdentifier") or ""
    if "assetbridge" in identifier.lower():
        print(identifier)
        break
PY
)"

    if [[ -z "$BUNDLE_ID" ]] && [[ -f build/Build/Products/Debug-iphoneos/AssetBridge.app/Info.plist ]]; then
        BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
            build/Build/Products/Debug-iphoneos/AssetBridge.app/Info.plist 2>/dev/null)"
    fi

    if [[ -z "$BUNDLE_ID" ]]; then
        printf '\n    %s✗%s 기기에서 AssetBridge 를 찾지 못했습니다.\n' "$RED" "$OFF"
        note "아직 설치되지 않았습니다. 먼저:  bash go.sh"
        exit 1
    fi
fi

step "Claude Code 에 등록"
note "번들 $BUNDLE_ID"

# --- 접속 정보 꺼내기 ----------------------------------------------------------

PULLED="${TMPDIR:-/tmp}/assetbridge-connection.json"
rm -f "$PULLED"
COPY_OUTPUT=""

# 데이터 컨테이너를 지정하면 devicectl 이 사용자 이름을 함께 요구한다:
#
#   Error: If you are targeting a data container, you must specify a username.
#
# iOS 에서 앱이 도는 사용자는 mobile(uid 501)이다. 어느 표기를 받는지는 Xcode
# 버전마다 다르고, 아예 이 옵션이 없던 버전도 있어서 세 가지를 다 시도한다.
copy_connection() {
    local user="$1"
    local args=(device copy from
        --device "$DEVICE_ID"
        --domain-type appDataContainer
        --domain-identifier "$BUNDLE_ID"
        --source "Library/Application Support/connection.json"
        --destination "$PULLED")
    [[ -n "$user" ]] && args+=(--user "$user")
    xcrun devicectl "${args[@]}" 2>&1
}

for _ in 1 2 3 4 5 6; do
    for candidate in mobile 501 ""; do
        COPY_OUTPUT="$(copy_connection "$candidate")"
        printf '%s\n' "$COPY_OUTPUT" >> "$LOG"
        [[ -s "$PULLED" ]] && break 2
    done
    sleep 2
done

if [[ ! -s "$PULLED" ]]; then
    warn "기기에서 접속 정보를 꺼내오지 못했습니다."
    note "이유: ${COPY_OUTPUT:-알 수 없음}"
    note ""
    note "앱이 한 번이라도 실행돼야 이 파일이 생깁니다. iPhone 에서 AssetBridge 를"
    note "열어 두고 다시 실행하거나, 앱의 'Claude Code 명령 복사' 를 쓰세요."
    exit 1
fi

read_field() {
    python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    print("")' "$PULLED" "$1"
}

MCP_URL="$(read_field url)"
MCP_TOKEN="$(read_field token)"
HOSTNAME_URL="$(read_field hostname_url)"

if [[ -z "$MCP_URL" || -z "$MCP_TOKEN" ]]; then
    warn "접속 정보를 읽지 못했습니다: $PULLED"
    exit 1
fi

# 응답을 확인하는 공용 루틴. 주소만 바꿔 가며 쓴다.
probe_url() {
    curl -sS -m 4 -o "$PROBE_BODY" -w '%{http_code}' \
        -X POST "$1" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "Authorization: Bearer $MCP_TOKEN" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>>"$LOG"
}

PROBE_BODY="${TMPDIR:-/tmp}/assetbridge-link-probe.json"

PORT="$(read_field port)"
[[ -n "$PORT" ]] || PORT=8765

# 주소를 고르는 순서. 위에 있을수록 오래 간다.
#
#   1. ASSETBRIDGE_HOST  — 사람이 직접 지정
#   2. Tailscale         — 다른 Wi-Fi, LTE, 어디서든. 주소가 고정
#   3. <이름>.local      — 같은 LAN 안에서만. DHCP 가 IP 를 바꿔도 버팀
#   4. LAN IP            — 지금 이 순간에만 맞는 주소
#
# 어느 것도 믿고 쓰지 않는다. 전부 실제로 찔러 보고, 200 이 오는 첫 번째를 쓴다.

# Tailscale 로 붙어 있는 iOS 기기를 찾는다.
#
# CLI 는 Homebrew 설치본과 App Store 설치본의 경로가 다르다. 둘 다 본다.
tailscale_cli() {
    if command -v tailscale >/dev/null 2>&1; then
        echo tailscale
    elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
        echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
    fi
}

tailscale_ios_hosts() {
    local cli; cli="$(tailscale_cli)"
    [[ -n "$cli" ]] || return 0
    # 이름을 맞춰 찾지 않고 iOS 피어만 추려 낸다. 이름은 사람이 바꾸지만
    # OS 는 안 바뀐다. 토큰이 틀린 곳에는 어차피 401 이 돌아온다.
    "$cli" status --json 2>>"$LOG" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for peer in (data.get("Peer") or {}).values():
    if (peer.get("OS") or "").lower() != "ios":
        continue
    if not peer.get("Online", False):
        continue
    for address in peer.get("TailscaleIPs") or []:
        if ":" not in address:          # IPv4 만. curl 에 넣기 쉽다.
            print(address)
' 2>>"$LOG"
}

CANDIDATES=()
[[ -n "${ASSETBRIDGE_HOST:-}" ]] && CANDIDATES+=("http://${ASSETBRIDGE_HOST}:${PORT}/mcp")
while read -r ts_ip; do
    [[ -n "$ts_ip" ]] && CANDIDATES+=("http://${ts_ip}:${PORT}/mcp")
done < <(tailscale_ios_hosts)
[[ -n "$HOSTNAME_URL" ]] && CANDIDATES+=("$HOSTNAME_URL")

for candidate in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    [[ "$(probe_url "$candidate")" == "200" ]] || continue
    MCP_URL="$candidate"
    case "$candidate" in
        *//100.*|*//"${ASSETBRIDGE_HOST:-@@none@@}":*)
            ok "Tailscale 로 붙습니다 — 다른 Wi-Fi 나 LTE 에서도 그대로 됩니다" ;;
        *.local:*)
            ok "이름으로 붙습니다 — 같은 Wi-Fi 안에서 IP 가 바뀌어도 따라갑니다" ;;
        *)
            ok "지정하신 주소로 붙습니다" ;;
    esac
    break
done

if [[ "$MCP_URL" != http://100.* && "$MCP_URL" != *.local:* ]]; then
    note "지금은 이 Wi-Fi 안에서만 됩니다. 어디서나 쓰려면 Tailscale 을 깔아 주세요:"
    note "  Mac·아이폰 양쪽에 설치 후 같은 계정으로 로그인 → 이 스크립트를 다시 실행"
fi

ok "접속 주소 $MCP_URL"

# --- 실제로 통하는지 확인 -------------------------------------------------------

# 여기서 걸리는 건 대개 토큰이 아니라 두 가지다 — 아직 안 누른 '로컬 네트워크
# 접근' 허용, 그리고 서로 다른 Wi-Fi. 둘 다 화면을 보는 사람만 고칠 수 있다.
printf '    iPhone 응답을 기다립니다. 화면에 %s로컬 네트워크 접근%s 창이 뜨면 허용해 주세요' "$BOLD" "$OFF"

PROBE_CODE=""
for _ in $(seq 1 30); do
    PROBE_CODE="$(probe_url "$MCP_URL")"
    [[ "$PROBE_CODE" == "200" ]] && break
    printf '.'
    sleep 2
done
printf '\n'

if [[ "$PROBE_CODE" != "200" ]]; then
    warn "iPhone 이 응답하지 않습니다 (HTTP ${PROBE_CODE:-없음})."
    note "토큰 문제가 아닙니다. 셋 중 하나입니다:"
    note "  - 앱에서 '로컬 네트워크 접근' 을 아직 허용하지 않음"
    note "  - Mac 과 iPhone 이 서로 다른 Wi-Fi"
    note "  - 공유기가 기기 간 통신을 막음 (게스트망 / AP 격리)"
    note ""
    note "앱 화면 상단의 '실행 중' 과 초록 불도 확인해 주세요."
    exit 1
fi

TOOL_COUNT="$(python3 -c 'import json,sys
try:
    print(len(json.load(open(sys.argv[1]))["result"]["tools"]))
except Exception:
    print("?")' "$PROBE_BODY" 2>/dev/null)"
ok "iPhone 이 응답했습니다 — 도구 ${TOOL_COUNT}개"

RESULT="$(bash tools/register_mcp.sh "$MCP_URL" "$MCP_TOKEN" iphone 2>>"$LOG")"
case "$RESULT" in
    both:*) ok "'iphone' 으로 등록 완료 — 어느 폴더에서 claude 를 띄워도 붙습니다" ;;
    file:*) ok "설정 파일에 기록: ${RESULT#file:}" ;;
    *)      warn "등록 결과를 확인하지 못했습니다. 로그: $LOG" ;;
esac

cat <<EOF

${BOLD}다음 단계${OFF}
  1. 열려 있는 claude 세션이 있으면 ${BOLD}종료했다가 다시${OFF} 실행하세요.
     설정은 세션이 뜰 때 한 번만 읽힙니다.
  2. ${BOLD}/mcp${OFF} 로 'iphone' 확인 — 토큰은 위에서 이미 통과시켜 봤습니다.
  3. iPhone 앱에서 ${BOLD}권한 요청${OFF} → 시트 전부 허용.
     허용한 도메인만 Claude 에게 보입니다.

  ${DIM}앱이 화면에 떠 있는 동안 확실히 동작합니다. 잠금 화면에서도 유지하려면${OFF}
  ${DIM}앱 설정의 '백그라운드 유지' 를 켜세요.${OFF}

EOF
