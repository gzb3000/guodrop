import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../models/device.dart';
import '../models/protocol.dart';

/// 文件落到公共目录后的结果：[path] 给人看/给桌面端打开，[uri] 给 Android 打开文件
typedef PublishedFile = ({String path, String? uri});

/// 把暂存目录里已完整写好的文件发布到最终位置（Android：下载/GUODROP）。
/// 返回 null 表示发布失败。
typedef PublishFileFn = Future<PublishedFile?> Function(
    String tempPath, String fileName, String? mimeType);

/// 一次接收中的会话
class ReceiveSession {
  final String sessionId;
  final Device sender;
  final List<FileMeta> files;
  final DateTime startedAt;

  int receivedBytes = 0;
  int totalBytes = 0;
  int completedFiles = 0;
  bool isCompleted = false;
  bool isCancelled = false;
  String? error;

  ReceiveSession({
    required this.sessionId,
    required this.sender,
    required this.files,
    required this.totalBytes,
  }) : startedAt = DateTime.now();

  double get progress =>
      totalBytes == 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);
}

/// 传输服务 — 同时扮演服务端和客户端
///
/// 服务端职责：
///   - 常驻监听 53317 端口
///   - 响应 /info 让别人能探测到我
///   - 响应 /upload 接收文件并落盘
///
/// 客户端职责：
///   - 向对端 /prepare-upload 提交文件清单，拿到上传许可
///   - 逐个文件 POST 到 /upload
class TransferService {
  TransferService({
    required this.selfDevice,
    required this.downloadDir,
    this.onSessionStarted,
    this.onProgress,
    this.onFileReceived,
    this.onSessionEnded,
    this.onError,
    this.onPeerSaidBye,
    this.publishFile,
    this.onPeerSeen,
  });

  final Device selfDevice;

  /// 接收文件的保存目录
  final String downloadDir;

  final void Function(ReceiveSession session)? onSessionStarted;
  final void Function(ReceiveSession session)? onProgress;
  final void Function(ReceiveSession session, FileMeta file)? onFileReceived;
  final void Function(ReceiveSession session)? onSessionEnded;
  final void Function(String message)? onError;

  /// 对端主动下线时触发，带上它的指纹
  final void Function(String fingerprint)? onPeerSaidBye;

  /// 可选：落盘后把文件发布到公共目录（Android 用 MediaStore）。
  /// 为 null 时文件直接保存在 [downloadDir]（桌面端）。
  final PublishFileFn? publishFile;

  /// 对端通过 HTTP 主动联系我（/register、/prepare-upload）时触发，
  /// 用于把它登记 / 刷新进设备列表（UDP 只单向可达时全靠这个）。
  final void Function(Device device)? onPeerSeen;

  HttpServer? _server;

  /// 进行中的接收会话，key 为 sessionId
  final Map<String, ReceiveSession> _sessions = {};

  /// 已批准的上传许可，key 为 sessionId
  final Map<String, Set<String>> _approvedUploads = {};

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  List<ReceiveSession> get sessions => _sessions.values.toList();

  // ==================== 服务端 ====================

  /// 启动 HTTP 服务端
  Future<void> startServer() async {
    if (_server != null) return;

    final router = Router()
      ..get(Protocol.infoPath, _handleInfo)
      ..post(Protocol.registerPath, _handleRegister)
      ..post(Protocol.byePath, _handleBye)
      ..post(Protocol.prepareUploadPath, _handlePrepareUpload)
      ..post(Protocol.uploadPath, _handleUpload)
      ..post(Protocol.cancelPath, _handleCancel)
      // 浏览器直接访问根路径时，给一个极简的网页上传界面。
      // 这是 HTTP 方案白送的能力：对方不装 App 也能传文件给你。
      ..get('/', _handleWebRoot);

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(router.call);

    _server = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      Protocol.defaultPort,
      shared: true,
    );

