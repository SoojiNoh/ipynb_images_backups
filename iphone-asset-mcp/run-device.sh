#!/usr/bin/env bash
#
# 연결된 실제 iPhone/iPad 에 AssetBridge 를 빌드·설치·실행한다.
#
#   ./run-device.sh
#
# 시뮬레이터와 달리 실기기는 코드 서명이 필요하다. 먼저 Xcode 에
# Apple ID 를 등록해야 하고(Xcode > Settings > Accounts), 그다음
# ./setup.sh 가 키체인에서 팀 ID 를 읽어 Config/Local.xcconfig 에 적어준다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

LOG="${TMPDIR:-/tmp}/assetbridge-device.log"
: > "$LOG"

step()  { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$1"; printf '==> %s\n' "$1" >> "$LOG"; }
ok()    { printf '    %s✓%s %s\n' "$GREEN" "$OFF" "$1"; printf '    OK: %s\n' "$1" >> "$LOG"; }
warn()  { printf '    %s!%s %s\n' "$YELLOW" "$OFF" "$1"; printf '    WARN: %s\n' "$1" >> "$LOG"; }
note()  { printf '      %s\n' "$1"; printf '      %s\n' "$1" >> "$LOG"; }

copy_log_and_exit() {
    printf '\n'
    if command -v pbcopy >/dev/null 2>&1 && pbcopy < "$LOG" 2>/dev/null; then
        printf '    %s전체 출력을 클립보드에 복사했습니다. 대화창에 ⌘V 로 붙여넣어 주세요.%s\n\n' "$BOLD" "$OFF"
    else
        printf '    전체 출력: %s\n\n' "$LOG"
    fi
    exit 1
}

die() {
    printf '\n    %s✗%s %s\n' "$RED" "$OFF" "$1"
    printf '\n실패: %s\n' "$1" >> "$LOG"
    shift
    for line in "$@"; do note "$line"; done
    copy_log_and_exit
}

# --- 1. 기기 찾기 ------------------------------------------------------------

step "연결된 기기 찾기"

DEVICE_JSON="${TMPDIR:-/tmp}/assetbridge-devices.json"
xcrun devicectl list devices --json-output "$DEVICE_JSON" >>"$LOG" 2>&1
xcrun devicectl list devices >>"$LOG" 2>&1

DEVICE_INFO="$(python3 - "$DEVICE_JSON" <<'PY'
import json, sys

try:
    with open(sys.argv[1]) as handle:
        payload = json.load(handle)
except Exception:
    sys.exit(0)

for device in payload.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    if hardware.get("platform") != "iOS":
        continue
    connection = device.get("connectionProperties", {})
    # 페어링은 됐지만 지금 붙어 있지 않은 기기는 건너뛴다.
    if connection.get("tunnelState") == "unavailable":
        continue
    print("\t".join([
        device.get("identifier", ""),
        hardware.get("udid", ""),
        device.get("deviceProperties", {}).get("name", "iPhone"),
        hardware.get("marketingName", ""),
        connection.get("pairingState", ""),
    ]))
    break
PY
)"

if [[ -z "$DEVICE_INFO" ]]; then
    die "연결된 iPhone 을 찾지 못했습니다." \
        "확인할 것:" \
        "  - 케이블이 데이터 전송용인지 (충전 전용 케이블이 흔한 원인입니다)" \
        "  - iPhone 화면 잠금이 풀려 있는지" \
        "  - iPhone 에 뜬 '이 컴퓨터를 신뢰하시겠습니까?' 에서 신뢰를 눌렀는지" \
        "" \
        "그래도 안 보이면 Xcode > Window > Devices and Simulators 에서 확인하세요."
fi

IFS=$'\t' read -r DEVICE_ID DEVICE_UDID DEVICE_NAME DEVICE_MODEL PAIRING <<<"$DEVICE_INFO"

ok "${DEVICE_NAME}${DEVICE_MODEL:+ ($DEVICE_MODEL)}"
note "UDID $DEVICE_UDID"

if [[ "$PAIRING" == "unpaired" ]]; then
    die "iPhone 이 아직 이 Mac 과 페어링되지 않았습니다." \
        "iPhone 잠금을 풀고 '이 컴퓨터를 신뢰' 를 누른 뒤 다시 실행하세요."
