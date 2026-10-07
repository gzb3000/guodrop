#!/usr/bin/env python3
"""
Flutter 平台脚手架生成器 — 替代 `flutter create`

为什么需要这个脚本：
  受管沙箱环境限制进程管道句柄，导致 `flutter create` 无法运行
  （报 CreateFile failed 231）。但 Flutter 自带的项目模板都在本地
  （packages/flutter_tools/templates/），我们直接渲染它们即可。

  本脚本做两件事：
    1. 把 .tmpl 模板按 Mustache 规则渲染成真实文件
    2. 渲染产物写入项目目录，且【不覆盖】已存在的手写配置文件
       （AndroidManifest.xml / Info.plist / *.entitlements）

用法：
    python tools/render_templates.py
"""

import os
import re
import shutil
import sys
from pathlib import Path

# ============ 配置 ============

PROJECT_NAME = "lan_share"
ORG = "com.example"
DESCRIPTION = "跨平台 WiFi 局域网文件传输工具"

# 从 Flutter SDK 的 gradle_utils.dart 读取的实际版本值
TEMPLATE_VARS = {
    "projectName": PROJECT_NAME,
    "titleCaseProjectName": "Lan Share",
    "description": DESCRIPTION,
    "organization": ORG,
    "androidIdentifier": f"{ORG}.{PROJECT_NAME}",
    "iosIdentifier": f"{ORG}.{PROJECT_NAME}",
    "macosIdentifier": f"{ORG}.{PROJECT_NAME}",
    "linuxIdentifier": f"{ORG}.{PROJECT_NAME}",
    "dartSdkVersionBounds": ">=3.4.0 <4.0.0",
    "year": "2026",
    # Android 构建版本（对应 Flutter 3.47.6 的默认值）
    "agpVersion": "9.1.0",
    "agpVersionForModule": "9.1.0",
    "kotlinVersion": "2.4.0",
    "gradleVersion": "9.3.1",
    "androidSdkVersion": "36",
    "compileSdkVersion": "36",
    "minSdkVersion": "24",
    "targetSdkVersion": "36",
    "ndkVersion": "28.2.13676358",
    # 条件开关
    "android": True,
    "ios": True,
    "macos": True,
    "windows": True,
    "linux": True,
    "web": False,
    "withEmptyMain": False,
    "withFfi": False,
    "withPluginHook": False,
    "withPlatformChannelPluginHook": False,
    "withSwiftPackageManager": False,
    "hasIosDevelopmentTeam": False,
}

FLUTTER_TEMPLATES = Path("C:/flutter/flutter/packages/flutter_tools/templates")
PROJECT_DIR = Path(__file__).resolve().parent.parent

# 这些文件是手写的，绝不能被模板覆盖
PROTECTED_FILES = {
    "android/app/src/main/AndroidManifest.xml",
    "ios/Runner/Info.plist",
    "macos/Runner/DebugProfile.entitlements",
    "macos/Runner/Release.entitlements",
    "pubspec.yaml",
    "README.md",
    # 我们自己写的源码目录
}
PROTECTED_PREFIXES = (
    "lib/",
    "test/",
    "tools/",
)


# ============ Mustache 渲染 ============


def render_mustache(template: str, variables: dict) -> str:
    """
    极简 Mustache 渲染器。

    只支持本项目模板用到的四种语法：
      {{var}}            — 变量替换（HTML 转义，但模板里都是普通文本）
      {{{var}}}          — 变量替换（不转义）
      {{#var}}...{{/var}} — 条件为真时保留区块
      {{^var}}...{{/var}} — 条件为假时保留区块

    不引入第三方库，因为模板语法很有限，手写反而更可控。
    """

    def find_block_end(text: str, start: int, open_tag: str, close_tag: str) -> int:
        """从 start 之后找到与 open_tag 配对的 close_tag 位置，支持嵌套"""
        depth = 1
        pos = start
        while pos < len(text):
            next_open = text.find(open_tag, pos)
            next_close = text.find(close_tag, pos)

            if next_close == -1:
                return -1
            if next_open != -1 and next_open < next_close:
                depth += 1
                pos = next_open + len(open_tag)
            else:
                depth -= 1
                if depth == 0:
                    return next_close
                pos = next_close + len(close_tag)
        return -1

    def strip_sections(text: str, var: str, is_inverted: bool) -> str:
        """
        处理某一变量的全部条件区块。

        is_inverted=False 处理 {{#var}}...{{/var}}（变量为真时保留）
        is_inverted=True  处理 {{^var}}...{{/var}}（变量为假时保留）

        注意：这里必须按标签本身的语法匹配。
        之前的实现把「保留条件」和「标签语法」混为一谈，
        导致 {{#web}} 去找 {{^web}} 而永远匹配不上。
        """
        if is_inverted:
            open_tag = "{{^" + var + "}}"
            # 取反区块：变量为假值时保留内容
            should_keep = not bool(variables.get(var, False))
        else:
            open_tag = "{{#" + var + "}}"
            # 正区块：变量为真值时保留内容
            should_keep = bool(variables.get(var, False))

        close_tag = "{{/" + var + "}}"

        while True:
            start = text.find(open_tag)
            if start == -1:
                break

            inner_start = start + len(open_tag)
            end = find_block_end(text, inner_start, open_tag, close_tag)
            if end == -1:
                break  # 模板损坏，保留原样避免死循环

            inner = text[inner_start:end]
            replacement = render_mustache(inner, variables) if should_keep else ""
            text = text[:start] + replacement + text[end + len(close_tag):]

        return text

    result = template

    # 处理所有条件区块。顺序上先处理取反区块（{{^var}}），
    # 再处理正区块（{{#var}}），避免嵌套时的配对错乱。
    ALL_VARS = [
        # 平台开关
        "android", "ios", "macos", "windows", "linux", "web",
        # 特性开关
        "withEmptyMain", "withFfi", "withPluginHook",
        "withPlatformChannelPluginHook", "withSwiftPackageManager",
        "hasIosDevelopmentTeam",
    ]

    # 反复几轮，处理嵌套区块
    for _ in range(3):
        for var in ALL_VARS:
            if "{{^" + var + "}}" in result:
                result = strip_sections(result, var, is_inverted=True)
        for var in ALL_VARS:
            if "{{#" + var + "}}" in result:
                result = strip_sections(result, var, is_inverted=False)

    # 三花括号变量（不转义）
    for key, value in variables.items():
        result = result.replace("{{{" + key + "}}", str(value))

    # 双花括号变量
    for key, value in variables.items():
        if isinstance(value, bool):
            continue
        result = result.replace("{{" + key + "}}", str(value))

    # 注意：不认识的 {{XXX}} 会被原样保留，这是刻意行为。
    # 例如 windows/runner/resource.h 首行的 {{NO_DEPENDENCIES}} 是
    # MSVC 编译器的指令，不是模板变量，必须原样输出。

    return result


