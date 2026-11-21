import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 导出报告图：**带中文**的三栏对比（家里 | 工地原图 | 拉到家里后）。
///
/// 为什么不用 image 包的 drawString：它内置的 arial24 只有 ASCII，
/// 中文会画成方块。这里改用 Flutter 的 Canvas + TextPainter（在主 isolate，
/// 走系统字体回退），中文、数字、标点都正常。
class ReportRow {
  const ReportRow({
    required this.label,
    required this.referencePath,
    required this.beforePath,
    required this.afterPath,
    required this.deltaE,
    required this.deltaEBefore,
    this.errorFloor = 0,
    this.trustworthy = 0,
    this.location = '',
    required this.createdAt,
  });

  final String label;
  final String referencePath;
  final String beforePath;
  final String afterPath;
  final double deltaE;
  final double deltaEBefore;
  final double errorFloor;
  final double trustworthy;
  final String location;
  final DateTime createdAt;
}

const double _margin = 28;
const double _gap = 14;
const double _imageSide = 360;
const double _rowMeta = 108;

Future<ui.Image?> _loadImage(String path, int targetWidth) async {
  try {
    final File file = File(path);
    if (!await file.exists()) return null;
    final Uint8List bytes = await file.readAsBytes();
    final ui.Codec codec =
        await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
    final ui.FrameInfo frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null;
  }
}

TextPainter _text(String text, {double size = 16, FontWeight weight = FontWeight.w400, Color color = const Color(0xFF1A1A1A), double maxWidth = 2000}) {
  final TextPainter painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: 1.35,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
  return painter;
}

/// 画完一整张报告，返回 PNG 字节。
Future<Uint8List> renderReportPng({
  required String sessionName,
  required String sessionNote,
  required List<ReportRow> rows,
}) async {
  final double rowWidth = _imageSide * 3 + _gap * 2;
  final double width = _margin * 2 + rowWidth;
  final double headerHeight = sessionNote.isEmpty ? 96 : 128;
  final double rowHeight = _imageSide + _rowMeta;
  final double height =
      _margin + headerHeight + rows.length * (rowHeight + 18) + _margin;

  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Paint bg = Paint()..color = const Color(0xFFFFFFFF);
  canvas.drawRect(Rect.fromLTWH(0, 0, width, height), bg);

  // 页眉
  final TextPainter title = _text('选色对比 · ' + sessionName,
      size: 28, weight: FontWeight.w700, maxWidth: width - _margin * 2);
  title.paint(canvas, const Offset(_margin, _margin));
  final TextPainter dateTime = _text(
    _formatDate(DateTime.now()) + '　·　共 ' + rows.length.toString() + ' 组',
    size: 15,
    color: const Color(0xFF5A6068),
    maxWidth: width - _margin * 2,
  );
  dateTime.paint(canvas, Offset(_margin, _margin + 38));
  if (sessionNote.isNotEmpty) {
    final TextPainter note = _text(sessionNote,
        size: 14,
        color: const Color(0xFF5A6068),
        maxWidth: width - _margin * 2);
    note.paint(canvas, Offset(_margin, _margin + 62));
  }
  canvas.drawLine(
    Offset(_margin, _margin + headerHeight - 12),
    Offset(width - _margin, _margin + headerHeight - 12),
    Paint()
      ..color = const Color(0xFFE4E7EB)
      ..strokeWidth = 1,
  );

  double y = _margin + headerHeight;
  for (final ReportRow row in rows) {
    final ui.Image? refImg = await _loadImage(row.referencePath, _imageSide.toInt());
    final ui.Image? beforeImg = await _loadImage(row.beforePath, _imageSide.toInt());
    final ui.Image? afterImg = await _loadImage(row.afterPath, _imageSide.toInt());

    // 行标题
    final TextPainter label = _text(row.label,
        size: 18, weight: FontWeight.w700, maxWidth: rowWidth);
    label.paint(canvas, Offset(_margin, y));
    y += 28;

    _drawImage(canvas, refImg, _margin, y);
    _drawImage(canvas, beforeImg, _margin + _imageSide + _gap, y);
    _drawImage(canvas, afterImg, _margin + (_imageSide + _gap) * 2, y);

    // 图下方三行小标签
    final double labelY = y + _imageSide + 6;
    _caption(canvas, '家里（基准）', _margin, labelY);
    _caption(canvas, '工地（原图）', _margin + _imageSide + _gap, labelY);
    _caption(canvas, '拉到家里光线后', _margin + (_imageSide + _gap) * 2, labelY);

    // 数据行
    final String floorText = row.errorFloor > 0
        ? '　·　误差下限 ' + row.errorFloor.toStringAsFixed(2)
        : '';
    final String trustText = row.errorFloor > 0
        ? '　·　可信 ' + row.trustworthy.toStringAsFixed(2)
        : '';
    final TextPainter numbers = _text(
      'ΔE ' + row.deltaE.toStringAsFixed(2) +
          '（校正前 ' + row.deltaEBefore.toStringAsFixed(2) + '）' +
          floorText +
          trustText,
      size: 15,
      weight: FontWeight.w600,
      color: const Color(0xFF2E7D32),
      maxWidth: rowWidth,
    );
    numbers.paint(canvas, Offset(_margin, labelY + 24));

    final String meta = (row.location.isEmpty ? '' : row.location + '　·　') +
        '拍摄 ' + _formatDate(row.createdAt);
    final TextPainter metaPainter = _text(meta,
        size: 13, color: const Color(0xFF9AA1A9), maxWidth: rowWidth);
    metaPainter.paint(canvas, Offset(_margin, labelY + 46));

    y += rowHeight + 18;
    refImg?.dispose();
    beforeImg?.dispose();
    afterImg?.dispose();
  }

  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(width.round(), height.round());
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void _drawImage(Canvas canvas, ui.Image? image, double x, double y) {
  final Rect box = Rect.fromLTWH(x, y, _imageSide, _imageSide);
  final Paint frame = Paint()..color = const Color(0xFFF5F6F8);
  canvas.drawRect(box, frame);
  if (image == null) {
    final TextPainter missing = _text('图片读取失败',
        size: 14, color: const Color(0xFF9AA1A9), maxWidth: _imageSide);
    missing.paint(canvas,
        Offset(x + _imageSide / 2 - missing.width / 2, y + _imageSide / 2));
    return;
  }
  final double scale = image.width >= image.height
      ? _imageSide / image.width
      : _imageSide / image.height;
  final double w = image.width * scale;
  final double h = image.height * scale;
  final Rect dst =
      Rect.fromLTWH(x + (_imageSide - w) / 2, y + (_imageSide - h) / 2, w, h);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    dst,
    Paint()..filterQuality = FilterQuality.medium,
  );
}

void _caption(Canvas canvas, String text, double x, double y) {
  final TextPainter painter = _text(text,
      size: 14,
      weight: FontWeight.w600,
      color: const Color(0xFF2F6FED),
      maxWidth: _imageSide);
  painter.paint(canvas, Offset(x, y));
}

String _formatDate(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return time.year.toString() +
      '-' +
      two(time.month) +
      '-' +
      two(time.day) +
      ' ' +
      two(time.hour) +
      ':' +
      two(time.minute);
}
