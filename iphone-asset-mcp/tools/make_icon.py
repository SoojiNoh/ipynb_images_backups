#!/usr/bin/env python3
"""AssetBridge 앱 아이콘을 만든다.

    python3 tools/make_icon.py

외부 라이브러리를 쓰지 않는다. PNG 는 zlib 만으로 충분히 쓸 수 있고, 의존성
하나를 위해 사용자에게 pip install 을 시키는 것보다 이쪽이 낫다.

4배로 그린 뒤 축소해서 계단을 없앤다. 그림 자체는 단순하게 간다 — 홈 화면에서는
60pt 로 줄어들기 때문에, 형태 하나가 또렷한 편이 세밀한 그림보다 잘 읽힌다.

도형: 왼쪽에 세로 라운드 사각형(폰), 오른쪽에 가로 라운드 사각형(맥),
가운데를 굵은 막대가 잇는다 — 이 앱이 하는 일 그대로다.
"""

import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "Assets.xcassets" / "AppIcon.appiconset"

SIZE = 1024
SS = 4                      # 슈퍼샘플링 배율
W = SIZE * SS


def lerp(a, b, t):
    return a + (b - a) * t


def rounded_rect_coverage(x, y, left, top, right, bottom, radius):
    """점이 라운드 사각형 안이면 1.0, 밖이면 0.0."""
    if x < left or x > right or y < top or y > bottom:
        return 0.0
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    dx, dy = x - cx, y - cy
    return 1.0 if dx * dx + dy * dy <= radius * radius else 0.0


def render():
    """RGB 바이트 배열을 만든다. 알파는 쓰지 않는다 — 앱 아이콘은 불투명이어야 한다."""
    # 배경 그러데이션: 짙은 인디고 → 밝은 파랑. 대각선으로 흐른다.
    top_left = (49, 46, 129)        # indigo-900
    bottom_right = (14, 165, 233)   # sky-500

    # 글리프 좌표(원본 1024 기준)를 슈퍼샘플 좌표로 옮긴다.
    def s(v):
        return v * SS

    # 홈 화면에서는 60pt 로 줄어든다. 글리프를 크게 잡고 막대를 굵게 둬야
    # 두 블록이 "이어져 있다" 로 읽힌다. 가늘면 그냥 점 세 개로 보인다.
    phone = (s(178), s(286), s(388), s(738), s(52))     # 왼쪽 세로 블록
    mac = (s(540), s(360), s(846), s(664), s(52))       # 오른쪽 가로 블록
    bar = (s(360), s(462), s(568), s(562), s(50))       # 잇는 막대

    shapes = [phone, mac, bar]

    rows = []
    for py in range(W):
        row = bytearray()
        for px in range(W):
            t = (px / (W - 1) + py / (W - 1)) / 2
            r = int(lerp(top_left[0], bottom_right[0], t))
            g = int(lerp(top_left[1], bottom_right[1], t))
            b = int(lerp(top_left[2], bottom_right[2], t))

            for left, top, right, bottom, radius in shapes:
                if rounded_rect_coverage(px, py, left, top, right, bottom, radius):
                    r = g = b = 255
                    break

            row += bytes((r, g, b))
        rows.append(row)
    return rows


def downsample(rows):
    """SS×SS 박스 평균. 이것이 안티에일리어싱 역할을 한다."""
    out = []
    for y in range(SIZE):
        line = bytearray()
        for x in range(SIZE):
            r = g = b = 0
            for dy in range(SS):
                src = rows[y * SS + dy]
                base = (x * SS) * 3
                for dx in range(SS):
                    offset = base + dx * 3
                    r += src[offset]
                    g += src[offset + 1]
                    b += src[offset + 2]
            count = SS * SS
            line += bytes((r // count, g // count, b // count))
        out.append(line)
    return out


def write_png(path, rows):
    raw = bytearray()
    for line in rows:
        raw.append(0)           # 필터 타입 0 (None)
        raw += line

    def chunk(tag, payload):
        body = tag + payload
        return (struct.pack(">I", len(payload)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)   # 8bit, truecolor
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    path.write_bytes(png)


CONTENTS = """{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (ROOT / "Assets.xcassets" / "Contents.json").write_text(
        '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    (OUT_DIR / "Contents.json").write_text(CONTENTS)

    print("그리는 중… (1024×1024, 4배 슈퍼샘플링)", file=sys.stderr)
    write_png(OUT_DIR / "AppIcon-1024.png", downsample(render()))
    print(f"완료: {OUT_DIR / 'AppIcon-1024.png'}")


if __name__ == "__main__":
    main()
