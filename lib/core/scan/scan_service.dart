import 'dart:convert';
import 'dart:math';

import '../models/device.dart';
import '../models/protocol.dart';

/// 扫码直连服务
///
/// 设计思路：
///  二维码里放的是一条带 token 的 URL。扫描方解析出 IP/端口后直接建连，
///  完全跳过 UDP 发现环节。这个兜底路径在两种场景下不可替代：
///   1. 公共 WiFi 开启了 AP isolation，组播被丢弃
///   2. 对端设备是浏览器（没有 UDP 能力），只能用 URL 通信
///
///  token 的作用：防止局域网内其他设备知道 IP 后乱传文件。
///  接收方校验 token，不匹配就拒绝。
class ScanService {
  ScanService();

  /// 生成一次性会话 token
  ///
  /// 每次展示二维码时刷新，避免长期有效的 token 被滥用。
  static String generateToken({int length = 16}) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return List.generate(
      length,
      (_) => chars[rand.nextInt(chars.length)],
    ).join();
  }

  /// 构建二维码内容
  static String buildQrPayload({
    required String ip,
    required int port,
    required String token,
    bool https = false,
  }) {
    final scheme = https ? 'https' : 'http';
    return '$scheme://$ip:$port/?token=$token';
  }

  /// 解析扫描结果，返回设备信息
  ///
  /// 输入可能是：
  ///   - http://192.168.1.5:53317/?token=abc123   （本 App 生成的二维码）
  ///   - 192.168.1.5:53317                        （手写/其他工具）
  ///   - 任意包含 IP 的文本                        （容错提取）
  static Device? parseScanResult(String rawText, {String? senderAlias}) {
    final text = rawText.trim();
    if (text.isEmpty) return null;

    // 标准 URL 形式
    if (text.contains('://')) {
      final uri = Uri.tryParse(text);
      if (uri != null && uri.host.isNotEmpty) {
        return Device(
          fingerprint: 'qr-${uri.host}-${uri.port}',
          alias: senderAlias ?? '扫码设备',
          deviceType: DeviceType.unknown,
          deviceModel: '',
          ip: uri.host,
          port: uri.hasPort ? uri.port : 53317,
          protocol: uri.scheme == 'https'
              ? TransferProtocol.https
              : TransferProtocol.http,
          lastSeen: DateTime.now(),
        );
      }
    }

    // IP:端口 形式
    final ipPortPattern = RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?::(\d+))?');
    final match = ipPortPattern.firstMatch(text);
    if (match != null) {
      final ip = match.group(1)!;
      final port = int.tryParse(match.group(2) ?? '') ?? 53317;

      if (isValidIpv4(ip)) {
        return Device(
          fingerprint: 'qr-$ip-$port',
          alias: senderAlias ?? '扫码设备',
          deviceType: DeviceType.unknown,
          deviceModel: '',
          ip: ip,
          port: port,
          lastSeen: DateTime.now(),
        );
      }
    }

    return null;
  }

  /// 校验 IPv4 地址合法性
  static bool isValidIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  /// 校验手输的 IP:端口
  static String? validateManualInput(String input) {
    if (input.trim().isEmpty) return '请输入 IP 地址';
    final device = parseScanResult(input);
    if (device == null) return '格式不正确，示例：192.168.1.5:53317';
    return null;
  }
}

/// 二维码会话 — 管理 token 生命周期
class QrSession {
  QrSession({required this.ip, required this.port});

  final String ip;
  final int port;

  String _token = ScanService.generateToken();
  DateTime _issuedAt = DateTime.now();

  String get token => _token;
  DateTime get issuedAt => _issuedAt;

  /// token 有效期（分钟）
  static const int validMinutes = 10;

  bool get isExpired =>
      DateTime.now().difference(_issuedAt).inMinutes >= validMinutes;

  /// 刷新 token — 二维码被重新展示时调用
  void refresh() {
    _token = ScanService.generateToken();
    _issuedAt = DateTime.now();
  }

  String get payload =>
      ScanService.buildQrPayload(ip: ip, port: port, token: _token);

  /// 校验传入的 token 是否有效
  bool verify(String candidate) => !isExpired && candidate == _token;
}

/// 将扫描结果编码为 JSON（用于跨进程传递）
String encodeScanResult(Device device) => jsonEncode(device.toJsonWithIp());
