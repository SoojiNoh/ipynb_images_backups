#!/usr/bin/env python3
"""공유 수신함에 새 항목이 오면 지시를 알아서 수행한다.

    python3 tools/inbox_watcher.py          한 번 검사하고 끝
    python3 tools/inbox_watcher.py --once   같은 동작 (명시적)

launchd 가 30초마다 부른다. 한 번 돌고 끝나는 편이 오래 떠 있는 것보다 낫다 —
죽어도 다음 호출에 되살아나고, 새는 프로세스가 없다.

왜 필요한가: MCP 는 서버가 먼저 말을 걸 수 없다. 폰이 항목을 받아도 누군가
물어봐 주기 전까지는 아무 일도 일어나지 않는다. 그 '누군가'가 이 스크립트다.

한 항목당 한 번만 실행한다. 같은 것을 두 번 캘린더에 넣으면 안 된다.
그래서 잠금 파일을 하나 쥐고 시작한다 — 한 번 처리가 30초를 넘기면 다음 호출이
겹쳐 들어오고, 그러면 같은 항목을 둘이 동시에 집는다.

텔레그램이 설정돼 있으면(tools/setup_telegram.sh) 애매한 항목을 만났을 때
찍지 않고 폰으로 물어본다.
"""

import fcntl
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ask_channel                                          # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
STATE_DIR = Path.home() / "Library" / "Application Support" / "AssetBridge"
STATE_FILE = STATE_DIR / "handled.json"
LOCK_FILE = STATE_DIR / "watcher.lock"
ASK_MCP_FILE = STATE_DIR / "ask-mcp.json"
LOG_DIR = Path.home() / "Library" / "Logs" / "AssetBridge"

CLAUDE_TIMEOUT = 240          # 초. 넘으면 죽이고 다음 기회에 다시 시도한다.
ASK_TIMEOUT = 900             # 초. 사람에게 물어볼 수 있으면 그만큼 더 기다린다.
ASK_TOOL_TIMEOUT_MS = 660000  # 밀리초. MCP 도구 하나가 답을 기다릴 수 있는 시간.
MAX_ATTEMPTS = 3              # 계속 실패하는 항목이 영원히 재시도되지 않게.
STATE_LIMIT = 500             # 처리 기록을 무한히 쌓지 않는다.


def log(message):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {message}"
    print(line)
    with open(LOG_DIR / "watcher.log", "a") as handle:
        handle.write(line + "\n")


def notify(subtitle, message):
    """Mac 알림 + 폰 메시지. 어느 쪽이 실패해도 처리 자체는 계속한다.

    Mac 알림만으로는 부족하다. 이 기능을 쓰는 상황이 곧 '사용자가 폰을 들고
    Mac 앞에 없는' 상황이다.
    """
    try:
        subprocess.run(
            ["osascript", "-e",
             f'display notification {json.dumps(message)} with title "AssetBridge" '
             f'subtitle {json.dumps(subtitle)}'],
            capture_output=True, timeout=10)
    except Exception:
        pass

    try:
        if ask_channel.configured():
            ask_channel.send(f"{subtitle}\n{message}")
    except Exception:
        pass


def hold_lock():
    """겹쳐 도는 것을 막는다. 이미 돌고 있으면 None.

    flock 은 프로세스가 죽으면 저절로 풀린다. 직접 만든 잠금 파일과 달리
    '죽은 프로세스가 남긴 잠금' 이 생기지 않는다.
    """
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    handle = open(LOCK_FILE, "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle          # 프로세스가 끝날 때까지 열어 둔다.


# --- 접속 정보 ---------------------------------------------------------------

def connection():
    """.mcp.json 에서 iphone 항목의 주소와 토큰을 읽는다.

    link_device.sh 가 방금 쓴 값이라, 여기서 따로 기기를 찾을 필요가 없다.
    """
    for path in [ROOT / ".mcp.json", ROOT.parent / ".mcp.json"]:
        if not path.exists():
            continue
        try:
            with open(path) as handle:
                servers = (json.load(handle).get("mcpServers") or {})
        except Exception:
            continue
        entry = servers.get("iphone")
        if not entry:
            continue
        url = entry.get("url") or ""
        token = ((entry.get("headers") or {})
                 .get("Authorization", "").replace("Bearer ", "").strip())
        if url and token:
            return url, token
    return None, None


def call_tool(url, token, name, arguments=None):
    """MCP tools/call 하나. 실패하면 None."""
    body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": name, "arguments": arguments or {}},
    }).encode()

    request = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {token}",
    })
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.load(response)
    except Exception:
        return None


