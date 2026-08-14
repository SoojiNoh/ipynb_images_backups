#!/usr/bin/env python3
"""AssetBridge.xcodeproj 를 생성한다.

XcodeGen 을 쓰지 않는 이유: XcodeGen 은 "설치된 자기 버전이 아는 최신" 프로젝트
포맷으로 내보내기 때문에, Xcode 쪽이 더 낮으면 열리지 않는다. 여기서는 objectVersion 56
(Xcode 14 포맷)으로 못 박아 생성한 결과물을 저장소에 커밋해 두고, 사용자는 그냥 연다.

생성 후 스스로 검증한다 — 참조된 모든 오브젝트 ID 가 실제로 정의되어 있는지 확인해서,
Xcode 가 "project is damaged" 를 띄우는 상황을 커밋 전에 잡는다.

사용법: python3 tools/generate_xcodeproj.py
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "AssetBridge"
BUNDLE_ID_DEFAULT = "com.example.assetbridge"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"
OBJECT_VERSION = 56  # Xcode 14 포맷. Xcode 15/16/26 모두 문제없이 연다.
COMPATIBILITY_VERSION = "Xcode 14.0"


def oid(key: str) -> str:
    """키에서 24자리 대문자 16진수 ID 를 결정론적으로 만든다.

    결정론적이어야 재생성해도 diff 가 나지 않는다.
    """
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()


def quoted(value: str) -> str:
    """pbxproj 는 영숫자/._/ 외의 문자가 들어가면 따옴표가 필요하다."""
    if value and re.fullmatch(r"[A-Za-z0-9_./]+", value):
        return value
    return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"'))


def settings_block(settings: dict[str, object], indent: int) -> str:
    pad = "\t" * indent
    lines = []
    for key in sorted(settings):
        value = settings[key]
        if isinstance(value, list):
            lines.append(f"{pad}{key} = (")
            for item in value:
                lines.append(f"{pad}\t{quoted(str(item))},")
            lines.append(f"{pad});")
        else:
            lines.append(f"{pad}{key} = {quoted(str(value))};")
    return "\n".join(lines)


# --- 소스 수집 -------------------------------------------------------------

def collect_sources() -> dict[str, list[Path]]:
    """Sources/<group>/*.swift 를 그룹별로 모은다."""
    groups: dict[str, list[Path]] = {}
    sources_dir = ROOT / "Sources"
    for path in sorted(sources_dir.rglob("*.swift")):
        group = path.parent.relative_to(sources_dir).as_posix()
        groups.setdefault(group, []).append(path)
    if not groups:
        sys.exit("Sources/ 에서 .swift 파일을 찾지 못했습니다.")
    return groups


# --- 빌드 설정 -------------------------------------------------------------

PROJECT_COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
    "SDKROOT": "iphoneos",
}

PROJECT_DEBUG = {
    **PROJECT_COMMON,
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}

PROJECT_RELEASE = {
    **PROJECT_COMMON,
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
    "VALIDATE_PRODUCT": "YES",
}

TARGET_COMMON = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": f"{PROJECT_NAME}-Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "MARKETING_VERSION": "1.0",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "SWIFT_VERSION": SWIFT_VERSION,
    "TARGETED_DEVICE_FAMILY": "1,2",
}


def build() -> str:
    groups = collect_sources()
    objects: list[str] = []

    # 파일 참조와 빌드 파일
    file_refs: dict[Path, str] = {}
    build_files: list[tuple[str, str, str]] = []   # (build id, ref id, filename)

    for group_files in groups.values():
        for path in group_files:
            ref = oid(f"ref:{path.relative_to(ROOT)}")
            file_refs[path] = ref
            build_files.append((oid(f"build:{path.relative_to(ROOT)}"), ref, path.name))

    product_ref = oid("ref:product")
    plist_ref = oid("ref:infoplist")
    xcconfig_ref = oid("ref:xcconfig")

    section = ["/* Begin PBXBuildFile section */"]
    for build_id, ref, name in sorted(build_files, key=lambda item: item[2]):
        section.append(
            f"\t\t{build_id} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};"
        )
    section.append("/* End PBXBuildFile section */")
    objects.append("\n".join(section))

    section = ["/* Begin PBXFileReference section */"]
    section.append(
        f"\t\t{product_ref} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = {PROJECT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
    )
    section.append(
        f"\t\t{plist_ref} /* {PROJECT_NAME}-Info.plist */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = text.plist.xml; path = "{PROJECT_NAME}-Info.plist"; '
        f'sourceTree = "<group>"; }};'
    )
    section.append(
        f"\t\t{xcconfig_ref} /* Base.xcconfig */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = text.xcconfig; path = Base.xcconfig; sourceTree = "<group>"; }};'
    )
    for path in sorted(file_refs, key=lambda p: p.name):
        section.append(
            f"\t\t{file_refs[path]} /* {path.name} */ = {{isa = PBXFileReference; "
            f'lastKnownFileType = sourcecode.swift; path = {path.name}; sourceTree = "<group>"; }};'
        )
    section.append("/* End PBXFileReference section */")
    objects.append("\n".join(section))

    frameworks_phase = oid("phase:frameworks")
    objects.append(
        "/* Begin PBXFrameworksBuildPhase section */\n"
        f"\t\t{frameworks_phase} /* Frameworks */ = {{\n"
        "\t\t\tisa = PBXFrameworksBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXFrameworksBuildPhase section */"
    )

    # 그룹 트리
    root_group = oid("group:root")
    sources_group = oid("group:Sources")
    config_group = oid("group:Config")
    products_group = oid("group:Products")

    section = ["/* Begin PBXGroup section */"]

    children = [
        f"{sources_group} /* Sources */",
        f"{config_group} /* Config */",
        f"{plist_ref} /* {PROJECT_NAME}-Info.plist */",
        f"{products_group} /* Products */",
    ]
    section.append(
        f"\t\t{root_group} = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        + "".join(f"\t\t\t\t{child},\n" for child in children)
        + "\t\t\t);\n"
        '\t\t\tsourceTree = "<group>";\n'
        "\t\t};"
    )

    subgroup_ids = {name: oid(f"group:Sources/{name}") for name in sorted(groups)}
    section.append(
        f"\t\t{sources_group} /* Sources */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        + "".join(
            f"\t\t\t\t{subgroup_ids[name]} /* {name} */,\n" for name in sorted(groups)
        )
        + "\t\t\t);\n"
        "\t\t\tpath = Sources;\n"
        '\t\t\tsourceTree = "<group>";\n'
        "\t\t};"
    )

    for name in sorted(groups):
        members = sorted(groups[name], key=lambda p: p.name)
        section.append(
            f"\t\t{subgroup_ids[name]} /* {name} */ = {{\n"
            "\t\t\tisa = PBXGroup;\n"
            "\t\t\tchildren = (\n"
            + "".join(
                f"\t\t\t\t{file_refs[path]} /* {path.name} */,\n" for path in members
            )
            + "\t\t\t);\n"
            f"\t\t\tpath = {name};\n"
            '\t\t\tsourceTree = "<group>";\n'
            "\t\t};"
        )

    section.append(
        f"\t\t{config_group} /* Config */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"\t\t\t\t{xcconfig_ref} /* Base.xcconfig */,\n"
        "\t\t\t);\n"
        "\t\t\tpath = Config;\n"
        '\t\t\tsourceTree = "<group>";\n'
        "\t\t};"
    )

    section.append(
        f"\t\t{products_group} /* Products */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"\t\t\t\t{product_ref} /* {PROJECT_NAME}.app */,\n"
        "\t\t\t);\n"
        "\t\t\tname = Products;\n"
        '\t\t\tsourceTree = "<group>";\n'
        "\t\t};"
    )
    section.append("/* End PBXGroup section */")
    objects.append("\n".join(section))

    # 타겟
    target_id = oid("target:app")
    sources_phase = oid("phase:sources")
    resources_phase = oid("phase:resources")
    target_config_list = oid("configlist:target")
    project_config_list = oid("configlist:project")
    project_id = oid("project:root")

    objects.append(
        "/* Begin PBXNativeTarget section */\n"
        f"\t\t{target_id} /* {PROJECT_NAME} */ = {{\n"
        "\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {target_config_list};\n"
        "\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{sources_phase} /* Sources */,\n"
        f"\t\t\t\t{frameworks_phase} /* Frameworks */,\n"
        f"\t\t\t\t{resources_phase} /* Resources */,\n"
        "\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n"
        "\t\t\tdependencies = (\n\t\t\t);\n"
        f"\t\t\tname = {PROJECT_NAME};\n"
        f"\t\t\tproductName = {PROJECT_NAME};\n"
        f"\t\t\tproductReference = {product_ref} /* {PROJECT_NAME}.app */;\n"
        '\t\t\tproductType = "com.apple.product-type.application";\n'
        "\t\t};\n"
        "/* End PBXNativeTarget section */"
    )

    objects.append(
        "/* Begin PBXProject section */\n"
        f"\t\t{project_id} /* Project object */ = {{\n"
        "\t\t\tisa = PBXProject;\n"
        "\t\t\tattributes = {\n"
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        "\t\t\t\tLastSwiftUpdateCheck = 1500;\n"
        "\t\t\t\tLastUpgradeCheck = 1500;\n"
        "\t\t\t\tTargetAttributes = {\n"
        f"\t\t\t\t\t{target_id} = {{\n"
        "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        "\t\t\t\t\t};\n"
        "\t\t\t\t};\n"
        "\t\t\t};\n"
        f"\t\t\tbuildConfigurationList = {project_config_list};\n"
        f'\t\t\tcompatibilityVersion = "{COMPATIBILITY_VERSION}";\n'
        "\t\t\tdevelopmentRegion = en;\n"
        "\t\t\thasScannedForEncodings = 0;\n"
        "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
        f"\t\t\tmainGroup = {root_group};\n"
        f"\t\t\tproductRefGroup = {products_group} /* Products */;\n"
        '\t\t\tprojectDirPath = "";\n'
        '\t\t\tprojectRoot = "";\n'
        "\t\t\ttargets = (\n"
        f"\t\t\t\t{target_id} /* {PROJECT_NAME} */,\n"
        "\t\t\t);\n"
        "\t\t};\n"
        "/* End PBXProject section */"
    )

    objects.append(
        "/* Begin PBXResourcesBuildPhase section */\n"
        f"\t\t{resources_phase} /* Resources */ = {{\n"
        "\t\t\tisa = PBXResourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXResourcesBuildPhase section */"
    )

    objects.append(
        "/* Begin PBXSourcesBuildPhase section */\n"
        f"\t\t{sources_phase} /* Sources */ = {{\n"
        "\t\t\tisa = PBXSourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        + "".join(
            f"\t\t\t\t{build_id} /* {name} in Sources */,\n"
            for build_id, _, name in sorted(build_files, key=lambda item: item[2])
        )
        + "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n"
        "/* End PBXSourcesBuildPhase section */"
    )

    # 빌드 설정. Config/Base.xcconfig 를 베이스로 깔아 두면
    # 팀 ID / 번들 ID 를 프로젝트 파일을 건드리지 않고 Local.xcconfig 로 덮어쓸 수 있다.
    configs = [
        (oid("config:project:Debug"), "Debug", PROJECT_DEBUG, True),
        (oid("config:project:Release"), "Release", PROJECT_RELEASE, True),
        (oid("config:target:Debug"), "Debug", TARGET_COMMON, False),
        (oid("config:target:Release"), "Release", TARGET_COMMON, False),
    ]

    section = ["/* Begin XCBuildConfiguration section */"]
    for config_id, name, settings, is_project in configs:
        base_line = (
            f"\t\t\tbaseConfigurationReference = {xcconfig_ref} /* Base.xcconfig */;\n"
            if is_project
            else ""
        )
        section.append(
            f"\t\t{config_id} /* {name} */ = {{\n"
            "\t\t\tisa = XCBuildConfiguration;\n"
            f"{base_line}"
            "\t\t\tbuildSettings = {\n"
            + settings_block(settings, 4)
            + "\n\t\t\t};\n"
            f"\t\t\tname = {name};\n"
            "\t\t};"
        )
    section.append("/* End XCBuildConfiguration section */")
    objects.append("\n".join(section))

    section = ["/* Begin XCConfigurationList section */"]
    for list_id, label, debug_id, release_id in (
        (project_config_list, f"PBXProject \"{PROJECT_NAME}\"",
         oid("config:project:Debug"), oid("config:project:Release")),
        (target_config_list, f"PBXNativeTarget \"{PROJECT_NAME}\"",
         oid("config:target:Debug"), oid("config:target:Release")),
    ):
        section.append(
            f"\t\t{list_id} /* Build configuration list for {label} */ = {{\n"
            "\t\t\tisa = XCConfigurationList;\n"
            "\t\t\tbuildConfigurations = (\n"
            f"\t\t\t\t{debug_id} /* Debug */,\n"
            f"\t\t\t\t{release_id} /* Release */,\n"
            "\t\t\t);\n"
            "\t\t\tdefaultConfigurationIsVisible = 0;\n"
            "\t\t\tdefaultConfigurationName = Release;\n"
            "\t\t};"
        )
    section.append("/* End XCConfigurationList section */")
    objects.append("\n".join(section))

    body = "\n\n".join(objects)
    return (
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {\n\t};\n"
        f"\tobjectVersion = {OBJECT_VERSION};\n"
        "\tobjects = {\n\n"
        f"{body}\n"
        "\t};\n"
        f"\trootObject = {project_id} /* Project object */;\n"
        "}\n"
    )