# ============ 文件操作 ============


def is_protected(rel_path: str) -> bool:
    """判断文件是否受保护（不能覆盖）"""
    normalized = rel_path.replace("\\", "/")
    if normalized in PROTECTED_FILES:
        return True
    return any(normalized.startswith(p) for p in PROTECTED_PREFIXES)


def copy_and_render(src: Path, dst: Path, rel_path: str) -> str:
    """
    复制单个模板文件到目标位置并渲染。

    返回操作结果：'skipped'（已存在且受保护）/ 'created' / 'updated'
    """
    # 计算目标文件名（去掉 .tmpl 后缀，处理特殊命名）
    target_name = dst.name
    if target_name.endswith(".tmpl"):
        target_name = target_name[: -len(".tmpl")]

    # 模板里的特殊命名规则
    target_name = target_name.replace("projectName", PROJECT_NAME)
    target_name = target_name.replace("androidIdentifier", TEMPLATE_VARS["androidIdentifier"])
    target_name = target_name.replace(".img", "")

    target = dst.parent / target_name

    # 二进制文件直接复制
    if src.suffix in (".png", ".ico", ".jpg", ".jar", ".ttf", ".xcassets"):
        if target.exists():
            return "skipped"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, target)
        return "created"

    # 文本文件渲染
    try:
        content = src.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        if target.exists():
            return "skipped"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, target)
        return "created"

    rendered = render_mustache(content, TEMPLATE_VARS)

    # 受保护文件：只在不存在时写入
    try:
        rel = target.relative_to(PROJECT_DIR).as_posix()
    except ValueError:
        rel = target_name

    if is_protected(rel) and target.exists():
        return "skipped"

    if target.exists():
        existing = target.read_text(encoding="utf-8", errors="ignore")
        if existing == rendered:
            return "skipped"
        status = "updated"
    else:
        status = "created"

    target.parent.mkdir(parents=True, exist_ok=True)
    # 统一用 LF 换行，避免跨平台差异
    target.write_text(rendered, encoding="utf-8", newline="\n")
    return status


def normalize_dir_name(name: str) -> str:
    """
    规范化目录名。

    模板里的目录名有几种特殊形式需要转换：
      androidIdentifier  -> com/example/lan_share  （包名要拆成目录层级）
      projectName        -> lan_share
    """
    if name in ("androidIdentifier", "iosIdentifier", "macosIdentifier",
                "linuxIdentifier"):
        # 包名 com.example.lan_share 对应 com/example/lan_share 目录结构
        return TEMPLATE_VARS["androidIdentifier"].replace(".", "/")
    if name == "projectName":
        return PROJECT_NAME
    # 普通目录名里也可能内嵌占位符（少见，但保险处理）
    return name.replace("projectName", PROJECT_NAME)


def render_tree(src_root: Path, dst_root: Path, stats: dict, skip_top: tuple = ()):
    """
    递归渲染整个模板目录。

    skip_top: 需要跳过的顶层子目录名（避免把 android-java / android-kotlin
              这类语言变体模板重复展开到根目录）。
    """
    for item in sorted(src_root.rglob("*")):
        if item.is_dir():
            continue

        rel = item.relative_to(src_root)

        # 跳过指定的顶层目录
        if skip_top and rel.parts and rel.parts[0] in skip_top:
            continue

        parts = []
        for p in rel.parts:
            # 去掉 .tmpl 后缀
            if p.endswith(".tmpl"):
                p = p[:-5]
            parts.append(normalize_dir_name(p))

        rel_path = Path(*parts)
        dst = dst_root / rel_path
        result = copy_and_render(item, dst, str(rel_path))
        stats[result] = stats.get(result, 0) + 1


