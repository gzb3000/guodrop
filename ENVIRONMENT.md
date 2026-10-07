# 环境配置记录

记录本机 Flutter 环境搭建过程中遇到的所有问题和解法。
如果你换了机器或重装环境，照这份文档走一遍即可。

## 当前环境

| 项 | 版本 / 路径 |
|---|---|
| Flutter SDK | 3.47.6 (stable) |
| Dart SDK | 3.13.5 |
| SDK 位置 | `C:/flutter/flutter` |
| 完整版 Git | `C:/Program Files/Git/cmd/git.exe` |
| pub 镜像 | `https://pub.flutter-io.cn` |
| Flutter 存储镜像 | `https://storage.flutter-io.cn` |

## 已执行的安装步骤

### 1. 解压 SDK

下载 `flutter_windows_3.47.6-stable.zip`（约 1.79 GB）后：

```bash
mkdir -p C:/flutter
cd C:/flutter
tar -xf /d/flutter_windows_3.47.6-stable.zip
```

解压后 SDK 位于 `C:/flutter/flutter`（官方压缩包内含一层 `flutter/` 目录）。

### 2. 修复 Git 安全目录

Git 2.35+ 会拒绝操作 owner 与自己不一致的仓库。Flutter 目录如果
从别处拷贝而来，必须声明为安全目录：

```bash
git config --global --add safe.directory C:/flutter/flutter
```

### 3. 拉取 flutter_tools 依赖

`flutter_tools` 本身的依赖必须先装好，否则快照无法使用：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
cd C:/flutter/flutter/packages/flutter_tools
C:/flutter/flutter/bin/cache/dart-sdk/bin/dart.exe pub get
```

### 4. 重建 flutter_tools 快照

如果 SDK 解压后的快照与当前 Dart 版本不匹配（表现为运行 flutter
无任何输出），需要重建：

```bash
cd C:/flutter/flutter
C:/flutter/flutter/bin/cache/dart-sdk/bin/dart.exe \
  --snapshot-kind=app-jit \
  --snapshot=bin/cache/flutter_tools.snapshot \
  packages/flutter_tools/bin/flutter_tools.dart
```

### 5. 绕过 git 版本探测

Flutter 启动时会调 `git log` 读 commit hash。若 git 调用失败会直接崩。
手工创建版本缓存文件可跳过这一步：

```bash
cat > C:/flutter/flutter/bin/cache/flutter.version.json <<'EOF'
{
  "frameworkVersion": "3.47.6",
  "channel": "stable",
  "repositoryUrl": "https://github.com/flutter/flutter.git",
  "frameworkRevision": "5fc346839b5d0eef006ed8404392afb4dfae428d",
  "frameworkCommitDate": "2026-09-29 18:09:00 +0000",
  "engineRevision": "5fc346839b5d0eef006ed8404392afb4dfae428d",
  "dartSdkVersion": "3.13.5",
  "devToolsVersion": "2.48.0",
  "flutterVersion": "3.47.6",
  "flutterRoot": "C:/flutter/flutter"
}
EOF
```

### 6. 验证

在**普通终端**（非受管沙箱）里执行：

```bash
export PATH="/c/Program Files/Git/cmd:$PATH"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
C:/flutter/flutter/bin/flutter.bat --version
```

## 项目初始化（下一步）

平台脚手架需要生成一次：

```bash
cd "C:/Users/Administrator/WorkBuddy AI/2026-10-06-20-31-50/lan_share"
C:/flutter/flutter/bin/flutter.bat create . \
  --platforms=android,ios,macos,windows,linux \
  --org com.example --project-name lan_share
```

**注意**：`flutter create` 不会覆盖已存在的文件，所以本仓库里
已经写好的 `android/app/src/main/AndroidManifest.xml`、
`ios/Runner/Info.plist`、`macos/Runner/*.entitlements` 会保留。
但如果它生成了同名文件并覆盖，需要从 git 恢复这几个配置文件。

然后拉依赖并运行：

```bash
C:/flutter/flutter/bin/flutter.bat pub get
C:/flutter/flutter/bin/flutter.bat run -d windows
```

## 已知环境限制

**受管沙箱内无法运行 flutter / dart analyze / dart compile。**

原因是这些命令都依赖子进程（`gen_kernel_aot`、`analysis_server`、
`dartaotruntime`），而沙箱对进程管道句柄有硬性限制，会报：

```
CreateFile failed 231 (所有的管道范例都在使用中。)
ProcessException at process_win.cc:744
```

**解法**：在普通 PowerShell / CMD / Git Bash 终端里执行编译与分析，
不要在 AI 助手的受管环境里跑。

已验证可行的操作：
- `dart pub get`（纯网络 IO，无子进程）—— 86 个依赖全部解析成功
- `git` 操作

## 加速配置

建议把这些写进系统环境变量，永久生效：

```
PUB_HOSTED_URL=https://pub.flutter-io.cn
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

实测差距：pub.dev 6.8s → 镜像 0.7s，约 **10 倍**提速。
