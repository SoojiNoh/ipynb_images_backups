#!/usr/bin/env bash
#
# 시뮬레이터에서 AssetBridge 를 빌드·설치·실행한다.
#
#   ./run-simulator.sh                 # 사용 가능한 첫 iPhone 시뮬레이터
#   ./run-simulator.sh "iPhone 15 Pro" # 이름 지정
#
# Xcode 의 실행 대상(destination) UI 를 거치지 않으므로,
# "A build only device cannot be used to run this target" 같은
# 대상 선택 문제와 무관하게 동작한다.
#
# 시뮬레이터의 사진 라이브러리가 비어 있으면 photos_* 도구를 시험할 수 없으므로,
# 저장소에 든 이미지를 처음 한 번 넣어 준다. 연락처·캘린더·걸음수는 여전히 비어 있고,
# 그쪽까지 보려면 진짜 iPhone 이 필요하다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

LOG="${TMPDIR:-/tmp}/assetbridge-run.log"
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

# --- 1. 시뮬레이터 고르기 ----------------------------------------------------

step "시뮬레이터 찾기"

WANTED="${1:-}"
DEVICE_LIST="$(xcrun simctl list devices available 2>&1)"
printf '%s\n' "$DEVICE_LIST" >> "$LOG"

# "    iPhone 15 (UDID) (Shutdown)" 형태에서 이름과 UDID 를 뽑는다.
if [[ -n "$WANTED" ]]; then
    MATCH="$(printf '%s\n' "$DEVICE_LIST" | grep -F "$WANTED (" | head -1)"
    [[ -n "$MATCH" ]] || die "'$WANTED' 시뮬레이터를 찾지 못했습니다." \
        "사용 가능한 목록은 아래 클립보드 내용을 보세요."
else
    MATCH="$(printf '%s\n' "$DEVICE_LIST" | grep -E '^[[:space:]]+iPhone' | head -1)"
    [[ -n "$MATCH" ]] || die "사용 가능한 iPhone 시뮬레이터가 없습니다." \
        "Xcode > Window > Devices and Simulators > Simulators 에서 하나 만들거나," \
        "  xcodebuild -downloadPlatform iOS" \
        "로 런타임을 받으세요."
fi

UDID="$(printf '%s' "$MATCH" | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
NAME="$(printf '%s' "$MATCH" | sed -E 's/^[[:space:]]*(.+) \([0-9A-Fa-f-]{36}\).*/\1/')"

[[ -n "$UDID" ]] || die "시뮬레이터 UDID 를 읽지 못했습니다." "찾은 줄: $MATCH"

ok "$NAME"
note "$UDID"

# --- 2. 부팅 ----------------------------------------------------------------

step "시뮬레이터 부팅"

BOOT_OUTPUT="$(xcrun simctl boot "$UDID" 2>&1)"
printf '%s\n' "$BOOT_OUTPUT" >> "$LOG"
if [[ -n "$BOOT_OUTPUT" && "$BOOT_OUTPUT" != *"Booted"* && "$BOOT_OUTPUT" != *"current state: Booted"* ]]; then
    warn "$BOOT_OUTPUT"
fi

open -a Simulator 2>>"$LOG"
ok "완료"

# --- 3. 샘플 사진 -------------------------------------------------------------

step "샘플 사진 넣기"

# 시뮬레이터의 사진 라이브러리는 사실상 비어 있어서 photos_* 도구를 시험할 수 없다.
# 저장소에 들어 있는 이미지를 한 번만 넣어 둔다.
SEED_MARKER="build/.photos-seeded-$UDID"

if [[ -f "$SEED_MARKER" ]]; then
    ok "이미 넣어두었습니다"
    hint_line="다시 넣으려면: rm $SEED_MARKER"
    printf '      %s%s%s\n' "$DIM" "$hint_line" "$OFF"
else
    SEED_FILES=()
    # 스크린샷이 먼저다. 글자가 있어서 OCR(photos_read_text) 확인에 좋다.
    while IFS= read -r file; do
        [[ -n "$file" ]] && SEED_FILES+=("$file")
    done < <(find ../screenshots -type f \( -name '*.png' -o -name '*.jpg' \) 2>/dev/null | sort | head -20)
    while IFS= read -r file; do
        [[ -n "$file" ]] && SEED_FILES+=("$file")
    done < <(find ../images -type f \( -name '*.png' -o -name '*.jpg' \) -size -3M 2>/dev/null | sort | head -15)

    if (( ${#SEED_FILES[@]} == 0 )); then
        warn "넣을 이미지를 찾지 못해 건너뜁니다."
    elif xcrun simctl addmedia "$UDID" "${SEED_FILES[@]}" >>"$LOG" 2>&1; then
        mkdir -p build && touch "$SEED_MARKER"
        ok "${#SEED_FILES[@]}장 추가 — photos_* 도구를 바로 시험할 수 있습니다"
    else
        warn "사진 추가에 실패했습니다. 클립보드 로그를 확인하세요."
    fi
fi

# --- 4. 빌드 ----------------------------------------------------------------

step "빌드 (처음에는 1~2분 걸립니다)"

BUILD_OUTPUT="$(xcodebuild \
    -project AssetBridge.xcodeproj \
    -scheme AssetBridge \
    -configuration Debug \
    -destination "id=$UDID" \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1)"
BUILD_STATUS=$?
printf '%s\n' "$BUILD_OUTPUT" >> "$LOG"

if (( BUILD_STATUS != 0 )); then
    printf '\n    %s✗%s 빌드 실패\n\n' "$RED" "$OFF"
    # 컴파일 에러만 추려서 보여준다. 전체 로그는 클립보드에 들어간다.
    ERRORS="$(printf '%s\n' "$BUILD_OUTPUT" | grep -E '(error|오류):' | sort -u | head -40)"
    if [[ -n "$ERRORS" ]]; then
        printf '%s\n' "$ERRORS" | sed 's/^/    /'
    else
        printf '%s\n' "$BUILD_OUTPUT" | tail -30 | sed 's/^/    /'
    fi
    printf '\n실패: 빌드\n' >> "$LOG"
    copy_log_and_exit
fi

APP_PATH="build/Build/Products/Debug-iphonesimulator/AssetBridge.app"
[[ -d "$APP_PATH" ]] || die "빌드는 성공했는데 앱 번들을 찾지 못했습니다." "찾은 경로: $APP_PATH"

ok "빌드 성공"

# --- 5. 설치 및 실행 ---------------------------------------------------------

step "설치 및 실행"

if ! xcrun simctl install "$UDID" "$APP_PATH" 2>>"$LOG"; then
    die "시뮬레이터에 설치하지 못했습니다."
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null)"
[[ -n "$BUNDLE_ID" ]] || die "번들 ID 를 읽지 못했습니다."

if ! xcrun simctl launch "$UDID" "$BUNDLE_ID" >>"$LOG" 2>&1; then
    die "앱을 실행하지 못했습니다." "번들 ID: $BUNDLE_ID"
fi

ok "$BUNDLE_ID 실행됨"

cat <<EOF

${BOLD}다음 단계${OFF}
  1. 시뮬레이터 창에서 AssetBridge 앱을 확인하세요.
  2. 우측 상단 ${BOLD}권한 요청${OFF} → 시트 허용 → ${BOLD}시작${OFF}
  3. Mac 에서 연결. 시뮬레이터는 Mac 의 네트워크를 그대로 쓰므로 ${BOLD}127.0.0.1${OFF} 입니다:

     claude mcp add --transport http iphone http://127.0.0.1:8765/mcp \\
       --header "Authorization: Bearer <앱에 표시된 토큰>"

  ${BOLD}시험해 볼 것${OFF} — 사진은 넣어 두었습니다.
     "내 아이폰 사진 몇 장인지 알려줘"    → photos_stats
     "최근 사진들 한눈에 보여줘"           → photos_contact_sheet
     "스크린샷에 적힌 글자 읽어줘"         → photos_read_text (OCR)

  ${DIM}연락처·캘린더·걸음수는 시뮬레이터에 데이터가 없어 비어 있습니다.${OFF}
  ${DIM}Finder 에서 이미지를 시뮬레이터 창에 끌어다 놓으면 사진이 더 추가됩니다.${OFF}

EOF
