#!/usr/bin/env bash
#
# 하나만 기억하면 되는 명령.
#
#   ./go.sh
#
# 최신 코드를 받고, 환경을 점검하고, 서명을 붙이고, 빌드해서, 실행한다.
# iPhone 이 연결돼 있으면 iPhone 에, 아니면 시뮬레이터에 올린다.
# 몇 번을 다시 돌려도 안전하다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

BOLD=$'\033[1m'; DIM=$'\033[2m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; OFF=$'\033[0m'

banner() { printf '\n%s%s%s\n' "$BOLD" "$1" "$OFF"; }
info()   { printf '    %s\n' "$1"; }
hint()   { printf '    %s%s%s\n' "$DIM" "$1" "$OFF"; }

# --- 1. 최신 코드 ------------------------------------------------------------

banner "1/3  최신 코드 받기"

BRANCH="$(git -C .. rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [[ -z "$BRANCH" || "$BRANCH" == "HEAD" ]]; then
    hint "git 저장소가 아니거나 브랜치를 알 수 없어 건너뜁니다."
elif git -C .. pull --ff-only origin "$BRANCH" 2>&1 | sed 's/^/    /'; then
    :
else
    printf '    %s!%s pull 을 건너뜁니다 (로컬 변경이 있거나 네트워크 문제).\n' "$YELLOW" "$OFF"
    hint "이미 받아둔 코드로 계속 진행합니다."
fi

# --- 2. 환경 점검 및 서명 -----------------------------------------------------

banner "2/3  환경 점검"

if ! bash setup.sh --no-open; then
    # setup.sh 가 원인과 해결 방법을 이미 출력했고 진단도 클립보드에 넣었다.
    exit 1
fi

# --- 3. 실행 대상 고르기 ------------------------------------------------------

banner "3/3  실행"

DEVICE_JSON="${TMPDIR:-/tmp}/assetbridge-go-devices.json"
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1

HAS_DEVICE="$(python3 - "$DEVICE_JSON" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        payload = json.load(handle)
except Exception:
    print("no"); raise SystemExit
for device in payload.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    if (hardware.get("platform") == "iOS"
            and connection.get("tunnelState") != "unavailable"
            and connection.get("pairingState") != "unpaired"):
        print("yes"); raise SystemExit
print("no")
PY
)"

HAS_TEAM=""
if [[ -f Config/Local.xcconfig ]]; then
    HAS_TEAM="$(grep -E '^ASSETBRIDGE_TEAM_ID' Config/Local.xcconfig \
        | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]')"
fi

if [[ "$HAS_DEVICE" == "yes" && -n "$HAS_TEAM" ]]; then
    info "연결된 iPhone 에 설치합니다."
    exec bash run-device.sh
fi

if [[ "$HAS_DEVICE" == "yes" && -z "$HAS_TEAM" ]]; then
    printf '    %s!%s iPhone 은 연결돼 있지만 서명할 개발자 팀이 없습니다.\n' "$YELLOW" "$OFF"
    info ""
    info "실기기에 설치하려면 본인 Apple ID 가 필요합니다. 이 부분만은 자동화할 수 없습니다:"
    info ""
    info "  Xcode > Settings (⌘,) > Accounts > 왼쪽 아래 '+' > Apple ID 로 로그인"
    info "  그다음 ./go.sh 를 다시 실행하면 나머지는 알아서 됩니다."
    info ""
    info "지금은 시뮬레이터로 진행합니다. 빌드와 연결은 여기서 확인할 수 있습니다."
    info ""
fi

if [[ "$HAS_DEVICE" != "yes" ]]; then
    hint "연결된 iPhone 이 없어 시뮬레이터로 진행합니다."
    hint "(실기기를 쓰려면 케이블 연결 후 잠금을 풀고 다시 실행하세요.)"
fi

exec bash run-simulator.sh
