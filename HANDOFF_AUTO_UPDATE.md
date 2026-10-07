# 交接文档：自动下载 + 自动安装（自动更新）

> 交接对象：接手开发的工程师 / AI（下称「你」）
> 项目：`lan_share` —— 跨平台 WiFi 局域网文件传输工具（Flutter）
> 仓库根目录：`lan_share/`
> 本文档目标：把「检查到新版本 → 自动下载安装包 → 自动拉起安装」这条链路补齐

---

## 一、先读这一节：已经做了什么，还差什么

### 1.1 已经完成（**不要重做，不要改坏**）

「强制更新」的**前半段**已经全部做完并且经过静态检查：

| 模块 | 文件 | 状态 |
|---|---|---|
| 三段式版本号比较 | `lib/core/version/version_info.dart` | ✅ 完成 |
| 版本拉取（3 秒超时、失败放行） | `lib/core/version/version_check_service.dart` | ✅ 完成 |
| 强制更新整页拦截 UI | `lib/ui/pages/force_update_screen.dart` | ✅ 完成 |
| 启动时并发检查版本 | `lib/ui/app_state.dart` → `_checkVersion()` | ✅ 完成 |
| 拦截页接管整个 App | `lib/ui/pages/home_page.dart` → `build()` 首行 | ✅ 完成 |
| 服务端接口（Cloudflare KV + Functions） | `cloudflare/functions/api/version.js` | ✅ 代码就绪，**尚未部署** |
| 部署文档 | `cloudflare/README.md` | ✅ 完成 |

**当前行为**：App 启动时并发请求 `https://appversion.harvin.top/api/version`，
如果本机版本 < `minVersion`，`home_page.dart` 的 `build()` 第一行就直接返回
`ForceUpdateScreen`，用户无法进入任何功能，只能点「去下载新版本」——
而那个按钮目前只是**用系统浏览器打开一个 URL**（`ShellOpen.openUrl`）。

### 1.2 你这次要补的（**本文档的全部内容**）

把「用浏览器打开一个下载网页」升级成：

```
点击「立即更新」
    ↓
App 内部下载 APK（带进度条，可取消）
    ↓
下载完成 → 校验文件
    ↓
拉起系统安装器（用户点「安装」→ 点「打开」）
    ↓
新版本启动，强制更新解除
```

---

## 二、平台现实：先把预期钉死

**这一节非常重要。** 不看这节会做出「做不到的东西」。

| 平台 | 能不能「自动下载」 | 能不能「自动安装」 | 结论 |
|---|---|---|---|
| **Android** | ✅ 能 | ⚠️ **不能静默安装**。必须弹系统安装器，用户至少要**点 2 次**（「安装」+「打开」） | 能做到「App 内下载 + 拉起安装器」，**做不到无人值守** |
| **Windows** | ✅ 能 | ✅ 能（关掉自己 → 覆盖安装包 → 重启） | 技术可行，但实现复杂，见第六节 |
| **iOS** | ❌ | ❌ | **系统限制，完全不可能**。只能跳 App Store 或 TestFlight |
| **macOS** | ✅ 能 | ⚠️ 能（.dmg 挂载拖拽），但需公证，成本高 | 建议先不做 |
| **Linux** | ✅ 能 | 看打包格式 | 建议先不做 |

### 关于 Android「不能静默安装」

这是 Android 系统的**安全设计**，任何 App 都无法绕过（除非设备已 root，
或 App 被授予 Device Owner / 系统签名权限 —— 都不是普通应用能拿到的）。

具体限制：

1. `REQUEST_INSTALL_PACKAGES` 权限**只是让 App 有资格拉起安装器**，
   不代表能静默装。
2. Android 8.0+ 需要用户在系统设置里给**这个 App** 打开
   「安装未知应用」（`ACTION_MANAGE_UNKNOWN_APP_SOURCES`）。
   不打开的话，拉起安装器会直接失败。
3. Android 7.0+ 传 APK 给安装器**必须用 `content://` URI**
   （FileProvider），传 `file://` 会抛 `FileUriExposedException`。

所以最终用户体验是：

