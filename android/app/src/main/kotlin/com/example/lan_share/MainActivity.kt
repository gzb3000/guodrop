package com.example.lan_share

import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

/**
 * 宿主 Activity，负责三件事：
 *
 *  1. 持有 WiFi 组播锁（发现的核心前提）
 *  2. 向 Dart 侧报告本机 WiFi 的真实 IPv4 地址
 *  3. **兜底**：进程被销毁时，原生地补发一个「下线」UDP 包
 *
 * ## 为什么必须要有组播锁
 *
 * Android 为省电，默认**主动丢弃 WiFi 组播包**。而本 App 的设备发现
 * 完全依赖 UDP 组播（224.0.0.167:53317），所以如果不申请组播锁：
 *
 *   - 刚打开 App 时：系统短暂放行，能发现设备
 *   - 过几秒后：进入省电状态，组播被掐断 → **发现不了任何设备**
 *   - App 切后台 / 屏幕关闭：彻底收不到
 *
 * 表现就是「刚打开一瞬间能搜到，过一会就看不到了」。
 *
 * 只声明 CHANGE_WIFI_MULTICAST_STATE 权限**是不够的**，权限只是前提，
 * 还必须通过 WifiManager.createMulticastLock() 实际申请锁。
 *
 * ## 为什么需要直接问 WiFi IP
 *
 * Dart 侧 NetworkInterface.list 在部分机型上拿不到 wlan0，或者返回的是
 * 蜂窝/VPN 的地址。用这个地址去广播，对端根本连不上 —— 表现就是
 * 「两边都显示在线，但一传文件就失败」。WifiManager 报的才是对的。
 *
 * ## 为什么还要在原生补发下线包
 *
 * 用户在最近任务里上滑划掉 App 时，进程会被**立刻杀掉**，
 * Flutter 那边的生命周期回调（didChangeAppLifecycleState）只有
 * 几十毫秒的时间窗口，Dart 的异步网络调用经常来不及完成。
 *
 * 所以这里留了一道原生兜底：`onDestroy` 里直接用 DatagramSocket
 * 把下线包发出去。这一步是纯 Java/Kotlin 的同步发送，
 * 不经过 Flutter 引擎，不依赖 Dart 运行时，可靠得多。
 *
 * 指纹和别名由 Dart 侧通过 MethodChannel 提前同步过来。
 *
 * ## 生命周期
 *
 * 锁由 Dart 侧显式控制（发现服务启动时 acquire、停止时 release），
 * 避免 App 在后台也占着 WiFi 不放。onDestroy 时兜底释放。
 */
class MainActivity : FlutterActivity() {

    private val multicastChannelName = "lan_share/multicast"
    private val networkChannelName = "lan_share/network"
    private val installerChannelName = "lan_share/installer"
    private val storageChannelName = "lan_share/storage"

    private var multicastLock: WifiManager.MulticastLock? = null

    /// Dart 侧同步过来的身份信息，用于 onDestroy 时补发下线包
    private var selfFingerprint: String? = null
    private var selfAlias: String = ""
    private var selfDeviceType: String = "mobile"
    private var selfDeviceModel: String = ""
    private var selfPort: Int = 53317

