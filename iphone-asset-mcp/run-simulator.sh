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

# 시뮬레이터가 실제로 Booted 상태가 될 때까지 기다린다.
#
# simctl boot 은 이미 켜져 있으면 실패하고, "Shutting Down" 중이면 역시 실패한다.
# 상태를 보고 필요할 때만 부팅하고, 전이 중이면 끝날 때까지 기다려야 한다.
ensure_booted() {
    local state
    for _ in $(seq 1 60); do
        state="$(xcrun simctl list devices 2>/dev/null \
            | grep -F "$UDID" \
            | sed -E 's/.*\(([^)]*)\)[[:space:]]*$/\1/')"

        case "$state" in
            Booted)   return 0 ;;
            Shutdown) xcrun simctl boot "$UDID" >>"$LOG" 2>&1 ;;
            *)        : ;;   # Booting / Shutting Down / Creating — 기다린다
        esac
        sleep 1
    done

    printf '마지막 상태: %s\n' "${state:-알 수 없음}" >> "$LOG"
    return 1
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

open -a Simulator 2>>"$LOG"

if ensure_booted; then
    ok "완료"
else
    die "시뮬레이터가 부팅되지 않았습니다." \
        "시뮬레이터 앱을 완전히 종료한 뒤 다시 실행해 보세요."
fi

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

# 빌드에 1~2분이 걸리는 동안 시뮬레이터가 꺼졌을 수 있다. 다시 확인한다.
if ! ensure_booted; then
    die "설치 직전에 시뮬레이터가 꺼져 있습니다." \
        "시뮬레이터 창을 닫지 말고 다시 실행해 주세요."
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null)"
[[ -n "$BUNDLE_ID" ]] || die "번들 ID 를 읽지 못했습니다."

# 이미 떠 있는 앱에 simctl launch 를 걸면 다시 뜨지 않고 앞으로 나오기만 한다.
# 그러면 방금 설치한 새 바이너리는 실행되지 않고, 예전 프로세스가 예전 토큰을
# 쥔 채 계속 포트를 붙들고 있는다. 설치 전에 확실히 죽인다.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >>"$LOG" 2>&1

if ! xcrun simctl install "$UDID" "$APP_PATH" 2>>"$LOG"; then
    warn "설치 실패 — 부팅 상태를 다시 맞추고 한 번 더 시도합니다."
    ensure_booted
    if ! xcrun simctl install "$UDID" "$APP_PATH" 2>>"$LOG"; then
        die "시뮬레이터에 설치하지 못했습니다."
    fi
fi

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>>"$LOG")"
[[ -n "$CONTAINER" ]] || die "앱 컨테이너 경로를 읽지 못했습니다." "번들 ID: $BUNDLE_ID"
CONNECTION="$CONTAINER/Library/Application Support/connection.json"

# 띄우기 전에 예전 접속 정보를 지운다.
#
# simctl install 은 데이터 컨테이너를 건드리지 않으므로 지난 실행이 남긴
# connection.json 이 그대로 남아 있다. 그걸 두고 "파일이 생겼나" 를 기다리면
# 첫 바퀴에 통과해 **예전 토큰**을 읽는다. 토큰이 한 번이라도 바뀌었으면
# 그 길로 401 이다. 지우고 다시 생기기를 기다려야 이번 실행의 값이 확실하다.
rm -f "$CONNECTION"

if ! xcrun simctl launch "$UDID" "$BUNDLE_ID" >>"$LOG" 2>&1; then
    die "앱을 실행하지 못했습니다." "번들 ID: $BUNDLE_ID"
fi

ok "$BUNDLE_ID 실행됨"

# --- 6. 연결 등록 -------------------------------------------------------------

step "Claude Code 에 등록"

# 앱은 뜨자마자 컨테이너에 접속 정보를 남긴다. 그 컨테이너는 Mac 디스크에 있으므로
# 여기서 읽어 그대로 등록할 수 있다. 사람이 토큰을 화면에서 옮겨 적을 이유가 없다.
for _ in $(seq 1 40); do
    [[ -s "$CONNECTION" ]] && break
    sleep 0.5
done

[[ -s "$CONNECTION" ]] || die "앱이 접속 정보를 쓰지 않았습니다." \
    "시뮬레이터 창에 AssetBridge 가 떠 있는지 확인하고 다시 실행해 주세요."

json_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>>"$LOG"
}

MCP_URL="$(json_field "$CONNECTION" url)"
MCP_TOKEN="$(json_field "$CONNECTION" token)"

[[ -n "$MCP_URL" && -n "$MCP_TOKEN" ]] || die "접속 정보를 읽지 못했습니다." "파일: $CONNECTION"

# 등록하기 전에 이 토큰이 진짜 통하는지 확인한다.
#
# 통하지 않는 값을 설정에 써 두면 Claude Code 는 401 만 반복하고, 원인이 앱인지
# 설정인지 화면만 봐서는 구분할 수 없다. 여기서 한 번 찔러 보면 그 구분이 끝난다.
PROBE_BODY="${TMPDIR:-/tmp}/assetbridge-probe.json"
PROBE_CODE=""

