# 打包 Android APK 说明

## 这个包是什么

`lan_share` 是一个 Flutter 跨平台局域网文件传输 App 的**完整源码**。

目标：编译出 Android 安装包（`.apk`）。

---

## ⚠️ 必读：APK 必须编译，不能直接解压得到

**`.apk` 是编译产物，不是压缩包。** 光有源码无法得到 apk，
必须在有 Flutter + Android 工具链的机器上执行 `flutter build apk`。

如果接收方没有这套环境，请先把下面的「环境要求」发给他确认。

---

## 环境要求

| 组件 | 版本要求 | 说明 |
|---|---|---|
| Flutter SDK | 3.47.6（或 3.4+ 的其他 stable 版本） | 必须是 **stable** 渠道 |
| Dart | 3.13.5（随 Flutter 附带） | — |
| JDK | 17 或更高 | Android Gradle Plugin 需要 |
| Android SDK | **Platform 36 或 37** + **Build-Tools 36+** | — |
| Android SDK Command-line Tools | latest | **必需**，缺了会报 `cmdline-tools component is missing` |
| 环境变量 | `ANDROID_HOME` 或 `ANDROID_SDK_ROOT` | 指向 Android SDK 目录 |

**验证环境是否就绪：**

```bash
flutter doctor
```

`Android toolchain` 那一项必须是 `[✓]`。如果是 `[!]`，按提示补齐
（通常缺 cmdline-tools 或 license 未接受）。

接受 license：

```bash
flutter doctor --android-licenses
```

---

## 打包步骤

### 1. 解压

解压到任意目录（**不要有中文、不要有空格**），例如 `D:\build\lan_share`。

### 2. 拉依赖

```bash
cd lan_share
flutter pub get
```

> 国内网络建议先设镜像（直连 pub.dev 可能很慢）：
> ```bash
> # Windows PowerShell
> $env:PUB_HOSTED_URL="https://pub.flutter-io.cn"
> $env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
> ```
> ```bash
> # macOS / Linux / Git Bash
> export PUB_HOSTED_URL=https://pub.flutter-io.cn
> export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
> ```

### 3. 打包

**通用 APK**（一个包兼容所有 CPU 架构，体积较大，约 40-60 MB）：

```bash
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

---

**分架构 APK**（每个包更小，但需要按手机架构安装对应的包）：

```bash
flutter build apk --release --split-per-abi
```

产物（三个）：
```
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk    ← 老设备
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk      ← 主流手机（推荐）
build/app/outputs/flutter-apk/app-x86_64-release.apk         ← 模拟器
```

**现代手机基本都装 `arm64-v8a` 那个。**

---

## 首次构建可能遇到的问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `cmdline-tools component is missing` | 没装 Command-line Tools | 在 Android Studio 的 SDK Manager → SDK Tools 里勾上 |
| `Android license status unknown` | 许可未接受 | 跑 `flutter doctor --android-licenses`，一路输 `y` |
| `Unsupported class file major version` | JDK 版本过高或过低 | 换 JDK 17 |
| Gradle 下载极慢 / 超时 | 网络问题 | 开代理（全局模式），或配 Gradle 国内镜像 |
| `Execution failed for task ':app:...'` 首次构建 | Gradle 首次要下很多依赖 | 正常，耐心等 5-15 分钟 |

**首次构建慢是正常的** —— Gradle 要下载自身 + Android Gradle Plugin + 一堆
依赖，几百 MB。之后再构建就快了。

---

## 关于签名

**默认构建出来的是 debug 签名的 release 包**（Flutter 的默认行为），
**可以正常安装到手机**，但：

- 不能上架 Google Play（需要正式签名）
- 不同机器构建的包签名不同，**覆盖安装会失败**，需先卸载旧版

如果只是自用/内测，**不用配签名，直接装**。

---

## 安装到手机

**方式一：数据线**

手机开「开发者选项 → USB 调试」，连电脑后：

```bash
flutter install
```

或者手动推送到手机：

```bash
adb install build/app/outputs/flutter-apk/app-release.apk
```

**方式二：传文件**

把 apk 拷到手机（微信/QQ/U盘都行），用文件管理器点击安装。
需要在手机设置里允许「安装未知来源应用」。

---

## 项目结构（供参考）

```
lan_share/
├── lib/                    Dart 源码（约 3600 行）
│   ├── core/
│   │   ├── models/         protocol.dart（协议常量）、device.dart（设备模型）
│   │   ├── discovery/      UDP 组播发现服务
│   │   ├── transport/      HTTP 传输服务（含浏览器上传页）
│   │   ├── scan/           二维码生成/解析
│   │   └── utils/          设备信息、本地持久化
│   ├── ui/                 界面（4 页面 + 5 组件 + 全局状态）
│   └── main.dart
├── android/                Android 平台配置
│   └── app/src/main/AndroidManifest.xml   ← 权限声明在这里
├── test/                   单元测试
├── tools/                  脚手架生成器 + 静态检查脚本
├── pubspec.yaml            依赖声明
└── pubspec.lock            依赖锁定版本（务必保留）
```

**注意 `pubspec.lock` 必须保留** —— 它锁定 89 个依赖的确切版本。
删掉的话 `pub get` 会拉取最新的主版本，可能引入不兼容的 API 变更导致编译失败。

---

## 技术要点（如果编译报错需要排查）

- **协议兼容 LocalSend v2**：组播地址 `224.0.0.167`、端口 `53317`，
  HTTP 路径 `/api/localsend/v2/upload` 等
- **Android 权限**：`AndroidManifest.xml` 里已声明
  `CHANGE_WIFI_MULTICAST_STATE`（组播必需）、`NEARBY_WIFI_DEVICES`、
  `INTERNET`、存储权限。**这些是必需的，不要删**
- **明文 HTTP**：`usesCleartextTraffic="true"` 已开启，局域网 HTTP 传输需要
- **依赖版本**：pubspec.yaml 里锁的是经过 API 核对的主版本，
  `flutter pub upgrade` 可能导致编译错误，**不建议升级**

---

## 快速验证（可选）

如果只想先确认代码本身没有语法错误，不构建：

```bash
# 需要额外装 Bash（Windows 上用 Git Bash）
bash tools/check.sh
```

这个脚本直接调用 Dart 的 `frontend_server` 做类型检查，
不依赖 `flutter analyze`，几秒出结果。