fi

# --- 2. 서명 확인 ------------------------------------------------------------

step "서명 확인"

TEAM_ID=""
if [[ -f Config/Local.xcconfig ]]; then
    TEAM_ID="$(grep -E '^ASSETBRIDGE_TEAM_ID' Config/Local.xcconfig | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]')"
fi

if [[ -z "$TEAM_ID" ]]; then
    # setup.sh 를 안 돌렸거나, 돌렸을 때 아직 인증서가 없었던 경우.
    TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()' | head -1)"
fi

if [[ -z "$TEAM_ID" ]]; then
    die "개발자 팀을 찾지 못했습니다. 실기기 설치에는 반드시 필요합니다." \
        "이 부분은 본인 Apple ID 라 자동화할 수 없습니다:" \
        "" \
        "  1. Xcode 를 연다" \
        "  2. Xcode > Settings (⌘,) > Accounts > 왼쪽 아래 '+' > Apple ID" \
        "  3. 로그인" \
        "  4. 터미널에서  bash setup.sh  를 다시 실행" \
        "  5. 그다음 이 스크립트를 다시 실행" \
        "" \
        "무료 Apple ID 로도 됩니다. 대신 7일마다 재설치해야 합니다."
fi

ok "팀 ID $TEAM_ID"

# --- 3. 기기 준비 상태 --------------------------------------------------------

step "기기 준비 상태"

# devicectl 이 보고하는 기기 속성 하나를 읽는다. 못 읽으면 빈 문자열.
device_flag() {
    xcrun devicectl list devices --json-output "$DEVICE_JSON" >>"$LOG" 2>&1
    python3 - "$DEVICE_JSON" "$DEVICE_ID" "$1" <<'PY'
import json, sys

path, identifier, field = sys.argv[1:4]
try:
    with open(path) as handle:
        payload = json.load(handle)
except Exception:
    raise SystemExit(0)

for device in payload.get("result", {}).get("devices", []):
    if device.get("identifier") != identifier:
        continue
    value = (device.get("deviceProperties") or {}).get(field)
    if isinstance(value, bool):
        print("true" if value else "false")
    elif value is not None:
        print(value)
    break
PY
}

DEV_MODE="$(device_flag developerModeStatus)"
case "$DEV_MODE" in
    enabled)
        ok "개발자 모드 켜짐"
        ;;
    "")
        warn "개발자 모드 상태를 읽지 못했습니다. 그대로 진행합니다."
        ;;
    *)
        die "iPhone 의 개발자 모드가 꺼져 있습니다 (상태: $DEV_MODE)." \
            "iOS 16 부터는 이게 꺼져 있으면 어떤 방법으로도 앱을 설치할 수 없습니다." \
            "기기에서 직접 켜야 합니다 — Mac 에서는 켤 수 없습니다:" \
            "" \
            "  설정 > 개인정보 보호 및 보안 > 개발자 모드 > 켬" \
            "  재시동을 묻습니다. 재시동 뒤 잠금을 풀면 확인 창이 한 번 더 뜹니다." \
            "" \
            "그다음 이 명령을 다시 실행하세요."
        ;;
esac

# DDI(개발자 디스크 이미지)가 기기에 올라가야 xcodebuild 가 이 기기를 목적지로
# 인정한다. devicectl 의 State 열에 'connected (no DDI)' 라고 나오는 그 단계다.
#
# 처음 연결했거나 iOS·Xcode 를 올린 직후에는 준비에 몇 분이 걸리고, 그동안 빌드를
# 걸면 "Device is busy (Waiting to reconnect...)" 로 죽는다. 기다렸다 진행한다.
# devicectl 의 사람이 읽는 출력에서 이 기기 줄의 State 를 본다.
# 'connected (no DDI)' 는 실제로 화면에 찍히는 문자열이라, JSON 필드 이름보다
# Xcode 버전 사이에서 덜 흔들린다. JSON 은 보조로만 쓴다.
#
# 0 = 준비됨, 1 = 아직, 2 = 알 수 없음
ddi_ready() {
    local text json
    text="$(xcrun devicectl list devices 2>>"$LOG" | grep -F "$DEVICE_ID")"
    if [[ -n "$text" ]]; then
        [[ "$text" == *"no DDI"* ]] && return 1
        [[ "$text" == *"connected"* ]] && return 0
    fi

    json="$(device_flag ddiServicesAvailable)"
    [[ "$json" == "true" ]] && return 0
    [[ "$json" == "false" ]] && return 1
    return 2
}

