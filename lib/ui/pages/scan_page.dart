import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/scan/scan_service.dart';
import '../app_state.dart';

/// 扫码页 — 两个 Tab：扫描对方二维码 / 展示自己的二维码
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  MobileScannerController? _cameraController;
  bool _handling = false;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index == 0) {
        _startCamera();
      } else {
        _stopCamera();
      }
    });
    _startCamera();
  }

  void _startCamera() {
    if (_cameraController != null) return;
    _cameraController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
    );
    setState(() {});
  }

  void _stopCamera() {
    _cameraController?.dispose();
    _cameraController = null;
    setState(() {});
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫码连接'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '扫描'),
            Tab(text: '我的二维码'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildScanner(),
          _buildMyQr(),
        ],
      ),
    );
  }

  // ---- Tab 1: 扫描 ----

  Widget _buildScanner() {
    final controller = _cameraController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        MobileScanner(
          controller: controller,
          onDetect: _onDetect,
        ),

        // 取景框
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.85),
                width: 2.5,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),

        // 提示文字
        Positioned(
          left: 0,
          right: 0,
          bottom: 40,
          child: Column(
            children: [
              Text(
                _lastError ?? '把对方屏幕上的二维码放进框内',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _showManualInput,
                icon: const Icon(Icons.keyboard, size: 18, color: Colors.white),
                label: const Text(
                  '手动输入 IP',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 扫到二维码后的处理
  Future<void> _onDetect(BarcodeCapture capture) async {
    // 防抖：扫描回调触发非常频繁，必须挡掉重复处理
    if (_handling) return;

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final raw = barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;

    _handling = true;
    _lastError = null;

    final state = context.read<AppState>();
    final device = await state.addDeviceFromScan(raw);

    if (!mounted) {
      _handling = false;
      return;
    }

    if (device == null) {
      _lastError = '无法识别这个二维码';
      setState(() {});
      // 2 秒后允许重试
      await Future.delayed(const Duration(seconds: 2));
      _handling = false;
      if (mounted) setState(() {});
      return;
    }

    // 成功 — 返回首页，设备已加入列表
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已连接 ${device.alias}'),
        backgroundColor: const Color(0xFF3B9E6E),
      ),
    );
  }

  /// 手动输入 IP 兜底
  void _showManualInput() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动输入'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(
            labelText: 'IP 地址',
            hintText: '192.168.1.5:53317',
            helperText: '端口可省略，默认 53317',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final input = controller.text.trim();
              Navigator.pop(ctx);

              // 解析出 IP 和端口
              final parts = input.split(':');
              final ip = parts[0];
              final port =
                  parts.length > 1 ? int.tryParse(parts[1]) : null;

              final state = context.read<AppState>();
              final device = await state.addDeviceByIp(ip, port: port);

              if (!mounted) return;
              if (device != null) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('已连接 ${device.alias}'),
                    backgroundColor: const Color(0xFF3B9E6E),
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('连接失败，请检查 IP 和网络'),
                    backgroundColor: Color(0xFFD0504E),
                  ),
                );
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }

  // ---- Tab 2: 展示我的二维码 ----

  Widget _buildMyQr() {
    final state = context.watch<AppState>();
    final qr = state.qrSession;
    final theme = Theme.of(context);

    if (qr == null || state.localIp == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '未检测到局域网地址。\n请确认设备已连接到 WiFi。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Text(
            '让对方扫描这个二维码',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '扫到后会自动连上，无需输入 IP',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),

          // 二维码本体
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              // 二维码必须是白底黑码，深色模式下也不例外，
              // 否则大部分扫码库都识别不出来
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: QrImageView(
              data: qr.payload,
              version: QrVersions.auto,
              size: 220,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          ),

          const SizedBox(height: 20),

          // 地址与 token 状态
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                SelectableText(
                  '${state.localIp}:${qr.port}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  qr.isExpired
                      ? '二维码已过期，请刷新'
                      : '${QrSession.validMinutes} 分钟内有效',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: qr.isExpired
                        ? const Color(0xFFD0504E)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          OutlinedButton.icon(
            onPressed: state.refreshQrToken,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('刷新二维码'),
          ),

          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 14),

          // 浏览器兜底入口
          Text(
            '对方没装应用？',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            'http://${state.localIp}:53317',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '在浏览器打开这个地址即可上传文件',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
