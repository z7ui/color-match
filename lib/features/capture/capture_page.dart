import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// 拍照页：全屏预览 + 构图指示（中间一个 A4 比例的框）。
///
/// 构图指示不是装饰：它让用户把白纸/灰卡放在固定位置，之后标定框选更稳。
class CapturePage extends StatefulWidget {
  const CapturePage({super.key, required this.role, required this.sessionId});

  final String role;
  final String sessionId;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  CameraController? _controller;
  List<CameraDescription> _cameras = <CameraDescription>[];
  int _index = 0;
  bool _ready = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _error = '没有可用摄像头');
        return;
      }
      await _open(0);
    } catch (error) {
      setState(() => _error = '相机启动失败：$error');
    }
  }

  Future<void> _open(int index) async {
    await _controller?.dispose();
    final CameraController controller = CameraController(
      _cameras[index],
      ResolutionPreset.high,
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
    });
  }

  Future<void> _shoot() async {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      final XFile file = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '拍照失败：$error';
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isReference = widget.role == 'reference';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(isReference ? '拍参照（家里）' : '拍目标（厂里）'),
        actions: <Widget>[
          if (_cameras.length > 1)
            IconButton(
              onPressed: () => _open((_index + 1) % _cameras.length),
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
          : _ready && _controller != null
              ? Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    CameraPreview(_controller!),
                    const _GuideOverlay(),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 32,
                      child: Column(
                        children: <Widget>[
                          const Text(
                            '主体放中间 · 白纸放左下角（别挡主体）',
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
                                      child: CircularProgressIndicator(strokeWidth: 2),
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

        // 主体框：水平居中偏上，占宽 72%、高 46%
        final Rect subject = Rect.fromCenter(
          center: Offset(w / 2, h * 0.40),
          width: w * 0.72,
          height: h * 0.46,
        );

        // 白纸框：左下角，占宽 24%
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
                child: Text('白纸',
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
