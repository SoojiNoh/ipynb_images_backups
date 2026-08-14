#!/usr/bin/env bash
#
# AssetBridge 를 Xcode 에서 바로 실행 가능한 상태로 만든다.
#
#   ./setup.sh
#
# 하는 일:
#   1. Xcode 가 제대로 설치·활성화되어 있는지 확인
#   2. 키체인의 개발자 인증서에서 팀 ID 를 찾아 서명 설정을 자동으로 채움
#   3. 프로젝트 파일이 실제로 읽히는지 확인
#   4. Xcode 로 열기
#
# 어느 단계에서 실패하든 원인과 함께 진단 정보를 클립보드에 복사한다.
# 프로젝트 파일은 저장소에 들어 있으므로 추가 도구 설치는 필요 없다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

LOG="${TMPDIR:-/tmp}/assetbridge-setup.log"
: > "$LOG"

record() { printf '%s\n' "$*" >> "$LOG"; }
step()   { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$1"; record "==> $1"; }
ok()     { printf '    %s✓%s %s\n' "$GREEN" "$OFF" "$1"; record "    OK: $1"; }
warn()   { printf '    %s!%s %s\n' "$YELLOW" "$OFF" "$1"; record "    WARN: $1"; }
note()   { printf '      %s\n' "$1"; record "      $1"; }

# 명령을 돌리고 출력을 로그에 남긴다. 출력은 $CAPTURED 에 담긴다.
CAPTURED=""
run() {
    record "--- \$ $* ---"
    CAPTURED="$("$@" 2>&1)"
    local status=$?
    record "${CAPTURED:-(출력 없음)}"
    record "--- exit $status ---"
    return $status
}

collect_diagnostics() {
    record ""
    record "================ 진단 정보 ================"
    record "시각: $(date)"
    record "작업 경로: $PWD"
    run sw_vers
    run uname -a
    run xcode-select -p
    run xcodebuild -version
    record "--- \$ ls -d /Applications/Xcode*.app ---"
    record "$(ls -d /Applications/Xcode*.app 2>&1)"
    run git -C .. log --oneline -3
    run git -C .. status --short
    record "--- \$ ls -la ---"
    record "$(ls -la 2>&1)"
    record "--- \$ ls -la AssetBridge.xcodeproj ---"
    record "$(ls -la AssetBridge.xcodeproj 2>&1)"
    run python3 tools/validate_pbxproj.py
    run xcodebuild -list -project AssetBridge.xcodeproj
    record "==========================================="
}

abort() {
    printf '\n    %s✗%s %s\n' "$RED" "$OFF" "$1"
    record ""
    record "실패: $1"
    shift
    for line in "$@"; do note "$line"; done

    collect_diagnostics

    printf '\n'
    if command -v pbcopy >/dev/null 2>&1 && pbcopy < "$LOG" 2>/dev/null; then
        printf '    %s진단 정보를 클립보드에 복사했습니다.%s\n' "$BOLD" "$OFF"
        printf '    대화창에 %s⌘V%s 로 붙여넣어 주세요. 그러면 원인을 특정할 수 있습니다.\n\n' "$BOLD" "$OFF"
    else
        printf '    진단 정보를 저장했습니다: %s\n' "$LOG"
        printf '    %scat "%s" | pbcopy%s 로 복사해 붙여넣어 주세요.\n\n' "$BOLD" "$LOG" "$OFF"
    fi
    exit 1
}

# --- 1. Xcode ---------------------------------------------------------------

step "Xcode 확인"

if [[ "$(uname -s)" != "Darwin" ]]; then
    abort "이 스크립트는 macOS 에서 실행해야 합니다."
fi

# Command Line Tools 만 설치해도 xcodebuild 와 xcode-select 는 존재한다.
# 그 상태로는 프로젝트를 열 수도 빌드할 수도 없으므로 Xcode.app 자체를 확인한다.
ACTIVE_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null)"

if [[ -z "$ACTIVE_DEVELOPER_DIR" ]]; then
    abort "개발자 도구 경로가 설정되어 있지 않습니다." \
          "Xcode 를 설치한 뒤 다시 실행하세요."
fi

if [[ "$ACTIVE_DEVELOPER_DIR" != *".app/Contents/Developer" ]]; then
    INSTALLED_XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
    if [[ -n "$INSTALLED_XCODE" ]]; then
        abort "Xcode.app 이 아니라 Command Line Tools 가 활성화되어 있습니다." \
              "현재 경로: $ACTIVE_DEVELOPER_DIR" \
              "" \
              "Xcode 는 설치되어 있습니다. 아래를 그대로 실행한 뒤 이 스크립트를 다시 돌리세요:" \
              "" \
              "    sudo xcode-select -s $INSTALLED_XCODE" \
              "" \
              "비밀번호를 물어봅니다. 입력해도 화면에 안 찍히는 게 정상입니다."
    fi
    abort "Xcode.app 이 설치되어 있지 않습니다." \
          "현재 경로: $ACTIVE_DEVELOPER_DIR" \
          "App Store 에서 Xcode 를 설치하고, 한 번 실행해 약관에 동의한 뒤 다시 시도하세요."
fi