# --- 검증 -----------------------------------------------------------------

def validate(text: str) -> None:
    """참조된 모든 오브젝트 ID 가 정의되어 있는지 확인한다.

    Xcode 의 "project is damaged" 는 대개 끊어진 참조에서 나오므로,
    커밋 전에 여기서 잡는다.
    """
    defined = set(re.findall(r"^\t\t([0-9A-F]{24}) ", text, re.MULTILINE))
    referenced = set(re.findall(r"\b([0-9A-F]{24})\b", text))

    dangling = referenced - defined
    if dangling:
        sys.exit(f"끊어진 오브젝트 참조: {sorted(dangling)}")

    unused = defined - (referenced - defined) - set()
    if text.count("{") != text.count("}"):
        sys.exit("중괄호 짝이 맞지 않습니다.")
    if text.count("(") != text.count(")"):
        sys.exit("괄호 짝이 맞지 않습니다.")

    for marker in ("PBXProject", "PBXNativeTarget", "PBXSourcesBuildPhase", "rootObject"):
        if marker not in text:
            sys.exit(f"필수 섹션 누락: {marker}")

    print(f"검증 통과 — 오브젝트 {len(defined)}개, 끊어진 참조 없음")


def write_scheme(project_dir: Path) -> None:
    """공유 스킴. 없으면 Xcode 가 열 때 자동으로 만들지만, 커밋해 두면
    처음 열자마자 ⌘R 이 되고 xcodebuild 로도 바로 빌드할 수 있다."""
    target_id = oid("target:app")
    reference = (
        '<BuildableReference\n'
        '               BuildableIdentifier = "primary"\n'
        f'               BlueprintIdentifier = "{target_id}"\n'
        f'               BuildableName = "{PROJECT_NAME}.app"\n'
        f'               BlueprintName = "{PROJECT_NAME}"\n'
        f'               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">\n'
        '            </BuildableReference>'
    )

    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {reference}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {reference}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {reference}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

    scheme_dir = project_dir / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (scheme_dir / f"{PROJECT_NAME}.xcscheme").write_text(scheme, encoding="utf-8")


def main() -> None:
    text = build()
    validate(text)

    project_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    (project_dir / "project.pbxproj").write_text(text, encoding="utf-8")
    write_scheme(project_dir)

    # 위의 validate() 는 ID 참조만 본다. 실제 문법까지 파싱해서 한 번 더 확인한다.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from validate_pbxproj import check

    if check(project_dir / "project.pbxproj") != 0:
        sys.exit("생성된 프로젝트가 문법 검증을 통과하지 못했습니다.")

    swift_count = sum(len(files) for files in collect_sources().values())
    print(f"{project_dir.relative_to(ROOT)} 생성 — Swift 파일 {swift_count}개, 공유 스킴 1개")


if __name__ == "__main__":
    main()