ddi_ready
DDI_STATE=$?

if (( DDI_STATE == 0 )); then
    ok "기기 준비 완료"
elif (( DDI_STATE == 2 )); then
    warn "기기 준비 상태를 읽지 못했습니다. 그대로 진행합니다."
else
    printf '    기기를 준비하는 중입니다(DDI 마운트). 최대 5분 기다립니다'

    # 연결을 한 번 건드려 준비를 앞당긴다. 준비 중에는 이 명령 자체가 오래
    # 걸릴 수 있으므로 뒤에서 돌리고, 끝나면 정리한다.
    ( xcrun devicectl device info details --device "$DEVICE_ID" >>"$LOG" 2>&1 ) &
    NUDGE_PID=$!

    for _ in $(seq 1 60); do
        sleep 5
        printf '.'
        ddi_ready
        DDI_STATE=$?
        (( DDI_STATE == 1 )) || break
    done
    printf '\n'

    kill "$NUDGE_PID" 2>/dev/null
    wait "$NUDGE_PID" 2>/dev/null

    if (( DDI_STATE == 1 )); then
        die "기기가 아직 개발용으로 준비되지 않았습니다 (DDI 미마운트)." \
            "devicectl 이 계속 'connected (no DDI)' 로 보고합니다. 이 상태에서는" \
            "xcodebuild 가 iPhone 을 빌드 대상으로 인정하지 않습니다." \
            "" \
            "기기에서 확인할 것 — 어느 것도 Mac 에서 대신 할 수 없습니다:" \
            "  1. iPhone 잠금을 풀고, 준비가 끝날 때까지 잠기지 않게 두세요" \
            "  2. 설정 > 개인정보 보호 및 보안 > 개발자 모드 가 켜져 있는지" \
            "  3. 케이블을 뽑았다 다시 꽂고 '이 컴퓨터를 신뢰' 를 누르세요" \
            "" \
            "Xcode > Window > Devices and Simulators 를 열어 두면 'Preparing" \
            "device for development' 진행 상황이 보입니다. 끝난 뒤 다시 실행하세요."
    fi

    ok "기기 준비 완료"
fi

# --- 4. 빌드 ----------------------------------------------------------------

step "빌드 및 서명 (처음에는 1~2분 걸립니다)"

# -destination-timeout 을 늘린다. 기본값은 짧아서, 기기가 잠깐 재연결되는 사이에
# "Timed out waiting for all destinations" 로 죽는다. 실제로 흔한 실패다.
run_build() {
    xcodebuild \
        -project AssetBridge.xcodeproj \
        -scheme AssetBridge \
        -configuration Debug \
        -destination "id=$DEVICE_UDID" \
        -destination-timeout 180 \
        -derivedDataPath build \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        build 2>&1
}

BUILD_OUTPUT="$(run_build)"
BUILD_STATUS=$?
printf '%s\n' "$BUILD_OUTPUT" >> "$LOG"

# 기기가 잠깐 자리를 비운 것뿐이라면 한 번 더 해 본다. 컴파일 결과는 이미
# derivedData 에 남아 있으므로 재시도는 훨씬 빠르다.
if (( BUILD_STATUS != 0 )) && [[ "$BUILD_OUTPUT" == *"Device is busy"* \
        || "$BUILD_OUTPUT" == *"Timed out waiting for all destinations"* \
        || "$BUILD_OUTPUT" == *"Waiting to reconnect"* ]]; then
    warn "기기가 재연결 중이라 빌드가 밀렸습니다. 30초 뒤 한 번 더 시도합니다."
    sleep 30
    BUILD_OUTPUT="$(run_build)"
    BUILD_STATUS=$?
    printf '%s\n' "$BUILD_OUTPUT" >> "$LOG"
fi