def inbox_items(url, token):
    """수신함 항목 목록. 폰이 꺼져 있거나 다른 망이면 빈 목록."""
    payload = call_tool(url, token, "inbox_list", {"limit": 50})
    if not payload:
        return []

    # 도구는 사람이 읽는 텍스트로 답한다. 그 안의 JSON 을 되꺼낸다.
    for block in ((payload.get("result") or {}).get("content") or []):
        if block.get("type") != "text":
            continue
        try:
            parsed = json.loads(block.get("text") or "")
        except Exception:
            continue
        if isinstance(parsed, dict) and "items" in parsed:
            return parsed["items"]
    return []


# --- 처리 기록 ---------------------------------------------------------------

def load_state():
    try:
        with open(STATE_FILE) as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_state(state):
    # 오래된 것부터 버린다. id 앞부분이 시간이라 정렬이 곧 순서다.
    if len(state) > STATE_LIMIT:
        for key in sorted(state)[:len(state) - STATE_LIMIT]:
            del state[key]
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    temp = STATE_FILE.with_suffix(".tmp")
    with open(temp, "w") as handle:
        json.dump(state, handle)
    os.replace(temp, STATE_FILE)


# --- 실행 --------------------------------------------------------------------

def supports_mcp_config():
    """이 claude 가 --mcp-config 를 받는지 확인한다. 없으면 없는 대로 간다."""
    try:
        result = subprocess.run(["claude", "--help"],
                                capture_output=True, text=True, timeout=30)
    except Exception:
        return False
    return "--mcp-config" in (result.stdout or "") + (result.stderr or "")


def write_ask_config():
    """되묻기 도구를 담은 MCP 설정 파일. 경로를 돌려준다.

    프로젝트 .mcp.json 에 넣지 않고 명령줄로 붙인다. 그래야 이 무인 실행에만
    적용되고, 사람이 쓰는 세션의 신뢰 설정을 건드리지 않는다.
    """
    payload = {"mcpServers": {"ask": {
        "command": sys.executable or "python3",
        "args": [str(ROOT / "tools" / "ask_mcp.py")],
    }}}
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    temp = ASK_MCP_FILE.with_suffix(".tmp")
    with open(temp, "w") as handle:
        json.dump(payload, handle)
    os.replace(temp, ASK_MCP_FILE)
    return ASK_MCP_FILE


