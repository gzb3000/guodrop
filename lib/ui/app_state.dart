import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/discovery/discovery_service.dart';
import '../core/models/device.dart';
import '../core/models/protocol.dart';
import '../core/scan/scan_service.dart';
import '../core/transport/transfer_service.dart';
import '../core/utils/device_info_helper.dart';
import '../core/utils/multicast_lock.dart';
import '../core/utils/preferences.dart';
import '../core/utils/public_storage.dart';
import '../core/version/version_check_service.dart';

/// 一次发送任务的进度状态
class SendTask {
  final Device target;
  final List<FileMeta> files;
  final int totalBytes;

  int sentBytes = 0;
  bool isDone = false;
  bool isFailed = false;
  String? error;

  SendTask({
    required this.target,
    required this.files,
    required this.totalBytes,
  });

  double get progress =>
      totalBytes == 0 ? 0 : (sentBytes / totalBytes).clamp(0.0, 1.0);
}

/// 全局应用状态
///
/// 这是整个 UI 唯一的数据来源。三个 Service 都挂在这里，
/// UI 只跟 AppState 打交道，不直接碰底层网络代码。
class AppState extends ChangeNotifier {
  AppState();

  // ---- 核心服务 ----
  DiscoveryService? _discovery;
  TransferService? _transfer;

  // ---- 状态字段 ----
  Device? _selfDevice;
  String? _localIp;
  final Map<String, Device> _devices = {};
  bool _isInitializing = true;
  bool _isRunning = false;
  String? _errorMessage;

  /// 接收会话
  final Map<String, ReceiveSession> _receiveSessions = {};

  /// 发送任务
  final Map<String, SendTask> _sendTasks = {};

  /// 扫码会话
  QrSession? _qrSession;

  /// 给用户看的接收目录（Android 为 下载/GUODROP）
  String _downloadDir = '';

  /// TransferService 实际落盘的目录。Android 上是私有暂存目录，
  /// 写完整后再由 PublicStorage 发布到公共下载目录。
  String _stagingDir = '';

  /// 版本检查结果。null 表示还没查（或查完了没问题，不需要 UI 处理）
  UpdateCheckResult? _updateResult;

  // ---- Getter ----
  Device? get selfDevice => _selfDevice;
  String? get localIp => _localIp;
  bool get isInitializing => _isInitializing;
  bool get isRunning => _isRunning;
  String? get errorMessage => _errorMessage;
  String get downloadDir => _downloadDir;
  QrSession? get qrSession => _qrSession;

  /// 是否需要强制更新（挡住了整个 App）
  bool get needsForceUpdate => _updateResult?.shouldBlock == true;

  /// 当前待处理的更新信息
  UpdateCheckResult? get updateResult => _updateResult;


  List<Device> get devices => _devices.values.toList()
    ..sort((a, b) => a.alias.compareTo(b.alias));

  List<ReceiveSession> get receiveSessions =>
      _receiveSessions.values.toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  List<SendTask> get sendTasks => _sendTasks.values.toList();

  bool get hasActiveTransfer =>
      _receiveSessions.values.any((s) => !s.isCompleted && !s.isCancelled) ||
      _sendTasks.values.any((t) => !t.isDone && !t.isFailed);

  // ==================== 初始化 ====================