    _server!.autoCompress = false; // 传二进制文件，压缩纯粹浪费 CPU
  }

  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// GET /info — 对端探测我是否在线
  Future<Response> _handleInfo(Request request) async {
    return Response.ok(
      jsonEncode(selfDevice.toJsonWithIp()),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// POST /register — 对端主动登记，回传我的信息
  Future<Response> _handleRegister(Request request) async {
    try {
      final body = await request.readAsString();
      if (body.trim().isNotEmpty) {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final ip = _remoteIp(request);
        if (ip != null && json['fingerprint'] != selfDevice.fingerprint) {
          onPeerSeen?.call(Device.fromJson(json, ip: ip));
        }
      }
    } catch (_) {
      // body 不合法也照常回自己的信息
    }
    return Response.ok(
      jsonEncode(selfDevice.toJsonWithIp()),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// POST /bye — 对端要下线了，请立刻把我从设备列表里删掉
  ///
  /// 收到后只是把指纹抛给上层（AppState），由它去删设备。
  /// 这个接口是幂等的，重复调用无害。
  Future<Response> _handleBye(Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final fp = (json['fingerprint'] as String?)?.trim();

      if (fp != null && fp.isNotEmpty) {
        onPeerSaidBye?.call(fp);
      }
    } catch (_) {
      // body 不合法也返回 200 —— 反正我们的目的就是「删掉你」，
      // 拿不到指纹时上层还能靠 IP 兜底。
    }

    return Response.ok(jsonEncode({'ok': true}));
  }

  /// POST /prepare-upload — 发送端提交文件清单，我决定是否接收
  ///
  /// 生产版本这里应该弹窗问用户「是否接收来自 XX 的 3 个文件」。
  /// 骨架里先默认同意，并返回每个文件的 fileId token。
  Future<Response> _handlePrepareUpload(Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final sessionId = json['sessionId'] as String? ?? const Uuid().v4();
      final senderInfo = json['info'] as Map<String, dynamic>?;
      final filesJson = (json['files'] as Map<String, dynamic>?) ?? {};

      final files = filesJson.values
          .map((e) => FileMeta.fromJson(e as Map<String, dynamic>))
          .toList();

      final totalBytes = files.fold<int>(0, (sum, f) => sum + f.size);

      // 取发送方真实 IP。
      //
      // shelf 把连接信息挂在 request.context 下，但它只在通过
      // shelf_io.serve 起的服务里存在，单元测试时可能拿不到，
      // 所以整段用 try 包住，失败就退回 x-forwarded-for 或 unknown。
      var senderIp = 'unknown';
      try {
        final connInfo = request.context['shelf.io.connection_info'];
        if (connInfo != null) {
          final addr = connInfo.toString();
          // 形如 InternetAddress('192.168.1.5', IPv4)
          final match =
              RegExp(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})').firstMatch(addr);
          if (match != null) senderIp = match.group(1)!;
        }
      } catch (_) {
        senderIp = request.headers['x-forwarded-for'] ?? 'unknown';
      }

      final sender = senderInfo != null
          ? Device.fromJson(senderInfo, ip: senderIp)
          : Device(
              fingerprint: 'unknown',
              alias: '未知设备',
              deviceType: DeviceType.unknown,
              deviceModel: '',
              ip: senderIp,
              port: Protocol.defaultPort,
            );

      final session = ReceiveSession(
        sessionId: sessionId,
        sender: sender,
        files: files,
        totalBytes: totalBytes,
      );

      if (senderInfo != null && senderIp != 'unknown') onPeerSeen?.call(sender);

      _sessions[sessionId] = session;
      _approvedUploads[sessionId] = files.map((f) => f.id).toSet();

      onSessionStarted?.call(session);

      // 返回许可：{ fileId: token }
      final tokens = {
        for (final f in files) f.id: f.id,
      };

      return Response.ok(
        jsonEncode({'sessionId': sessionId, 'files': tokens}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': '$e'}),
      );
    }
  }

  /// POST /upload — 接收单个文件（流式落盘，不在内存里缓存整个文件）
  Future<Response> _handleUpload(Request request) async {
    try {
      final sessionId = request.url.queryParameters['sessionId'] ?? '';
      final fileId = request.url.queryParameters['fileId'] ?? '';

      final approved = _approvedUploads[sessionId];
      if (approved == null || !approved.contains(fileId)) {
        return Response.forbidden(
          jsonEncode({'error': '未授权或会话已过期'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final session = _sessions[sessionId];
      if (session == null) {
        return Response.notFound(
          jsonEncode({'error': '会话不存在'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // 在已登记的清单里找文件元信息
      FileMeta? meta;
      for (final f in session.files) {
        if (f.id == fileId) {
          meta = f;
          break;
        }
      }
      if (meta == null) {
        return Response.notFound(
          jsonEncode({'error': '文件不在清单中'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // 安全处理：清洗文件名，防止 ../ 路径穿越
      final safeName = _sanitizeFileName(meta.fileName);
      final targetPath = _uniquePath(downloadDir, safeName);
      final file = File(targetPath);

      await file.parent.create(recursive: true);
      final sink = file.openWrite();

      var written = 0;

      try {
        await for (final chunk in request.read()) {
          sink.add(chunk);
          written += chunk.length;
          session.receivedBytes += chunk.length;
          onProgress?.call(session);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // 校验完整性：声明了大小却没收全（对端中断）→ 当失败处理，不留半截文件
      if (meta.size > 0 && written < meta.size) {
        try {
          await file.delete();
        } catch (_) {}
        throw StateError('文件不完整：${meta.fileName}（$written/${meta.size} 字节）');
      }

      var savedPath = targetPath;
      String? savedUri;
      final publish = publishFile;
      if (publish != null) {
        final pub = await publish(targetPath, safeName, meta.mimeType);
        if (pub == null) {
          throw StateError('保存到公共目录失败：${meta.fileName}');
        }
        savedPath = pub.path;
        savedUri = pub.uri;
        if (pub.path != targetPath) {
          try {
            await file.delete();
          } catch (_) {}
        }
      }

      final received = FileMeta(
        id: meta.id,
        fileName: meta.fileName,
        size: written,
        mimeType: meta.mimeType,
        savedPath: savedPath,
        savedUri: savedUri,
      );
      // 把清单里的条目替换成「已保存」版本 —— 否则 UI 一直显示「(待接收)」
      final idx = session.files.indexWhere((f) => f.id == meta!.id);
      if (idx >= 0) session.files[idx] = received;
      session.completedFiles += 1;
      onFileReceived?.call(session, received);

      if (session.completedFiles >= session.files.length) {
        session.isCompleted = true;
        onSessionEnded?.call(session);
      }

      return Response.ok(jsonEncode({'status': 'ok', 'path': savedPath}));
    } catch (e) {
      onError?.call('接收文件失败: $e');
      return Response.internalServerError(body: jsonEncode({'error': '$e'}));
    }
  }

  /// POST /cancel
  Future<Response> _handleCancel(Request request) async {
    final body = await request.readAsString();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final sessionId = json['sessionId'] as String?;
    if (sessionId != null) {
      final s = _sessions[sessionId];
      if (s != null) {
        s.isCancelled = true;
        onSessionEnded?.call(s);
      }
    }
    return Response.ok(jsonEncode({'status': 'ok'}));
  }

  /// GET / — 给浏览器看的极简上传页
  ///
  /// 用 raw 字符串（r'''）是必须的：页面里的 JS 模板字面量含 `${...}`，
  /// 普通字符串会把它们当成 Dart 插值解析，编译期直接报错。
  Future<Response> _handleWebRoot(Request request) async {
    const html = r'''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GUODROP</title>
<style>
  body{font-family:system-ui,-apple-system,sans-serif;max-width:560px;
       margin:0 auto;padding:32px 20px;background:#fafafa;color:#222}
  h1{font-size:20px;font-weight:600;margin:0 0 8px}
  p{color:#666;font-size:14px;line-height:1.6}
  .drop{border:2px dashed #bbb;border-radius:12px;padding:48px 20px;
        text-align:center;margin:24px 0;background:#fff;cursor:pointer}
  .drop.active{border-color:#378ADD;background:#f0f7ff}
  button{background:#378ADD;color:#fff;border:0;border-radius:8px;
         padding:12px 28px;font-size:15px;cursor:pointer;width:100%}
  button:disabled{background:#ccc;cursor:not-allowed}
  .list{font-size:13px;color:#555;margin:12px 0}
  .item{padding:6px 0;border-bottom:1px solid #eee}
</style>
</head>
<body>
<h1>GUODROP</h1>
<p>选择或拖入文件，直接传到这台设备。无需安装任何软件。</p>
<div class="drop" id="drop">点击选择文件，或把文件拖到这里</div>
<input type="file" id="picker" multiple hidden>
<div class="list" id="list"></div>
<button id="send" disabled>开始传输</button>
<script>
const drop=document.getElementById('drop'),picker=document.getElementById('picker'),
      list=document.getElementById('list'),send=document.getElementById('send');
let files=[];
drop.onclick=()=>picker.click();
drop.ondragover=e=>{e.preventDefault();drop.classList.add('active')};
drop.ondragleave=()=>drop.classList.remove('active');
drop.ondrop=e=>{e.preventDefault();drop.classList.remove('active');add(e.dataTransfer.files)};
picker.onchange=e=>add(e.target.files);
function add(fs){files=files.concat(Array.from(fs));render()}
function render(){
  list.innerHTML=files.map(f=>`<div class="item">${f.name} — ${(f.size/1024/1024).toFixed(2)} MB</div>`).join('');
  send.disabled=files.length===0;
}
send.onclick=async()=>{
  send.disabled=true;send.textContent='正在传输...';
  const sid=crypto.randomUUID();
  const map={};files.forEach((f,i)=>map['f'+i]={id:'f'+i,fileName:f.name,size:f.size});
  const prep=await fetch('/api/localsend/v2/prepare-upload',{method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({sessionId:sid,info:{alias:'浏览器',deviceType:'web',fingerprint:'web-'+sid},files:map})});
  const tokens=(await prep.json()).files;
  for(let i=0;i<files.length;i++){
    const id='f'+i;
    await fetch(`/api/localsend/v2/upload?sessionId=${sid}&fileId=${id}&token=${tokens[id]}`,
      {method:'POST',body:files[i]});
  }
  send.textContent='传输完成 ✓';files=[];list.innerHTML='';
};
</script>
</body>
</html>''';

    return Response.ok(html, headers: {'Content-Type': 'text/html; charset=utf-8'});
  }

  // ==================== 客户端 ====================

  /// 快速探活：对端还在不在？
  ///
  /// 用于发送前的预检，以及发现层的超时复核。
  /// 超时设得很短（2 秒）—— 这个调用在 UI 的交互路径上，不能让人等。
  ///
  /// 返回 true 表示对端 HTTP 服务正常响应。
  Future<bool> isAlive(Device device) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);

    try {
      final uri = Uri.parse(
        '${device.protocol.value}://${device.ip}:${device.port}'
        '${Protocol.infoPath}',
      );
      final request = await client.getUrl(uri);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 告诉所有对端「我要下线了」，请把我从列表里删掉
  ///
  /// 并发通知，单个失败不影响其他。整体加一个总超时，
  /// 避免 App 退出时被某个不响应的对端拖住。
  ///
  /// 返回成功通知到的设备数。
  Future<int> sendGoodbye(List<Device> peers) async {
    if (peers.isEmpty) return 0;

    final payload = jsonEncode(selfDevice.toJson());

    /// 通知单个对端，返回是否成功
    Future<bool> notifyOne(Device d) async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);

      try {
        final uri = Uri.parse(
          '${d.protocol.value}://${d.ip}:${d.port}${Protocol.byePath}',
        );
        final request = await client.postUrl(uri);
        request.headers.contentType = ContentType.json;
        request.write(payload);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode == 200;
      } catch (_) {
        // 对端可能已经先关了，或者不认识这个接口。忽略。
        return false;
      } finally {
        client.close(force: true);
      }
    }

    try {
      // 整体 3 秒上限：退出路径上绝不能久等
      final results = await Future.wait(peers.map(notifyOne)).timeout(
        const Duration(seconds: 3),
      );
      return results.where((ok) => ok).length;
    } on TimeoutException {
      return 0;
    }
  }

  /// 向目标设备发送一组文件
  ///
  /// 返回是否全部成功。
  Future<bool> sendFiles({
    required Device target,
    required List<FileMeta> files,
    void Function(int sentBytes, int totalBytes)? onSendProgress,
  }) async {
    final sessionId = const Uuid().v4();
    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.size);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

    try {
      // 第一步：提交清单，取得上传许可
      final fileMap = <String, dynamic>{};
      for (final f in files) {
        fileMap[f.id] = f.toJson();
      }

      final prepUri =
          Uri.parse('${target.protocol.value}://${target.ip}:${target.port}'
              '${Protocol.prepareUploadPath}');

      final prepReq = await client.postUrl(prepUri);
      prepReq.headers.contentType = ContentType.json;
      prepReq.write(jsonEncode({
        'sessionId': sessionId,
        'info': selfDevice.toJson(),
        'files': fileMap,
      }));

      final prepResp = await prepReq.close();
      if (prepResp.statusCode != 200) {
        final body = await prepResp.transform(utf8.decoder).join();
        onError?.call('对方拒绝接收: ${prepResp.statusCode} $body');
        return false;
      }

      final prepBody = await prepResp.transform(utf8.decoder).join();
      final prepJson = jsonDecode(prepBody) as Map<String, dynamic>;
      final tokens = (prepJson['files'] as Map<String, dynamic>?) ?? {};

      // 第二步：逐个文件上传
      var sentBytes = 0;

      for (final meta in files) {
        if (meta.localPath == null) continue;

        final file = File(meta.localPath!);
        if (!await file.exists()) {
          onError?.call('文件不存在: ${meta.localPath}');
          return false;
        }

        final token = tokens[meta.id] ?? meta.id;
        final uploadUri = Uri.parse(
            '${target.protocol.value}://${target.ip}:${target.port}'
            '${Protocol.uploadPath}?sessionId=$sessionId'
            '&fileId=${meta.id}&token=$token');

        final req = await client.postUrl(uploadUri);
        req.headers.contentType = ContentType.binary;
        req.headers.set(HttpHeaders.contentLengthHeader, '${meta.size}');

        // 流式读取并上传，避免大文件撑爆内存
        await for (final chunk in file.openRead()) {
          req.add(chunk);
          sentBytes += chunk.length;
          onSendProgress?.call(sentBytes, totalBytes);
        }

        final resp = await req.close();
        if (resp.statusCode != 200) {
          final body = await resp.transform(utf8.decoder).join();
          onError?.call('上传 ${meta.fileName} 失败: ${resp.statusCode} $body');
          return false;
        }
        await resp.drain();
      }

      return true;
    } catch (e) {
      onError?.call('传输失败: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ==================== 工具 ====================

  static String? _remoteIp(Request request) {
    try {
      final connInfo = request.context['shelf.io.connection_info'];
      if (connInfo is HttpConnectionInfo) return connInfo.remoteAddress.address;
    } catch (_) {}
    return null;
  }

  /// 清洗文件名，防止路径穿越攻击
  static String _sanitizeFileName(String name) {
    var cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    cleaned = cleaned.replaceAll('..', '_');
    if (cleaned.isEmpty) cleaned = 'unnamed';
    if (cleaned.length > 200) {
      final ext = cleaned.contains('.')
          ? '.${cleaned.split('.').last}'
          : '';
      cleaned = cleaned.substring(0, 200 - ext.length) + ext;
    }
    return cleaned;
  }

  /// 同名文件自动加序号，不覆盖已有文件
  static String _uniquePath(String dir, String fileName) {
    final base = File('$dir${Platform.pathSeparator}$fileName');
    if (!base.existsSync()) return base.path;

    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';

    var i = 1;
    while (true) {
      final candidate =
          File('$dir${Platform.pathSeparator}$stem ($i)$ext');
      if (!candidate.existsSync()) return candidate.path;
      i++;
    }
  }
}
