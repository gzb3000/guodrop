# lan_share — 交接说明（先读这个）

跨平台 WiFi 局域网文件传输工具。协议兼容 LocalSend v2。

---

## 一、这个包里有什么

总共 **168 个文件**，全部是源码和文档，**不含任何编译产物**
（`build/`、`.dart_tool/`、`ephemeral/` 都已排除，可以放心解压）。

```
lan_share/
├── README.md                    ← 本文件（总索引）
├── HANDOFF_AUTO_UPDATE.md       ← ★ 自动更新功能的交接文档（你要做的主要是这件）
│
├── BUILD_APK.md                 ← 打包 Android APK 的步骤
├── BUILD_WINDOWS_EXE.md         ← 打包 Windows exe 的步骤
├── FIX_NOTES.md                 ← 已修复问题的记录
├── SETUP.md                     ← 环境搭建
├── ENVIRONMENT.md               ← 环境要求
│
├── cloudflare/                  ← ★ 版本发布后端（自动更新依赖它）
│   ├── README.md                ← 部署 7 步
│   └── functions/api/version.js ← 版本接口代码
│
├── lib/                         ← Dart 源码（24 个 .dart）
│   ├── main.dart
│   ├── core/
│   │   ├── discovery/           设备发现（UDP 组播 + 广播）
│   │   ├── transport/           HTTP 传输
│   │   ├── models/              协议常量、设备模型
│   │   ├── scan/                扫码
│   │   ├── utils/               ← ★ 你要新增文件的地方
│   │   └── version/             ← 已有的版本检查逻辑
│   └── ui/                      界面
│       ├── app_state.dart       全局状态
│       ├── pages/               ← ★ force_update_screen.dart 在这
│       └── widgets/
│
├── android/                     ← ★ 你要改 Android 配置的地方
│   └── app/src/main/
│       ├── AndroidManifest.xml  ← 加权限 + 注册 FileProvider
│       ├── kotlin/.../MainActivity.kt  ← 加安装器 MethodChannel
│       └── res/                 ← 需要新建 xml/ 子目录
│
├── ios/  macos/  windows/  linux/   ← 其他平台（配置已就绪，一般不用动）
├── test/
├── tools/
│   ├── check.sh                 ← ★ 静态检查（这个环境唯一的检查手段）
│   └── render_templates.py
└── pubspec.yaml / pubspec.lock  ← ★ 依赖清单，不要改
```

---

## 二、要做什么

**主要任务：实现「自动下载 + 自动安装」。**

完整规格见 **`HANDOFF_AUTO_UPDATE.md`**（847 行，含可直接复制的代码）。

一句话总结现状：

> 「检查新版本 → 拦截老版本」**已经做完了**。
> 差的是最后一步：现在是「用浏览器打开下载链接」，
> 要改成「App 内下载 → 拉起系统安装器」。

**先读 `HANDOFF_AUTO_UPDATE.md` 的第二节（平台现实）**，
那里说清楚了 Android 的能力边界 —— 做不到静默安装，别往那个方向使劲。

---

## 三、三条硬约束

### 1. 不要动依赖

`pubspec.yaml` 里 14 个依赖的版本是逐一核对过的。
**不要升级、不要新增、不要改 `pubspec.lock`。**

本文档要求的所有功能，用 `dart:io` 的 `HttpClient` 手写就能完成。

### 2. 不要执行 `flutter create`

会覆盖 `ios/`、`macos/`、`windows/`、`linux/` 四个平台目录，
导致已做好的配置（iOS 的本地网络权限声明、macOS 的网络 entitlements）全部丢失。

### 3. 用 `tools/check.sh` 做静态检查

这个开发环境**跑不了 `dart analyze`，也跑不了 `flutter run`**。

```bash
bash tools/check.sh              # 快速：检查主入口
bash tools/check.sh lib          # 全量：逐个文件检查
bash tools/check.sh lib/core/utils/apk_downloader.dart   # 指定文件
```

**每改完一个文件就跑一次。** 这是唯一能发现语法/类型错误的手段。

---

## 四、版本号：改两处

发版时必须同时改，否则会出现「装了新版还被拦」：

| 文件 | 位置 |
|---|---|
| `pubspec.yaml` | 第 4 行 `version: 0.2.0+1` |
| `lib/core/version/version_check_service.dart` | 第 80 行 `currentVersion = '0.2.0'` |

---

## 五、还有哪些事没做（全局面貌）

做完自动更新后，整个项目剩余待办：

- [ ] **Cloudflare 部署** —— `appversion.harvin.top` 目前还是空的
      （域名解析没配、KV 没建、Functions 没部署）。7 步见 `cloudflare/README.md`
- [ ] **GitHub 仓库** —— 还没创建。安装包要放在 Releases 里，
      **仓库必须是 Public**，私有仓库的 Release 匿名下载会失败
- [ ] **重新打 APK** —— 当前手机上装的版本缺 `/bye` 协议，
      所以「手机退出后电脑端不清理设备」的修复还没生效
- [ ] **重新打 exe** —— 同上
- [ ] **Android Studio SDK 路径** —— 之前没保存成功（在 SDK Manager 里
      点了 Cancel 而不是 OK）
- [ ] 提过但未获批准的功能：HTTPS 加密传输、接收前确认弹窗、并发上传、断点续传

---

## 六、协议要点（改传输相关代码前必读）

- **端口**：UDP 和 HTTP 共用 `53317`
- **组播地址**：`224.0.0.167`
- **接口前缀**：`/api/localsend/v2/`

已有的 5 个标准接口 + 1 个自定义扩展：

| 路径 | 说明 |
|---|---|
| `/register` | 注册 |
| `/info` | 查询设备信息 |
| `/prepare-upload` | 传输前协商 |
| `/upload` | 上传文件 |
| `/cancel` | 取消 |
| `/bye` | **本项目自定义**。主动下线通知。LocalSend 不认识它，会返回 404，不影响互通 |

发现机制是**三层冗余**：组播 + 子网广播（`x.x.x.255`）+ HTTP 反向注册。
改动发现逻辑时注意别破坏这个结构。

---

## 七、Android 组播锁（很容易踩的坑）

Android 会**主动丢弃 WiFi 组播包**。

只声明 `CHANGE_WIFI_MULTICAST_STATE` 权限**是不够的**，
还必须通过 `WifiManager.createMulticastLock()` 实际申请锁。

不申请的表现是：**刚打开 App 能搜到设备，过几秒就搜不到了**。

原生实现已在 `MainActivity.kt` 里做好（`acquireMulticastLock()`），
Dart 侧封装在 `lib/core/utils/multicast_lock.dart`。
新增 MethodChannel 时**照这个文件的写法来**：

1. 非 Android 平台直接返回安全默认值，不抛异常
2. 必须捕获 `MissingPluginException`（用老 APK 跑新 Dart 代码时会发生）
3. 方法要幂等

---

## 八、遇到问题

`HANDOFF_AUTO_UPDATE.md` 第十二节有一张故障排查表（8 条）。

如果 `flutter` 命令没有任何输出、或者卡住不动：
检查 `flutter.bat.lock` 是否被残留进程占住。
