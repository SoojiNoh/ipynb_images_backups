#!/usr/bin/env python3
"""Xcode 에 로그인된 Apple ID 와 그 팀 목록을 출력한다.

한 줄에 하나씩, 탭으로 구분:

    <teamID>\t<teamName>\t<appleID>\t<free|paid>

계정이 하나도 없으면 아무것도 출력하지 않고 종료 코드 1 로 끝난다.
목록 자체를 읽지 못했으면 종료 코드 2 — "계정이 없다" 와 "확인하지 못했다" 는
다른 상황이고, 뒤엣것을 앞엣것처럼 다루면 멀쩡한 사람을 막게 된다.

키체인에 개발자 인증서가 남아 있어도 Xcode 에 계정이 없으면 프로비저닝
프로파일을 만들 수 없다. 그때 xcodebuild 는 이렇게 말한다:

    error: No Account for Team "XXXXXXXXXX".

그래서 서명 가능 여부는 인증서가 아니라 이 목록으로 판단해야 한다.
"""

import plistlib
import subprocess
import sys
from pathlib import Path

DOMAIN = "com.apple.dt.Xcode"


def load_preferences():
    """Xcode 환경설정을 읽는다. 못 읽으면 None."""
    # cfprefsd 를 거치는 쪽이 먼저다. Xcode 가 떠 있으면 디스크의 plist 는
    # 아직 갱신되지 않았을 수 있다.
    try:
        result = subprocess.run(["defaults", "export", DOMAIN, "-"],
                                capture_output=True, timeout=10)
        if result.returncode == 0 and result.stdout.strip():
            return plistlib.loads(result.stdout)
    except Exception:
        pass

    path = Path.home() / "Library" / "Preferences" / f"{DOMAIN}.plist"
    try:
        with open(path, "rb") as handle:
            return plistlib.load(handle)
    except Exception:
        return None


def teams(preferences):
    """IDEProvisioningTeams 를 (teamID, teamName, appleID, free) 로 펼친다."""
    raw = preferences.get("IDEProvisioningTeams") or {}
    if not isinstance(raw, dict):
        return []

    found = []
    for apple_id, entries in raw.items():
        # Xcode 버전에 따라 팀 하나가 dict 로 바로 오기도 한다.
        if isinstance(entries, dict):
            entries = [entries]
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            team_id = entry.get("teamID") or ""
            if not team_id:
                continue
            found.append((
                team_id,
                entry.get("teamName") or "",
                apple_id,
                "free" if entry.get("isFreeProvisioningTeam") else "paid",
            ))
    return found


def main():
    preferences = load_preferences()
    if preferences is None:
        print("Xcode 환경설정을 읽지 못했습니다.", file=sys.stderr)
        return 2

    found = teams(preferences)
    if not found:
        return 1

    for row in found:
        print("\t".join(row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
