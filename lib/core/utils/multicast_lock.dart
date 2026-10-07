import 'dart:io';

import 'package:flutter/services.dart';

/// Android WiFi 组播锁的 Dart 侧封装
///
/// ## 为什么需要
///
/// Android 为省电会**主动丢弃 WiFi 组播包**，而设备发现完全依赖组播。
/// 只声明 `CHANGE_WIFI_MULTICAST_STATE` 权限不够，必须实际申请组播锁，
/// 否则表现为「刚打开 App 能搜到设备，几秒后就搜不到了」。
///
/// 原生实现在 `MainActivity.kt`，通过 MethodChannel 调用。
///
/// ## 其他平台
///
/// 只有 Android 需要这个锁。Windows / macOS / Linux / iOS 的组播
/// 不需要特殊申请，所以这些平台上所有方法都是空操作。
class MulticastLock {
  MulticastLock._();

  static const _channel = MethodChannel('lan_share/multicast');

  static bool _held = false;

  /// 是否已持有锁
  static bool get isHeld => _held;

  /// 申请组播锁。重复调用安全。
  ///
  /// 在发现服务启动时调用。
  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    if (_held) return;

    try {
      final ok = await _channel.invokeMethod<bool>('acquire');
      _held = ok ?? false;
    } on PlatformException {
      // 原生侧失败（如 Wi-Fi 关闭）。不致命——单播探测仍能兜底。
      _held = false;
    } on MissingPluginException {
      // 平台通道未注册（理论上不会发生，除非原生代码没编进去）
      _held = false;
    }
  }

  /// 释放组播锁。
  ///
  /// 在发现服务停止时调用，避免 App 在后台仍占着 WiFi。
  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    if (!_held) return;

    try {
      await _channel.invokeMethod<bool>('release');
    } catch (_) {
      // 忽略：进程可能正在退出
    }
    _held = false;
  }

  /// 把本机身份同步给原生侧。
  ///
  /// ## 为什么要同步
  ///
  /// 原生侧在 `onDestroy` 里会兜底补发一个「下线」UDP 包 ——
  /// 因为用户上滑划掉 App 时，Dart 的异步网络调用常常来不及完成，
  /// 但原生的同步发送一定来得及。
  ///
  /// 那个包需要包含本机指纹、别名等信息，所以得提前同步过去。
  ///
  /// 在 App 初始化完成、身份确定之后调用一次即可。
  static Future<void> syncIdentity({
    required String fingerprint,
    required String alias,
    required String deviceType,
    required String deviceModel,
    required int port,
  }) async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod<bool>('setIdentity', <String, dynamic>{
        'fingerprint': fingerprint,
        'alias': alias,
        'deviceType': deviceType,
        'deviceModel': deviceModel,
        'port': port,
      });
    } catch (_) {
      // 原生侧没实现这个接口（老版本 APK），忽略。
      // 最坏情况就是 onDestroy 兜底发不出下线包，
      // 还有 Dart 侧的两条通道和 30 秒超时兜着。
    }
  }
}