> 点「立即更新」→ 看到下载进度 → 下载完自动弹出系统安装界面 →
> 点「安装」→ 点「打开」→ 新版本启动

比「跳浏览器下载 + 手动找文件点击安装」好很多，但**不是一键完成**。
这是天花板，请在设计 UI 文案时不要承诺「自动安装完成」。

---

## 三、已确认的产品决策（不要推翻）

| 决策项 | 结论 |
|---|---|
| 自动安装做到什么程度 | **App 内下载 + 拉起系统安装器** |
| 安装包托管在哪 | **GitHub Releases** |
| 版本信息从哪读 | Cloudflare KV，经 Pages Functions 暴露为 JSON |
| 版本接口地址 | `https://appversion.harvin.top/api/version` |
| 版本号格式 | 三段式 `x.y.z` |
| 检查失败怎么办 | **放行**（局域网传输常在没有外网的环境用，不能因为查不到版本就挡人） |
| 老版本必须停止工作 | 通过调高 KV 里的 `minVersion` 实现，已实现 |

---

## 四、改动前的环境确认

### 4.1 绝对不要动的东西

```
❌ 不要升级 pubspec.yaml 里的任何依赖版本
❌ 不要改 pubspec.lock
❌ 不要执行 flutter create（会覆盖现有平台配置）
❌ 不要改 lib/core/discovery/、lib/core/transport/ 里的协议常量
```

**原因**：`pubspec.lock` 里 14 个依赖的版本是逐一核对过的，
`linux/`、`macos/`、`ios/`、`windows/` 四个平台目录是手工渲染的模板产物。
`flutter create` 会重写它们，导致已做好的平台配置（iOS 的
`NSLocalNetworkUsageDescription`、macOS 的网络 entitlements）全部丢失。

**本文档要求的所有功能，都不需要新增任何依赖。**
下载器用 `dart:io` 的 `HttpClient` 手写即可。

### 4.2 静态检查工具（很重要）

本项目的开发环境**不能跑 `dart analyze`，也不能跑 `flutter run`**
（沙箱禁止创建子进程）。但有一个替代方案：

```bash
cd lan_share
bash tools/check.sh          # 检查 lib/main.dart + test/core_test.dart
bash tools/check.sh lib      # 逐个文件全量检查 lib 下所有 .dart
bash tools/check.sh lib/core/utils/apk_downloader.dart   # 检查指定文件
```

它直接调用 Flutter 的 `frontend_server_aot.dart.snapshot`，
能完成**完整的语法 + 类型检查**，效果等同 `dart analyze`。
**每改完一个文件就跑一次**，不要攒到最后。

> 注意：如果输出是空的、或者命令卡住，检查
> `C:/flutter/flutter/bin/cache/flutter.bat.lock` 是否被残留进程占住。

---

## 五、Android 侧：具体要改的东西（**逐条照做**）

### 5.1 加权限

文件：`android/app/src/main/AndroidManifest.xml`

在 `<manifest>` 标签内、`<application>` 之前，加入：

```xml
<!-- 允许拉起系统安装器（Android 8.0+ 需要，否则 install 会直接失败） -->
<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
```

**位置建议**：放在现有的 `FOREGROUND_SERVICE` 那一组权限附近。

### 5.2 建 FileProvider 的路径配置

**新建文件**：`android/app/src/main/res/xml/file_paths.xml`

> ⚠️ `res/xml/` 这个**目录当前不存在**，需要先创建。
> 现有目录只有 `drawable`、`drawable-v21`、`mipmap-*`、`values`、`values-night`。

内容：

```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
  FileProvider 可共享的路径白名单。

  Android 7.0 起，把文件交给别的 App（这里是系统安装器）必须用
  content:// URI，直接用 file:// 会抛 FileUriExposedException 崩溃。

  APK 下载到 cacheDir 下的 update/ 子目录，所以这里只开放
  cache-path，不开放外部存储 —— 最小权限原则。
-->
<paths>
    <!-- 对应 Kotlin 里的 context.cacheDir -->
    <cache-path name="update_apk" path="update/" />

    <!-- 兜底：万一改用 filesDir 存放 -->
    <files-path name="update_apk_files" path="update/" />
</paths>
```

