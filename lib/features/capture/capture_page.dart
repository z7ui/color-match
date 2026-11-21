import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// 拍照结果：文件路径 + 当时有没有开补光（手电筒常亮）。
///
/// 为什么要记：补光会改变光源光谱和照度，之后看数据必须知道这张是不是补光拍的。
class CaptureOutcome {
  const CaptureOutcome({required this.path, required this.usedTorch});

  final String path;
  final bool usedTorch;
}

/// 拍照页：全屏预览 + 构图指示（中间一个主体框，左下角白纸框）。
///
/// 两个稳定性要点：
/// * **跟随生命周期**：切后台/来电/权限弹窗时释放相机，回来重建；不处理的话
///   回来就是黑屏（Android 上相机会被别的 App 抢走）。
/// * **切换摄像头要先把旧 controller 置空**：否则 build 期间可能用到已 dispose
///   的实例，抛「CameraController was used after being disposed」。
class CapturePage extends StatefulWidget {
  const CapturePage({super.key, required this.role, required this.sessionId});

  final String role;
  final String sessionId;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = <CameraDescription>[];
  int _index = 0;
  bool _ready = false;
  bool _busy = false;
  bool _switching = false;
  bool _torch = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _releaseCamera();
    } else if (state == AppLifecycleState.resumed && !_ready && _error == null) {
      _init();
    }
  }

  Future<void> _releaseCamera() async {
    final CameraController? controller = _controller;
    // 先断开引用，再 dispose：这样即使有 rebuild 也不会碰到已释放的实例
    setState(() {
      _controller = null;
      _ready = false;
    });
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  Future<void> _init() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _error = '没有可用摄像头');
        return;
      }
      await _open(0);
    } catch (error) {
      if (mounted) setState(() => _error = '相机启动失败：' + error.toString());
    }
  }

  Future<void> _open(int index) async {
    if (_switching) return;
    _switching = true;
    try {
      await _releaseCamera();
      final CameraController controller = CameraController(
        _cameras[index],
        // 选色要给足分辨率：high 只有 720p，白点采样精度会打折
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _index = index;
        _ready = true;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '相机启动失败：' + error.toString());
    } finally {
      _switching = false;
    }
  }

  /// 补光开关：torch = 常亮（像手电筒），比「按下快门闪一下」安全得多。
  Future<void> _toggleTorch() async {
    final CameraController? controller = _controller;
    if (controller == null) return;
    final bool next = !_torch;
    try {
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (!mounted) return;
      setState(() => _torch = next);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '补光打不开：' + error.toString());
    }
  }

  Future<void> _shoot() async {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      final XFile file = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context)
          .pop(CaptureOutcome(path: file.path, usedTorch: _torch));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '拍照失败：' + error.toString();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final CameraController? controller = _controller;
    _controller = null;
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isReference = widget.role == 'reference';
    final CameraController? controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(isReference ? '拍参照（家里）' : '拍目标（厂里）'),
        actions: <Widget>[
          IconButton(
            onPressed: _busy ? null : _toggleTorch,
            icon: Icon(
              _torch ? Icons.flashlight_on : Icons.flashlight_off,
              color: _torch ? Colors.amber : Colors.white,
            ),
            tooltip: _torch ? '补光：开' : '补光：关',
          ),
          if (_cameras.length > 1)
            IconButton(
              onPressed: _switching ? null : () => _open((_index + 1) % _cameras.length),
              icon: const Icon(Icons.flip_camera_ios),
              tooltip: '切换摄像头',
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.white, height: 1.6)),
              ),
            )
          : (_ready && controller != null)
              ? Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    CameraPreview(controller),
                    const _GuideOverlay(),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 32,
                      child: Column(
                        children: <Widget>[
                          const Text(
                            '主体放中间 · 白纸露一个角就行（不用整张入画）',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: _shoot,
                            child: Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.4),
                                    width: 6),
                              ),
                              child: _busy
                                  ? const Padding(
                                      padding: EdgeInsets.all(22),
                                      child:
                                          CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.camera_alt,
                                      color: Colors.black, size: 32),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : const Center(
                  child: CircularProgressIndicator(color: Colors.white)),
    );
  }
}

/// 构图指示：中间是「主体」（要对比的瓷砖/门窗/小样），左下角是「白纸」（光的参照）。
class _GuideOverlay extends StatelessWidget {
  const _GuideOverlay();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;

        final Rect subject = Rect.fromCenter(
          center: Offset(w / 2, h * 0.40),
          width: w * 0.72,
          height: h * 0.46,
        );

        final double paperW = w * 0.24;
        final Rect paper = Rect.fromLTWH(
          w * 0.06,
          h * 0.62,
          paperW,
          paperW * 1.15,
        );

        return Stack(
          children: <Widget>[
            CustomPaint(
              size: Size(w, h),
              painter: _MaskPainter(hole: subject, secondary: paper),
            ),
            Positioned.fromRect(
              rect: subject,
              child: IgnorePointer(
                child: CustomPaint(painter: _CornerPainter()),
              ),
            ),
            Positioned.fromRect(
              rect: paper,
              child: IgnorePointer(
                child: CustomPaint(painter: _DashedBoxPainter()),
              ),
            ),
            Positioned(
              left: subject.left,
              top: subject.top - 22,
              width: subject.width,
              child: const Center(
                child: Text('主体（要对比的东西）',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Positioned(
              left: paper.left,
              top: paper.top - 20,
              width: paper.width,
              child: const Center(
                child: Text('白纸露一角',
                    style: TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter({required this.hole, this.secondary});

  final Rect hole;
  final Rect? secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(hole);
    final Rect? second = secondary;
    if (second != null) path.addRect(second);
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.45));
  }

  @override
  bool shouldRepaint(_MaskPainter old) =>
      old.hole != hole || old.secondary != secondary;
}

/// 白纸位置的虚线框。
class _DashedBoxPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final Rect rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    const double dash = 7;
    const double gap = 5;

    void dashed(Offset from, Offset to) {
      final double total = (to - from).distance;
      if (total <= 0) return;
      final Offset dir = (to - from) / total;
      double t = 0;
      while (t < total) {
        final double end = (t + dash).clamp(0, total);
        canvas.drawLine(from + dir * t, from + dir * end, paint);
        t = end + gap;
      }
    }

    dashed(rect.topLeft, rect.topRight);
    dashed(rect.topRight, rect.bottomRight);
    dashed(rect.bottomRight, rect.bottomLeft);
    dashed(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(_DashedBoxPainter old) => false;
}

class _CornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    const double arm = 28;
    final double w = size.width;
    final double h = size.height;
    canvas.drawLine(Offset.zero, const Offset(arm, 0), paint);
    canvas.drawLine(Offset.zero, const Offset(0, arm), paint);
    canvas.drawLine(Offset(w, 0), Offset(w - arm, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, arm), paint);
    canvas.drawLine(Offset(0, h), Offset(arm, h), paint);
    canvas.drawLine(Offset(0, h), Offset(0, h - arm), paint);
    canvas.drawLine(Offset(w, h), Offset(w - arm, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w, h - arm), paint);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => false;
}