for _ in $(seq 1 20); do
    PROBE_CODE="$(curl -sS -m 5 -o "$PROBE_BODY" -w '%{http_code}' \
        -X POST "$MCP_URL" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "Authorization: Bearer $MCP_TOKEN" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>>"$LOG")"
    [[ "$PROBE_CODE" == "200" ]] && break
    sleep 0.5
done

if [[ "$PROBE_CODE" != "200" ]]; then
    {
        printf '\n--- 진단 ---\n'
        printf 'URL:         %s\n' "$MCP_URL"
        printf '앱 토큰:      %s\n' "$MCP_TOKEN"
        printf 'HTTP:        %s\n' "${PROBE_CODE:-응답 없음}"
        printf '응답 본문:    '; cat "$PROBE_BODY" 2>/dev/null; printf '\n'
        python3 - "$HOME/.claude.json" "$PWD/.mcp.json" "$(git rev-parse --show-toplevel 2>/dev/null)/.mcp.json" iphone <<'PY'
import json, os, sys

home, project, root, name = sys.argv[1:5]

def token_of(entry):
    header = ((entry or {}).get("headers") or {}).get("Authorization", "")
    return header.replace("Bearer ", "").strip() or "(헤더 없음)"

def report(label, path, finder):
    if not path or not os.path.exists(path):
        print(f"{label}: 파일 없음")
        return
    try:
        data = json.load(open(path))
    except Exception as exc:
        print(f"{label}: 읽기 실패 — {exc}")
        return
    hits = finder(data)
    if not hits:
        print(f"{label}: '{name}' 항목 없음")
    for where, entry in hits:
        print(f"{label} [{where}]: {token_of(entry)}   url={entry.get('url', '')}")

def flat(data):
    entry = (data.get("mcpServers") or {}).get(name)
    return [("mcpServers", entry)] if entry else []

def nested(data):
    hits = flat(data)
    for path, blob in (data.get("projects") or {}).items():
        entry = ((blob or {}).get("mcpServers") or {}).get(name)
        if entry:
            hits.append((path, entry))
    return hits

report("~/.claude.json", home, nested)
report("프로젝트 .mcp.json", project, flat)
if root != project:
    report("저장소 .mcp.json", root, flat)
PY
    } 2>&1 | tee -a "$LOG"

    if [[ "$PROBE_CODE" == "000" || -z "$PROBE_CODE" ]]; then
        die "서버가 응답하지 않습니다 ($MCP_URL)." \
            "시뮬레이터의 AssetBridge 화면에서 '시작' 버튼이 초록불인지 확인해 주세요."
    fi
    die "앱이 알려준 토큰을 앱 자신이 거부했습니다 (HTTP $PROBE_CODE)." \
        "위 진단 내용이 클립보드에 들어 있습니다. 그대로 붙여넣어 주세요."
fi

ok "토큰 $MCP_TOKEN — 서버가 실제로 받아들였습니다"

# 등록은 헬퍼가 맡는다. 항상 .mcp.json 을 쓰고, CLI 가 확실히 지원할 때만
# 전역 등록까지 한다. 지원 확인 없이 claude 를 부르면 대화 세션이 떠 버린다.
RESULT="$(bash tools/register_mcp.sh "$MCP_URL" "$MCP_TOKEN" iphone 2>>"$LOG")"

case "$RESULT" in
    both:*)
        ok "'iphone' 으로 등록 완료 — 어느 폴더에서 claude 를 띄워도 붙습니다"
        note "해제하려면: claude mcp remove iphone"
        ;;
    file:*)
        ok "설정 파일에 기록: ${RESULT#file:}"
        note "이 claude CLI 는 등록 명령을 지원하지 않아 .mcp.json 으로 붙습니다."
        ;;
    *)
        warn "등록 결과를 확인하지 못했습니다. 로그를 보세요."
        ;;
esac

cat <<EOF

${BOLD}다음 단계${OFF}
  1. 열려 있는 claude 세션이 있으면 ${BOLD}종료했다가 다시${OFF} 실행하세요.
     설정은 세션이 뜰 때 한 번만 읽힙니다. 켜 둔 채로는 예전 토큰을 계속 씁니다.
  2. ${BOLD}/mcp${OFF} 로 'iphone' 확인 — 토큰은 위에서 이미 서버에 통과시켜 봤습니다.
  3. 시뮬레이터의 AssetBridge 에서 ${BOLD}권한 요청${OFF} → 시트 허용.
     서버는 앱이 뜨는 즉시 켜지므로 '시작' 버튼은 누를 필요 없습니다.

  ${BOLD}시험해 볼 것${OFF} — 사진은 넣어 두었습니다.
     "내 아이폰 사진 몇 장인지 알려줘"    → photos_stats
     "최근 사진들 한눈에 보여줘"           → photos_contact_sheet
     "스크린샷에 적힌 글자 읽어줘"         → photos_read_text (OCR)

  ${DIM}연락처·캘린더·걸음수는 시뮬레이터에 데이터가 없어 비어 있습니다.${OFF}
  ${DIM}Finder 에서 이미지를 시뮬레이터 창에 끌어다 놓으면 사진이 더 추가됩니다.${OFF}

EOF