### 5.3 注册 FileProvider

文件：`android/app/src/main/AndroidManifest.xml`

在 `<application>` 标签**内部**（`<activity>` 之后、`</application>` 之前）加入：

```xml
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="${applicationId}.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths" />
</provider>
```

注意 `android:authorities` 用的是 `${applicationId}` 占位符，
Gradle 会自动替换成实际包名（当前是 `com.example.lan_share`）。
**Dart 侧拼 authority 时也要用同样的值**，见 5.5。

### 5.4 检查 androidx.core 依赖

`FileProvider` 来自 `androidx.core:core`。Flutter 项目的
`flutter_embedding` 会传递引入它，通常**不需要显式声明**。

但为了保险，先确认它能编译。如果需要显式声明，在
`android/app/build.gradle.kts` 的 `dependencies { }` 块里加：

```kotlin
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}
```

> 当前 `android/app/build.gradle.kts` **没有** `dependencies` 块，
> 需要时再新建。**先用不加的方式试编译**，能过就不加 —— 少一个版本要维护。

### 5.5 原生侧：新增一个安装器 MethodChannel

文件：`android/app/src/main/kotlin/com/example/lan_share/MainActivity.kt`

#### 5.5.1 加 import

在文件顶部的 import 区加入：

```kotlin
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
```

#### 5.5.2 加频道名常量

在 `private val networkChannelName = "lan_share/network"` 后面加一行：

```kotlin
private val installerChannelName = "lan_share/installer"
```

#### 5.5.3 注册频道

在 `configureFlutterEngine()` 里，
`MethodChannel(messenger, networkChannelName)` 那段**之后**，加入：

```kotlin
// ---- 安装器 ----
MethodChannel(messenger, installerChannelName).setMethodCallHandler { call, result ->
    when (call.method) {
        // 查询「是否已允许安装未知应用」
        "canInstall" -> result.success(canInstallPackages())

        // 跳转到系统的「安装未知应用」授权页
        "requestInstallPermission" -> {
            requestInstallPermission()
            result.success(true)
        }

        // 用系统安装器打开一个 APK 文件
        "installApk" -> {
            val path = call.argument<String>("path")
            if (path.isNullOrBlank()) {
                result.error("BAD_ARGS", "缺少 path 参数", null)
            } else {
                val err = installApk(path)
                if (err == null) result.success(true)
                else result.error("INSTALL_FAILED", err, null)
            }
        }

        else -> result.notImplemented()
    }
}
```

#### 5.5.4 加三个实现方法

在 `MainActivity` 类里（建议放在 `releaseMulticastLock()` 之后）加入：

```kotlin
/**
 * 是否已获得「安装未知应用」的授权。
 *
 * Android 8.0（API 26）起才需要这个检查；更低版本直接返回 true。
 */
private fun canInstallPackages(): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        packageManager.canRequestPackageInstalls()
    } else {
        true
    }
}

/**
 * 跳到系统设置里的「安装未知应用」页面，让用户为本 App 打开开关。
 *
 * 注意：这里**拿不到**用户是否真的打开了开关 —— Android 不提供回调。
 * Dart 侧应该在用户从设置页返回时（App 恢复前台）再调一次 canInstall 复查。
 */
private fun requestInstallPermission() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

    try {
        val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    } catch (_: Exception) {
        // 极少数 ROM 没有这个页面，退回到应用详情页
        try {
            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(fallback)
        } catch (_: Exception) {
            // 都不行就算了，Dart 侧会给出「请手动到设置里授权」的提示
        }
    }
}

/**
 * 用系统安装器打开 APK。
 *
 * @return null 表示成功拉起；非 null 是给 Dart 侧看的错误描述。
 *
 * 关键点：
 *  1. APK 必须位于 res/xml/file_paths.xml 声明的路径下，否则
 *     FileProvider.getUriForFile 会抛 IllegalArgumentException。
 *  2. 必须用 content:// URI。Android 7.0+ 传 file:// 会崩溃。
 *  3. 必须加 FLAG_GRANT_READ_URI_PERMISSION，否则安装器读不到文件。
 *  4. 必须加 FLAG_ACTIVITY_NEW_TASK —— 我们从 Activity 上下文调用，
 *     但安装器会以新任务栈启动。
 */
private fun installApk(path: String): String? {
    return try {
        val file = File(path)
        if (!file.exists()) return "APK 文件不存在：$path"

        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            // 部分 ROM（如小米）需要这个 flag 才认
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }

        startActivity(intent)
        null
    } catch (e: Exception) {
        "拉起安装器失败：${e.message}"
    }
}
```

