import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 下载进度
class DownloadProgress {
  final int received;
  final int total; // 0 表示服务端没给 Content-Length
  const DownloadProgress(this.received, this.total);

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

/// 下载结果
class DownloadResult {
  final bool success;
  final bool cancelled;
  final String? filePath;
  final String? error;
  const DownloadResult({
    required this.success,
    this.cancelled = false,
    this.filePath,
    this.error,
  });
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// 更新安装包下载器（Android 的 APK、Windows 的安装器 exe 共用）。
///
/// 只用 `dart:io` 的 [HttpClient]，不引入新依赖。
///   - 下载到 `getTemporaryDirectory()/update/`（Android 上即 cacheDir/update/，
///     与 res/xml/file_paths.xml 的 cache-path 对应）
///   - 进度回调、取消、60 秒无数据超时
///   - 多个地址按顺序尝试；自动跟随 GitHub Releases 的 302 重定向
///   - 先写 `.part`，校验大小一致后再改名，绝不留下半截文件
class ApkDownloader {
  ApkDownloader._();

  /// 两次收到数据之间允许的最长间隔
  static const idleTimeout = Duration(seconds: 60);

  /// 下载目录：<tmp>/update/
  static Future<Directory> updateDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}${Platform.pathSeparator}update');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<DownloadResult> download({
    required List<String> urls,
    required String fileName,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? shouldCancel,
  }) async {
    final candidates =
        urls.map((u) => u.trim()).where((u) => u.isNotEmpty).toList();
    if (candidates.isEmpty) {
      return const DownloadResult(success: false, error: '没有可用的下载地址');
    }

    final Directory dir;
    try {
      dir = await updateDir();
    } catch (e) {
      return DownloadResult(success: false, error: '无法创建下载目录：$e');
    }
    final target = File('${dir.path}${Platform.pathSeparator}$fileName');
    final part = File('${target.path}.part');

    String? lastError;
    for (final url in candidates) {
      await _safeDelete(target);
      await _safeDelete(part);
      try {
        await _downloadOne(url, part, onProgress, shouldCancel);
        await part.rename(target.path);
        return DownloadResult(success: true, filePath: target.path);
      } on _Cancelled {
        await _safeDelete(part);
        return const DownloadResult(
            success: false, cancelled: true, error: '已取消下载');
      } catch (e) {
        await _safeDelete(part);
        lastError = '$e';
      }
    }
    return DownloadResult(success: false, error: lastError ?? '下载失败');
  }

  static Future<void> _downloadOne(
    String url,
    File part,
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function()? shouldCancel,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = idleTimeout;
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = true; // GitHub Releases → 302 到 CDN
      request.maxRedirects = 10;
      request.headers.set(HttpHeaders.userAgentHeader, 'lan_share-updater');
      final response = await request.close().timeout(idleTimeout);

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final ct = response.headers.contentType?.mimeType ?? '';
      if (ct == 'text/html') {
        // 填成了网页地址而不是直链
        throw const FormatException('下载到的是网页而不是安装包，请检查下载直链');
      }

      final total = response.contentLength > 0 ? response.contentLength : 0;
      var received = 0;
      onProgress?.call(DownloadProgress(0, total));
      sink = part.openWrite();

      await for (final chunk in response.timeout(idleTimeout)) {
        if (shouldCancel != null && await shouldCancel()) {
          throw const _Cancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(DownloadProgress(received, total));
      }
      await sink.flush();
      await sink.close();
      sink = null;

      final size = await part.length();
      if (size <= 0) throw const FormatException('下载的文件为空');
      if (total > 0 && size != total) {
        throw FormatException('文件不完整（$size / $total 字节）');
      }
    } on TimeoutException {
      throw const SocketException('下载超时（60 秒无数据）');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  static Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
