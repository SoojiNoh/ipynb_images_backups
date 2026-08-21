#!/usr/bin/env python3
"""이 팀으로 실제로 쓸 수 있는 번들 ID 를 빌드 전에 정한다.

    python3 tools/bundle_id.py <기본번들ID> <팀ID>

출력은 두 줄이다.

    1줄: 쓸 번들 ID
    2줄: 왜 그 이름인지 (사람에게 보여줄 한 줄)

왜 필요한가: 무료 Apple ID 로 한 번 등록한 App ID 는 그 팀의 것이 된다.
계정을 바꾸면 새 팀은 같은 이름을 쓸 수 없고, 빌드는 이렇게 죽는다.

    error: Failed Registering Bundle Identifier

예전에는 이 오류를 보고 나서야 이름을 바꿔 다시 빌드했다. 즉 한 번은 반드시
실패해야 했다. 그런데 누가 그 이름을 가졌는지는 빌드하지 않아도 알 수 있다 —
Xcode 가 발급받아 둔 프로비저닝 프로파일 안에 답이 들어 있다.

    Entitlements["application-identifier"] = "<팀ID>.<번들ID>"

그래서 프로파일을 먼저 읽고, 이 팀이 못 쓸 이름이면 처음부터 팀 ID 를 붙인
이름으로 빌드한다. 실패를 한 번 겪지 않아도 된다.

한계: 프로파일은 이 Mac 에 내려받힌 것만 있다. 다른 Mac 에서 등록한 App ID 는
보이지 않는다. 그때는 빌드가 예전처럼 실패하고, run-device.sh 의 사후 처리가
받아 준다. 이 스크립트는 확실히 아는 경우에만 이름을 바꾼다.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from list_devices import SEARCH_DIRS, decode      # noqa: E402


def owners():
    """{번들ID: {그 이름을 등록한 팀ID, ...}}

    와일드카드(`TEAM.*`)는 뺀다. 특정 이름의 소유를 증명하지 못한다.
    만료된 프로파일도 센다 — 프로파일은 만료돼도 App ID 등록은 남는다.
    """
    found = {}
    for directory in SEARCH_DIRS:
        if not directory.is_dir():
            continue
        for path in sorted(directory.glob("*.mobileprovision")):
            profile = decode(path)
            if profile is None:
                continue
            app_id = ((profile.get("Entitlements") or {})
                      .get("application-identifier") or "")
            team, _, bundle = app_id.partition(".")
            if not team or not bundle or bundle.endswith("*"):
                continue
            found.setdefault(bundle, set()).add(team)
    return found


def choose(base, team):
    """(번들ID, 이유). 확실하지 않으면 기본 이름을 그대로 둔다."""
    suffixed = f"{base}.{team.lower()}"
    registered = owners()

    if not registered:
        return base, ""

    if team in registered.get(base, set()):
        return base, ""

    holders = registered.get(base, set())
    if holders:
        return suffixed, (f"{base} 는 다른 팀({', '.join(sorted(holders))})이 "
                          f"등록해 둔 이름이라 이 팀으로는 못 씁니다.")

    if team in registered.get(suffixed, set()):
        return suffixed, "이 팀이 예전에 등록해 둔 이름을 그대로 씁니다."

    return base, ""


def main():
    if len(sys.argv) < 3:
        print("사용법: bundle_id.py <기본번들ID> <팀ID>", file=sys.stderr)
        return 2

    base = sys.argv[1].strip()
    team = sys.argv[2].strip()
    if not base or not team:
        print("번들 ID 와 팀 ID 가 모두 필요합니다.", file=sys.stderr)
        return 2

    bundle, reason = choose(base, team)
    print(bundle)
    print(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
