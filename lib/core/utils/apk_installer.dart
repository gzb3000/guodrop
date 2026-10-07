import 'dart:io';

import 'package:flutter/services.dart';

/// 用系统安装器安装 APK（仅 Android）
///
/// Android 7.0+ 禁止把 `file://` 暴露给其他 App，必须经 FileProvider
/// 转成 `content://`，这完全在原生层完成，所以走 MethodChannel
/// （原生实现见 MainActivity.kt 的 `lan_share/installer`）。
///
/// 非 Android 平台全部返回安全默认值，不抛异常。
class ApkInstaller {
  ApkInstaller._();

  static const _channel = MethodChannel('lan_share/installer');

  /// 当前平台是否支持 App 内安装
  static bool get isSupported => Platform.isAndroid;

  /// 是否已获得「安装未知应用」授权
  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 跳转到系统的「安装未知应用」授权页。
  ///
  /// 拿不到授权结果，调用方应在 App 恢复前台时重新调用 [canInstall]。
  static Future<void> requestInstallPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('requestInstallPermission');
    } on PlatformException {
      // 忽略：用户还可以手动去设置里开
    } on MissingPluginException {
      // 老 APK 跑新 Dart 代码
    }
  }

  /// 拉起系统安装器。返回 null 表示成功拉起；非 null 是错误描述。
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