#### 5.5.5 onDestroy 里的注意点

**不要**在 `onDestroy()` 里加任何东西。现有顺序
（先 `sendGoodbyePacket()` 再 `releaseMulticastLock()`）是有意义的，
不要破坏。拉起安装器是独立路径，与它无关。

### 5.6 Dart 侧：安装器的封装

**新建文件**：`lib/core/utils/apk_installer.dart`

```dart
import 'dart:io';

import 'package:flutter/services.dart';

/// 用系统安装器安装 APK（仅 Android）
///
/// ## 为什么需要原生代码
///
/// Android 从 7.0 起禁止 App 直接暴露 `file://` URI 给别的程序，
/// 必须通过 FileProvider 转成 `content://`。这套机制完全在 Android
/// 框架层，Dart 侧无法自己完成，所以走 MethodChannel。
///
/// ## 各方法在非 Android 平台的行为
///
/// 全部返回安全默认值（false / 抛 UnsupportedError），
/// 让调用方可以用同一个 API 而不用到处 `if (Platform.isAndroid)`。
class ApkInstaller {
  ApkInstaller._();

  static const _channel = MethodChannel('lan_share/installer');

  /// 当前平台是否支持 App 内安装
  static bool get isSupported => Platform.isAndroid;

  /// 是否已获得「安装未知应用」授权
  ///
  /// 非 Android 返回 false（调用方应该先看 isSupported）。
  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳转到系统的「安装未知应用」授权页
  ///
  /// 注意：无法知道用户是否真的授权了。调用方应在 App 恢复前台时
  /// 重新调用 [canInstall] 复查。
  static Future<void> requestInstallPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('requestInstallPermission');
    } catch (_) {
      // 忽略：用户还可以手动去设置里开
    }
  }

  /// 拉起系统安装器安装指定的 APK 文件
  ///
  /// 返回 null 表示成功拉起；非 null 是错误描述。
  static Future<String?> install(String apkPath) async {
    if (!Platform.isAndroid) return '当前平台不支持 App 内安装';
    try {
      await _channel.invokeMethod<bool>('installApk', <String, dynamic>{
        'path': apkPath,
      });
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '安装失败';
    } on MissingPluginException {
      return '原生安装接口未注册（APK 未重新编译？）';
    } catch (e) {
      return '安装失败：$e';
    }
  }
}
```

---

## 六、Dart 侧：下载器

### 6.1 新建下载器

**新建文件**：`lib/core/utils/apk_downloader.dart`

要求：

1. **只用 `dart:io`**，不新增依赖。
2. 下载到 `getTemporaryDirectory()` 下的 `update/` 子目录
   （对应 `file_paths.xml` 里的 `cache-path`）。
3. 支持**进度回调**、**取消**、**超时**。
4. 支持**镜像 / 备选地址**：主地址失败自动试下一个。
5. 处理 GitHub Releases 的 **302 重定向**（`HttpClient` 的
   `followRedirects` 默认为 true，但要确认；GitHub 会把
   `objects.githubusercontent.com` 的地址塞在 Location 里）。
6. 下载完成后**校验文件**：至少检查「文件存在」+「大小 > 0」+
   「大小与 Content-Length 一致」（若服务端返回了 Content-Length）。
   如果 KV 里能提供 `sha256` 字段，做完整校验更好，但不是必须。

参考骨架（**请补全实现**，这里是接口约定）：

```dart
import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 下载进度
class DownloadProgress {
  final int received;
  final int total; // 0 表示服务端没给 Content-Length
  const DownloadProgress(this.received, this.total);

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

/// 下载结果
class DownloadResult {
  final bool success;
  final String? filePath;
  final String? error;
  const DownloadResult({required this.success, this.filePath, this.error});
}

class ApkDownloader {
  ApkDownloader._();

