import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'protocol.dart';

/// 局域网内一台对端设备的描述
///
/// 这个对象在三个地方被创建：
///  1. 本机自述（用于回应别人的探测）
///  2. 收到别人的 UDP 广播时解析出来
///  3. 扫二维码时从 URL 里还原出来
class Device {
  /// 设备唯一标识（安装时生成，持久化）
  final String fingerprint;

  /// 用户可见的设备名，如「小明的 MacBook」
  final String alias;

  final DeviceType deviceType;

  /// 设备型号，如 "iPhone15,2"
  final String deviceModel;

  /// 对端 IP
  final String ip;

  /// HTTP 服务端口
  final int port;

  final TransferProtocol protocol;

  /// 上次收到广播的时间，用于老化淘汰
  final DateTime? lastSeen;

  /// 是否为本机
  final bool isLocal;

  const Device({
    required this.fingerprint,
    required this.alias,
    required this.deviceType,
    required this.deviceModel,
    required this.ip,
    required this.port,
    this.protocol = TransferProtocol.http,
    this.lastSeen,
    this.isLocal = false,
  });

  /// 从 UDP 广播或 /info 接口的 JSON 构造
  ///
  /// [ip] 是数据包的来源地址，作为兜底。如果 JSON 里自带 ip 字段
  /// 且看起来是个可用的私有地址，优先用自报的 —— 对端自己最清楚
  /// 该用哪个 IP 才能连通它（多网卡、虚拟网卡场景下推断常出错）。
  factory Device.fromJson(Map<String, dynamic> json, {required String ip}) {
    final rawPort = json['port'];
    final selfReported = (json['ip'] as String?)?.trim();

    final resolvedIp = (selfReported != null &&
            selfReported.isNotEmpty &&
            selfReported != '127.0.0.1' &&
            selfReported != '0.0.0.0')
        ? selfReported
        : ip;

    return Device(
      fingerprint: json['fingerprint'] as String? ?? '',
      alias: json['alias'] as String? ?? '未知设备',
      deviceType: DeviceType.fromString(json['deviceType'] as String?),
      deviceModel: json['deviceModel'] as String? ?? '',
      ip: resolvedIp,
      port: rawPort is int
          ? rawPort
          : int.tryParse('$rawPort') ?? Protocol.defaultPort,
      protocol: TransferProtocol.fromString(json['protocol'] as String?),
      lastSeen: DateTime.now(),
    );
  }

  /// 序列化为本机自述 JSON
  ///
  /// 带上 ip：接收方本来能从数据包来源地址推断，但多网卡 / NAT 场景下
  /// 推断出来的可能是错的那个。自己报的更准，接收方优先用它。
  Map<String, dynamic> toJson() => {
        'alias': alias,
        'version': Protocol.version,
        'deviceModel': deviceModel,
        'deviceType': deviceType.value,
        'fingerprint': fingerprint,
        'ip': ip,
        'port': port,
        'protocol': protocol.value,
        'download': false,
      };

  Map<String, dynamic> toJsonWithIp() => toJson();

  /// 供二维码使用的直达 URL
  ///
  /// 手机扫到这个 URL 后：装了 App 就唤起 App，没装就落到浏览器下载页
  String toQrUrl({String? token}) {
    final scheme = protocol.value;
    final t = token != null ? '?token=$token' : '';
    return '$scheme://$ip:$port$t';
  }

  Device copyWith({DateTime? lastSeen, bool? isLocal}) => Device(
        fingerprint: fingerprint,
        alias: alias,
        deviceType: deviceType,
        deviceModel: deviceModel,
        ip: ip,
        port: port,
        protocol: protocol,
        lastSeen: lastSeen ?? this.lastSeen,
        isLocal: isLocal ?? this.isLocal,
      );

  /// 判断设备是否已超时
  bool isStale(DateTime now) {
    if (lastSeen == null) return false;
    return now.difference(lastSeen!).inMilliseconds > Protocol.deviceTimeoutMs;
  }

  @override
  bool operator ==(Object other) =>
      other is Device && other.fingerprint == fingerprint;

  @override
  int get hashCode => fingerprint.hashCode;

  @override
  String toString() => 'Device($alias @ $ip:$port, $deviceType)';

  /// 从二维码 URL 反解设备信息
  ///
  /// 支持两种输入：
  ///  - http://192.168.1.5:53317?token=xxx
  ///  - 纯 IP:端口  192.168.1.5:53317
  static Device? fromQrText(String text, {String alias = '扫码设备'}) {
    var raw = text.trim();
    if (raw.isEmpty) return null;

    String? ip;
    int? port;
    var protocol = TransferProtocol.http;

    if (raw.contains('://')) {
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.host.isEmpty) return null;
      ip = uri.host;
      port = uri.hasPort ? uri.port : Protocol.defaultPort;
      protocol = uri.scheme == 'https'
          ? TransferProtocol.https
          : TransferProtocol.http;
    } else {
      // 纯 IP:端口 形式
      final parts = raw.split(':');
      if (parts.isEmpty) return null;
      ip = parts[0];
      port = parts.length > 1
          ? int.tryParse(parts[1]) ?? Protocol.defaultPort
          : Protocol.defaultPort;
    }

