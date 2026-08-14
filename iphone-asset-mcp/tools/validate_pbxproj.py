#!/usr/bin/env python3
"""project.pbxproj 를 실제로 파싱해서 문법이 유효한지 확인한다.

generate_xcodeproj.py 의 자체 검증은 오브젝트 ID 참조만 본다. 그것만으로는
따옴표나 세미콜론이 빠진 문법 오류를 잡지 못하고, 그런 파일은 Xcode 에서
"project is damaged" 또는 xcodebuild 실패로만 드러난다.

여기서는 OpenStep(구 NeXT) 프로퍼티 리스트 문법을 직접 파싱해서
구조가 온전한지, 필수 키가 제자리에 있는지까지 확인한다.

사용법: python3 tools/validate_pbxproj.py [경로]
"""

from __future__ import annotations

import sys
from pathlib import Path

UNQUOTED = set(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    "_$/:.-"
)


class ParseError(Exception):
    pass


class Parser:
    """pbxproj 가 쓰는 OpenStep plist 부분집합 파서.

    지원: 딕셔너리, 배열, 따옴표 문자열, 따옴표 없는 문자열, // 및 /* */ 주석.
    """

    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0

    # --- 저수준 ---

    def error(self, message: str) -> ParseError:
        line = self.text.count("\n", 0, self.pos) + 1
        column = self.pos - (self.text.rfind("\n", 0, self.pos) + 1) + 1
        snippet = self.text[max(0, self.pos - 60):self.pos + 60].replace("\n", "\\n")
        return ParseError(f"{line}행 {column}열: {message}\n  근처: ...{snippet}...")

    def skip_trivia(self) -> None:
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char in " \t\r\n":
                self.pos += 1
            elif self.text.startswith("//", self.pos):
                end = self.text.find("\n", self.pos)
                self.pos = len(self.text) if end < 0 else end
            elif self.text.startswith("/*", self.pos):
                end = self.text.find("*/", self.pos + 2)
                if end < 0:
                    raise self.error("닫히지 않은 블록 주석")
                self.pos = end + 2
            else:
                return

    def expect(self, char: str) -> None:
        self.skip_trivia()
        if self.pos >= len(self.text) or self.text[self.pos] != char:
            found = self.text[self.pos] if self.pos < len(self.text) else "<파일 끝>"
            raise self.error(f"'{char}' 를 기대했는데 '{found}' 를 만남")
        self.pos += 1

    # --- 값 ---

    def parse_value(self):
        self.skip_trivia()
        if self.pos >= len(self.text):
            raise self.error("값이 오기 전에 파일이 끝남")

        char = self.text[self.pos]
        if char == "{":
            return self.parse_dict()
        if char == "(":
            return self.parse_array()
        if char == '"':
            return self.parse_quoted()
        return self.parse_bare()

    def parse_quoted(self) -> str:
        self.expect('"')
        chunks: list[str] = []
        while True:
            if self.pos >= len(self.text):
                raise self.error("닫히지 않은 문자열")
            char = self.text[self.pos]
            if char == "\\":
                chunks.append(self.text[self.pos:self.pos + 2])
                self.pos += 2
            elif char == '"':
                self.pos += 1
                return "".join(chunks)
            else:
                chunks.append(char)
                self.pos += 1

    def parse_bare(self) -> str:
        start = self.pos
        while self.pos < len(self.text) and self.text[self.pos] in UNQUOTED:
            self.pos += 1
        if self.pos == start:
            raise self.error(f"값을 읽을 수 없음 (문자 {self.text[self.pos]!r})")
        return self.text[start:self.pos]

    def parse_array(self) -> list:
        self.expect("(")
        items: list = []
        while True:
            self.skip_trivia()
            if self.pos < len(self.text) and self.text[self.pos] == ")":
                self.pos += 1
                return items
            items.append(self.parse_value())
            self.skip_trivia()
            if self.pos < len(self.text) and self.text[self.pos] == ",":
                self.pos += 1

    def parse_dict(self) -> dict:
        self.expect("{")
        result: dict = {}
        while True:
            self.skip_trivia()
            if self.pos < len(self.text) and self.text[self.pos] == "}":
                self.pos += 1
                return result
            key = self.parse_quoted() if self.text[self.pos] == '"' else self.parse_bare()
            self.expect("=")
            result[key] = self.parse_value()
            self.expect(";")