    companion object {
        private const val MULTICAST_GROUP = "224.0.0.167"
        private const val DEFAULT_PORT = 53317
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // ---- 组播锁 + 身份同步 ----
        MethodChannel(messenger, multicastChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    acquireMulticastLock()
                    result.success(multicastLock?.isHeld == true)
                }
                "release" -> {
                    releaseMulticastLock()
                    result.success(true)
                }
                "isHeld" -> result.success(multicastLock?.isHeld == true)

                // Dart 侧把身份同步过来，供 onDestroy 补发下线包用
                "setIdentity" -> {
                    call.argument<String>("fingerprint")?.let { selfFingerprint = it }
                    call.argument<String>("alias")?.let { selfAlias = it }
                    call.argument<String>("deviceType")?.let { selfDeviceType = it }
                    call.argument<String>("deviceModel")?.let { selfDeviceModel = it }
                    call.argument<Int>("port")?.let { selfPort = it }
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        // ---- 网络信息 ----
        MethodChannel(messenger, networkChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getWifiIp" -> result.success(getWifiIpAddress())
                else -> result.notImplemented()
            }
        }

        // ---- 公共存储：收到的文件放到 下载/GUODROP ----
        MethodChannel(messenger, storageChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "publicDir" -> result.success(publicDirFile().absolutePath)
                "publish" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    val mime = call.argument<String>("mime")
                    if (path.isNullOrBlank() || name.isNullOrBlank()) {
                        result.error("BAD_ARGS", "缺少 path/name", null)
                    } else {
                        // 大文件复制可能要几秒，放到后台线程，完成后回主线程回复
                        Thread {
                            val r = try { publishToDownloads(File(path), name, mime) } catch (e: Exception) { null }
                            runOnUiThread {
                                if (r != null) result.success(r)
                                else result.error("PUBLISH_FAILED", "保存到下载目录失败", null)
                            }
                        }.start()
                    }
                }
                "openFolder" -> result.success(openPublicFolder())
                "openFile" -> result.success(
                    openReceivedFile(
                        call.argument<String>("uri"),
                        call.argument<String>("path"),
                        call.argument<String>("mime"),
                    )
                )
                else -> result.notImplemented()
            }
        }

        // ---- 安装器（自动更新）----
        MethodChannel(messenger, installerChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(canInstallPackages())
                "requestInstallPermission" -> {
                    requestInstallPermission()
                    result.success(true)
                }
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
    }

    /**
     * 申请组播锁。重复调用安全（已持有则直接返回）。
     *
     * 注意：acquire() 默认是引用计数的，若不加 setReferenceCounted(false)，
     * 多次 acquire 后需要同样次数的 release 才能释放。这里显式关掉引用计数，
     * 让 acquire/release 变成幂等的开关。
     */
    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return

        try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager

            multicastLock = wifi.createMulticastLock("lan_share_multicast").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
            // 极少数设备 Wi-Fi 未开启时会抛异常。
            // 不致命：单播 HTTP 探测（probeDevice）仍可作为兜底。
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.let {
                if (it.isHeld) it.release()
            }
        } catch (_: Exception) {
            // 忽略：进程可能正在退出
        }
        multicastLock = null
    }

    /** 是否已获得「安装未知应用」授权（Android 8.0 以下恒为 true） */
    private fun canInstallPackages(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    /** 跳到系统「安装未知应用」授权页；Dart 侧在 resumed 时复查 canInstall */
    private fun requestInstallPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (_: Exception) {
            try {
                val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(fallback)
            } catch (_: Exception) {
            }
        }
    }

    /** 用系统安装器打开 APK。返回 null 表示成功拉起，否则为错误描述 */
    private fun installApk(path: String): String? {
        return try {
            val file = File(path)
            if (!file.exists()) return "APK 文件不存在：$path"
            val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
            startActivity(intent)
            null
        } catch (e: Exception) {
            "拉起安装器失败：${e.message}"
        }
    }

    // ==================== 公共存储 ====================

    private val publicFolder = "GUODROP"

    @Suppress("DEPRECATION")
    private fun publicDirFile(): File = File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        publicFolder,
    )

    private fun guessMime(name: String, given: String?): String {
        if (!given.isNullOrBlank() && given.contains('/') && given != "application/octet-stream") return given
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: (given ?: "application/octet-stream")
    }

    /**
     * 把暂存文件复制到 下载/GUODROP。
     * API 29+：MediaStore.Downloads（无需权限，IS_PENDING 保证别的 App 看不到半截文件）；
     * API 24–28：直接写公共目录 + MediaScanner 入库（相册可见）。
     */
    private fun publishToDownloads(src: File, name: String, mimeIn: String?): Map<String, String>? {
        if (!src.exists()) return null
        val mime = guessMime(name, mimeIn)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/" + publicFolder)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = resolver.insert(collection, values) ?: return null
            try {
                resolver.openOutputStream(uri, "w")?.use { out ->
                    src.inputStream().use { it.copyTo(out, 256 * 1024) }
                } ?: throw IllegalStateException("openOutputStream null")
                val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                resolver.update(uri, done, null, null)
            } catch (e: Exception) {
                try { resolver.delete(uri, null, null) } catch (_: Exception) {}
                return null
            }
            // 系统可能因重名自动改名（xxx (1).jpg），取回真实文件名
            var finalName = name
            try {
                resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) finalName = c.getString(0) ?: name
                }
            } catch (_: Exception) {}
            return mapOf("path" to File(publicDirFile(), finalName).absolutePath, "uri" to uri.toString())
        } else {
            val dir = publicDirFile()
            if (!dir.exists() && !dir.mkdirs()) return null
            val dot = name.lastIndexOf('.')
            val stem = if (dot > 0) name.substring(0, dot) else name
            val ext = if (dot > 0) name.substring(dot) else ""
            var target = File(dir, name)
            var i = 1
            while (target.exists()) { target = File(dir, "$stem ($i)$ext"); i++ }
            src.inputStream().use { input -> target.outputStream().use { input.copyTo(it, 256 * 1024) } }
            MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), arrayOf(mime), null)
            return mapOf("path" to target.absolutePath, "uri" to "")
        }
    }

    private fun tryStart(intent: Intent): Boolean = try {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    /** 在系统文件管理器里打开 下载/GUODROP，逐级降级 */
    private fun openPublicFolder(): Boolean {
        try { publicDirFile().mkdirs() } catch (_: Exception) {}
        val docId = "primary:" + Environment.DIRECTORY_DOWNLOADS + "/" + publicFolder
        val dirUri = DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", docId)
        // 1) 系统「文件」(DocumentsUI) 直接定位到目录
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(dirUri, DocumentsContract.Document.MIME_TYPE_DIR)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (tryStart(Intent(view).setPackage("com.google.android.documentsui"))) return true
        if (tryStart(Intent(view).setPackage("com.android.documentsui"))) return true
        if (tryStart(view)) return true
        // 2) 各家文件管理器常见的 resource/folder 方式
        val folder = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse(publicDirFile().absolutePath), "resource/folder")
        }
        if (folder.resolveActivity(packageManager) != null && tryStart(folder)) return true
        // 3) 退回系统「下载」
        return tryStart(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS))
    }

    /** 用默认应用打开收到的文件 */
    private fun openReceivedFile(uriStr: String?, path: String?, mimeIn: String?): Boolean {
        val uri: Uri = when {
            !uriStr.isNullOrBlank() -> Uri.parse(uriStr)
            !path.isNullOrBlank() -> try {
                FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path))
            } catch (_: Exception) { return false }
            else -> return false
        }
        val name = path?.substringAfterLast('/') ?: ""
        val mime = guessMime(name, mimeIn)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return tryStart(Intent.createChooser(intent, "打开文件"))
    }

    /**
     * 取 WiFi 的 IPv4 地址。
     *
     * 两道保险，按可靠性排序：
     *  1. 遍历网卡找 wlan0（最准，且能拿到真实子网地址）
     *  2. 退回 WifiManager.connectionInfo.ipAddress（部分定制 ROM 上更准）
     *
     * 两者都拿不到就返回 null，Dart 侧会退回自己的枚举逻辑。
     */
    private fun getWifiIpAddress(): String? {
        // 方案 1：找名字里带 wlan / wifi 的网卡
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces != null && interfaces.hasMoreElements()) {
                val nif = interfaces.nextElement()
                val name = nif.name.lowercase()
                val looksLikeWifi = name.startsWith("wlan") ||
                        name.startsWith("wifi") ||
                        name.startsWith("ap")
                if (!looksLikeWifi) continue

                for (addr in nif.inetAddresses) {
                    if (!addr.isLoopbackAddress && addr is Inet4Address) {
                        val ip = addr.hostAddress ?: continue
                        if (ip.isNotEmpty() && !ip.startsWith("127.")) return ip
                    }
                }
            }
        } catch (_: Exception) {
            // 继续尝试方案 2
        }

        // 方案 2：WifiManager
        try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            val rawIp = wifi.connectionInfo?.ipAddress ?: return null
            if (rawIp == 0) return null

            // ipAddress 是小端序的 int，要手动转成点分十进制
            return String.format(
                "%d.%d.%d.%d",
                rawIp and 0xff,
                (rawIp shr 8) and 0xff,
                (rawIp shr 16) and 0xff,
                (rawIp shr 24) and 0xff,
            )
        } catch (_: Exception) {
            return null
        }
    }

    /**
     * 原生补发「下线」UDP 包。
     *
     * 这是最后一道保险：用户在最近任务划掉 App 时，Dart 侧往往来不及
     * 发完网络请求，但这个方法在 onDestroy 里同步执行，不经过 Flutter
     * 引擎，只要进程还在就一定能发出去。
     *
     * 同时往组播组和子网广播地址各发一份 —— 和 Dart 侧的策略一致。
     */
    private fun sendGoodbyePacket() {
        val fp = selfFingerprint
        if (fp.isNullOrEmpty()) return // 身份还没同步过来，说明根本没初始化完

        try {
            val payload = JSONObject().apply {
                put("fingerprint", fp)
                put("alias", selfAlias)
                put("deviceType", selfDeviceType)
                put("deviceModel", selfDeviceModel)
                put("port", selfPort)
                put("protocol", "http")
                put("version", "2.0")
                put("bye", true)
            }.toString().toByteArray(Charsets.UTF_8)

            DatagramSocket().use { socket ->
                socket.broadcast = true

                // 1) 组播组
                try {
                    socket.send(
                        DatagramPacket(
                            payload, payload.size,
                            InetAddress.getByName(MULTICAST_GROUP),
                            selfPort,
                        )
                    )
                } catch (_: Exception) {
                }

                // 2) 各网段的广播地址
                for (bcast in broadcastAddresses()) {
                    try {
                        socket.send(
                            DatagramPacket(
                                payload, payload.size,
                                InetAddress.getByName(bcast),
                                selfPort,
                            )
                        )
                    } catch (_: Exception) {
                    }
                }
            }
        } catch (_: Exception) {
            // 退出路径，失败就失败
        }
    }

    /** 算出所有网段的广播地址，外加全局广播地址 */
    private fun broadcastAddresses(): List<String> {
        val result = mutableSetOf("255.255.255.255")
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces != null && interfaces.hasMoreElements()) {
                val nif = interfaces.nextElement()
                for (addr in nif.interfaceAddresses) {
                    val bcast = addr.broadcast ?: continue
                    if (bcast is Inet4Address) {
                        result.add(bcast.hostAddress ?: continue)
                    }
                }
            }
        } catch (_: Exception) {
        }
        return result.toList()
    }

    override fun onDestroy() {
        // 顺序很重要：先补发下线包（此时 socket 还能用），再释放组播锁
        sendGoodbyePacket()
        releaseMulticastLock()
        super.onDestroy()
    }
}
