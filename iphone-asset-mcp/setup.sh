#!/usr/bin/env bash
#
# AssetBridge 를 Xcode 에서 바로 실행 가능한 상태로 만든다.
#
#   ./setup.sh
#
# 하는 일:
#   1. Xcode 버전이 요구사항(15 이상)을 만족하는지 확인
#   2. 키체인의 개발자 인증서에서 팀 ID 를 찾아 서명 설정을 자동으로 채움
#   3. 번들 ID 를 계정에 맞춰 고유하게 지정
#   4. Xcode 로 프로젝트 열기
#
# 프로젝트 파일(AssetBridge.xcodeproj)은 저장소에 이미 들어 있으므로
# XcodeGen 같은 추가 도구를 설치할 필요가 없다.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

step()  { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$1"; }
ok()    { printf '    %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
warn()  { printf '    %s!%s %s\n' "$YELLOW" "$OFF" "$1"; }
fail()  { printf '    %s✗%s %s\n' "$RED" "$OFF" "$1"; exit 1; }

# --- 1. Xcode ---------------------------------------------------------------

step "Xcode 확인"

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "이 스크립트는 macOS 에서 실행해야 합니다."
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    fail "Xcode 가 설치되어 있지 않습니다. App Store 에서 설치한 뒤 다시 실행하세요."
fi

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"

if [[ -z "$XCODE_MAJOR" ]]; then
    warn "Xcode 버전을 읽지 못했습니다. 계속 진행합니다."
elif (( XCODE_MAJOR < 15 )); then
    fail "Xcode $XCODE_VERSION 입니다. iOS 17 SDK 가 필요해 Xcode 15 이상이어야 합니다."
else
    ok "Xcode $XCODE_VERSION"
fi

if ! xcode-select -p >/dev/null 2>&1; then
    fail "명령줄 도구 경로가 설정되지 않았습니다: sudo xcode-select -s /Applications/Xcode.app"
fi

# --- 2. 서명 ----------------------------------------------------------------

step "서명 설정"

# "Apple Development: 이름 (XXXXXXXXXX)" 형태에서 팀 ID 를 뽑는다.
TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '(\([A-Z0-9]\{10\}\))' \
    | tr -d '()' \
    | head -1 || true)"

if [[ -z "$TEAM_ID" ]]; then
    warn "키체인에서 개발자 인증서를 찾지 못했습니다."
    warn "Xcode 가 열리면 Signing & Capabilities 에서 Team 을 직접 고르세요."
    warn "(Xcode > Settings > Accounts 에서 Apple ID 로그인이 먼저 필요합니다)"
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
// 값을 바꾸고 싶으면 이 파일을 직접 고치거나 setup.sh 를 다시 실행하세요.

ASSETBRIDGE_BUNDLE_ID = ${BUNDLE_ID}
ASSETBRIDGE_TEAM_ID = ${TEAM_ID}
EOF

ok "번들 ID ${BUNDLE_ID}"
ok "Config/Local.xcconfig 작성"

# --- 3. 프로젝트 무결성 ------------------------------------------------------

step "프로젝트 확인"

if [[ ! -f AssetBridge.xcodeproj/project.pbxproj ]]; then
    fail "AssetBridge.xcodeproj 가 없습니다. 저장소를 다시 받아 주세요."
fi

if xcodebuild -list -project AssetBridge.xcodeproj >/dev/null 2>&1; then
    ok "프로젝트 파일 정상"
else
    fail "프로젝트 파일을 읽지 못했습니다: xcodebuild -list -project AssetBridge.xcodeproj"
fi

# --- 4. 열기 ----------------------------------------------------------------

step "Xcode 열기"
open AssetBridge.xcodeproj
ok "완료"

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