  /// 启动整个应用：加载身份、开服务、开始发现
  Future<void> initialize() async {
    _isInitializing = true;
    _errorMessage = null;
    notifyListeners();

    // 版本检查**并发**跑，不阻塞启动。
    //
    // 为什么不 await：检查要联网，最长 3 秒。用户开 App 是要传文件，
    // 不该为了等版本检查白站 3 秒。发现新版本时再弹 UI 就行。
    unawaited(_checkVersion());

    try {
      // 1. 准备下载目录
      _downloadDir = await _resolveDownloadDir();
      _stagingDir = _downloadDir;
      if (Platform.isAndroid) {
        final tmp = await getTemporaryDirectory();
        final staging = Directory('${tmp.path}${Platform.pathSeparator}incoming');
        if (!await staging.exists()) await staging.create(recursive: true);
        _stagingDir = staging.path;
        unawaited(PublicStorage.ensureWritePermission());
      }

      // 2. 加载或生成本机身份
      final identity = await AppPreferences.loadOrCreateIdentity();
      final ip = await NetworkAddressResolver.resolveLocalIp();
      _localIp = ip;

      final model = await DeviceInfoHelper.deviceModel();
      final type = DeviceInfoHelper.currentDeviceType();

      _selfDevice = Device(
        fingerprint: identity.fingerprint,
        alias: identity.alias,
        deviceType: type,
        deviceModel: model,
        ip: ip ?? '127.0.0.1',
        port: Protocol.defaultPort,
        isLocal: true,
      );

      // 2.5 把身份同步给 Android 原生侧。
      //     原生在 onDestroy 时会用它补发「下线」包 —— 这是最后一道保险，
      //     因为用户划掉 App 时 Dart 的异步调用常常来不及跑完。
      await MulticastLock.syncIdentity(
        fingerprint: _selfDevice!.fingerprint,
        alias: _selfDevice!.alias,
        deviceType: _selfDevice!.deviceType.value,
        deviceModel: _selfDevice!.deviceModel,
        port: _selfDevice!.port,
      );

      // 3. 启动 HTTP 服务端（接收文件）
      _transfer = TransferService(
        selfDevice: _selfDevice!,
        downloadDir: _stagingDir,
        publishFile: Platform.isAndroid ? PublicStorage.publish : null,
        onSessionStarted: (s) {
          _receiveSessions[s.sessionId] = s;
          notifyListeners();
        },
        onProgress: (s) => notifyListeners(),
        onFileReceived: (s, f) {
          debugPrint('收到文件: ${f.savedPath}');
          notifyListeners();
        },
        onSessionEnded: (s) => notifyListeners(),
        onError: (msg) {
          _errorMessage = msg;
          notifyListeners();
        },
        // 对端通过 HTTP 主动告知下线 —— 立刻从列表移除
        onPeerSaidBye: _removeDeviceByFingerprint,
        onPeerSeen: (d) => _discovery?.markSeen(d),
      );
      await _transfer!.startServer();

      // 4. 启动 UDP 发现
      _discovery = DiscoveryService(
        selfDevice: _selfDevice!,
        onDeviceFound: (d) {
          _devices[d.fingerprint] = d;
          notifyListeners();
        },
        onDeviceLost: (d) {
          _devices.remove(d.fingerprint);
          notifyListeners();
        },
        onError: (msg) {
          _errorMessage = msg;
          notifyListeners();
        },
      );
      await _discovery!.start();

      // 5. 准备扫码会话
      if (ip != null) {
        _qrSession = QrSession(ip: ip, port: Protocol.defaultPort);
      }

      _isRunning = true;
    } catch (e) {
      _errorMessage = '初始化失败: $e';
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  /// 关闭所有服务
  ///
  /// 顺序很重要：**先告别，再关服务**。
  /// 如果先把 HTTP 服务关了，/bye 就发不出去了（对方连不上我们，
  /// 但其实我们也要连对方，所以更关键的是本机能正常发出请求）。
  Future<void> shutdown() async {
    // 通知所有对端「我要下线了」，让它们的设备列表立刻更新。
    // 失败/超时都不阻塞退出 —— 最坏情况就是对方等 30 秒超时。
    try {
      final peers = _devices.values.toList();
      if (peers.isNotEmpty) {
        await _transfer?.sendGoodbye(peers);
      }
      await _discovery?.announceGoodbye();
    } catch (_) {
      // 退出路径，任何异常都不该阻止关闭
    }

    await _discovery?.stop();
    await _transfer?.stopServer();
    _isRunning = false;
    notifyListeners();
  }

  /// 按指纹移除设备（对端主动下线时调用）
  ///
  /// 两条通道都会走到这里：HTTP 的 /bye 和 UDP 的 bye 包。
  /// 重复调用是安全的。
  void _removeDeviceByFingerprint(String fingerprint) {
    // 必须同步删掉发现层的记录，否则发现层以为「已存在」，
    // 之后再收到它的广播也不会通知 UI，设备就再也回不来了。
    _discovery?.removeDevice(fingerprint);
    final existed = _devices.remove(fingerprint);
    if (existed != null) {
      notifyListeners();
    }
  }

  /// 告知对端「我暂时退出了」，但**不停服务**
  ///
  /// 用在 App 退到后台/即将被销毁时。和 shutdown() 的区别：
  ///   - shutdown()  ：真正关闭，释放端口，退出应用时用
  ///   - 本方法       ：只打个招呼，服务继续跑，切回前台无缝恢复
  ///
  /// 为什么不干脆也用 shutdown()：手机上切后台太频繁了（按 Home 键、
  /// 切到微信、锁屏），每次都重启服务会导致回来后要等一两秒才能用。
  ///
  /// ## 顺序很关键
  ///
  /// **先发 UDP，再发 HTTP。**
  ///
  /// UDP 的 socket.send() 是同步的 —— 数据包当场进入内核发送队列，
  /// 之后进程就算立刻被杀，包也已经上路了。
  ///
  /// HTTP 需要 TCP 三次握手 + 收响应，至少几个 RTT。手机上用户
  /// 上滑划掉 App 时，进程可能在几十毫秒内就被杀了，这个往返
  /// 经常来不及完成。
  ///
  /// 所以两条通道并发打，但 UDP 那条是「发出即算数」的。
  void notifyPeersGoingAway() {
    final peers = _devices.values.toList();
    if (peers.isEmpty) return;

    // 先把 UDP 包推出去（同步，不 await）
    final udp = _discovery?.announceGoodbye();

    // HTTP 是尽力而为：能完成最好，完不成也不影响
    final http = _transfer?.sendGoodbye(peers);

    // 两个都不 await，但挂着引用避免被 GC 提前回收
    if (udp != null) unawaited(udp);
    if (http != null) unawaited(http);
  }

  // ==================== 设备操作 ====================

  /// 手动刷新设备列表
  Future<void> refreshDevices() async {
    await _discovery?.refresh();
    notifyListeners();
  }

  /// 通过扫码结果添加设备
  Future<Device?> addDeviceFromScan(String rawText) async {
    final device = ScanService.parseScanResult(rawText);
    if (device == null) {
      _errorMessage = '二维码内容无法识别';
      notifyListeners();
      return null;
    }

    // 反向探测，确认真实别名和型号
    final probed = await _discovery?.probeDevice(device.ip, port: device.port);
    final result = probed ?? device;

    _devices[result.fingerprint] = result;
    notifyListeners();
    return result;
  }

  /// 手动输入 IP 添加设备
  Future<Device?> addDeviceByIp(String ip, {int? port}) async {
    final probed = await _discovery?.probeDevice(ip, port: port);
    if (probed == null) {
      _errorMessage = '无法连接到 $ip，请检查设备是否在线且在同一网络';
      notifyListeners();
      return null;
    }
    _devices[probed.fingerprint] = probed;
    notifyListeners();
    return probed;
  }

  void removeDevice(Device device) {
    _discovery?.removeDevice(device.fingerprint);
    _devices.remove(device.fingerprint);
    notifyListeners();
  }

  // ==================== 传输操作 ====================

  /// 向目标设备发送文件
  ///
  /// 发送前先探活。为什么：设备列表可能还留着一个刚关掉的对端
  /// （超时淘汰要等 30 秒），如果不预检就发，用户会看到进度条卡住、
  /// 过一会儿才报失败。预检 2 秒内就能给出明确结论。
  Future<bool> sendFiles(Device target, List<FileMeta> files) async {
    if (_transfer == null) return false;

    // 预检：对端还在不在？
    final alive = await _transfer!.isAlive(target);
    if (!alive) {
      // 已经死了 —— 立刻从列表移除，并给出明确提示
      _discovery?.removeDevice(target.fingerprint);
      _devices.remove(target.fingerprint);
      _errorMessage = '${target.alias} 已离线，请重新选择设备';
      notifyListeners();
      return false;
    }

    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.size);
    final task = SendTask(
      target: target,
      files: files,
      totalBytes: totalBytes,
    );
    final taskId = const Uuid().v4();
    _sendTasks[taskId] = task;
    notifyListeners();

    final ok = await _transfer!.sendFiles(
      target: target,
      files: files,
      onSendProgress: (sent, total) {
        task.sentBytes = sent;
        notifyListeners();
      },
    );

    task.isDone = ok;
    task.isFailed = !ok;
    notifyListeners();

    // 失败且是「连不上」类错误时，顺手把设备移除
    if (!ok) {
      final stillAlive = await _transfer!.isAlive(target);
      if (!stillAlive) {
        _discovery?.removeDevice(target.fingerprint);
        _devices.remove(target.fingerprint);
        _errorMessage = '${target.alias} 已离线';
        notifyListeners();
      }
    }

    // 完成后 3 秒从列表移除
    Timer(const Duration(seconds: 3), () {
      _sendTasks.remove(taskId);
      notifyListeners();
    });

    return ok;
  }

  /// 刷新二维码 token
  void refreshQrToken() {
    _qrSession?.refresh();
    notifyListeners();
  }

  /// 修改本机别名
  Future<void> updateAlias(String newAlias) async {
    if (newAlias.trim().isEmpty || _selfDevice == null) return;

    await AppPreferences.saveAlias(newAlias.trim());

    _selfDevice = Device(
      fingerprint: _selfDevice!.fingerprint,
      alias: newAlias.trim(),
      deviceType: _selfDevice!.deviceType,
      deviceModel: _selfDevice!.deviceModel,
      ip: _selfDevice!.ip,
      port: _selfDevice!.port,
      isLocal: true,
    );

    // 重启发现服务，让新名字立刻广播出去
    await _discovery?.stop();
    _discovery = DiscoveryService(
      selfDevice: _selfDevice!,
      onDeviceFound: (d) {
        _devices[d.fingerprint] = d;
        notifyListeners();
      },
      onDeviceLost: (d) {
        _devices.remove(d.fingerprint);
        notifyListeners();
      },
      onError: (msg) {
        _errorMessage = msg;
        notifyListeners();
      },
    );
    await _discovery!.start();

    // transfer 服务也要用新名字
    await _transfer?.stopServer();
    _transfer = TransferService(
      selfDevice: _selfDevice!,
      downloadDir: _stagingDir,
      publishFile: Platform.isAndroid ? PublicStorage.publish : null,
      onSessionStarted: (s) {
        _receiveSessions[s.sessionId] = s;
        notifyListeners();
      },
      onProgress: (s) => notifyListeners(),
      onFileReceived: (s, f) => notifyListeners(),
      onSessionEnded: (s) => notifyListeners(),
      onError: (msg) {
        _errorMessage = msg;
        notifyListeners();
      },
      onPeerSaidBye: _removeDeviceByFingerprint,
      onPeerSeen: (d) => _discovery?.markSeen(d),
    );
    await _transfer!.startServer();

    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  // ==================== 内部工具 ====================

  /// 版本检查接口地址。
  ///
  /// 部署在 Cloudflare Pages + Functions（子域名 `appversion.harvin.top`），
  /// 数据存在 KV 里。改了 KV 里的 minVersion，所有用户下次启动就会被强制更新。
  ///
  /// 用独立子域名而不是挂在 harvin.top 根下，是为了和主站的服务完全隔离 ——
  /// 主站的 nginx 配了 catch-all 规则，挂在同一个域下容易互相干扰。
  static const _versionEndpoint = 'https://appversion.harvin.top/api/version';

  /// 检查是否有新版本 / 是否被强制更新
  ///
  /// 任何时候失败都放行 —— 见 VersionCheckService 的注释。
  Future<void> _checkVersion() async {
    try {
      final service = VersionCheckService(endpoint: _versionEndpoint);
      final result = await service.check();

      // 只有「需要拦截」或「有新版本可选」时才记下来让 UI 展示。
      // upToDate / checkFailed 都当作没事，不打扰用户。
      if (result.status == UpdateStatus.required ||
          result.status == UpdateStatus.optional) {
        _updateResult = result;
        notifyListeners();
      }
    } catch (_) {
      // 检查失败静默放行
    }
  }

  /// 解析接收文件的保存目录
  ///
  /// 桌面端优先用系统下载目录；移动端用应用私有目录
  /// （Android 10+ 分区存储下，应用无法随意写公共目录）。
  Future<String> _resolveDownloadDir() async {
    if (Platform.isAndroid) {
      final pub = await PublicStorage.publicDir();
      if (pub != null && pub.isNotEmpty) return pub;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      final sub = Directory('${dir.path}${Platform.pathSeparator}LanShare');
      if (!await sub.exists()) await sub.create(recursive: true);
      return sub.path;
    }

    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) {
        final sub = Directory('${dir.path}${Platform.pathSeparator}GUODROP');
        if (!await sub.exists()) await sub.create(recursive: true);
        return sub.path;
      }
    } catch (_) {}

    final fallback = await getApplicationDocumentsDirectory();
    return fallback.path;
  }

  @override
  void dispose() {
    shutdown();
    super.dispose();
  }
}
