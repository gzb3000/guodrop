import 'package:flutter_test/flutter_test.dart';
import 'package:lan_share/core/models/device.dart';
import 'package:lan_share/core/models/protocol.dart';
import 'package:lan_share/core/scan/scan_service.dart';

/// 核心逻辑单元测试
///
/// 这些测试不依赖真实网络，覆盖最容易出错的解析逻辑：
/// 二维码解析、设备反序列化、文件大小格式化、路径安全。
void main() {
  group('扫码解析 ScanService.parseScanResult', () {
    test('标准 URL 形式', () {
      final d = ScanService.parseScanResult('http://192.168.1.5:53317/?token=abc');
      expect(d, isNotNull);
      expect(d!.ip, '192.168.1.5');
      expect(d.port, 53317);
    });

    test('URL 省略端口时用默认值', () {
      final d = ScanService.parseScanResult('http://192.168.1.5/?token=abc');
      expect(d!.port, 53317);
    });

    test('IP:端口 纯文本形式', () {
      final d = ScanService.parseScanResult('192.168.1.5:8080');
      expect(d!.ip, '192.168.1.5');
      expect(d.port, 8080);
    });

    test('只有 IP 时用默认端口', () {
      final d = ScanService.parseScanResult('10.0.0.23');
      expect(d!.port, 53317);
    });

    test('从混杂文本中提取 IP', () {
      final d = ScanService.parseScanResult('设备地址是 192.168.0.100 请连接');
      expect(d!.ip, '192.168.0.100');
    });

    test('https 协议正确识别', () {
      final d = ScanService.parseScanResult('https://192.168.1.5:53318/?token=x');
      expect(d!.protocol.value, 'https');
    });

    test('非法输入返回 null', () {
      expect(ScanService.parseScanResult(''), isNull);
      expect(ScanService.parseScanResult('这不是二维码内容'), isNull);
    });

    test('超出范围的 IP 被拒绝', () {
      expect(ScanService.parseScanResult('999.1.1.1:53317'), isNull);
    });
  });

  group('IPv4 校验', () {
    test('合法地址', () {
      expect(ScanService.isValidIpv4('192.168.1.1'), isTrue);
      expect(ScanService.isValidIpv4('0.0.0.0'), isTrue);
      expect(ScanService.isValidIpv4('255.255.255.255'), isTrue);
    });

    test('非法地址', () {
      expect(ScanService.isValidIpv4('256.1.1.1'), isFalse);
      expect(ScanService.isValidIpv4('1.1.1'), isFalse);
      expect(ScanService.isValidIpv4('a.b.c.d'), isFalse);
    });
  });

  group('设备序列化 Device', () {
    test('fromJson 解析组播广播内容', () {
      final d = Device.fromJson({
        'alias': '小明的手机',
        'deviceType': 'mobile',
        'deviceModel': 'Xiaomi 14',
        'fingerprint': 'abc123',
        'port': 53317,
        'protocol': 'http',
      }, ip: '192.168.1.8');

      expect(d.alias, '小明的手机');
      expect(d.deviceType, DeviceType.mobile);
      expect(d.ip, '192.168.1.8');
    });

    test('端口为字符串时容错解析', () {
      final d = Device.fromJson({
        'alias': 'test',
        'fingerprint': 'x',
        'port': '53317',
      }, ip: '192.168.1.8');
      expect(d.port, 53317);
    });

    test('字段缺失时用默认值而非崩溃', () {
      final d = Device.fromJson({}, ip: '192.168.1.8');
      expect(d.alias, '未知设备');
      expect(d.deviceType, DeviceType.unknown);
      expect(d.port, 53317);
    });

    test('toJson 带上自报 ip（多网卡/NAT 下比来源地址更准）', () {
      final d = Device(
        fingerprint: 'f',
        alias: 'a',
        deviceType: DeviceType.desktop,
        deviceModel: 'm',
        ip: '192.168.1.5',
        port: 53317,
      );
      expect(d.toJson()['ip'], '192.168.1.5');
      expect(d.toJsonWithIp()['ip'], '192.168.1.5');
    });

    test('超时判定', () {
      final stale = Device(
        fingerprint: 'f', alias: 'a', deviceType: DeviceType.desktop,
        deviceModel: '', ip: '1.1.1.1', port: 53317,
        lastSeen: DateTime.now().subtract(const Duration(milliseconds: Protocol.deviceTimeoutMs + 5000)),
      );
      expect(stale.isStale(DateTime.now()), isTrue);

      final fresh = Device(
        fingerprint: 'g', alias: 'a', deviceType: DeviceType.desktop,
        deviceModel: '', ip: '1.1.1.1', port: 53317,
        lastSeen: DateTime.now(),
      );
      expect(fresh.isStale(DateTime.now()), isFalse);
    });
  });

  group('文件大小格式化', () {
    test('各量级正确显示', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.00 GB');
    });
  });

  group('二维码 token 校验', () {
    test('生成的 token 正确匹配', () {
      final s = QrSession(ip: '192.168.1.5', port: 53317);
      expect(s.verify(s.token), isTrue);
      expect(s.verify('wrong-token'), isFalse);
      expect(s.isExpired, isFalse);
    });

    test('刷新后旧 token 失效', () {
      final s = QrSession(ip: '192.168.1.5', port: 53317);
      final old = s.token;
      s.refresh();
      expect(s.verify(old), isFalse);
      expect(s.verify(s.token), isTrue);
    });

    test('payload 包含 IP 和端口', () {
      final s = QrSession(ip: '192.168.1.5', port: 53317);
      expect(s.payload.contains('192.168.1.5'), isTrue);
      expect(s.payload.contains('53317'), isTrue);
    });
  });

  group('二维码往返', () {
    test('电脑端生成的二维码能被手机端解析', () {
      final qr = QrSession(ip: '192.168.31.19', port: 53317);
      final d = ScanService.parseScanResult(qr.payload);
      expect(d, isNotNull);
      expect(d!.ip, '192.168.31.19');
      expect(d.port, 53317);
    });
  });
}
