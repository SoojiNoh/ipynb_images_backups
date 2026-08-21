#!/usr/bin/env bash
#
# 예약 갱신. launchd 가 부른다. 사람이 직접 부를 일은 없지만 불러도 안전하다.
#
# 무료 Apple 계정으로 서명한 앱은 7일 뒤 만료된다. 그때마다 사람이 기억해서
# 명령을 치는 대신, Mac 이 알아서 다시 설치하게 한다.
#
# 조용히 실패하면 안 된다 — 실패한 줄 모르고 있다가 앱이 안 열려야 알게 되면
# 자동화가 없느니만 못하다. 결과를 항상 알림으로 띄운다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

LOG_DIR="$HOME/Library/Logs/AssetBridge"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/refresh-$(date '+%Y%m%d-%H%M%S').log"

# 로그가 무한히 쌓이지 않게 최근 10개만 남긴다.
ls -1t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +11 | while read -r old; do
    rm -f "$old"
done

notify() {
    # 알림 실패가 갱신 실패로 번지지 않게 한다.
    osascript -e "display notification \"$2\" with title \"AssetBridge\" subtitle \"$1\"" \
        >/dev/null 2>&1 || true
}

{
    printf '=== %s 예약 갱신 시작 ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    bash go.sh
    status=$?
    printf '\n=== 종료 코드 %s ===\n' "$status"
    exit "$status"
} >>"$LOG" 2>&1

STATUS=$?

if (( STATUS == 0 )); then
    notify "갱신 완료" "앞으로 6일 더 쓸 수 있습니다."
else
    # 무엇이 필요한지 알림에 담는다. 로그를 열어야만 알 수 있으면 안 본다.
    HINT="아이폰을 같은 Wi-Fi 에 두고 잠금을 푼 뒤 터미널에서 bash go.sh"
    if grep -q "연결된 iPhone 을 찾지 못했습니다" "$LOG" 2>/dev/null; then
        HINT="아이폰이 안 잡힙니다. 케이블을 꽂거나 같은 Wi-Fi 에 두세요."
    elif grep -q "maximum number of registered" "$LOG" 2>/dev/null; then
        HINT="Apple 계정 기기 한도. python3 tools/list_devices.py 로 확인하세요."
    elif grep -q "최신 코드를 받지 못했습니다" "$LOG" 2>/dev/null; then
        HINT="git pull 이 막혔습니다. 저장소에서 직접 해결해 주세요."
    fi
    notify "갱신 실패" "$HINT"
fi

printf '로그: %s\n' "$LOG"
exit "$STATUS"
