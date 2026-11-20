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
                            '把白纸 / 灰卡放进中间的框，整张纸入画',
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

/// 构图指示：四周压暗，中间留一个 A4 竖版比例的框。
class _GuideOverlay extends StatelessWidget {
  const _GuideOverlay();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth * 0.78;
        final double h = w * 297 / 210;
        return Stack(
          children: <Widget>[
            CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: _MaskPainter(
                hole: Rect.fromCenter(
                  center: Offset(constraints.maxWidth / 2, constraints.maxHeight * 0.42),
                  width: w,
                  height: h,
                ),
              ),
            ),
            Positioned(
              left: (constraints.maxWidth - w) / 2,
              top: constraints.maxHeight * 0.42 - h / 2,
              width: w,
              height: h,
              child: IgnorePointer(
                child: CustomPaint(painter: _CornerPainter()),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter({required this.hole});

  final Rect hole;

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(hole)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.45));
  }

  @override
  bool shouldRepaint(_MaskPainter old) => old.hole != hole;
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
