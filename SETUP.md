# 项目运行指南

## 环境依赖清单（先看这个）

**Windows 桌面版：零额外下载。** 本机已装齐，实测确认：

| 组件 | 版本 | 状态 |
|---|---|---|
| Flutter SDK | 3.47.6 / Dart 3.13.5 | ✅ `C:\flutter\flutter` |
| Visual Studio | 18 Community | ✅ |
| MSVC 编译器 | 14.50.35717 | ✅ |
| CMake / Ninja | VS 内置 | ✅ |
| Windows SDK | 10.0.26100.0 | ✅ |

> 注意：`C:\Program Files\CMake` 不存在是**正常的**，Flutter 会用 VS 自带的
> CMake 和 Ninja，不需要单独安装。

**其他平台要先装东西：**

| 目标 | 需要安装 | 体积 | 备注 |
|---|---|---|---|
| Android 打包 | Android Studio 或 Android SDK | 数 GB | 本机**未安装**，建议提前下 |
| macOS / iOS | Mac 电脑 | — | Windows 上无解，必须换设备 |

## 现在就能跑

项目脚手架已经**全部生成完毕**，不需要再执行 `flutter create`。

> 注意：`C:/flutter` 不一定是最终位置。如果你把 SDK 挪到别处
> （比如 `D:/flutter`），下面所有命令里的路径都要同步替换。

**Windows 用户（PowerShell）：**

```powershell
cd "C:\Users\Administrator\WorkBuddy AI\2026-10-06-20-31-50\lan_share"

# 设置镜像（强烈建议，直连 pub.dev 慢 10 倍）
$env:PUB_HOSTED_URL="https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"

# 拉依赖（必须执行！见下方「为什么必须跑 flutter pub get」）
C:\flutter\flutter\bin\flutter.bat pub get

# 先确认 Windows 桌面工具链可用（看不到 Visual Studio 就要装）
C:\flutter\flutter\bin\flutter.bat doctor

# 运行
C:\flutter\flutter\bin\flutter.bat run -d windows
```

> ### 为什么必须跑 `flutter pub get`（不是可选的）
>
> 项目里的 `.dart_tool/package_config.json` 是**用 `dart pub get`
> 生成的，不是 `flutter pub get`**。两者差别很大：
>
> `flutter pub get` 除了拉包，还会**额外生成三类平台构建文件**：
>
> | 文件 | 作用 | 缺了会怎样 |
> |---|---|---|
> | `windows/flutter/generated_plugins.cmake` | 声明要编译的原生插件 | CMake 在 `include()` 那行直接报错 |
> | `windows/flutter/ephemeral/.plugin_symlinks/` | 指向插件源码的符号链接 | 找不到插件目录 |
> | `windows/flutter/generated_config.cmake` | Flutter 库路径等 | 链接阶段失败 |
>
> 本项目在 Windows 上需要编译 **2 个原生插件**：`permission_handler_windows`
> 和 `jni`（后者是 mobile_scanner 的传递依赖，`ffiPlugin: true`）。
>
> 所以：**第一次运行前务必先跑 `flutter pub get`**，让它把上面这些补齐。
> 手动创建这些文件是没用的——`ephemeral/.plugin_symlinks/` 里的符号链接
> 必须由工具创建。

**Git Bash 用户：**

```bash
cd "C:/Users/Administrator/WorkBuddy AI/2026-10-06-20-31-50/lan_share"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
C:/flutter/flutter/bin/flutter.bat pub get   # 必须，用于生成平台构建文件
C:/flutter/flutter/bin/flutter.bat run -d windows
```

**关于 `flutter doctor`** —— 第一次务必跑一遍。三个最常见的红灯：

- **Visual Studio** 未安装 → Windows 桌面编译不了，装
  「Visual Studio 2022 Community」并勾选**「使用 C++ 的桌面开发」**工作负载
  （只装 VS 本体不够，必须勾这个负载，否则找不到 `MSBuild`/`cl.exe`）
- **Android toolchain** 缺 SDK 或 licenses 未接受 →
  `flutter doctor --android-licenses` 逐条输入 `y`
- 提示 `cmdline-tools component is missing` → 用 Android Studio 的
  SDK Manager 勾上 `Android SDK Command-line Tools`

**只想先看看界面长什么样**，可以先跑 Web 版（零额外依赖，最省事）：

```bash
C:/flutter/flutter/bin/flutter.bat run -d chrome
```

Web 版能验证 UI 布局和状态管理，但**网络层是残缺的**：浏览器里没有
UDP 组播，也起不了本地 HTTP 服务器，所以设备发现和接收功能不可用。
要测真实传输还是得上 Windows 桌面版。

其他平台：

```bash
C:/flutter/flutter/bin/flutter.bat devices          # 先看有哪些可用设备
C:/flutter/flutter/bin/flutter.bat run -d macos     # 需在 macOS 上执行
C:/flutter/flutter/bin/flutter.bat build apk        # Android 打包
```

