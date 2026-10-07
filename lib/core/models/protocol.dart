/// 协议常量 — 与 LocalSend v2 协议保持兼容
///
/// 采用 LocalSend 的协议格式意味着：你的 App 可以和 LocalSend、
/// 以及任何实现了该协议的工具互通。这是免费获得的生态能力。
class Protocol {
  /// UDP 组播地址（本地网络控制块范围，不会被路由到公网）
  static const String multicastGroup = '224.0.0.167';

  /// 默认端口：UDP 发现和 HTTP 传输共用
  static const int defaultPort = 53317;

  /// 协议版本
  static const String version = '2.0';

  // ---- HTTP 接口路径 ----
  static const String registerPath = '/api/localsend/v2/register';
  static const String infoPath = '/api/localsend/v2/info';
  static const String uploadPath = '/api/localsend/v2/upload';
  static const String prepareUploadPath = '/api/localsend/v2/prepare-upload';
  static const String cancelPath = '/api/localsend/v2/cancel';

  /// 主动下线通知。
  ///
  /// 这是一个**本协议扩展**（LocalSend 没有），所以对端如果不认识它，
  /// 会返回 404 —— 那次调用就当没发生过，不影响互通性。
  ///
  /// 存在的理由：靠超时淘汰设备要等 30 秒，这期间对方还能往一台
  /// 已经关掉的机器发文件，白等一场。主动打个招呼能把这个窗口压到 0。
  static const String byePath = '/api/localsend/v2/bye';

  /// 广播间隔（毫秒）— 太频繁费电，太稀疏发现慢
  ///
  /// 2 秒是为了「打开 App 后尽快看到对方」和「丢包容错」之间取平衡。
  /// 之前是 3 秒，配合 15 秒超时，安卓端丢几个包就刚好卡在临界线上。
  static const int announceIntervalMs = 2000;

  /// 设备离线判定阈值（毫秒）— 超过这个时间没收到广播就移除
  ///
  /// 30 秒 = 广播间隔的 15 倍。容忍连续丢 14 个包。
  /// 阈值放宽的代价只是「对方真的关了 App，列表里多留 30 秒」，
  /// 远比「明明还在线却搜不到」可接受。而且超时后还有 HTTP 兜底确认
  /// （见 DiscoveryService._confirmLost）。
  static const int deviceTimeoutMs = 30000;

  /// 文件分块大小 — 1MB 是吞吐与内存占用的平衡点
  ///
  /// 注意：当前实现用 File.openRead() 的默认分块（64KB）流式传输，
  /// 这个常量预留给后续做「自定义分块 + 断点续传」时使用。
  static const int chunkSize = 1024 * 1024;
}

/// 设备类型
enum DeviceType {
  mobile('mobile', '手机'),
  desktop('desktop', '电脑'),
  web('web', '浏览器'),
  headless('headless', '服务器'),
  unknown('unknown', '未知设备');

  final String value;
  final String label;
  const DeviceType(this.value, this.label);

  static DeviceType fromString(String? s) {
    return DeviceType.values.firstWhere(
      (e) => e.value == s,
      orElse: () => DeviceType.unknown,
    );
  }
}

/// 传输协议类型
enum TransferProtocol {
  http('http'),
  https('https');

  final String value;
  const TransferProtocol(this.value);

  static TransferProtocol fromString(String? s) =>
      s == 'https' ? TransferProtocol.https : TransferProtocol.http;
}