    if (ip.isEmpty) return null;

    return Device(
      fingerprint: 'qr-$ip-$port',
      alias: alias,
      deviceType: DeviceType.unknown,
      deviceModel: '',
      ip: ip,
      port: port,
      protocol: protocol,
      lastSeen: DateTime.now(),
    );
  }
}

/// 待传输的文件元信息
class FileMeta {
  final String id;
  final String fileName;

  /// 文件大小（字节）
  final int size;

  final String? mimeType;

  /// 本地绝对路径（发送端使用）
  final String? localPath;

  /// 接收端保存后的路径
  final String? savedPath;

  /// 接收端保存后的 content:// URI（Android MediaStore），用于直接打开文件
  final String? savedUri;

  const FileMeta({
    required this.id,
    required this.fileName,
    required this.size,
    this.mimeType,
    this.localPath,
    this.savedPath,
    this.savedUri,
  });

  factory FileMeta.fromJson(Map<String, dynamic> json) => FileMeta(
        id: json['id'] as String? ?? '',
        fileName: json['fileName'] as String? ?? 'unnamed',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mimeType: json['mimeType'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'size': size,
        'mimeType': mimeType,
      };

  String get readableSize => formatBytes(size);

  static String fromBytes(List<int> bytes) => utf8.decode(bytes);
}

/// 人类可读的文件大小
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 本机网络地址探测 — 区分 WiFi 和有线，并排除回环、虚拟网卡
class NetworkAddressResolver {
  /// 取本机在局域网中的 IPv4 地址
  ///
  /// 优先级：WiFi/以太网 > 其他。虚拟网卡（VMware/VirtualBox/Docker）
  /// 的地址会被排除，否则会广播出去一个别人根本连不上的 IP。
  ///
  /// 注意：Android 上 NetworkInterface.list 有时会返回蜂窝网/VPN 的地址，
  /// 所以 Android 分支会额外通过平台通道问系统要 WiFi 的真实 IP。
  static Future<String?> resolveLocalIp() async {
    // Android 优先问系统要 WiFi IP —— 最准
    if (Platform.isAndroid) {
      final wifiIp = await _androidWifiIp();
      if (wifiIp != null) return wifiIp;
    }

    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );

    final candidates = <String>[];
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      if (_isVirtualInterface(name)) continue;
      for (final addr in iface.addresses) {
        if (addr.isLoopback) continue;
        if (_isPrivateIp(addr.address)) candidates.add(addr.address);
      }
    }

    if (candidates.isEmpty) return null;

    // 192.168.x.x 最像家庭/办公 WiFi，优先
    candidates.sort((a, b) {
      int rank(String ip) {
        if (ip.startsWith('192.168.')) return 0;
        if (ip.startsWith('10.')) return 1;
        return 2; // 172.16-31.x.x
      }

      return rank(a).compareTo(rank(b));
    });

    return candidates.first;
  }

  /// 通过平台通道向 Android 要 WiFi 的 IPv4 地址
  ///
  /// 为什么需要：NetworkInterface.list 在部分机型上拿不到 wlan0，
  /// 或者返回的是运营商蜂窝地址（100.64.x.x / 10.x.x.x），
  /// 广播出去后对端根本连不上。WifiManager 的报的才是能用的那个。
  static Future<String?> _androidWifiIp() async {
    try {
      const channel = MethodChannel('lan_share/network');
      final ip = await channel.invokeMethod<String>('getWifiIp');
      final trimmed = ip?.trim();
      if (trimmed == null || trimmed.isEmpty) return null;
      if (trimmed == '0.0.0.0' || trimmed.startsWith('127.')) return null;
      return trimmed;
    } catch (_) {
      // 通道不存在 / 权限不足，退回网卡枚举
      return null;
    }
  }

  static bool _isPrivateIp(String ip) {
    return ip.startsWith('192.168.') ||
        ip.startsWith('10.') ||
        _is172Private(ip);
  }

  static bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final second = int.tryParse(ip.split('.')[1]);
    if (second == null) return false;
    return second >= 16 && second <= 31;
  }

  static bool _isVirtualInterface(String name) {
    const virtualHints = [
      'vmware',
      'virtualbox',
      'vbox',
      'docker',
      'hyper-v',
      'vethernet',
      'loopback',
      'tap',
      'tun',
      'wsl',
      'bluetooth',
    ];
    return virtualHints.any(name.contains);
  }
}
