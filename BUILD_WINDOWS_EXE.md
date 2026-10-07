# 局域网传输 · Windows 桌面版 —— 编译说明（给打包方）

## 这是什么

一个 Flutter 项目的完整源码包。**请在 Windows 上编译成桌面应用（exe）。**

跨平台局域网文件传输工具，协议兼容 LocalSend v2。
本包同时包含 Android / iOS / macOS / Linux / Windows 五个平台的完整脚手架，
**但本次只需要 Windows 桌面版**。

---

## 环境要求（缺一不可）

| 组件 | 要求 | 说明 |
|---|---|---|
| Flutter SDK | **3.4 或以上（stable 渠道）** | 推荐 3.47.x，本项目在此版本开发 |
| Visual Studio | **2022 或更新，含「使用 C++ 的桌面开发」工作负载** | Windows 桌面构建的必需项，光装 VS 本体不够 |
| MSVC 编译器 | v143 或以上 | 随上面的 C++ 工作负载一起装 |
| CMake | 3.14+ | **VS 自带**，无需单独装 |
| Ninja | — | **VS 自带**，无需单独装 |
| Windows SDK | 10.0.19041.0 或以上 | 随 VS 安装器勾选 |
| Git | 任意版本 | Flutter 需要它读版本号 |

### 快速自检

```powershell
flutter doctor -v
```

**必须看到这一行才算环境就绪**：
```
[√] Visual Studio - develop Windows apps (Visual Studio Community 2022 ...)
```

如果显示 `[X] Visual Studio` 或 `[!]`，说明 C++ 桌面开发工作负载没装。
去 VS 安装器里补上「使用 C++ 的桌面开发」，勾选：
- MSVC v143 - VS 2022 C++ x64/x86 生成工具
- 适用于 Windows 的 C++ CMake 工具
- Windows 10/11 SDK

---

## 编译步骤

```powershell
# 1. 解压
Expand-Archive -Path lan_share.zip -DestinationPath . -Force
cd lan_share

# 2. 拉依赖（必须！不能跳过）
flutter pub get

# 3. 编译 Release 版
flutter build windows --release
```

### 产物位置

```
build\windows\x64\runner\Release\
├── lan_share.exe              ← 主程序
├── flutter_windows.dll        ← Flutter 运行时（必需）
├── *.dll                      ← 各插件的原生库
└── data\                      ← 资源文件夹（必需）
    ├── icudtl.dat
    ├── app.so
    └── flutter_assets\
```

**整个 Release 目录要一起分发，不能只拿 exe。**
双击 `lan_share.exe` 即可运行。

---

## 常见错误

### 1. `Unable to find suitable Visual Studio toolchain`

C++ 桌面开发工作负载没装。见上面的环境要求。

### 2. `Building with plugins requires symlink support`

Windows 上创建符号链接需要权限。两种解法：
- 开启开发者模式：`设置 → 隐私和安全性 → 开发者选项 → 开发人员模式`（推荐）
- 或者用管理员身份运行终端

### 3. `flutter pub get` 卡住 / 超时

国内网络访问 pub.dev 很慢。设置镜像：

```powershell
$env:PUB_HOSTED_URL="https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
flutter pub get
```

### 4. `flutter` 命令没反应、零输出

`flutter.bat` 有个锁文件机制，残留进程会导致它**静默死循环**（不打印任何东西）。

排查：
```powershell
Get-Process | Where-Object { $_.Path -like "*flutter*" } | Select-Object Id, ProcessName
Remove-Item "$env:FLUTTER_ROOT\bin\cache\flutter.bat.lock" -Force
```
还不行就重启电脑。

### 5. `Building with plugins requires downloading artifacts` / 引擎下载慢

设置存储镜像：
```powershell
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
```

### 6. 编译到一半报 `ninja: error: ... missing`

`build\` 目录有脏数据。清掉重来：
```powershell
flutter clean
flutter pub get
flutter build windows --release
```

---

## ⚠️ 重要约束

1. **不要升级任何依赖版本。** `pubspec.lock` 必须原样保留。
   所有依赖的 API 都经过逐一核对，主版本升级有破坏性变更，会直接编译失败。
   （`pub get` 可能提示 20 个包有新版本，**忽略它**。）

2. **不要动 `windows/` 目录下的文件。**
   里面的 `CMakeLists.txt`、`Runner`、`flutter/` 都是对的，改了就编不过。

3. **不要用 `flutter create` 重建项目。**
   本项目已包含完整的多平台脚手架。

4. **不要删除 `lib/` 下任何文件。**

5. **`pubspec.yaml` 里没有 assets 目录依赖**，`assets/` 文件夹是空的，
   可以忽略（不删也行）。

---

## 项目结构速览

```
lan_share/
├── lib/                        ← 全部 Dart 源码（约 4000 行）
│   ├── main.dart               ← 入口
│   ├── core/
│   │   ├── models/             ← protocol.dart / device.dart
│   │   ├── discovery/          ← UDP 组播 + 广播发现
│   │   ├── transport/          ← HTTP 服务端 + 客户端
│   │   ├── scan/               ← 二维码
│   │   └── utils/              ← 组播锁、文件管理器调用、偏好设置
│   └── ui/                     ← 界面（4 页面 + 5 组件）
├── windows/                    ← Windows 平台脚手架（勿动）
├── android/                    ← Android 平台脚手架（本次不需要）
├── ios/ macos/ linux/          ← 其他平台（本次不需要）
├── pubspec.yaml                ← 依赖声明
└── pubspec.lock                ← ⚠️ 锁定版本，必须保留
```

---

## 编译完成后

请提供 **整个 `Release` 目录的压缩包**，不要只给 exe 文件。

也可以额外提供一个**单文件版本**（如果你有现成工具）：
- [Enigma Virtual Box](https://enigmaprotector.com/en/downloads.html)（免费，把整个目录封装成一个 exe）
- 或 Inno Setup 做安装包

单文件版和目录版都给，用户可自选。

---

## 可选：验证编译结果

应用启动后会：
1. 显示本机名称和 IP
2. 监听 `TCP 0.0.0.0:53317`（HTTP 接收）和 `UDP 0.0.0.0:53317`（设备发现）
3. 在 53317 端口提供网页上传界面

验证命令：
```powershell
netstat -ano | findstr 53317
```
应该看到 TCP LISTENING 和 UDP 两条记录。

**注意**：首次运行 Windows 防火墙会弹窗询问是否允许网络访问，
**必须勾选「专用网络」并允许**，否则局域网内其他设备连不上。
