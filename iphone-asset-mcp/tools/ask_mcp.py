#!/usr/bin/env python3
"""claude 가 사용자에게 되물을 수 있게 해 주는 아주 작은 MCP 서버 (stdio).

    claude -p "..." --mcp-config <이 서버가 적힌 json>

도구 두 개.

    ask_user(question, choices?)   폰에 묻고 답이 올 때까지 기다린다
    tell_user(message)             답은 필요 없고 알려만 준다

무인 실행에서 모델이 막히는 지점은 늘 같다. 공유된 글에 "3시" 라고만 적혀
있는데 오늘인지 내일인지 모른다. 지금까지는 둘 중 하나였다 — 찍어서 넣거나,
포기하거나. 둘 다 나쁘다. 사람은 폰을 들고 있는데 물어볼 길이 없었을 뿐이다.

전송은 tools/ask_channel.py 가 맡는다 (텔레그램). 여기서는 MCP 껍데기만 한다.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ask_channel import ChannelError, ask, configured, send    # noqa: E402

PROTOCOL = "2025-06-18"
MAX_WAIT = 600

TOOLS = [
    {
        "name": "ask_user",
        "description": (
            "사용자에게 직접 물어보고 답을 기다린다. 사용자의 폰으로 메시지가 가고, "
            "거기서 답장하면 그 내용이 그대로 돌아온다. 최대 몇 분까지 걸릴 수 있다.\n\n"
            "공유된 내용만으로 판단이 서지 않을 때 쓴다 — 날짜가 '3시' 처럼 반쪽이거나, "
            "어느 캘린더에 넣을지 모르거나, 지우거나 보내는 것처럼 되돌리기 어려운 일을 "
            "앞두고 있을 때. 찍어서 진행하는 것보다 묻는 편이 낫다.\n\n"
            "답이 오지 않으면 그렇게 알려 준다. 그때는 되돌릴 수 있는 쪽으로 진행한다."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "question": {
                    "type": "string",
                    "description": "질문 한 문장. 무엇에 대한 질문인지 알 수 있게 맥락을 한 줄 붙인다.",
                },
                "choices": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "보기. 주면 폰에 버튼으로 떠서 눌러 답할 수 있다. 두세 개가 적당하다.",
                },
                "wait_seconds": {
                    "type": "integer",
                    "description": f"기다릴 시간. 기본 240초, 최대 {MAX_WAIT}초.",
                },
            },
            "required": ["question"],
        },
    },
    {
        "name": "tell_user",
        "description": (
            "사용자 폰으로 짧은 소식을 보낸다. 답은 기다리지 않는다. "
            "무엇을 했는지, 또는 왜 못 했는지 알릴 때 쓴다."),
        "inputSchema": {
            "type": "object",
            "properties": {"message": {"type": "string"}},
            "required": ["message"],
        },
    },
]


def text_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def call_tool(name, arguments):
    if not configured():
        return text_result(
            "폰으로 보내는 통로가 아직 설정되지 않았습니다. "
            "사용자에게 물을 수 없으니, 되돌릴 수 있는 선에서 판단해 진행하세요.",
            is_error=True)

    try:
        if name == "ask_user":
            question = (arguments.get("question") or "").strip()
            if not question:
                return text_result("question 이 비어 있습니다.", is_error=True)

            choices = arguments.get("choices") or None
            if choices is not None and not isinstance(choices, list):
                choices = None

            wait = arguments.get("wait_seconds") or 240
            try:
                wait = max(30, min(MAX_WAIT, int(wait)))
            except (TypeError, ValueError):
                wait = 240

            answer = ask(question, choices, wait=wait)
            if answer is None:
                return text_result(
                    f"{wait}초 동안 답이 오지 않았습니다. 사용자가 지금 폰을 보지 못하는 "
                    f"상황일 수 있습니다. 되돌릴 수 있는 쪽으로 진행하고, 무엇을 가정했는지 "
                    f"tell_user 로 남기세요.")
            return text_result(answer)

        if name == "tell_user":
            message = (arguments.get("message") or "").strip()
            if not message:
                return text_result("message 가 비어 있습니다.", is_error=True)
            send(message)
            return text_result("보냈습니다.")

    except ChannelError as error:
        return text_result(str(error), is_error=True)

    return text_result(f"그런 도구는 없습니다: {name}", is_error=True)


def handle(message):
    """요청 하나 → 응답 하나. 알림(id 없음)이면 None."""
    method = message.get("method")
    identifier = message.get("id")

    if identifier is None:
        return None             # 알림에는 답하지 않는다. 답하면 규약 위반이다.

    def reply(result):
        return {"jsonrpc": "2.0", "id": identifier, "result": result}

    if method == "initialize":
        asked = (message.get("params") or {}).get("protocolVersion")
        return reply({
            "protocolVersion": asked if isinstance(asked, str) and asked else PROTOCOL,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "assetbridge-ask", "version": "1.0.0"},
        })

    if method == "tools/list":
        return reply({"tools": TOOLS})

    if method == "tools/call":
        params = message.get("params") or {}
        return reply(call_tool(params.get("name") or "",
                               params.get("arguments") or {}))

    if method == "ping":
        return reply({})

    return {"jsonrpc": "2.0", "id": identifier,
            "error": {"code": -32601, "message": f"Method not found: {method}"}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except Exception:
            # 못 알아들은 줄에 답할 방법이 없다 (id 를 모른다). 조용히 넘긴다.
            continue

        response = handle(message)
        if response is None:
            continue
        sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