def main():
    if not FLUTTER_TEMPLATES.exists():
        print(f"错误：找不到 Flutter 模板目录 {FLUTTER_TEMPLATES}")
        print("请确认 Flutter SDK 已安装在 C:/flutter/flutter")
        return 1

    print(f"Flutter 模板: {FLUTTER_TEMPLATES}")
    print(f"目标项目   : {PROJECT_DIR}")
    print()

    stats = {}

    # 模板 → 目标目录 的映射。
    #
    # 关键点：不同模板的内部结构不同，落点也不同。
    # 例如 android.tmpl 内的路径已经是 android/app/... 形式，
    # 而 android-kotlin.tmpl 内是 app/build.gradle.kts 形式，
    # 需要额外落到 android/ 下，否则会生成一个错误的根级 app/ 目录。
    mapping = [
        # (模板目录, 目标子目录, 说明, 要跳过的顶层子目录)
        #
        # 注意 android.tmpl 内部路径以 app/ 和 gradle/ 开头，
        # 直接落到根目录会生成错误的顶层 app/ gradle/，
        # 必须指定目标为 android/。但它同时含 .gitignore，那个属于 android/。
        ("app", "", "基础 app 模板（windows/linux/macos/ios 主体）",
         ("android.tmpl", "android-kotlin.tmpl", "android-java.tmpl",
          "lib", "web")),
        ("app/android.tmpl", "android",
         "Android 通用部分（res、manifest、gradle wrapper）", ()),
        ("app/android-kotlin.tmpl", "android",
         "Android Kotlin 模板（gradle.kts、MainActivity）", ()),
    ]

    for tpl_name, dest_sub, desc, skip in mapping:
        tpl_path = FLUTTER_TEMPLATES / tpl_name
        if not tpl_path.exists():
            print(f"跳过（不存在）：{tpl_name}")
            continue

        dest = PROJECT_DIR / dest_sub if dest_sub else PROJECT_DIR
        print(f"渲染 {tpl_name}  ->  {dest_sub or '.'}  ({desc})")
        render_tree(tpl_path, dest, stats, skip_top=skip)

    # CocoaPods 的 Podfile 不在 app 模板里，单独处理
    for podfile_name, dest_path in [
        ("Podfile-ios", PROJECT_DIR / "ios" / "Podfile"),
        ("Podfile-macos", PROJECT_DIR / "macos" / "Podfile"),
    ]:
        src = FLUTTER_TEMPLATES / "cocoapods" / podfile_name
        if src.exists() and not dest_path.exists():
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest_path)
            stats["created"] = stats.get("created", 0) + 1
            print(f"渲染 cocoapods/{podfile_name}  ->  {dest_path.relative_to(PROJECT_DIR)}")

    # .metadata 文件（flutter create 也会生成，记录项目与 SDK 版本关联）
    metadata_path = PROJECT_DIR / ".metadata"
    if not metadata_path.exists():
        metadata_path.write_text(
            "# This file tracks properties of this Flutter project.\n"
            "# Used by Flutter tool to assess capabilities and perform upgrades etc.\n"
            "#\n"
            "# This file should be version controlled and should not be manually edited.\n"
            "\n"
            "version:\n"
            '  revision: "5fc346839b5d0eef006ed8404392afb4dfae428d"\n'
            '  channel: "stable"\n'
            "\n"
            "project_type: app\n"
            "\n"
            "# Tracks metadata for the flutter migrate command\n"
            "migration:\n"
            "  platforms:\n"
            "    - platform: root\n"
            "      create_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "      base_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "    - platform: android\n"
            "      create_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "      base_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "    - platform: ios\n"
            "      create_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "      base_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "    - platform: linux\n"
            "      create_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "      base_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "    - platform: macos\n"
            "      create_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "      base_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "    - platform: windows\n"
            "      create_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "      base_revision: 5fc346839b5d0eef006ed8404392afb4dfae428d\n"
            "\n"
            "  # To add assets to your application, add an assets section, like this:\n"
            "  # assets:\n"
            "  #   - images/a_dot_burr.jpeg\n"
            "  unmanaged_files:\n"
            "    - 'lib/main.dart'\n"
            "    - 'ios/Runner.xcodeproj/project.pbxproj'\n",
            encoding="utf-8",
            newline="\n",
        )
        stats["created"] = stats.get("created", 0) + 1
        print("生成 .metadata")

    print()
    print("=" * 50)
    print(f"  新建   : {stats.get('created', 0)} 个文件")
    print(f"  更新   : {stats.get('updated', 0)} 个文件")
    print(f"  跳过   : {stats.get('skipped', 0)} 个文件（已存在或受保护）")
    print("=" * 50)

    return 0


if __name__ == "__main__":
    sys.exit(main())