  /// 下载安装包。
  ///
  /// [urls] 按优先级排列，主地址失败会自动试下一个。
  /// [onProgress] 每收到一块数据回调一次，用于更新进度条。
  static Future<DownloadResult> download({
    required List<String> urls,
    required String fileName,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? shouldCancel,
  }) async {
    // TODO: 实现
    // 1. 准备目录：tmp/update/
    // 2. 遍历 urls，逐个尝试
    // 3. HttpClient().getUrl() → 检查 statusCode == 200
    // 4. 边收边写文件 + 调 onProgress
    // 5. 中间检查 shouldCancel()，为 true 就中止并删掉半截文件
    // 6. 校验大小
    // 7. 返回 DownloadResult
  }
}
```

**实现要点提醒**：

- 每次都先删掉同名旧文件，避免半截文件被当成完整的。
- 用 `File.openWrite()` 拿到 `IOSink`，循环
  `await for (final chunk in response) { sink.add(chunk); ... }`。
- `HttpClient` 记得 `client.close(force: true)`，放 `finally` 里。
- 下载超时设为 **更宽松** 的值（比如 60 秒无数据才算超时），
  不要用版本检查那个 3 秒 —— 装包有几十 MB。
- GitHub 的下载地址形如：
  `https://github.com/<USER>/<REPO>/releases/download/v0.2.0/lan_share.apk`

### 6.2 改造强制更新页

文件：`lib/ui/pages/force_update_screen.dart`

**当前状态**：`StatelessWidget`，点「去下载新版本」→ `_openDownload()` →
`ShellOpen.openUrl(url)`（用浏览器打开）。

**要改成**：

1. **改为 `StatefulWidget`** —— 需要维护下载状态。

2. 页面内状态：
   ```
   枚举 UpdatePhase { idle, downloading, downloaded, installing, failed }
   ```
   加字段：`_phase`、`_progress`（`DownloadProgress?`）、`_error`、
   `_savedPath`、`_cancelRequested`。

3. **按钮行为分平台**：

