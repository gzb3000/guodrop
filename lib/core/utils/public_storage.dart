import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../transport/transfer_service.dart';

/// Android 公共存储：把收到的文件放进「下载/GUODROP」，并能直接打开目录/文件。
///
/// 原生实现见 MainActivity.kt 的 `lan_share/storage` 通道：
///   - Android 10+（API 29+）：MediaStore.Downloads，RELATIVE_PATH=Download/GUODROP，
///     无需任何存储权限；图片/视频由 MediaProvider 自动入库，相册可见。
///   - Android 7–9（API 24–28）：直接写 /sdcard/Download/GUODROP（需 WRITE_EXTERNAL_STORAGE），
///     写完 MediaScanner 扫描入库。
class PublicStorage {
  PublicStorage._();

  static const _channel = MethodChannel('lan_share/storage');
  static const folderName = 'GUODROP';

  static bool get isSupported => Platform.isAndroid;

  /// 给用户看的保存目录（形如 /storage/emulated/0/Download/GUODROP）
  static Future<String?> publicDir() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('publicDir');
    } catch (_) {
      return null;
    }
  }

  /// API 28 及以下需要存储权限；10+ 直接返回 true
  static Future<bool> ensureWritePermission() async {
    if (!isSupported) return true;
    try {
      final sdk = await _channel.invokeMethod<int>('sdkInt') ?? 0;
      if (sdk >= 29) return true;
      final st = await Permission.storage.request();
      return st.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 把暂存文件复制到公共下载目录，返回最终路径 + content URI
  static Future<PublishedFile?> publish(
      String tempPath, String fileName, String? mimeType) async {
    if (!isSupported) return (path: tempPath, uri: null);
    await ensureWritePermission();
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('publish', {
        'path': tempPath,
        'name': fileName,
        'mime': mimeType,
      });
      if (r == null) return null;
      return (path: r['path'] as String, uri: r['uri'] as String?);
    } catch (_) {
      return null;
    }
  }

  /// 在系统文件管理器里打开「下载/GUODROP」
  static Future<bool> openFolder() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('openFolder') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 用系统默认应用打开收到的文件
  static Future<bool> openFile({String? uri, String? path, String? mime}) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>(
              'openFile', {'uri': uri, 'path': path, 'mime': mime}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