if ! run xcodebuild -version; then
    if [[ "$CAPTURED" == *"license"* || "$CAPTURED" == *"agree"* || "$CAPTURED" == *"동의"* ]]; then
        abort "Xcode 사용권 계약에 아직 동의하지 않았습니다." \
              "아래를 실행한 뒤 이 스크립트를 다시 돌리세요:" \
              "" \
              "    sudo xcodebuild -license accept"
    fi
    abort "xcodebuild 가 실패했습니다." "출력: ${CAPTURED:-(없음)}"
fi

XCODE_VERSION="$(printf '%s' "$CAPTURED" | head -1 | awk '{print $2}')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"

if [[ -z "$XCODE_MAJOR" ]]; then
    abort "Xcode 버전을 읽지 못했습니다." "xcodebuild 출력: ${CAPTURED:-(없음)}"
elif (( XCODE_MAJOR < 15 )); then
    abort "Xcode $XCODE_VERSION 입니다." \
          "이 앱은 iOS 17 SDK 를 쓰므로 Xcode 15 이상이 필요합니다." \
          "App Store 에서 Xcode 를 업데이트하세요."
fi

ok "Xcode $XCODE_VERSION"
note "$ACTIVE_DEVELOPER_DIR"

# --- 2. 서명 ----------------------------------------------------------------

step "서명 설정"

# "Apple Development: 이름 (XXXXXXXXXX)" 형태에서 팀 ID 를 뽑는다.
TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '\([A-Z0-9]{10}\)' \
    | tr -d '()' \
    | head -1)"

if [[ -z "$TEAM_ID" ]]; then
    warn "키체인에서 개발자 인증서를 찾지 못했습니다."
    note "Xcode > Settings > Accounts 에서 Apple ID 로 로그인하면 자동으로 만들어집니다."
    note "지금은 그냥 진행합니다. Xcode 에서 Team 을 직접 골라도 됩니다."
else
    ok "팀 ID $TEAM_ID"
fi

# 번들 ID 는 전 세계에서 고유해야 하므로 macOS 계정명을 섞는다.
ACCOUNT="$(id -un | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
[[ -n "$ACCOUNT" ]] || ACCOUNT="local"
BUNDLE_ID="com.${ACCOUNT}.assetbridge"

mkdir -p Config
cat > Config/Local.xcconfig <<EOF
// setup.sh 가 생성한 파일입니다. 커밋되지 않습니다.
// 값을 바꾸려면 이 파일을 직접 고치거나 setup.sh 를 다시 실행하세요.

ASSETBRIDGE_BUNDLE_ID = ${BUNDLE_ID}
ASSETBRIDGE_TEAM_ID = ${TEAM_ID}
EOF

ok "번들 ID ${BUNDLE_ID}"

# --- 3. 프로젝트 무결성 ------------------------------------------------------

step "프로젝트 확인"

# 추적 중인 파일이 로컬에서만 지워진 경우 git 이 되살려 준다.
# (git pull 은 가져올 커밋이 없으면 지워진 파일을 복구하지 않는다.)
DELETED_FILES="$(git -C .. ls-files --deleted -- "$(basename "$PWD")" 2>/dev/null)"
if [[ -n "$DELETED_FILES" ]]; then
    warn "로컬에서 지워진 파일 $(printf '%s\n' "$DELETED_FILES" | wc -l | tr -d ' ')개를 복구합니다."
    # shellcheck disable=SC2086
    if git -C .. checkout -- $DELETED_FILES 2>>"$LOG"; then
        ok "복구 완료"
    else
        warn "복구에 실패했습니다."
    fi
fi

if [[ ! -f AssetBridge.xcodeproj/project.pbxproj ]]; then
    abort "AssetBridge.xcodeproj 가 없습니다." \
          "저장소를 최신으로 받으세요:" \
          "" \
          "    git -C .. pull origin claude/iphone-asset-access-mcp-ja9w53"
fi

if ! run xcodebuild -list -project AssetBridge.xcodeproj; then
    abort "Xcode 가 프로젝트 파일을 읽지 못했습니다." \
          "xcodebuild 출력: ${CAPTURED:-(없음)}"
fi

ok "프로젝트 파일 정상"

# --- 4. 열기 ----------------------------------------------------------------

step "Xcode 열기"

XCODE_APP="${ACTIVE_DEVELOPER_DIR%/Contents/Developer}"

if run open -a "$XCODE_APP" AssetBridge.xcodeproj; then
    ok "완료 — $XCODE_APP"
else
    warn "자동으로 열지 못했습니다. Finder 에서 직접 더블클릭하세요:"
    note "$PWD/AssetBridge.xcodeproj"
    note "open 출력: ${CAPTURED:-(없음)}"
fi

cat <<EOF

${BOLD}다음 단계${OFF}
  1. iPhone 을 케이블로 연결하고 Xcode 상단 기기 선택창에서 고르세요.
  2. ${BOLD}⌘R${OFF} 로 빌드 및 실행.
     ${DIM}빨간 서명 오류가 보이면 타겟 > Signing & Capabilities 에서 Team 을 선택하세요.${OFF}
  3. iPhone: 설정 > 일반 > VPN 및 기기 관리 > 본인 계정 > 신뢰
     ${DIM}무료 Apple ID 로 설치한 경우에만 필요합니다.${OFF}
  4. 앱 실행 → 우측 상단 '권한 요청' → 전부 허용 → '시작'
  5. ${BOLD}'로컬 네트워크 접근'${OFF} 프롬프트는 반드시 허용해야 합니다.
  6. 앱의 'Claude Code 명령 복사' 를 눌러 터미널에 붙여넣기.

EOF
