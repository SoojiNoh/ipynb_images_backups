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
EXTENSION_NAME = "AssetBridgeShare"
EXTENSION_DIR = "ShareExtension"
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


def collect_extension_sources() -> list[Path]:
    """공유 익스텐션 소스. 앱 타겟과 섞이면 안 되므로 Sources/ 밖에 둔다."""
    directory = ROOT / EXTENSION_DIR
    if not directory.is_dir():
        return []
    return sorted(directory.glob("*.swift"))


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
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
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


# 익스텐션은 앱과 번들 ID 가 달라야 한다. Base.xcconfig 가 프로젝트 수준에서
# PRODUCT_BUNDLE_IDENTIFIER 를 앱 것으로 깔아 두므로 여기서 덮어쓴다.
EXTENSION_TARGET = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": f"{EXTENSION_DIR}/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": [
        "$(inherited)",
        "@executable_path/Frameworks",
        "@executable_path/../../Frameworks",
    ],
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": "$(ASSETBRIDGE_BUNDLE_ID).share",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SKIP_INSTALL": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "SWIFT_VERSION": SWIFT_VERSION,
    "TARGETED_DEVICE_FAMILY": "1,2",
}


def build() -> str:
    groups = collect_sources()
    ext_sources = collect_extension_sources()
    objects: list[str] = []

    # 파일 참조와 빌드 파일
    file_refs: dict[Path, str] = {}
    build_files: list[tuple[str, str, str]] = []   # (build id, ref id, filename)

    for group_files in groups.values():
        for path in group_files:
            ref = oid(f"ref:{path.relative_to(ROOT)}")
            file_refs[path] = ref
            build_files.append((oid(f"build:{path.relative_to(ROOT)}"), ref, path.name))

    ext_build_files: list[tuple[str, str, str]] = []
    for path in ext_sources:
        ref = oid(f"ref:{path.relative_to(ROOT)}")
        file_refs[path] = ref
        ext_build_files.append((oid(f"build:{path.relative_to(ROOT)}"), ref, path.name))

    product_ref = oid("ref:product")
    plist_ref = oid("ref:infoplist")
    xcconfig_ref = oid("ref:xcconfig")
    assets_ref = oid("ref:assets")
    assets_build = oid("build:assets")
    ext_product_ref = oid("ref:ext-product")
    ext_plist_ref = oid("ref:ext-infoplist")
    embed_build = oid("build:embed-appex")

    section = ["/* Begin PBXBuildFile section */"]
    for build_id, ref, name in sorted(build_files + ext_build_files, key=lambda item: item[2]):
        section.append(
            f"\t\t{build_id} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};"
        )
    section.append(
        f"\t\t{assets_build} /* Assets.xcassets in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};"
    )
    if ext_sources:
        # RemoveHeadersOnCopy 가 없으면 Xcode 가 검증 단계에서 경고를 낸다.
        section.append(
            f"\t\t{embed_build} /* {EXTENSION_NAME}.appex in Embed Foundation Extensions */ = "
            f"{{isa = PBXBuildFile; fileRef = {ext_product_ref} /* {EXTENSION_NAME}.appex */; "
            f"settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};"
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
    section.append(
        f"\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};'
    )
    if ext_sources:
        section.append(
            f"\t\t{ext_product_ref} /* {EXTENSION_NAME}.appex */ = {{isa = PBXFileReference; "
            f"explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; "
            f"path = {EXTENSION_NAME}.appex; sourceTree = BUILT_PRODUCTS_DIR; }};"
        )
        section.append(
            f"\t\t{ext_plist_ref} /* Info.plist */ = {{isa = PBXFileReference; "
            f'lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};'
        )
    for path in sorted(file_refs, key=lambda p: p.name):
        section.append(
            f"\t\t{file_refs[path]} /* {path.name} */ = {{isa = PBXFileReference; "
            f'lastKnownFileType = sourcecode.swift; path = {path.name}; sourceTree = "<group>"; }};'
        )
    section.append("/* End PBXFileReference section */")
    objects.append("\n".join(section))

    frameworks_phase = oid("phase:frameworks")
    ext_frameworks_phase = oid("phase:ext-frameworks")

    def empty_phase(phase_id: str, isa: str, label: str) -> str:
        return (
            f"\t\t{phase_id} /* {label} */ = {{\n"
            f"\t\t\tisa = {isa};\n"
            "\t\t\tbuildActionMask = 2147483647;\n"
            "\t\t\tfiles = (\n\t\t\t);\n"
            "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            "\t\t};"
        )

    section = ["/* Begin PBXFrameworksBuildPhase section */"]
    section.append(empty_phase(frameworks_phase, "PBXFrameworksBuildPhase", "Frameworks"))
    if ext_sources:
        section.append(empty_phase(ext_frameworks_phase, "PBXFrameworksBuildPhase", "Frameworks"))
    section.append("/* End PBXFrameworksBuildPhase section */")
    objects.append("\n".join(section))

    # 앱 번들 안 PlugIns/ 로 appex 를 복사하는 단계. 이게 없으면 익스텐션이
    # 빌드는 되지만 앱에 실리지 않아 공유 시트에 나타나지 않는다.
    embed_phase = oid("phase:embed")
    if ext_sources:
        objects.append(
            "/* Begin PBXCopyFilesBuildPhase section */\n"
            f"\t\t{embed_phase} /* Embed Foundation Extensions */ = {{\n"
            "\t\t\tisa = PBXCopyFilesBuildPhase;\n"
            "\t\t\tbuildActionMask = 2147483647;\n"
            '\t\t\tdstPath = "";\n'
            "\t\t\tdstSubfolderSpec = 13;\n"
            "\t\t\tfiles = (\n"
            f"\t\t\t\t{embed_build} /* {EXTENSION_NAME}.appex in Embed Foundation Extensions */,\n"
            "\t\t\t);\n"
            '\t\t\tname = "Embed Foundation Extensions";\n'
            "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            "\t\t};\n"
            "/* End PBXCopyFilesBuildPhase section */"
        )

    # 그룹 트리
    root_group = oid("group:root")
    sources_group = oid("group:Sources")
    config_group = oid("group:Config")
    products_group = oid("group:Products")

    section = ["/* Begin PBXGroup section */"]

    ext_group = oid("group:ShareExtension")

    children = [f"{sources_group} /* Sources */"]
    if ext_sources:
        children.append(f"{ext_group} /* {EXTENSION_DIR} */")
    children += [
        f"{config_group} /* Config */",
        f"{assets_ref} /* Assets.xcassets */",
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

    if ext_sources:
        section.append(
            f"\t\t{ext_group} /* {EXTENSION_DIR} */ = {{\n"
            "\t\t\tisa = PBXGroup;\n"
            "\t\t\tchildren = (\n"
            + "".join(
                f"\t\t\t\t{file_refs[path]} /* {path.name} */,\n"
                for path in sorted(ext_sources, key=lambda p: p.name)
            )
            + f"\t\t\t\t{ext_plist_ref} /* Info.plist */,\n"
            "\t\t\t);\n"
            f"\t\t\tpath = {EXTENSION_DIR};\n"
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
        + (f"\t\t\t\t{ext_product_ref} /* {EXTENSION_NAME}.appex */,\n" if ext_sources else "")
        + "\t\t\t);\n"
        "\t\t\tname = Products;\n"
        '\t\t\tsourceTree = "<group>";\n'
        "\t\t};"
    )
    section.append("/* End PBXGroup section */")
    objects.append("\n".join(section))

    # 타겟
    target_id = oid("target:app")
    ext_target_id = oid("target:ext")
    dependency_id = oid("dependency:ext")
    proxy_id = oid("proxy:ext")
    sources_phase = oid("phase:sources")
    ext_sources_phase = oid("phase:ext-sources")
    resources_phase = oid("phase:resources")
    ext_resources_phase = oid("phase:ext-resources")
    target_config_list = oid("configlist:target")
    ext_config_list = oid("configlist:ext")
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
        + (f"\t\t\t\t{embed_phase} /* Embed Foundation Extensions */,\n" if ext_sources else "")
        + "\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n"
        "\t\t\tdependencies = (\n"
        + (f"\t\t\t\t{dependency_id} /* PBXTargetDependency */,\n" if ext_sources else "")
        + "\t\t\t);\n"
        f"\t\t\tname = {PROJECT_NAME};\n"
        f"\t\t\tproductName = {PROJECT_NAME};\n"
        f"\t\t\tproductReference = {product_ref} /* {PROJECT_NAME}.app */;\n"
        '\t\t\tproductType = "com.apple.product-type.application";\n'
        "\t\t};\n"
        + (
            f"\t\t{ext_target_id} /* {EXTENSION_NAME} */ = {{\n"
            "\t\t\tisa = PBXNativeTarget;\n"
            f"\t\t\tbuildConfigurationList = {ext_config_list};\n"
            "\t\t\tbuildPhases = (\n"
            f"\t\t\t\t{ext_sources_phase} /* Sources */,\n"
            f"\t\t\t\t{ext_frameworks_phase} /* Frameworks */,\n"
            f"\t\t\t\t{ext_resources_phase} /* Resources */,\n"
            "\t\t\t);\n"
            "\t\t\tbuildRules = (\n\t\t\t);\n"
            "\t\t\tdependencies = (\n\t\t\t);\n"
            f"\t\t\tname = {EXTENSION_NAME};\n"
            f"\t\t\tproductName = {EXTENSION_NAME};\n"
            f"\t\t\tproductReference = {ext_product_ref} /* {EXTENSION_NAME}.appex */;\n"
            '\t\t\tproductType = "com.apple.product-type.app-extension";\n'
            "\t\t};\n"
            if ext_sources else ""
        )
        + "/* End PBXNativeTarget section */"
    )

    # 앱이 익스텐션보다 먼저 빌드되면 복사할 appex 가 없다. 순서를 못 박는다.
    if ext_sources:
        objects.append(
            "/* Begin PBXContainerItemProxy section */\n"
            f"\t\t{proxy_id} /* PBXContainerItemProxy */ = {{\n"
            "\t\t\tisa = PBXContainerItemProxy;\n"
            f"\t\t\tcontainerPortal = {project_id} /* Project object */;\n"
            "\t\t\tproxyType = 1;\n"
            f"\t\t\tremoteGlobalIDString = {ext_target_id};\n"
            f"\t\t\tremoteInfo = {EXTENSION_NAME};\n"
            "\t\t};\n"
            "/* End PBXContainerItemProxy section */"
        )
        objects.append(
            "/* Begin PBXTargetDependency section */\n"
            f"\t\t{dependency_id} /* PBXTargetDependency */ = {{\n"
            "\t\t\tisa = PBXTargetDependency;\n"
            f"\t\t\ttarget = {ext_target_id} /* {EXTENSION_NAME} */;\n"
            f"\t\t\ttargetProxy = {proxy_id} /* PBXContainerItemProxy */;\n"
            "\t\t};\n"
            "/* End PBXTargetDependency section */"
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
        + (
            f"\t\t\t\t\t{ext_target_id} = {{\n"
            "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
            "\t\t\t\t\t};\n"
            if ext_sources else ""
        )
        + "\t\t\t\t};\n"
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
        + (f"\t\t\t\t{ext_target_id} /* {EXTENSION_NAME} */,\n" if ext_sources else "")
        + "\t\t\t);\n"
        "\t\t};\n"
        "/* End PBXProject section */"
    )

    section = ["/* Begin PBXResourcesBuildPhase section */"]
    section.append(
        f"\t\t{resources_phase} /* Resources */ = {{\n"
        "\t\t\tisa = PBXResourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        f"\t\t\t\t{assets_build} /* Assets.xcassets in Resources */,\n"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};"
    )
    if ext_sources:
        section.append(empty_phase(ext_resources_phase, "PBXResourcesBuildPhase", "Resources"))
    section.append("/* End PBXResourcesBuildPhase section */")
    objects.append("\n".join(section))

    def sources_phase_block(phase_id: str, files: list[tuple[str, str, str]]) -> str:
        return (
            f"\t\t{phase_id} /* Sources */ = {{\n"
            "\t\t\tisa = PBXSourcesBuildPhase;\n"
            "\t\t\tbuildActionMask = 2147483647;\n"
            "\t\t\tfiles = (\n"
            + "".join(
                f"\t\t\t\t{build_id} /* {name} in Sources */,\n"
                for build_id, _, name in sorted(files, key=lambda item: item[2])
            )
            + "\t\t\t);\n"
            "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
            "\t\t};"
        )

    section = ["/* Begin PBXSourcesBuildPhase section */"]
    section.append(sources_phase_block(sources_phase, build_files))
    if ext_sources:
        section.append(sources_phase_block(ext_sources_phase, ext_build_files))
    section.append("/* End PBXSourcesBuildPhase section */")
    objects.append("\n".join(section))

    # 빌드 설정. Config/Base.xcconfig 를 베이스로 깔아 두면
    # 팀 ID / 번들 ID 를 프로젝트 파일을 건드리지 않고 Local.xcconfig 로 덮어쓸 수 있다.
    configs = [
        (oid("config:project:Debug"), "Debug", PROJECT_DEBUG, True),
        (oid("config:project:Release"), "Release", PROJECT_RELEASE, True),
        (oid("config:target:Debug"), "Debug", TARGET_COMMON, False),
        (oid("config:target:Release"), "Release", TARGET_COMMON, False),
    ]
    if ext_sources:
        configs += [
            (oid("config:ext:Debug"), "Debug", EXTENSION_TARGET, False),
            (oid("config:ext:Release"), "Release", EXTENSION_TARGET, False),
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
    config_lists = [
        (project_config_list, f"PBXProject \"{PROJECT_NAME}\"",
         oid("config:project:Debug"), oid("config:project:Release")),
        (target_config_list, f"PBXNativeTarget \"{PROJECT_NAME}\"",
         oid("config:target:Debug"), oid("config:target:Release")),
    ]
    if ext_sources:
        config_lists.append(
            (ext_config_list, f"PBXNativeTarget \"{EXTENSION_NAME}\"",
             oid("config:ext:Debug"), oid("config:ext:Release"))
        )

    for list_id, label, debug_id, release_id in config_lists:
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
