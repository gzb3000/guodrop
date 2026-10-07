import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/protocol.dart';

/// 设备信息辅助 — 跨平台获取设备型号与类型
class DeviceInfoHelper {
  /// 获取设备型号字符串
  ///
  /// 各平台 API 差异较大，这里统一收口。失败时返回空字符串
  /// 而不是抛异常——设备型号只是展示用的锦上添花，
  /// 不该因为它拿不到就导致整个 App 起不来。
  static Future<String> deviceModel() async {
    try {
      final plugin = DeviceInfoPlugin();

      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        return '${info.manufacturer} ${info.model}';
      }
      if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        return info.utsname.machine;
      }
      if (Platform.isMacOS) {
        final info = await plugin.macOsInfo;
        return info.model;
      }
      if (Platform.isWindows) {
        final info = await plugin.windowsInfo;
        return info.productName;
      }
      if (Platform.isLinux) {
        final info = await plugin.linuxInfo;
        return info.prettyName;
      }
    } catch (e) {
      debugPrint('获取设备型号失败: $e');
    }
    return '';
  }

  /// 判断当前设备类型
  static DeviceType currentDeviceType() {
    if (kIsWeb) return DeviceType.web;
    if (Platform.isAndroid || Platform.isIOS) return DeviceType.mobile;
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return DeviceType.desktop;
    }
    return DeviceType.unknown;
  }

  /// 是否是移动端（用于 UI 自适应布局）
  static bool get isMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// 是否是桌面端
  static bool get isDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  /// 默认设备别名 — 首次启动时用
  ///
  /// 格式如「小明的 iPhone」，比一串哈希友好得多。
  static Future<String> defaultAlias() async {
    final model = await deviceModel();
    final type = currentDeviceType();

    if (model.isEmpty) {
      return type.label;
    }
    return model;
  }
}