if (( BUILD_STATUS != 0 )); then
    printf '\n    %s✗%s 빌드 실패\n\n' "$RED" "$OFF"

    if [[ "$BUILD_OUTPUT" == *"requires a development team"* ]]; then
        note "서명 설정이 아직 안 붙었습니다. Xcode 에서 AssetBridge 타겟 >"
        note "Signing & Capabilities > Team 을 직접 골라 주세요."
    elif [[ "$BUILD_OUTPUT" == *"Failed to register bundle identifier"* ]]; then
        note "번들 ID 가 이미 다른 계정에 등록되어 있습니다."
        note "Config/Local.xcconfig 의 ASSETBRIDGE_BUNDLE_ID 를 다른 값으로 바꾸세요."
    elif [[ "$BUILD_OUTPUT" == *"Device is busy"* \
            || "$BUILD_OUTPUT" == *"Timed out waiting for all destinations"* \
            || "$BUILD_OUTPUT" == *"Ineligible destinations"* ]]; then
        note "iPhone 이 빌드 대상으로 인정되지 않는 상태입니다. 기기 쪽 문제입니다:"
        note ""
        note "  - iPhone 잠금을 풀고, 빌드가 끝날 때까지 잠기지 않게 두세요"
        note "  - 설정 > 개인정보 보호 및 보안 > 개발자 모드 가 켜져 있는지 확인"
        note "  - 케이블을 뽑았다 다시 꽂고 '이 컴퓨터를 신뢰' 를 누르세요"
        note ""
        note "Xcode > Window > Devices and Simulators 에서 'Preparing device for"
        note "development' 가 끝났는지 볼 수 있습니다. 끝난 뒤 다시 실행하세요."
    elif [[ "$BUILD_OUTPUT" == *"Unable to find a destination"* ]]; then
        note "기기를 찾지 못했습니다. iPhone 잠금을 풀고 다시 실행하세요."
    fi

    ERRORS="$(printf '%s\n' "$BUILD_OUTPUT" | grep -E '(error|오류):' | sort -u | head -40)"
    if [[ -n "$ERRORS" ]]; then
        printf '\n'
        printf '%s\n' "$ERRORS" | sed 's/^/    /'
    else
        printf '%s\n' "$BUILD_OUTPUT" | tail -30 | sed 's/^/    /'
    fi
    printf '\n실패: 빌드\n' >> "$LOG"
    copy_log_and_exit
fi

APP_PATH="build/Build/Products/Debug-iphoneos/AssetBridge.app"
[[ -d "$APP_PATH" ]] || die "빌드는 성공했는데 앱 번들을 찾지 못했습니다." "찾은 경로: $APP_PATH"

ok "빌드 성공"

# --- 5. 설치 ----------------------------------------------------------------

step "iPhone 에 설치"

if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >>"$LOG" 2>&1; then
    die "설치에 실패했습니다." \
        "iPhone 잠금이 풀려 있는지 확인하고 다시 시도하세요."
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null)"
[[ -n "$BUNDLE_ID" ]] || die "번들 ID 를 읽지 못했습니다."

ok "$BUNDLE_ID"

# --- 6. 실행 ----------------------------------------------------------------

step "실행"

LAUNCH_OUTPUT="$(xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1)"
LAUNCH_STATUS=$?
printf '%s\n' "$LAUNCH_OUTPUT" >> "$LOG"

if (( LAUNCH_STATUS != 0 )); then
    # 무료 계정으로 처음 설치하면 기기에서 개발자를 신뢰해야 실행된다.
    warn "설치는 됐지만 자동 실행에 실패했습니다."
    note "무료 Apple ID 로 설치한 경우, iPhone 에서 개발자를 한 번 신뢰해야 합니다:"
    note ""
    note "  설정 > 일반 > VPN 및 기기 관리 > 본인 계정 > 신뢰"
    note ""
    note "그다음 홈 화면에서 AssetBridge 를 직접 눌러 실행하세요."
    note ""
    note "launch 출력: $LAUNCH_OUTPUT"
else
    ok "실행됨"
fi

# --- 7. 연결 등록 -------------------------------------------------------------

step "Claude Code 에 등록"

