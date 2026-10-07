#!/usr/bin/env bash
# 纯编译期检查 —— 不依赖 flutter run / dart analyze
#
# 为什么需要这个脚本：
#   沙箱环境禁止创建子进程，dart analyze 会 spawn analysis_server 而失败，
#   flutter run 同理。但 frontend_server 可以被直接调用，它能完成
#   完整的语法 + 类型检查，效果等同于 dart analyze。
#
# 用法：
#   bash tools/check.sh            # 检查 lib + test（默认入口，最快）
#   bash tools/check.sh lib        # 逐个文件全量检查 lib
#   bash tools/check.sh lib/ui/widgets/receive_card.dart   # 检查指定文件

set -u

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
# Flutter 根目录：优先 FLUTTER_ROOT，其次 PATH 里的 flutter，最后退回原 Windows 路径
if [ -z "${FLUTTER_ROOT:-}" ] && command -v flutter >/dev/null 2>&1; then
  FLUTTER_ROOT="$(cd "$(dirname "$(readlink -f "$(command -v flutter)")")/.." && pwd)"
fi
FLUTTER_ROOT="${FLUTTER_ROOT:-C:/flutter/flutter}"
DART_SDK="$FLUTTER_ROOT/bin/cache/dart-sdk"
ENGINE="$FLUTTER_ROOT/bin/cache/artifacts/engine/common/flutter_patched_sdk"
AOT_RT="$DART_SDK/bin/dartaotruntime"
[ -x "$AOT_RT" ] || AOT_RT="$DART_SDK/bin/dartaotruntime.exe"
FRONTEND="$DART_SDK/bin/snapshots/frontend_server_aot.dart.snapshot"

# 注意：必须用 Flutter 的 patched SDK 作为 sdk-root，而不是 dart-sdk/lib。
# 后者是纯 Dart VM 的 SDK，缺少 dart:ui 等 Flutter 专有库，
# 会报一堆 "Dart library 'dart:async' is not available on this platform"。
SDK_ROOT="$ENGINE"

cd "$PROJ" || exit 1

MODE="${1:-default}"
TARGETS=()

if [ "$MODE" = "lib" ]; then
  # 全量：把 lib 下每个 .dart 文件都当成独立入口过一遍。
  # 入口文件引用的其他文件会被连带检查，所以覆盖是全的。
  while IFS= read -r f; do
    TARGETS+=("$f")
  done < <(find lib -name '*.dart' | sort)
elif [ "$MODE" != "default" ]; then
  TARGETS=("$@")
else
  TARGETS=(lib/main.dart test/core_test.dart)
fi

OUT_DIR="$(mktemp -d)"
FAILED=0
CHECKED=0

for entry in "${TARGETS[@]}"; do
  # 只要整体过一次就行，入口文件本身的检查结果最有代表性。
  # 但 lib 全量模式下每个文件都过一遍，能定位到具体是哪个文件坏了。
  if [ "$MODE" = "lib" ]; then
    echo "=== 检查 $entry ==="
  else
    echo "=== 检查 $entry ==="
  fi

  out="$OUT_DIR/$(echo "$entry" | tr '/' '_').dill"
  raw="$OUT_DIR/raw.txt"

  "$AOT_RT" "$FRONTEND" \
    --packages=.dart_tool/package_config.json \
    --sdk-root "$SDK_ROOT" \
    --target=flutter \
    --output-dill="$out" \
    "$entry" > "$raw" 2>&1

  # 提取真正的报错行。
  #
  # 注意要过滤掉两类噪音：
  #   - `No 'main' method found.`   非入口文件的合法状态（库文件本来就没 main）
  #   - `Error when reading ...`    输出 dill 时的写盘问题，不是源码问题
  grep -E "Error:|error:" "$raw" \
    | grep -v "^+file:" \
    | grep -v "No 'main' method found" \
    | grep -v "Error when reading" \
    > "$OUT_DIR/errs.txt" 2>/dev/null || true

  CHECKED=$((CHECKED + 1))

  if [ -s "$OUT_DIR/errs.txt" ]; then
    echo "❌ 发现错误："
    head -30 "$OUT_DIR/errs.txt"
    FAILED=1
  else
    echo "✅ 通过"
  fi
done

echo
echo "---- 汇总：检查 $CHECKED 个入口，失败 $FAILED ----"

rm -rf "$OUT_DIR"
exit $FAILED