## 故障排查

### `flutter` 命令完全没反应、零输出？

不要怀疑是构建慢。真实原因几乎总是**残留进程持着锁**。

`flutter.bat` 内部（`bin/internal/shared.bat`）用一个忙等循环抢
`bin/cache/flutter.bat.lock` 的排他锁，**抢不到就静默死转，不打印任何东西**。

**三步定位：**

```bash
# 1. 看有没有 0 字节的残留锁
ls -la C:/flutter/flutter/bin/cache/flutter.bat.lock

# 2. 看有没有孤儿进程（Git Bash 的 ps -W 能看到沙箱外的进程）
ps -W | grep -iE "dart|flutter"
```

**解决**（需要管理员权限的 PowerShell）：

```powershell
Get-Process | Where-Object { $_.Path -like "C:\flutter\*" } | Stop-Process -Force
Remove-Item "C:\flutter\flutter\bin\cache\flutter.bat.lock" -Force
```

杀掉后确认清干净了（应当无输出）：

```powershell
Get-Process | Where-Object { $_.Path -like "C:\flutter\*" } | Select-Object Id,ProcessName
```

**如果杀不掉，直接重启电脑** —— 最省事，僵尸进程和锁文件会一并清空。

### 首次运行可能遇到的事

**Windows 防火墙弹窗** —— 必须勾选「专用网络」。选错的话需要手动到
「Windows Defender 防火墙 → 允许应用通过防火墙」里补上，否则其他设备
发现不了你。

**端口 53317 被占用** —— 如果同时装了 LocalSend，两者会抢同一个端口。
启动日志里会打印绑定失败。改 `lib/core/models/protocol.dart` 里的
`defaultPort` 即可。

## 测试

```bash
C:/flutter/flutter/bin/flutter.bat test
```

`test/core_test.dart` 覆盖的是纯逻辑（二维码解析、IP 校验、Device
序列化、字节格式化），不需要设备也不需要网络，应该秒过。

## 不装设备也能做的静态检查：`tools/check.sh`

```bash
bash tools/check.sh
```

这个脚本绕过 `flutter` / `dart analyze`，直接调用 Dart SDK 里的
`frontend_server` 做完整的**语法 + 类型检查**，输出与 `dart analyze`
基本等价，但**不需要能创建子进程**，所以在受限环境里也能跑。

原理上有两个关键点，改脚本时别踩：

1. **`--sdk-root` 必须指向 Flutter 的 patched SDK**：
   `C:/flutter/flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk/`
   如果指向 `dart-sdk/lib/`（纯 Dart VM 的 SDK），会缺 `dart:ui`，
   报满屏 `Dart library 'dart:async' is not available on this platform`
2. **`--target=flutter`**，不是 `vm`

它检查的是编译错误，不检查 lint 规则（`avoid_print` 之类）。
lint 还是要靠 `flutter analyze`。

## 如果平台文件丢失或需要重新生成

`tools/render_templates.py` 是脚手架生成器，它直接渲染 Flutter SDK
自带的模板（`C:/flutter/flutter/packages/flutter_tools/templates/`），
效果等同于 `flutter create`，但有两点不同：

1. **不会覆盖手写的平台配置文件** —— AndroidManifest.xml、Info.plist、
   `*.entitlements` 这些含有关键权限声明的文件受保护，只在不存在时创建
2. **可在沙箱环境运行** —— 不依赖子进程

```bash
"C:/Users/Administrator/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe" \
  tools/render_templates.py
```

生成结果：Android 19 个文件、iOS 41 个、macOS 28 个、Windows 15 个、
Linux 7 个。

### 脚本做了什么

模板用 Mustache 语法，脚本实现了最小渲染器：

- `{{var}}` / `{{{var}}}` —— 变量替换
- `{{#var}}...{{/var}}` —— 变量为真时保留
- `{{^var}}...{{/var}}` —— 变量为假时保留

两个容易踩的坑，脚本已处理：

1. **目录名转路径** —— 模板里包名写作 `androidIdentifier`，
   需要展开成 `com/example/lan_share` 的目录层级
2. **模板落点不同** —— `android-kotlin.tmpl` 内部路径以 `app/` 开头，
   必须落到 `android/` 下，否则会生成错误的顶层 `app/` 目录

### 修改项目名或包名

改脚本顶部的 `PROJECT_NAME` 和 `ORG`，然后删掉对应平台目录重新生成。
注意 `pubspec.yaml` 里的 `name` 字段也要同步改。

## 开发建议

改 Dart 代码时用热重载，不用重启：

```bash
C:/flutter/flutter/bin/flutter.bat run -d windows
# 运行后按 r 热重载，按 R 热重启
```

调试网络层时，VSCode 的 Flutter 插件比命令行顺手，可以打断点看
UDP 收包和 HTTP 请求的实际情况。