   | 平台 | 「去下载新版本」按钮的行为 |
   |---|---|
   | Android | 走 App 内下载 → 下载完校验权限 → 拉起安装器 |
   | Windows | **先保持现状**（浏览器打开下载页），见第七节 |
   | iOS | 保持现状（打开 URL，通常是 App Store 链接） |
   | 其他 | 保持现状 |

4. **Android 的完整流程**：
   ```
   点击
     ↓
   检查 ApkInstaller.canInstall()
     ├─ false → 弹说明：「需要先允许安装未知应用」
     │          按钮「去授权」→ requestInstallPermission()
     │          用户返回后（App 恢复前台）复查 canInstall()
     └─ true  → 开始下载
     ↓
   下载中：显示进度条 + 百分比 + 已下载/总大小 + 「取消」按钮
     ↓
   下载完成：调 ApkInstaller.install(path)
     ├─ 返回 null（成功拉起）→ 显示「已拉起安装界面，请按提示完成安装」
     │                        + 「我已完成安装」按钮（重新检查版本）
     └─ 返回错误 → 显示错误 + 「重试」+「复制下载链接」兜底
   ```

5. **授权复查的钩子**：
   用户从系统设置页返回时，`HomePage` 的
   `didChangeAppLifecycleState` 会收到 `resumed`。
   最简做法：在 `ForceUpdateScreen` 里自己加
   `WidgetsBindingObserver`，`resumed` 时调 `ApkInstaller.canInstall()`
   刷新状态。**不要**去改 `HomePage` 的现有逻辑。

6. **本地兜底**：如果 KV 的 `urls.android` 为空，
   退回到「复制下载链接」+ 提示文案，不要卡死在加载中。

7. **保留**现有的「复制下载链接」和「退出」按钮。

---

## 七、Windows 侧（可以本轮不做，但要知道怎么做）

Windows **技术上可以全自动更新**，流程是：

1. App 内下载新的 `lan_share.zip` 或 `.exe` 到临时目录，解压。
2. 生成一个批处理 / PowerShell 脚本，内容是：
   ```
   等待当前进程退出 (tasklist /FI "PID eq <pid>" 轮询)
   → 复制新文件覆盖安装目录
   → 启动新版
   → 删除自己
   ```
3. `Process.start('cmd.exe', ['/c', scriptPath], mode: ProcessStartMode.detached)`
   以后台方式启动脚本。
4. 主进程 `exit(0)`。

**风险点**（这就是建议先不做的原因）：

- 安装目录可能在 `C:\Program Files`，需要管理员权限。
- 覆盖时如果杀软正在扫描，会失败。
- 用户可能装在 U 盘 / 网络盘上。
- 失败时没有回滚机制，可能把 App 弄成半残。

**折中方案（推荐先做这个）**：
Windows 上保持「浏览器打开下载页」，但把下载页做成一个
`appversion.harvin.top` 上的静态页面，写清楚「下载 → 覆盖到原目录 →
重启」。用户体验略差但零风险。

**如果确实要做全自动**，务必：
- 安装包改成 **单文件 exe 安装器**（Inno Setup / NSIS 打包），
  不要用 zip 覆盖那种脆弱方案。
- 脚本里加日志，写到 `%TEMP%\lan_share_update.log`，方便排障。

---

## 八、iOS / macOS（明确不做）

- **iOS**：系统不允许 App 自更新。`urls.ios` 只能填 App Store
  或 TestFlight 链接，点了跳浏览器。
- **macOS**：理论上可以（下载 .dmg → 挂载 → 复制 → 重启），
  但需要开发者证书签名 + 公证（Notarization），否则 Gatekeeper 会拦。
  本轮不做。

---

## 九、配置：服务端 KV 里怎么写

文件：`cloudflare/functions/api/version.js` 顶部注释有完整示例。
这里给出**自动更新上线后**的写法：

```json
{
  "latestVersion": "0.2.0",
  "minVersion": "0.2.0",
  "message": "本次更新：新增 App 内自动下载安装，修复设备下线不同步问题。",
  "urls": {
    "android": "https://github.com/YOUR_USER/lan-share/releases/download/v0.2.0/lan_share.apk",
    "windows": "https://github.com/YOUR_USER/lan-share/releases/download/v0.2.0/lan_share.zip",
    "ios": "",
    "macos": ""
  },
  "forceUpdate": true
}
```

### 字段对照

| 字段 | 作用 | 注意 |
|---|---|---|
| `latestVersion` | 最新版本号 | 比它低 → 提示/拦截 |
| `minVersion` | 允许使用的最低版本 | **这就是「让老版本停止工作」的开关** |
| `message` | 更新说明，展示在拦截页 | 纯文本，`\n` 可换行 |
| `urls.android` | Android 直链（**必须是 APK 文件的直链**） | 不要填网页地址 |
| `urls.windows` | Windows 直链 | 同上 |
| `urls.ios` / `urls.macos` | 留空即可 | |
| `forceUpdate` | `true` = 低于 latest 就强制拦截 | |

### 关于 `urls.android` 必须是直链

App 内下载器直接 GET 这个地址并把响应体当 APK 写盘。
**如果填的是 GitHub 的 Release 页面地址（HTML），下载下来的会是一个网页，
安装器打开会失败。** 必须是
`.../releases/download/<tag>/<file>.apk` 这种直链。

### 改版本号不用重新部署

`minVersion` 改了以后，Cloudflare KV 几秒内全球生效，
**不需要重新部署 Pages，也不需要重新编译 App**。

---

## 十、版本号同步（容易踩的坑）

**两处必须保持一致**：

1. `lan_share/pubspec.yaml` 第 4 行：
   ```yaml
   version: 0.2.0+1
   ```
2. `lan_share/lib/core/version/version_check_service.dart` 第 80 行：
   ```dart
   static const currentVersion = '0.2.0';
   ```

> `currentVersion` 是硬编码的，**没有**用 `package_info_plus`。
> 这是刻意的：引入那个包要改 `pubspec.lock`，为一个版本号动依赖树不划算。
> **两处不一致的后果**：装了新版本还是被拦（或者老版本没被拦）。

发版时记得同步更新。**建议**：在 `tools/` 下加一个
`bump_version.sh`，一次改两个地方。

---

## 十一、验收清单

改完之后，逐条自查：

### 编译层面
- [ ] `bash tools/check.sh lib` 全绿，无 Error
- [ ] `android/app/src/main/res/xml/file_paths.xml` 已创建
- [ ] `AndroidManifest.xml` 里同时有 `REQUEST_INSTALL_PACKAGES` 和 `<provider>`
- [ ] `MainActivity.kt` 里 `lan_share/installer` 频道三个方法都实现了
- [ ] `pubspec.yaml` 依赖列表**一个字都没动**
- [ ] `pubspec.lock` **没有被修改**（用 `git diff pubspec.lock` 确认）

### 功能层面（需要真机）
- [ ] 装旧版 APK → 改 KV 的 `minVersion` 到新版 → 重启 App → 被拦截
- [ ] 点「去下载新版本」→ 看到进度条在动
- [ ] 下载中途点「取消」→ 下载停止，且没留下损坏的半截文件
- [ ] 第一次装会弹「允许安装未知应用」→ 点「去授权」→ 系统设置页打开
- [ ] 授权后返回 App → 状态刷新为「已授权」
- [ ] 下载完成 → 弹出系统安装界面
- [ ] 点「安装」→ 安装成功 → 点「打开」→ 新版本启动
- [ ] 新版本启动后**不再被拦截**（说明 `currentVersion` 同步对了）
- [ ] 拔网线 / 飞行模式启动 App → **正常进入，不被拦**（放行逻辑生效）
- [ ] 把 `urls.android` 改成空字符串 → 点按钮 → 退回到「复制链接」，不卡死

### 失败路径
- [ ] `urls.android` 填一个不存在的地址 → 显示错误 + 可重试
- [ ] 下载到 99% 断网 → 显示错误，重试能重新开始（不残留坏文件）

---

## 十二、常见故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| 点安装无反应 | 没加 `FLAG_GRANT_READ_URI_PERMISSION`，或 URI 不是 `content://` | 见 5.5.4 |
| `FileUriExposedException` | 用了 `file://` | 必须走 FileProvider |
| `IllegalArgumentException: Failed to find configured root` | APK 路径不在 `file_paths.xml` 白名单里 | 确认下载目录是 `cacheDir/update/` |
| 安装器提示「解析包错误」 | 下载到的是 HTML（URL 填的是网页不是直链） | 见第九节 |
| 装完还是被拦 | `currentVersion` 没更新 | 见第十节 |
| `canInstall` 一直 false | 用户没授权，或 App 恢复前台后没复查 | 见 6.2 第 5 点 |
| 编译报找不到 `FileProvider` | 缺 androidx.core | 见 5.4 |
| `flutter` 命令没输出 | `flutter.bat.lock` 被占 | 删掉锁文件，并确认没有残留 dart 进程 |

---

## 十三、长期维护建议

1. **`tools/check.sh` 是硬性门槛** —— 这个环境跑不了 `dart analyze`，
   这个脚本是唯一的静态检查手段。提交前必须全绿。

2. **不要为了一个功能引入新依赖**。现有 14 个依赖的版本是精心
   锁定的，任何新增都会引发连锁反应（要重拉 `pubspec.lock`，
   可能被迫升级 Flutter 版本）。本文档要求的全部功能
   用 `dart:io` + 现有依赖就能完成。

3. **Android 的「静默安装」是伪需求** —— 系统不允许。
   如果有人要求做到完全无感，正确答复是「做不到」，
   而不是去研究和系统对抗的方案。

4. **发版流程**：
   ```
   改 pubspec.yaml 的 version
   → 改 version_check_service.dart 的 currentVersion
   → flutter build apk --release
   → 上传 APK 到 GitHub Releases（打 tag，如 v0.2.0）
   → 更新 Cloudflare KV 的 JSON（latestVersion / minVersion / urls）
   ```

5. **灰度发布技巧**：先把 `latestVersion` 调到新版但
   `minVersion` 保持旧值 → 老用户只看到提示、可选更新 →
   观察几天没大问题，再把 `minVersion` 调高 → 强制淘汰。
   **不要一上来就拉高 `minVersion`**，万一新版有严重 bug 就全完了。

---

## 附：关键文件索引

| 文件 | 作用 |
|---|---|
| `lib/core/version/version_info.dart` | `SemVersion` 三段式比较、`VersionInfo` 解析 |
| `lib/core/version/version_check_service.dart` | 版本拉取（3s 超时、失败放行）、`currentVersion` 常量 |
| `lib/ui/pages/force_update_screen.dart` | **本次主要改造对象** |
| `lib/ui/app_state.dart` → `_checkVersion()` | 启动时并发检查；`_versionEndpoint` 在此 |
| `lib/ui/pages/home_page.dart` → `build()` | 拦截页接管入口；`didChangeAppLifecycleState` |
| `lib/core/utils/shell_open.dart` | 跨平台打开 URL / 目录（现有） |
| `lib/core/utils/apk_installer.dart` | **本次新建**：安装器 MethodChannel 封装 |
| `lib/core/utils/apk_downloader.dart` | **本次新建**：带进度的下载器 |
| `lib/core/utils/multicast_lock.dart` | MethodChannel 封装的参考范例，**写法照它来** |
| `android/app/src/main/kotlin/com/example/lan_share/MainActivity.kt` | **本次主要改造对象** |
| `android/app/src/main/AndroidManifest.xml` | 加权限 + 注册 FileProvider |
| `android/app/src/main/res/xml/file_paths.xml` | **本次新建**（目录也要新建） |
| `cloudflare/functions/api/version.js` | 版本接口，KV 示例在文件底部注释 |
| `cloudflare/README.md` | Cloudflare 部署 7 步 |
| `tools/check.sh` | 静态检查（唯一可用的检查手段） |

---

## 附：MethodChannel 写法参考

新增的 `lan_share/installer` 请**完全照抄** `lan_share/multicast`
的现有风格。Dart 侧参考 `lib/core/utils/multicast_lock.dart`：

```dart
static const _channel = MethodChannel('lan_share/multicast');

static Future<void> acquire() async {
  if (!Platform.isAndroid) return;   // 非 Android 直接返回
  if (_held) return;                 // 幂等
  try {
    final ok = await _channel.invokeMethod<bool>('acquire');
    _held = ok ?? false;
  } on PlatformException {
    _held = false;                   // 原生侧失败不致命
  } on MissingPluginException {
    _held = false;                   // 原生没编进去（老 APK）
  }
}
```

三个要点：
1. **非 Android 平台直接返回安全默认值**，不要抛异常。
2. **`MissingPluginException` 必须捕获** —— 用老 APK 跑新 Dart 代码时会发生。
3. **幂等** —— 重复调用不出问题。

---

## 附：相关但不在本文档范围内的待办

这些是主项目里**还没做**的事，列出来让接手的人有全局视野：

- [ ] Cloudflare 部署（`appversion.harvin.top` 目前是空的，7 步见 `cloudflare/README.md`）
- [ ] GitHub 仓库尚未创建（需要 Public，否则匿名下载 Release 会失败）
- [ ] 手机端 APK 需要用最新源码重新打包（当前装的版本缺 `/bye` 协议，所以下线清理不生效）
- [ ] 桌面端 exe 需要用最新源码重新打包
- [ ] Android Studio 的 SDK 路径尚未保存（需要在 SDK Manager 里点 OK 而不是 Cancel）
- [ ] 之前提过但未获批准的功能：HTTPS 加密传输、接收前确认弹窗、并发上传、断点续传

---

**文档结束。**

有任何信息缺失或与代码不符的地方，**以代码为准**，并回头修正本文档。
