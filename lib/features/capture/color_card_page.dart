import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../core/app_theme.dart';
import '../../core/ccm.dart';
import '../../core/image_pipeline.dart';

/// 24 色卡校正：拍一张 ColorChecker，点四个角，算出这台手机的 3×3 色彩矩阵。
///
/// 为什么值得做：手机在强色偏光源下（射灯、暖光）每个通道的响应不是线性的，
/// 单靠白点只能对齐「白」，对齐不了「红有多红」。CCM 能把这块误差压掉一半左右。
class ColorCardPage extends StatefulWidget {
  const ColorCardPage({super.key});

  @override
  State<ColorCardPage> createState() => _ColorCardPageState();
}

class _ColorCardPageState extends State<ColorCardPage> {
  img.Image? _image;
  Uint8List? _previewBytes;
  String? _error;
  bool _busy = false;
  bool _showGrid = false;
  CameraCcm? _result;
  CameraCcm? _saved;

  /// 四个角（左上、右上、右下、左下），归一化 0..1。
  final List<Offset> _corners = <Offset>[
    const Offset(0.12, 0.22),
    const Offset(0.88, 0.22),
    const Offset(0.88, 0.78),
    const Offset(0.12, 0.78),
  ];

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final CameraCcm? ccm = await CameraProfile.load();
    if (!mounted) return;
    setState(() => _saved = ccm);
  }

  Future<void> _pick() async {
    final XFile? picked =
        await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2400);
    if (picked == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final File file = File(picked.path);
      final Uint8List bytes = await file.readAsBytes();
      final Uint8List preview = await decodePreviewBytes(bytes);
      final img.Image? decoded = img.decodeImage(preview);
      if (decoded == null) throw const FormatException('图片解析失败');
      if (!mounted) return;
      setState(() {
        _image = decoded;
        _previewBytes = preview;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '读取失败：' + error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _solve() async {
    final img.Image? image = _image;
    if (image == null) return;
    setState(() => _busy = true);
    try {
      final CameraCcm ccm = calibrateColorCard(image, <Offset2>[
        for (final Offset c in _corners)
          Offset2(c.dx * image.width, c.dy * image.height),
      ]);
      if (!mounted) return;
      setState(() {
        _result = ccm;
        _showGrid = true;
      });
    } catch (error) {
      if (!mounted) return;
      showSnack(context, '拟合失败：' + error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final CameraCcm? ccm = _result;
    if (ccm == null) return;
    await CameraProfile.save(ccm);
    await _loadSaved();
    if (!mounted) return;
    showSnack(context, '已保存，之后的对比会先做相机校色');
  }

  Future<void> _clear() async {
    await CameraProfile.save(null);
    await _loadSaved();
    if (!mounted) return;
    showSnack(context, '已关闭相机校色');
  }

  @override
  Widget build(BuildContext context) {
    final bool hasImage = _image != null;
    return Scaffold(
      appBar: buildAppBar('相机色彩校正'),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: <Widget>[
          _intro(),
          if (_saved != null) _savedCard(_saved!),
          const SizedBox(height: AppSpacing.md),
          if (!hasImage)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('选一张 24 色卡照片'),
              ),
            )
          else ...<Widget>[
            _canvas(),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pick,
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: const Text('换一张'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _solve,
                    icon: const Icon(Icons.calculate_outlined, size: 18),
                    label: const Text('计算校正'),
                  ),
                ),
              ],
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text(_error!,
                  style: const TextStyle(color: AppColors.danger)),
            ),
          if (_result != null) ...<Widget>[
            const SizedBox(height: AppSpacing.md),
            _resultCard(_result!),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存为这台手机的校正'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _intro() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('这是什么',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          SizedBox(height: 6),
          Text(
            '白纸只能对齐「白」，对不齐「红有多红」。24 色卡能算出这台手机的色彩矩阵，'
            '把强色偏光源下的偏色压掉一半左右。\n\n'
            '拍法：色卡放平、正对、占满画面、光照均匀（别让射灯直射出反光），'
            '四个角要能看见。拍完点四个内角。\n\n'
            '开启后：ΔE 是两张都做过相机校色后算的；对比图右侧经过校色，左侧仍是家里原图。',
            style: TextStyle(
                fontSize: 12, height: 1.6, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _savedCard(CameraCcm ccm) {
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.line(context)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.check_circle_outline,
              size: 18,
              color: ccm.isUsable ? AppColors.success : AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前已启用相机校色（拟合残差 ΔE '
              '${ccm.meanDelta.toStringAsFixed(2)} / 最差 ${ccm.maxDelta.toStringAsFixed(2)}）',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _clear,
            child: const Text('关闭', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _canvas() {
    final img.Image image = _image!;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double height = width * image.height / image.width;
        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: <Widget>[
              if (_previewBytes != null)
                Positioned.fill(
                  child: Image.memory(_previewBytes!, fit: BoxFit.fill),
                ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _CornerPainter(
                    corners: <Offset>[
                      for (final Offset c in _corners)
                        Offset(c.dx * width, c.dy * height),
                    ],
                    showGrid: _showGrid,
                  ),
                ),
              ),
              for (int i = 0; i < 4; i++)
                Positioned(
                  left: _corners[i].dx * width - 22,
                  top: _corners[i].dy * height - 22,
                  child: GestureDetector(
                    onPanUpdate: (DragUpdateDetails d) {
                      setState(() {
                        _corners[i] = Offset(
                          (_corners[i].dx + d.delta.dx / width).clamp(0.0, 1.0),
                          (_corners[i].dy + d.delta.dy / height).clamp(0.0, 1.0),
                        );
                        _showGrid = false;
                      });
                    },
                    child: Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.primary, width: 2),
                      ),
                      child: Text('${i + 1}',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _resultCard(CameraCcm ccm) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
            color: ccm.isUsable ? AppColors.success : AppColors.warning),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(ccm.isUsable ? Icons.check_circle : Icons.warning_amber_rounded,
                  size: 18,
                  color: ccm.isUsable ? AppColors.success : AppColors.warning),
              const SizedBox(width: 6),
              Text(ccm.isUsable ? '拟合结果可用' : '拟合残差偏大，建议重拍',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Text('24 块平均残差 ΔE ' + ccm.meanDelta.toStringAsFixed(2),
              style: const TextStyle(fontSize: 12)),
          Text('最差一块 ΔE ' + ccm.maxDelta.toStringAsFixed(2),
              style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Text(
            '残差 <4 说明色卡拍得比较正；>8 通常是反光、阴影、色卡没摆正，重拍一次更稳。',
            style: TextStyle(
                fontSize: 11, height: 1.5, color: AppColors.sub(context)),
          ),
        ],
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  _CornerPainter({required this.corners, required this.showGrid});

  final List<Offset> corners;
  final bool showGrid;

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = Path()
      ..addPolygon(corners, true)
      ..fillType = PathFillType.evenOdd;
    final Path outer = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final Path mask = Path.combine(PathOperation.difference, outer, path);
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.35));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = AppColors.primary,
    );
    if (!showGrid) return;

    final Homography h = Homography.fromQuad(<Offset2>[
      for (final Offset c in corners) Offset2(c.dx, c.dy),
    ]);
    final Paint grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.75);
    for (int row = 0; row < ColorChecker.rows; row++) {
      for (int col = 0; col < ColorChecker.columns; col++) {
        final double u1 = col / ColorChecker.columns;
        final double v1 = row / ColorChecker.rows;
        final double u2 = (col + 1) / ColorChecker.columns;
        final double v2 = (row + 1) / ColorChecker.rows;
        final Offset2 a = h.map(u1, v1);
        final Offset2 b = h.map(u2, v1);
        final Offset2 c = h.map(u2, v2);
        final Offset2 d = h.map(u1, v2);
        canvas.drawPath(
          Path()
            ..moveTo(a.x, a.y)
            ..lineTo(b.x, b.y)
            ..lineTo(c.x, c.y)
            ..lineTo(d.x, d.y)
            ..close(),
          grid,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CornerPainter old) =>
      old.corners != corners || old.showGrid != showGrid;
}