def check(path: Path) -> int:
    text = path.read_text(encoding="utf-8")

    if not text.startswith("// !$*UTF8*$!"):
        print("✗ UTF-8 매직 주석이 없습니다.")
        return 1

    parser = Parser(text)
    try:
        root = parser.parse_value()
    except ParseError as error:
        print(f"✗ 문법 오류\n  {error}")
        return 1

    parser.skip_trivia()
    if parser.pos != len(text):
        print(f"✗ 최상위 값 뒤에 잉여 내용이 있습니다 (오프셋 {parser.pos}).")
        return 1

    if not isinstance(root, dict):
        print("✗ 최상위가 딕셔너리가 아닙니다.")
        return 1

    for key in ("archiveVersion", "objectVersion", "objects", "rootObject"):
        if key not in root:
            print(f"✗ 최상위 키 누락: {key}")
            return 1

    objects = root["objects"]
    if not isinstance(objects, dict):
        print("✗ objects 가 딕셔너리가 아닙니다.")
        return 1

    # 모든 오브젝트에 isa 가 있어야 한다.
    for oid, obj in objects.items():
        if not isinstance(obj, dict):
            print(f"✗ 오브젝트 {oid} 가 딕셔너리가 아닙니다.")
            return 1
        if "isa" not in obj:
            print(f"✗ 오브젝트 {oid} 에 isa 가 없습니다.")
            return 1

    root_object = root["rootObject"]
    if root_object not in objects:
        print(f"✗ rootObject {root_object} 가 objects 에 없습니다.")
        return 1

    project = objects[root_object]
    if project.get("isa") != "PBXProject":
        print(f"✗ rootObject 의 isa 가 PBXProject 가 아닙니다: {project.get('isa')}")
        return 1

    # 프로젝트가 가리키는 참조들이 실제로 존재하는지.
    problems: list[str] = []

    def require(oid: str, context: str) -> None:
        if oid not in objects:
            problems.append(f"{context} → 없는 오브젝트 {oid}")

    for key in ("mainGroup", "productRefGroup", "buildConfigurationList"):
        if key in project:
            require(project[key], f"PBXProject.{key}")

    targets = project.get("targets", [])
    if not targets:
        problems.append("PBXProject.targets 가 비어 있습니다")
    for target_id in targets:
        require(target_id, "PBXProject.targets")

    for oid, obj in objects.items():
        isa = obj["isa"]
        if isa == "PBXBuildFile" and "fileRef" in obj:
            require(obj["fileRef"], f"{isa} {oid}.fileRef")
        elif isa == "PBXGroup":
            for child in obj.get("children", []):
                require(child, f"PBXGroup {oid}.children")
        elif isa == "PBXNativeTarget":
            require(obj["buildConfigurationList"], f"{isa} {oid}.buildConfigurationList")
            require(obj["productReference"], f"{isa} {oid}.productReference")
            for phase in obj.get("buildPhases", []):
                require(phase, f"{isa} {oid}.buildPhases")
        elif isa.endswith("BuildPhase"):
            for build_file in obj.get("files", []):
                require(build_file, f"{isa} {oid}.files")
        elif isa == "XCConfigurationList":
            for config in obj.get("buildConfigurations", []):
                require(config, f"{isa} {oid}.buildConfigurations")
        elif isa == "XCBuildConfiguration" and "baseConfigurationReference" in obj:
            require(obj["baseConfigurationReference"], f"{isa} {oid}.baseConfigurationReference")

    if problems:
        print("✗ 끊어진 참조")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    counts: dict[str, int] = {}
    for obj in objects.values():
        counts[obj["isa"]] = counts.get(obj["isa"], 0) + 1

    print(f"✓ {path.name} 파싱 성공 — objectVersion {root['objectVersion']}, 오브젝트 {len(objects)}개")
    for isa in sorted(counts):
        print(f"    {isa}: {counts[isa]}")
    return 0


def main() -> None:
    default = Path(__file__).resolve().parent.parent / "AssetBridge.xcodeproj" / "project.pbxproj"
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else default
    if not path.exists():
        sys.exit(f"파일이 없습니다: {path}")
    sys.exit(check(path))


if __name__ == "__main__":
    main()