# 앱은 뜨자마자 접속 정보를 자기 컨테이너에 남긴다. 개발 서명된 빌드라면 그
# 컨테이너를 Mac 에서 꺼내올 수 있으므로, 토큰을 사람이 옮겨 적을 이유가 없다.
#
# 꺼내오지 못하더라도 막다른 길은 아니다 — 앱 화면의 복사 버튼이 그대로 있다.
# 그래서 여기서 실패해도 스크립트를 죽이지 않고 안내로 넘어간다.
PULLED="${TMPDIR:-/tmp}/assetbridge-connection.json"
rm -f "$PULLED"
COPY_OUTPUT=""
MANUAL=1

pull_connection() {
    xcrun devicectl device copy from \
        --device "$DEVICE_ID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "Library/Application Support/connection.json" \
        --destination "$PULLED" 2>&1
}

for _ in 1 2 3 4 5 6; do
    COPY_OUTPUT="$(pull_connection)"
    printf '%s\n' "$COPY_OUTPUT" >> "$LOG"
    [[ -s "$PULLED" ]] && break
    sleep 2
done

MCP_URL=""; MCP_TOKEN=""
if [[ -s "$PULLED" ]]; then
    read_field() {
        python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    print("")' "$PULLED" "$1"
    }
    MCP_URL="$(read_field url)"
    MCP_TOKEN="$(read_field token)"
fi

if [[ -z "$MCP_URL" || -z "$MCP_TOKEN" ]]; then
    warn "기기에서 접속 정보를 꺼내오지 못했습니다. 앱의 복사 버튼을 쓰면 됩니다."
    note "이유: ${COPY_OUTPUT:-알 수 없음}"
    MANUAL=1
else
    ok "접속 주소 $MCP_URL"

    # 등록하기 전에 실제로 통하는지 확인한다. 여기서 걸리는 것은 대개 토큰이
    # 아니라 두 가지다 — 아직 안 누른 '로컬 네트워크 접근' 허용, 그리고 서로
    # 다른 Wi-Fi. 둘 다 화면을 보고 있는 사람만 고칠 수 있으므로 그렇게 말해 준다.
    printf '    iPhone 응답을 기다립니다. 화면에 %s로컬 네트워크 접근%s 창이 뜨면 허용해 주세요' "$BOLD" "$OFF"

    PROBE_BODY="${TMPDIR:-/tmp}/assetbridge-device-probe.json"
    PROBE_CODE=""
    for _ in $(seq 1 30); do
        PROBE_CODE="$(curl -sS -m 4 -o "$PROBE_BODY" -w '%{http_code}' \
            -X POST "$MCP_URL" \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            -H "Authorization: Bearer $MCP_TOKEN" \
            -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>>"$LOG")"
        [[ "$PROBE_CODE" == "200" ]] && break
        printf '.'
        sleep 2
    done
    printf '\n'

    if [[ "$PROBE_CODE" == "200" ]]; then
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
            *)      warn "등록 결과를 확인하지 못했습니다. 로그를 보세요." ;;
        esac
        MANUAL=0
    else
        warn "iPhone 이 아직 응답하지 않습니다 (HTTP ${PROBE_CODE:-없음})."
        note "토큰 문제가 아닙니다. 셋 중 하나입니다:"
        note "  - 앱에서 '로컬 네트워크 접근' 을 아직 허용하지 않음"
        note "  - Mac 과 iPhone 이 서로 다른 Wi-Fi"
        note "  - 공유기가 기기 간 통신을 막음 (게스트망 / AP 격리)"
        MANUAL=1
    fi
fi

if (( MANUAL )); then
cat <<EOF

${BOLD}다음 단계${OFF}
  1. iPhone 에서 AssetBridge → 우측 상단 ${BOLD}권한 요청${OFF} → 시트 전부 허용
  2. ${BOLD}'로컬 네트워크 접근'${OFF} 은 반드시 허용 — 거부하면 접속이 안 됩니다
  3. 앱의 ${BOLD}'Claude Code 명령 복사'${OFF} → Mac 터미널에 붙여넣기

  ${DIM}그다음 이 스크립트를 다시 돌리면 등록까지 자동으로 됩니다.${OFF}
  ${DIM}Mac 과 iPhone 이 같은 Wi-Fi 여야 합니다.${OFF}

EOF
else
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
fi
