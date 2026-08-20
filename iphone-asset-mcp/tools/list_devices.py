#!/usr/bin/env python3
"""이 Mac 의 프로비저닝 프로파일에 등록된 기기를 보여준다.

    python3 tools/list_devices.py [현재기기UDID]

무료 Apple ID(Personal Team)에는 등록 기기를 볼 수 있는 웹 포털이 없다.
그래서 "3대 다 찼다" 는 말만 듣고 무엇이 그 3대인지는 알 수 없다.

하지만 Xcode 가 만든 프로파일 안에 ProvisionedDevices 로 그 목록이 그대로
들어 있다. 프로파일은 CMS 서명된 plist 라 `security cms -D` 로 풀 수 있다.

한계: 프로파일이 **발급된 시점**의 목록이다. 그 뒤에 등록된 기기는 그 프로파일에
없을 수 있다. 그래도 무엇이 자리를 차지하고 있는지 보기에는 이것이 유일한 창이다.
"""

import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SEARCH_DIRS = [
    Path.home() / "Library" / "Developer" / "Xcode" / "UserData" / "Provisioning Profiles",
    Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles",
]


def decode(path):
    """서명된 .mobileprovision 을 plist 로 푼다. 실패하면 None."""
    try:
        result = subprocess.run(["security", "cms", "-D", "-i", str(path)],
                                capture_output=True, timeout=20)
    except Exception:
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        return plistlib.loads(result.stdout)
    except Exception:
        return None


def summarize(profile):
    teams = profile.get("TeamIdentifier") or []
    expires = profile.get("ExpirationDate")
    return {
        "name": profile.get("Name") or "(이름 없음)",
        "team": teams[0] if teams else "",
        "team_name": profile.get("TeamName") or "",
        "expires": expires,
        "devices": list(profile.get("ProvisionedDevices") or []),
        "platforms": profile.get("Platform") or [],
    }


def main():
    current = (sys.argv[1] if len(sys.argv) > 1 else "").strip().lower()

    paths = []
    for directory in SEARCH_DIRS:
        if directory.is_dir():
            paths.extend(sorted(directory.glob("*.mobileprovision")))
            paths.extend(sorted(directory.glob("*.provisionprofile")))

    if not paths:
        print("프로비저닝 프로파일이 하나도 없습니다.")
        print("아직 실기기 빌드가 한 번도 성공하지 않았다는 뜻입니다.")
        return 1

    now = datetime.now(timezone.utc)
    by_team = {}
    shown = 0

    for path in paths:
        profile = decode(path)
        if profile is None:
            print(f"! 읽지 못함: {path.name}")
            continue

        info = summarize(profile)
        shown += 1

        expired = ""
        if isinstance(info["expires"], datetime):
            stamp = info["expires"]
            if stamp.tzinfo is None:
                stamp = stamp.replace(tzinfo=timezone.utc)
            expired = "  [만료됨]" if stamp < now else f"  (만료 {stamp:%Y-%m-%d})"

        label = info["team"] or "(팀 없음)"
        print(f"\n▸ {info['name']}{expired}")
        print(f"    팀      {label}  {info['team_name']}")
        print(f"    플랫폼  {', '.join(info['platforms']) or '알 수 없음'}")
        print(f"    기기    {len(info['devices'])}대")
        for udid in info["devices"]:
            mark = "  ← 지금 연결된 이 폰" if current and udid.lower() == current else ""
            print(f"      {udid}{mark}")

        by_team.setdefault(label, set()).update(d.lower() for d in info["devices"])

    if not shown:
        print("\n프로파일을 하나도 읽지 못했습니다.")
        return 1

    print("\n── 팀별 등록 기기 합계 ──")
    for team, devices in sorted(by_team.items()):
        here = "  (이 폰 포함)" if current and current in devices else "  (이 폰 없음)"
        print(f"  {team}: {len(devices)}대{here if current else ''}")

    print("\n무료 팀은 3대가 한도이고, 등록을 지워서 자리를 비울 수 없습니다.")
    print("위 목록에 없는 기기가 더 등록돼 있을 수도 있습니다 — 프로파일은")
    print("발급 시점의 사본이라, 실제 계정 상태와 다를 수 있습니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
