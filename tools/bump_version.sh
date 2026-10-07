#!/usr/bin/env bash
# 同时修改两处版本号：bash tools/bump_version.sh 0.3.0 2003
set -euo pipefail
cd "$(dirname "$0")/.."
V="$1"; B="$2"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "版本号须为 x.y.z"; exit 1; }
sed -i.bak -E "s/^version: .*/version: $V+$B/" pubspec.yaml && rm -f pubspec.yaml.bak
sed -i.bak -E "s/(static const currentVersion = ')[^']*(')/\1$V\2/" lib/core/version/version_check_service.dart && rm -f lib/core/version/version_check_service.dart.bak
grep -n '^version:' pubspec.yaml; grep -n 'currentVersion = ' lib/core/version/version_check_service.dart
echo "下一步：git commit -am 'v$V' && git tag v$V && git push --tags"
