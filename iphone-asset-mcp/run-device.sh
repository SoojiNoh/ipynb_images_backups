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

# --- 3. 빌드 ----------------------------------------------------------------

step "빌드 및 서명 (처음에는 1~2분 걸립니다)"

BUILD_OUTPUT="$(xcodebuild \
    -project AssetBridge.xcodeproj \
    -scheme AssetBridge \
    -configuration Debug \
    -destination "id=$DEVICE_UDID" \
    -derivedDataPath build \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    build 2>&1)"
BUILD_STATUS=$?
printf '%s\n' "$BUILD_OUTPUT" >> "$LOG"

if (( BUILD_STATUS != 0 )); then
    printf '\n    %s✗%s 빌드 실패\n\n' "$RED" "$OFF"

    if [[ "$BUILD_OUTPUT" == *"requires a development team"* ]]; then
        note "서명 설정이 아직 안 붙었습니다. Xcode 에서 AssetBridge 타겟 >"
        note "Signing & Capabilities > Team 을 직접 골라 주세요."
    elif [[ "$BUILD_OUTPUT" == *"Failed to register bundle identifier"* ]]; then
        note "번들 ID 가 이미 다른 계정에 등록되어 있습니다."
        note "Config/Local.xcconfig 의 ASSETBRIDGE_BUNDLE_ID 를 다른 값으로 바꾸세요."
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

# --- 4. 설치 ----------------------------------------------------------------

step "iPhone 에 설치"

if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >>"$LOG" 2>&1; then
    die "설치에 실패했습니다." \
        "iPhone 잠금이 풀려 있는지 확인하고 다시 시도하세요."
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null)"
[[ -n "$BUNDLE_ID" ]] || die "번들 ID 를 읽지 못했습니다."

ok "$BUNDLE_ID"

# --- 5. 실행 ----------------------------------------------------------------

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

cat <<EOF

${BOLD}다음 단계${OFF}
  1. iPhone 에서 AssetBridge 앱 → 우측 상단 ${BOLD}권한 요청${OFF} → 시트 전부 허용
  2. ${BOLD}시작${OFF} 버튼
  3. ${BOLD}'로컬 네트워크 접근'${OFF} 프롬프트는 반드시 허용 — 거부하면 접속이 안 됩니다
  4. 앱의 ${BOLD}'Claude Code 명령 복사'${OFF} → Mac 터미널에 붙여넣기

  ${DIM}Mac 과 iPhone 이 같은 Wi-Fi 에 있어야 합니다.${OFF}
  ${DIM}연결 확인:  curl -s http://<앱에 표시된 IP>:8765/health${OFF}

EOF
