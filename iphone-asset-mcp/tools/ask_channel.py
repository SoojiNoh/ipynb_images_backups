#!/usr/bin/env python3
"""폰으로 물어보고, 답을 기다린다. (텔레그램)

    python3 tools/ask_channel.py --check
    python3 tools/ask_channel.py --send "다 됐습니다"
    python3 tools/ask_channel.py --ask "몇 시로 할까요?" --choice 오전 --choice 오후

왜 텔레그램인가. 셋 다 봤다.

  텔레그램  봇 만들기 2분(@BotFather), 공개 주소 불필요. getUpdates 롱폴링이라
            NAT 안쪽 Mac 에서 그냥 된다. 답장 읽기가 HTTPS 한 번.
  슬랙      워크스페이스 + 앱 등록 + Socket Mode 나 공개 이벤트 URL 이 필요하다.
  디스코드  웹훅은 보내기만 된다. 답장을 읽으려면 봇 + 게이트웨이 웹소켓.

받는 쪽 경험은 셋 다 "폰에 알림이 오고 거기 답장한다" 로 같다. 그러면 설치가
가장 짧은 것을 고르는 게 맞다.

설정은 ~/Library/Application Support/AssetBridge/telegram.json 에 있고,
환경변수로 덮어쓸 수 있다 (ASSETBRIDGE_TELEGRAM_TOKEN / _CHAT / _API).
토큰은 봇을 통째로 가져갈 수 있는 값이므로 파일 권한은 600 이고,
오류 메시지에 URL 을 그대로 싣지 않는다 — URL 안에 토큰이 들어 있다.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

STATE_DIR = Path.home() / "Library" / "Application Support" / "AssetBridge"
CONFIG_FILE = STATE_DIR / "telegram.json"
OFFSET_FILE = STATE_DIR / "telegram-offset"

POLL_CHUNK = 45           # 초. 텔레그램 롱폴링 한 번의 길이.
DEFAULT_WAIT = 300        # 초. 답을 기다리는 기본 시간.


class ChannelError(Exception):
    """URL(토큰 포함)이 절대 섞이지 않는, 사람에게 보여도 되는 오류."""


# --- 설정 --------------------------------------------------------------------

def config():
    """(token, chat_id). 없으면 (None, None)."""
    token = os.environ.get("ASSETBRIDGE_TELEGRAM_TOKEN", "").strip()
    chat = os.environ.get("ASSETBRIDGE_TELEGRAM_CHAT", "").strip()
    if token and chat:
        return token, chat

    try:
        with open(CONFIG_FILE) as handle:
            data = json.load(handle)
    except Exception:
        return None, None

    token = token or str(data.get("token") or "").strip()
    chat = chat or str(data.get("chat_id") or "").strip()
    return (token, chat) if token and chat else (None, None)


def configured():
    return config()[0] is not None


def save_config(token, chat_id):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    temp = CONFIG_FILE.with_suffix(".tmp")
    with open(temp, "w") as handle:
        json.dump({"token": token, "chat_id": str(chat_id)}, handle)
    os.chmod(temp, 0o600)
    os.replace(temp, CONFIG_FILE)


# --- 텔레그램 ----------------------------------------------------------------

def api(method, params=None, token=None, timeout=20):
    """봇 API 한 번. 실패는 ChannelError 로만 나간다 (URL 은 숨긴다)."""
    if token is None:
        token = config()[0]
    if not token:
        raise ChannelError("텔레그램이 설정돼 있지 않습니다.")

    base = os.environ.get("ASSETBRIDGE_TELEGRAM_API", "https://api.telegram.org")
    url = f"{base.rstrip('/')}/bot{token}/{method}"
    body = json.dumps(params or {}).encode()
    request = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Content-Type": "application/json"})

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        detail = ""
        try:
            detail = (json.load(error) or {}).get("description", "")
        except Exception:
            pass
        if error.code == 401:
            raise ChannelError("텔레그램이 토큰을 거부했습니다 (401). "
                               "bash tools/setup_telegram.sh 로 다시 넣어 주세요.")
        raise ChannelError(f"텔레그램 오류 {error.code}"
                           f"{': ' + detail if detail else ''} ({method})")
    except Exception as error:
        raise ChannelError(f"텔레그램에 닿지 못했습니다: {type(error).__name__} ({method})")

    if not payload.get("ok"):
        raise ChannelError(f"텔레그램이 거절했습니다: "
                           f"{payload.get('description', '이유 없음')} ({method})")
    return payload.get("result")


def send(text, choices=None, token=None, chat=None):
    """메시지 하나. choices 가 있으면 폰에 버튼으로 뜬다."""
    if token is None or chat is None:
        token, chat = config()
    if not token:
        raise ChannelError("텔레그램이 설정돼 있지 않습니다.")

    params = {"chat_id": chat, "text": text}
    if choices:
        params["reply_markup"] = {
            "keyboard": [[{"text": str(c)}] for c in choices],
            "one_time_keyboard": True,
            "resize_keyboard": True,
        }
    return api("sendMessage", params, token=token)


# --- 오프셋 ------------------------------------------------------------------
#
# getUpdates 는 아직 확인하지 않은 것만 준다. 어디까지 봤는지는 우리가 기억해야
# 하고, 그 기억이 없으면 예전 메시지가 새 질문의 답으로 둔갑한다.

def read_offset():
    try:
        return int(OFFSET_FILE.read_text().strip())
    except Exception:
        return 0


def write_offset(value):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    OFFSET_FILE.write_text(str(int(value)))


def drain(token=None):
    """지금까지 온 것을 모두 읽은 것으로 표시한다. 질문 직전에 부른다."""
    offset = read_offset()
    while True:
        updates = api("getUpdates",
                      {"offset": offset, "timeout": 0, "limit": 100},
                      token=token, timeout=20) or []
        if not updates:
            break
        offset = max(u.get("update_id", 0) for u in updates) + 1
        if len(updates) < 100:
            break
    write_offset(offset)
    return offset


def wait_for_reply(offset, chat, deadline, token=None):
    """설정된 대화에서 온 첫 텍스트. 시간이 다 되면 None."""
    while time.time() < deadline:
        chunk = int(min(POLL_CHUNK, max(1, deadline - time.time())))
        try:
            updates = api("getUpdates",
                          {"offset": offset, "timeout": chunk, "limit": 20},
                          token=token, timeout=chunk + 15) or []
        except ChannelError:
            # 잠깐 끊긴 것과 영영 안 되는 것을 여기서 구분할 수 없다.
            # 남은 시간 안에서는 계속 두드린다.
            time.sleep(3)
            continue

        for update in updates:
            offset = max(offset, update.get("update_id", 0) + 1)
            write_offset(offset)
            message = update.get("message") or update.get("edited_message") or {}
            if str((message.get("chat") or {}).get("id")) != str(chat):
                continue        # 다른 사람이 이 봇에게 말을 걸었다. 답이 아니다.
            text = (message.get("text") or "").strip()
            if text:
                return text
    return None


def ask(question, choices=None, wait=DEFAULT_WAIT):
    """폰에 묻고 답을 기다린다. 답이 없으면 None.

    질문 직전에 drain 을 한다. 어제 보낸 "ㅇㅇ" 이 오늘 질문의 답이 되는 일을
    막는 것이 이 한 줄이다.
    """
    token, chat = config()
    if not token:
        raise ChannelError("텔레그램이 설정돼 있지 않습니다. "
                           "bash tools/setup_telegram.sh 를 먼저 돌리세요.")

    offset = drain(token=token)

    text = question
    if choices:
        text += "\n\n" + "\n".join(f"· {c}" for c in choices)
    send(text, choices=choices, token=token, chat=chat)

    answer = wait_for_reply(offset, chat, time.time() + wait, token=token)
    if answer is None:
        try:
            send("(답이 없어서 그냥 진행합니다)", token=token, chat=chat)
        except ChannelError:
            pass
    return answer


# --- 첫 설정 -----------------------------------------------------------------

def setup(token, wait=300, out=sys.stdout):
    """토큰을 확인하고, 사용자가 봇에게 말을 걸면 그 대화를 기억한다.

    chat_id 를 사용자가 손으로 찾게 하지 않는다. 봇에게 한 마디 보내면
    getUpdates 에 그 대화 번호가 실려 오고, 그걸 그대로 저장하면 된다.
    """
    me = api("getMe", token=token, timeout=20) or {}
    username = me.get("username") or "?"
    print(f"봇 확인: @{username}", file=out)
    print(f"이제 폰에서 https://t.me/{username} 를 열고 아무 말이나 보내세요.", file=out)
    print("기다리는 중", end="", file=out, flush=True)

    offset = 0
    deadline = time.time() + wait
    while time.time() < deadline:
        chunk = int(min(20, max(1, deadline - time.time())))
        try:
            updates = api("getUpdates",
                          {"offset": offset, "timeout": chunk, "limit": 20},
                          token=token, timeout=chunk + 15) or []
        except ChannelError:
            time.sleep(2)
            updates = []
        print(".", end="", file=out, flush=True)

        for update in updates:
            offset = max(offset, update.get("update_id", 0) + 1)
            message = update.get("message") or {}
            chat_id = (message.get("chat") or {}).get("id")
            if chat_id is None:
                continue
            print("", file=out)
            save_config(token, chat_id)
            write_offset(offset)
            send("AssetBridge 가 이 대화에 연결됐습니다. 앞으로 여기로 물어보겠습니다.",
                 token=token, chat=chat_id)
            return chat_id

    print("", file=out)
    return None


# --- 명령줄 ------------------------------------------------------------------

def main():
    argv = sys.argv[1:]

    if "--check" in argv:
        token, chat = config()
        if not token:
            print("설정 안 됨")
            return 1
        try:
            me = api("getMe", token=token) or {}
        except ChannelError as error:
            print(str(error))
            return 1
        print(f"연결됨: @{me.get('username', '?')} → 대화 {chat}")
        return 0

    def value_after(flag):
        """--setup --wait 10 처럼 값이 빠진 자리를 옆 깃발로 채우지 않는다.

        그렇게 채우면 '토큰이 없다' 가 '토큰이 거부됐다' 로 둔갑한다.
        """
        if flag not in argv:
            return None
        index = argv.index(flag) + 1
        if index >= len(argv) or argv[index].startswith("--"):
            return None
        return argv[index]

    choices = [argv[i + 1] for i, a in enumerate(argv) if a == "--choice" and i + 1 < len(argv)]

    try:
        if "--setup" in argv:
            token = value_after("--setup") or os.environ.get("ASSETBRIDGE_TELEGRAM_TOKEN", "")
            token = token.strip()
            if not token:
                print("--setup 뒤에 봇 토큰이 필요합니다.", file=sys.stderr)
                return 2
            chat_id = setup(token, wait=int(value_after("--wait") or 300))
            if chat_id is None:
                print("봇에게 온 메시지가 없어서 대화를 알아내지 못했습니다.", file=sys.stderr)
                return 1
            print(f"저장했습니다: {CONFIG_FILE}")
            return 0

        if "--send" in argv:
            text = value_after("--send")
            if not text:
                print("--send 뒤에 보낼 내용이 필요합니다.", file=sys.stderr)
                return 2
            send(text)
            return 0

        if "--ask" in argv:
            question = value_after("--ask")
            if not question:
                print("--ask 뒤에 질문이 필요합니다.", file=sys.stderr)
                return 2
            wait = int(value_after("--wait") or DEFAULT_WAIT)
            answer = ask(question, choices or None, wait=wait)
            if answer is None:
                print("(답 없음)", file=sys.stderr)
                return 1
            print(answer)
            return 0
    except ChannelError as error:
        print(str(error), file=sys.stderr)
        return 1

    print(__doc__.strip().splitlines()[0])
    print("사용법: --setup <토큰> | --check | --send <내용> | --ask <질문> [--choice 보기]...")
    return 2


if __name__ == "__main__":
    sys.exit(main())
