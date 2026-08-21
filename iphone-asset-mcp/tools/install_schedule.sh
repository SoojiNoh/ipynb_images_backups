#!/usr/bin/env bash
#
# Mac 이 알아서 하도록 예약을 건다. 두 가지다.
#
#   1. 갱신  — 6일마다 앱을 다시 설치한다 (무료 서명은 7일 뒤 만료)
#   2. 감시  — 30초마다 공유 수신함을 보고, 지시가 있으면 바로 수행한다
#
#   bash tools/install_schedule.sh           둘 다 걸기 (다시 걸어도 안전)
#   bash tools/install_schedule.sh --remove  둘 다 지우기
#
# Claude 는 클라우드에 있어서 이 Mac 의 Xcode·키체인·아이폰에 닿을 수 없다.
# 그러니 Mac 이 스스로 하게 한다.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
PROJECT_DIR="$(pwd)"

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

AGENT_DIR="$HOME/Library/LaunchAgents"
REFRESH_LABEL="com.assetbridge.refresh"
WATCHER_LABEL="com.assetbridge.watcher"

ok()   { printf '    %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$OFF" "$1"; }
note() { printf '      %s%s%s\n' "$DIM" "$1" "$OFF"; }
die()  { printf '\n    %s✗%s %s\n\n' "$RED" "$OFF" "$1"; exit 1; }

unload() {
    launchctl bootout "gui/$UID/$1" >/dev/null 2>&1 \
        || launchctl unload "$AGENT_DIR/$1.plist" >/dev/null 2>&1 || true
}

if [[ "${1:-}" == "--remove" ]]; then
    for label in "$REFRESH_LABEL" "$WATCHER_LABEL"; do
        unload "$label"
        rm -f "$AGENT_DIR/$label.plist"
    done
    ok "예약을 모두 지웠습니다."
    note "앱은 그대로 있습니다. 만료되면 bash go.sh 로 직접 갱신하세요."
    exit 0
fi

[[ -f "$PROJECT_DIR/go.sh" ]] || die "go.sh 를 찾지 못했습니다: $PROJECT_DIR"

mkdir -p "$AGENT_DIR" "$HOME/Library/Logs/AssetBridge"

# launchd 는 최소한의 PATH 만 준다. claude·xcrun·git 을 못 찾으면 조용히 죽는다.
# claude 는 설치 방식마다 위치가 달라서, 지금 찾아 그 경로를 박아 둔다.
AGENT_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin"
CLAUDE_BIN="$(command -v claude 2>/dev/null)"
if [[ -n "$CLAUDE_BIN" ]]; then
    AGENT_PATH="$(dirname "$CLAUDE_BIN"):$AGENT_PATH"
else
    warn "claude 를 찾지 못했습니다. 감시자가 지시를 수행하지 못할 수 있습니다."
fi

write_agent() {
    # $1 라벨  $2 실행할 것(공백 구분)  $3 간격(초)
    local label="$1" program="$2" interval="$3"
    local args=""
    for piece in $program; do
        args+="		<string>$piece</string>
"
    done

    cat > "$AGENT_DIR/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
$args	</array>
	<key>WorkingDirectory</key>
	<string>$PROJECT_DIR</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$AGENT_PATH</string>
	</dict>
	<key>StartInterval</key>
	<integer>$interval</integer>
	<key>RunAtLoad</key>
	<false/>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/AssetBridge/$label.out.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/AssetBridge/$label.err.log</string>
</dict>
</plist>
PLIST

    unload "$label"
    if ! launchctl bootstrap "gui/$UID" "$AGENT_DIR/$label.plist" >/dev/null 2>&1; then
        launchctl load -w "$AGENT_DIR/$label.plist" >/dev/null 2>&1 \
            || die "예약을 걸지 못했습니다: $label"
    fi
}

write_agent "$REFRESH_LABEL" "/bin/bash $PROJECT_DIR/tools/scheduled_refresh.sh" $((6 * 24 * 60 * 60))
ok "갱신 — 6일마다 앱을 다시 설치합니다"

write_agent "$WATCHER_LABEL" "/usr/bin/python3 $PROJECT_DIR/tools/inbox_watcher.py" 30
ok "감시 — 30초마다 공유 수신함을 확인합니다"

note "로그: ~/Library/Logs/AssetBridge/"
note "지우기: bash tools/install_schedule.sh --remove"

# 되묻기 통로가 있으면 알려 준다. 있는 줄 알았는데 없는 것이 제일 나쁘다.
TELEGRAM_CONFIG="$HOME/Library/Application Support/AssetBridge/telegram.json"
if [[ -f "$TELEGRAM_CONFIG" ]] && CHANNEL="$(python3 tools/ask_channel.py --check 2>&1)"; then
    ok "되묻기 — 애매하면 폰으로 물어봅니다 ($CHANNEL)"
else
    warn "되묻기 통로가 없습니다. 애매해도 묻지 않고 알아서 판단합니다."
    note "폰으로 물어보게 하려면: bash tools/setup_telegram.sh"
fi

cat <<EOF

${BOLD}이제 공유만 하면 알아서 됩니다${OFF}
  카톡에서 공유 → AssetBridge → "캘린더에 넣어줘" → 보내기
  ${DIM}30초 안에 Mac 이 집어 가서 수행하고, 끝나면 알림이 뜹니다.${OFF}

${BOLD}먼저 한 번 손으로 돌려 보세요${OFF}
  ${BOLD}python3 tools/inbox_watcher.py${OFF}

  무인 실행이라 claude 가 도구 승인을 물으면 그 자리에서 멈춥니다. 어떤 도구를
  미리 허용해 둘지는 ${BOLD}직접 정하셔야 합니다${OFF} — 캘린더에 쓰는 것과 파일을 지우는
  것은 다른 얘기이고, 그 선을 제가 대신 그을 수는 없습니다.

  ${DIM}허용 목록은 프로젝트의 .claude/settings.json 에 둡니다. 손으로 돌려 봤을 때${OFF}
  ${DIM}멈춘 도구 이름을 알려 주시면 그 항목만 넣어 드리겠습니다.${OFF}

EOF
