#!/bin/bash
# Flutter 调用包装脚本
#
# 本机环境下有两个坑，这个脚本负责绕开：
#
# 1. PATH 里第一个 git 是 PortableGit 里的残缺版本，Flutter 调它读
#    版本号时会崩（CreateFile failed 231）。脚本把系统完整版 Git
#    提到 PATH 最前。
#
# 2. pub.dev 直连要 6.8 秒，国内镜像只要 0.7 秒，差 10 倍。
#    脚本预设镜像地址，可在外部用环境变量覆盖。
#
# 另外已手工创建 bin/cache/flutter.version.json，
# 让 Flutter 跳过 git 版本探测这一步。

export PATH="/c/Program Files/Git/cmd:$PATH"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
export FLUTTER_SUPPRESS_ANALYTICS=true

FLUTTER_ROOT="C:/flutter/flutter"
DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart.exe"
SNAPSHOT="$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"

"$DART" "$SNAPSHOT" "$@"
