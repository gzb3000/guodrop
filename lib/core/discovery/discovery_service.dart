import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/device.dart';
import '../models/protocol.dart';
import '../utils/multicast_lock.dart';

/// UDP 组播发现服务
///
/// 组播在真实网络里非常不可靠，所以这里做了**三层冗余**，
/// 任意一层通就能发现对方：
///
///   第 1 层：UDP 组播广播（224.0.0.167:53317）
///           最快、最省事，但可能被 AP isolation、路由器设置、
///           Android 省电策略掐掉。
///
///   第 2 层：UDP 广播地址泛洪（255.255.255.255 + 各网段 x.x.x.255）
///           组播被禁时，子网广播往往还能通。
///
///   第 3 层：收到任何一层的数据后，立刻用 HTTP 单播向对方 /register
///           反向登记。这样只要「A 能到 B」或「B 能到 A」单向可达，
///           双向发现都能建立。
///
/// 另外：设备淘汰阈值放宽到 15 秒，且每收到一次广播就刷新 lastSeen，
/// 避免因为丢几个包就把在线设备误删。
class DiscoveryService {
  DiscoveryService({
    required this.selfDevice,
    this.onDeviceFound,
    this.onDeviceLost,
    this.onError,
  });

  final Device selfDevice;
  final void Function(Device device)? onDeviceFound;
  final void Function(Device device)? onDeviceLost;
  final void Function(String message)? onError;

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _cleanupTimer;

  /// 已发现的设备，key 为指纹
  final Map<String, Device> _devices = {};

  /// 已经回过 register 的设备指纹。
  ///
  /// 避免每次收到广播都回一发 HTTP（每 3 秒一次，太吵）。
  /// 一个设备回一次就够——对方收到后也会把本机登记进它的列表。
  final Set<String> _registered = {};

  /// 本机所有私有网段的广播地址，缓存下来避免每次 annouce 都重新枚举网卡
  List<InternetAddress> _broadcastTargets = const [];

  bool _running = false;
  bool get isRunning => _running;

  List<Device> get devices => _devices.values.toList();

