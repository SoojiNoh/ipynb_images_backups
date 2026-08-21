#!/usr/bin/env bash
#
# 6일마다 앱을 다시 설치하도록 Mac 에 예약을 건다.
#
#   bash tools/install_schedule.sh          예약 걸기 (다시 걸어도 안전)
#   bash tools/install_schedule.sh --remove 예약 지우기
#
# 무료 Apple 계정 서명은 7일 뒤 만료된다. Claude 는 클라우드에 있어서 이 Mac 의
# Xcode·키체인·연결된 아이폰에 닿을 수 없다 — 그러니 Mac 이 스스로 하게 한다.
# launchd 는 Mac 이 자고 있었으면 깨어난 뒤에 밀린 작업을 실행한다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
PROJECT_DIR="$(pwd)"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'

LABEL="com.assetbridge.refresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL=$((6 * 24 * 60 * 60))   # 6일. 7일 만료 하루 전에 갱신한다.

ok()   { printf '    %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
note() { printf '      %s%s%s\n' "$DIM" "$1" "$OFF"; }
die()  { printf '\n    %s✗%s %s\n\n' "$RED" "$OFF" "$1"; exit 1; }

unload() {
    # 최신 문법을 먼저, 안 되면 옛 문법으로. 둘 다 실패해도 진행한다
    # (애초에 걸려 있지 않았다는 뜻이다).
    launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 \
        || launchctl unload "$PLIST" >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--remove" ]]; then
    unload
    rm -f "$PLIST"
    ok "예약을 지웠습니다."
    note "앱은 그대로 있습니다. 만료되면 bash go.sh 로 직접 갱신하세요."
    exit 0
fi

[[ -f "$PROJECT_DIR/go.sh" ]] || die "go.sh 를 찾지 못했습니다: $PROJECT_DIR"

mkdir -p "$HOME/Library/LaunchAgents"

# launchd 는 최소한의 PATH 만 준다. xcrun·git·python3 를 찾지 못하면 조용히 죽는다.
cat > "$PLIST" <<PLIST_BODY
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$PROJECT_DIR/tools/scheduled_refresh.sh</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$PROJECT_DIR</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
	</dict>
	<key>StartInterval</key>
	<integer>$INTERVAL</integer>
	<key>RunAtLoad</key>
	<false/>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/AssetBridge/launchd.out.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/AssetBridge/launchd.err.log</string>
</dict>
</plist>
PLIST_BODY

mkdir -p "$HOME/Library/Logs/AssetBridge"

# 이미 걸려 있으면 새 내용으로 갈아 끼운다. 다시 실행해도 중복되지 않는다.
unload
if ! launchctl bootstrap "gui/$UID" "$PLIST" >/dev/null 2>&1; then
    launchctl load -w "$PLIST" >/dev/null 2>&1 \
        || die "예약을 걸지 못했습니다. plist: $PLIST"
fi

ok "6일마다 자동 갱신하도록 걸었습니다."
note "다음 실행: 지금부터 6일 뒤 (Mac 이 자고 있었으면 깨어난 직후)"
note "로그: ~/Library/Logs/AssetBridge/"
note "지우기: bash tools/install_schedule.sh --remove"

cat <<EOF

${BOLD}자동 갱신이 되려면${OFF}
  · Mac 이 켜져 있고 로그인돼 있어야 합니다 (잠자기는 괜찮습니다)
  · 아이폰이 같은 Wi-Fi 에 있거나 케이블로 연결돼 있어야 합니다
  · 실패하면 ${BOLD}알림${OFF}이 뜹니다 — 무엇이 필요한지 알림에 적힙니다

  ${DIM}지금 바로 한 번 돌려 보려면:  bash tools/scheduled_refresh.sh${OFF}

EOF