def run_claude(item_id, note, can_ask):
    """claude 에게 이 항목의 지시를 수행하게 한다. (성공여부, 출력)"""
    if can_ask:
        # 물어볼 사람이 있다. 찍는 것보다 묻는 게 낫다는 것을 분명히 말해 준다.
        guidance = (
            "확실하지 않은 것이 있으면 ask_user 로 물어보세요 — 사용자의 폰으로 "
            "질문이 가고, 답장이 그대로 돌아옵니다. 날짜나 시각이 반쪽이거나"
            "(예: '3시'), 어디에 넣을지 모르거나, 지우고 보내는 것처럼 되돌리기 "
            "어려운 일이면 묻는 편이 낫습니다. 보기가 두세 개로 좁혀지면 choices 로 "
            "주면 버튼으로 뜹니다. 답이 오지 않으면 되돌릴 수 있는 쪽으로 진행하고 "
            "tell_user 로 무엇을 가정했는지 남기세요. 다 끝났다는 알림은 제가 따로 "
            "보내니 tell_user 로 또 보내지는 마세요."
        )
    else:
        guidance = "확인 질문은 하지 말고 바로 실행하세요 — 지금은 물어볼 통로가 없습니다."

    prompt = (
        f"아이폰 공유 수신함에 새 항목이 있습니다. id 는 {item_id} 입니다.\n"
        f"사용자가 적은 지시: {note}\n\n"
        f"inbox_read 로 그 항목의 전문을 읽고, 위 지시를 수행하세요. "
        f"{guidance} "
        f"끝나면 무엇을 했는지 한 줄로만 답하세요."
    )

    # 권한 승인이 필요한 도구를 만나면 claude 가 멈춰 선다. 무인 실행이므로
    # 사용자가 직접 허용 범위를 정하게 두고, 기본값은 아무것도 열지 않는다.
    extra = os.environ.get("ASSETBRIDGE_CLAUDE_FLAGS", "").split()

    command = ["claude", "-p", prompt, *extra]
    timeout = CLAUDE_TIMEOUT
    environment = dict(os.environ)

    if can_ask:
        command += ["--mcp-config", str(write_ask_config())]
        # 사람이 답할 때까지 도구 하나가 몇 분을 붙잡고 있는다. MCP 도구 제한은
        # 기본이 60초라, 그대로 두면 질문을 보내 놓고 답을 받기 전에 끊긴다.
        # 이미 값이 있어도 더 짧으면 올린다 — setdefault 로는 못 막는다.
        current = environment.get("MCP_TOOL_TIMEOUT", "")
        try:
            keep = int(current) >= ASK_TOOL_TIMEOUT_MS
        except ValueError:
            keep = False
        if not keep:
            environment["MCP_TOOL_TIMEOUT"] = str(ASK_TOOL_TIMEOUT_MS)
        environment.setdefault("MCP_TIMEOUT", "30000")
        timeout = ASK_TIMEOUT

    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout,
            cwd=str(ROOT.parent), env=environment)
    except FileNotFoundError:
        return False, "claude 명령을 찾지 못했습니다."
    except subprocess.TimeoutExpired:
        return False, f"{timeout}초 안에 끝나지 않았습니다."

    output = (result.stdout or result.stderr or "").strip()
    return result.returncode == 0, output


def main():
    lock = hold_lock()
    if lock is None:
        return 0            # 앞의 실행이 아직 돌고 있다. 겹쳐 처리하지 않는다.

    url, token = connection()
    if not url:
        log("'.mcp.json' 에서 iphone 항목을 찾지 못했습니다. link_device.sh 를 먼저 돌리세요.")
        return 1

    items = inbox_items(url, token)
    if not items:
        return 0            # 폰이 안 잡히거나 새 항목이 없다. 조용히 넘어간다.

    # 되묻기가 가능한지는 여기서 한 번만 판단한다. 항목마다 claude --help 를
    # 부를 이유가 없다.
    can_ask = ask_channel.configured() and supports_mcp_config()
    if ask_channel.configured() and not can_ask:
        log("텔레그램은 설정돼 있지만 이 claude 는 --mcp-config 를 받지 않습니다. "
            "되묻기 없이 진행합니다.")

    state = load_state()
    handled = 0

    # 오래된 것부터. 사용자가 보낸 순서대로 처리된다.
    for item in sorted(items, key=lambda row: row.get("id", "")):
        item_id = item.get("id")
        note = (item.get("note") or "").strip()

        if not item_id or item_id in state:
            continue
        if not note:
            # 지시가 없으면 무엇을 할지 알 수 없다. 보관이 목적일 수 있으므로
            # 손대지 않고, 다시 보지 않도록 기록만 해 둔다.
            state[item_id] = "지시 없음"
            continue

        attempts = STATE_DIR / f"attempts-{item_id}"
        count = int(attempts.read_text()) if attempts.exists() else 0
        if count >= MAX_ATTEMPTS:
            state[item_id] = f"{MAX_ATTEMPTS}회 실패 후 포기"
            attempts.unlink(missing_ok=True)
            notify("자동 처리 실패", f"{note[:40]} — 직접 처리해 주세요")
            continue

        log(f"처리 시작 {item_id} — {note}")
        ok, output = run_claude(item_id, note, can_ask)

        if ok:
            state[item_id] = "완료"
            attempts.unlink(missing_ok=True)
            handled += 1
            summary = output.splitlines()[-1] if output else "완료"
            log(f"완료 {item_id} — {summary}")
            notify("처리 완료", summary[:120])
        else:
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            attempts.write_text(str(count + 1))
            log(f"실패 {item_id} ({count + 1}/{MAX_ATTEMPTS}) — {output[:300]}")

    save_state(state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
