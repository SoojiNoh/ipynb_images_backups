#!/usr/bin/env bash
#
# 폰으로 되물을 수 있는 통로를 만든다. 한 번만 하면 된다.
#
#   bash tools/setup_telegram.sh          물어보면서 진행 (다시 돌려도 안전)
#   bash tools/setup_telegram.sh --check  지금 상태만 확인
#   bash tools/setup_telegram.sh --remove 설정 지우기
#
# 봇을 만드는 것만은 대신 해 드릴 수 없다. 사용자 본인의 텔레그램 계정으로
# @BotFather 에게 말을 걸어야 나오는 토큰이고, 그 계정에 저는 닿을 수 없다.
# 대신 그 뒤로 필요한 것(대화 번호 찾기, 저장, 검증)은 전부 여기서 한다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'

CONFIG="$HOME/Library/Application Support/AssetBridge/telegram.json"

ok()   { printf '    %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
note() { printf '      %s%s%s\n' "$DIM" "$1" "$OFF"; }
die()  { printf '\n    %s✗%s %s\n\n' "$RED" "$OFF" "$1"; exit 1; }

case "${1:-}" in
--check)
    python3 tools/ask_channel.py --check
    exit $?
    ;;
--remove)
    rm -f "$CONFIG" "$HOME/Library/Application Support/AssetBridge/telegram-offset"
    ok "지웠습니다. 이제 되묻지 않고 알아서 판단합니다."
    exit 0
    ;;
esac

if [[ -f "$CONFIG" ]]; then
    if CURRENT="$(python3 tools/ask_channel.py --check 2>&1)"; then
        ok "이미 연결돼 있습니다 — $CURRENT"
        note "다시 설정하려면 먼저: bash tools/setup_telegram.sh --remove"
        exit 0
    fi
    printf '    설정은 있지만 지금 쓸 수 없습니다 — %s\n' "$CURRENT"
    printf '    다시 연결하겠습니다.\n\n'
fi

TOKEN="${1:-${ASSETBRIDGE_TELEGRAM_TOKEN:-}}"

if [[ -z "$TOKEN" ]]; then
    cat <<EOF

${BOLD}폰에서 봇 하나를 만들어 주세요${OFF} ${DIM}(2분, 무료)${OFF}

  1. 텔레그램에서 ${BOLD}@BotFather${OFF} 를 검색해 대화를 엽니다
  2. ${BOLD}/newbot${OFF} 을 보냅니다
  3. 이름을 묻습니다 → 아무거나 (예: AssetBridge)
  4. 사용자명을 묻습니다 → ${BOLD}_bot${OFF} 으로 끝나야 합니다 (예: soojin_assetbridge_bot)
  5. ${BOLD}123456789:AAE...${OFF} 처럼 생긴 토큰을 줍니다 — 그걸 여기 붙여넣으세요

  ${DIM}이 단계만 자동화할 수 없습니다. 본인 텔레그램 계정으로 받아야 하는 값입니다.${OFF}

EOF
    printf '  토큰: '
    read -r TOKEN
    printf '\n'
fi

TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
[[ -n "$TOKEN" ]] || die "토큰이 비어 있습니다."

# 토큰을 명령줄 인자로 넘기지 않는다. ps 로 남의 눈에 보일 이유가 없다.
if ! ASSETBRIDGE_TELEGRAM_TOKEN="$TOKEN" python3 tools/ask_channel.py --setup; then
    die "연결하지 못했습니다. 위에 찍힌 이유를 보고 다시 시도해 주세요."
fi

ok "연결됐습니다"
note "설정 파일: $CONFIG (본인만 읽을 수 있게 저장했습니다)"

cat <<EOF

${BOLD}한 번 시험해 보세요${OFF}
  ${BOLD}python3 tools/ask_channel.py --ask "잘 오나요?" --choice 네 --choice 아니오${OFF}

  폰에 질문이 뜨고, 거기서 누르거나 답장하면 그 내용이 이 화면에 찍힙니다.

${BOLD}이제 달라지는 것${OFF}
  공유한 항목을 처리하다가 애매한 게 나오면 ${BOLD}폰으로 물어봅니다${OFF}.
  ${DIM}"3시라고만 적혀 있는데 오늘인가요 내일인가요?" 처럼요. 답하면 그대로 진행하고,${OFF}
  ${DIM}4분 안에 답이 없으면 되돌릴 수 있는 쪽으로 진행한 뒤 무엇을 가정했는지 보냅니다.${OFF}

EOF