  /// 启动发现服务
  Future<void> start() async {
    if (_running) return;

    // Android 必须先拿组播锁，否则系统会丢弃组播包。
    // 放在最前面：即使下面绑定端口失败，锁也已释放（见 catch 分支）。
    await MulticastLock.acquire();

    try {
      // 绑定组播端口。reuseAddress 让多个进程（或本机多网卡）能同时监听
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        Protocol.defaultPort,
        reuseAddress: true,
      );

      _socket!.multicastHops = 2; // 允许跨一层路由，但不能跑到公网
      _socket!.broadcastEnabled = true; // 打开 UDP 广播（第 2 层冗余要用）

      // 加入组播组，开始接收别人的广播
      try {
        _socket!.joinMulticast(InternetAddress(Protocol.multicastGroup));
      } catch (e) {
        // 某些网卡/系统不允许加入组播。不致命——还有广播和单播兜底。
        onError?.call('加入组播组失败，将使用广播兜底: $e');
      }

      _socket!.listen(
        _handleSocketEvent,
        onError: (e) => onError?.call('发现服务异常: $e'),
      );

      // 预先算好广播地址（异步枚举网卡，只做一次）
      _broadcastTargets = await _computeBroadcastTargets();

      _running = true;

      // 立即广播一次，让对端尽快看到自己
      await _announce();

      _announceTimer = Timer.periodic(
        const Duration(milliseconds: Protocol.announceIntervalMs),
        (_) => _announce(),
      );

      // 定时清理超时离线的设备
      _cleanupTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _cleanupStaleDevices(),
      );
    } catch (e) {
      _running = false;
      await MulticastLock.release(); // 启动失败，别占着锁
      onError?.call('无法启动发现服务（端口可能被占用）: $e');
    }
  }

  /// 停止并释放资源
  Future<void> stop() async {
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    _announceTimer = null;
    _cleanupTimer = null;

    try {
      _socket?.leaveMulticast(InternetAddress(Protocol.multicastGroup));
    } catch (_) {}

    _socket?.close();
    _socket = null;
    _running = false;
    _registered.clear();

    // 释放 Android 组播锁（其他平台是空操作）
    await MulticastLock.release();

    // 通知所有设备已离线
    for (final d in _devices.values) {
      onDeviceLost?.call(d);
    }
    _devices.clear();
  }

  /// 广播本机指纹
  ///
  /// 同时往组播组和子网广播地址各发一份。多花几个包，
  /// 换来的是「组播被禁用时仍然能发现」。
  Future<void> _announce() async {
    final socket = _socket;
    if (socket == null) return;

    try {
      final payload = utf8.encode(jsonEncode(selfDevice.toJson()));

      // 第 1 层：组播
      try {
        socket.send(
          payload,
          InternetAddress(Protocol.multicastGroup),
          Protocol.defaultPort,
        );
      } catch (_) {
        // 网卡不支持组播，忽略，继续走广播
      }

      // 第 2 层：子网广播（含全局广播地址）
      for (final target in _broadcastTargets) {
        try {
          socket.send(payload, target, Protocol.defaultPort);
        } catch (_) {
          // 单个地址失败不影响其他
        }
      }
    } catch (e) {
      onError?.call('广播失败: $e');
    }
  }

  /// 枚举本机所有网卡，算出各自网段的广播地址
  ///
  /// 例如 192.168.31.19/24 → 192.168.31.255
  /// 同时总是包含 255.255.255.255（受限广播，同一子网内必达）。
  Future<List<InternetAddress>> _computeBroadcastTargets() async {
    final targets = <String>{'255.255.255.255'};

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          // 用 /24 近似：绝大多数家庭和办公 WiFi 都是 /24
          targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
    } catch (_) {
      // 枚举失败就只用全局广播地址
    }

    return targets
        .map((s) => InternetAddress.tryParse(s))
        .whereType<InternetAddress>()
        .toList();
  }

  /// 处理 socket 事件
  void _handleSocketEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final datagram = _socket?.receive();
      if (datagram == null) return;
      _handleDatagram(datagram);
    }
  }

  void _handleDatagram(Datagram datagram) {
    try {
      final text = utf8.decode(datagram.data);
      final json = jsonDecode(text) as Map<String, dynamic>;

      // 忽略自己发的广播。
      //
      // 注意：子网广播（x.x.x.255）会被本机网卡回环收到，所以这条判断
      // 是必须的，否则会把自己加进设备列表。
      if (json['fingerprint'] == selfDevice.fingerprint) return;

      // 对端主动下线：立刻删掉，不登记、不回 register。
      if (json['bye'] == true) {
        final fp = (json['fingerprint'] as String?)?.trim();
        if (fp != null && fp.isNotEmpty) {
          final gone = _devices.remove(fp);
          _registered.remove(fp);
          if (gone != null) onDeviceLost?.call(gone);
        }
        return;
      }

      // 对端可能没填 fingerprint（老版本/LocalSend），用 IP 兜底当 key
      final fp = (json['fingerprint'] as String?)?.trim();
      if (fp == null || fp.isEmpty) {
        // 没有指纹就没法去重，也基本不是我们的对端
        if (json['port'] == null) return;
      }

      final device = Device.fromJson(json, ip: datagram.address.address);

      final existed = _devices.containsKey(device.fingerprint);
      _devices[device.fingerprint] = device;

      if (!existed) {
        onDeviceFound?.call(device);
      }

      // 关键：回发一次 HTTP 单播，确保对方也能发现本机。
      //
      // 为什么需要：组播和广播都是**单向**的，AP isolation / 对称路由
      // 可能只放行一个方向。A 能收到 B 的广播，不代表 B 能收到 A 的。
      // 补一发单播 HTTP，让对方把我的信息登记进它的列表。
      //
      // 每台设备只回一次，避免每 3 秒一次的广播造成 HTTP 风暴。
      if (!_registered.contains(device.fingerprint)) {
        _registered.add(device.fingerprint);
        unawaited(_registerWith(device));
      }
    } catch (_) {
      // 收到非法数据包（可能来自其他程序），静默忽略
    }
  }

  /// 向对端 /register 接口登记本机信息，并把对方的回应登记进设备列表
  ///
  /// 这是一个「反向告知」：我听到了你的广播，现在请你把我加进你的列表，
  /// 顺便把你的信息也回给我 —— 一来一回，双向发现就都建立了。
  ///
  /// 失败不重试也不报错——组播/广播本身仍然在工作，这只是补强。
  Future<void> _registerWith(Device device) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);

    try {
      final uri = Uri.parse(
        'http://${device.ip}:${device.port}${Protocol.registerPath}',
      );
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(selfDevice.toJson()));
      final response = await request.close();

      final body = await response.transform(utf8.decoder).join();

      // 200 且带 body 时，把对方回传的信息也登记下来。
      // 这样即使我们从来收不到它的广播，也能看到它。
      if (response.statusCode == 200 && body.trim().isNotEmpty) {
        try {
          final json = jsonDecode(body) as Map<String, dynamic>;
          // 对方回传的 ip 字段可信（它自己知道自己的 IP），没有就用连接地址
          final replyIp = (json['ip'] as String?) ?? device.ip;
          final reply = Device.fromJson(json, ip: replyIp);
          if (reply.fingerprint != selfDevice.fingerprint) {
            final existed = _devices.containsKey(reply.fingerprint);
            _devices[reply.fingerprint] = reply;
            if (!existed) onDeviceFound?.call(reply);
          }
        } catch (_) {
          // body 不是合法 JSON，忽略
        }
      }
    } catch (_) {
      // 对端可能没有实现 register（比如 LocalSend），忽略即可。
      // 允许下次广播时再试一次。
      _registered.remove(device.fingerprint);
    } finally {
      client.close(force: true);
    }
  }

  /// 主动向已知 IP 探测设备（用于扫码后的反向确认，或手动添加 IP）
  Future<Device?> probeDevice(String ip, {int? port}) async {
    final targetPort = port ?? Protocol.defaultPort;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);

    try {
      final uri = Uri.parse('http://$ip:$targetPort${Protocol.infoPath}');
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode != 200) return null;

      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final device = Device.fromJson(json, ip: ip);

      _devices[device.fingerprint] = device;
      onDeviceFound?.call(device);
      return device;
    } catch (e) {
      onError?.call('探测 $ip 失败: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 清理超时设备
  ///
  /// 阈值是 15 秒（3 秒广播间隔的 5 倍）。中间丢几个包不会误删。
  /// 另外：对**已知的设备**额外做一次 HTTP 心跳确认，只有连 HTTP 也打不通
  /// 才真正移除 —— 避免「其实对方还活着，只是广播丢了」被误判离线。
  void _cleanupStaleDevices() {
    final now = DateTime.now();
    final stale = _devices.values.where((d) => d.isStale(now)).toList();

    for (final d in stale) {
      unawaited(_confirmLost(d));
    }
  }

  /// 设备超时后，用 HTTP 做最后一次确认
  ///
  /// 打得通 → 只刷新在线时间，不移除（说明只是广播丢了）；
  /// 打不通 → 才真的移除并通知 UI。
  Future<void> _confirmLost(Device device) async {
    // 如果这期间它又广播了，就不要动了
    if (!_devices.containsKey(device.fingerprint)) return;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);

    try {
      final uri = Uri.parse(
        'http://${device.ip}:${device.port}${Protocol.infoPath}',
      );
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final ip = (json['ip'] as String?) ?? device.ip;
        _devices[device.fingerprint] = Device.fromJson(json, ip: ip);
        return; // 还活着，刷新一下就行
      }
    } catch (_) {
      // 打不通，下面执行移除
    } finally {
      client.close(force: true);
    }

    // 二次确认：万一在 HTTP 往返期间广播又到了，就别删
    final current = _devices[device.fingerprint];
    if (current != null && !current.isStale(DateTime.now())) return;

    _devices.remove(device.fingerprint);
    _registered.remove(device.fingerprint); // 允许它回来时重新登记
    onDeviceLost?.call(device);
  }

  /// 对外提供一个立刻重新扫描的动作
  Future<void> refresh() => _announce();

  /// 立刻把某个设备从列表里移除（收到对端下线通知时调用）
  ///
  /// 与 `_confirmLost` 不同：这里**不做任何探活确认**，说删就删。
  /// 因为这是对端亲口说的「我走了」，可信度最高。
  void removeDevice(String fingerprint) {
    final device = _devices.remove(fingerprint);
    _registered.remove(fingerprint);

    if (device != null) {
      onDeviceLost?.call(device);
    }
  }

  /// 广播一条「我要走了」的 UDP 包
  ///
  /// 和 `_announce` 走同样的通道（组播 + 子网广播），但 payload 里带
  /// `bye: true`。对端收到后会立刻把我删掉，不用等 30 秒超时。
  ///
  /// 这是 HTTP `/bye` 之外的第二条通道 —— HTTP 可能因为对方防火墙
  /// 规则而被拦，UDP 通常更宽松。
  ///
  /// ## 为什么这个方法几乎不 await
  ///
  /// `socket.send()` 本身是同步的：数据包当场交给内核，之后进程
  /// 就算被杀，包也已经发出去了。所以关键动作全部放在同步段里，
  /// 保证「调用即送达」。
  ///
  /// 末尾那个 30ms 的小延迟只是给内核一点时间真正把包推上网卡，
  /// 非常短，不影响「进程立刻被杀也能发出」这个特性。
  /// （原来这里是 120ms，太长了 —— 手机上划掉 App 时根本等不到。）
  Future<void> announceGoodbye() async {
    final socket = _socket;
    if (socket == null) return;

    try {
      final payload = utf8.encode(jsonEncode({
        ...selfDevice.toJson(),
        'bye': true,
      }));

      // ↓↓↓ 以下全部是同步调用，包立刻进入内核发送队列 ↓↓↓

      try {
        socket.send(
          payload,
          InternetAddress(Protocol.multicastGroup),
          Protocol.defaultPort,
        );
      } catch (_) {
        // 网卡不支持组播，继续走广播
      }

      for (final target in _broadcastTargets) {
        try {
          socket.send(payload, target, Protocol.defaultPort);
        } catch (_) {
          // 单个地址失败不影响其他
        }
      }

      // ↑↑↑ 到这里包已经全部发出去了 ↑↑↑
    } catch (_) {
      // 退出路径上，失败就算了
      return;
    }

    // 给内核 30ms 把包推上物理网卡，然后就可以让进程走了。
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}
