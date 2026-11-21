import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_theme.dart';
import '../../core/storage.dart';

/// 全屏看图：多张图左右滑，支持双指缩放。
///
/// 右上角可以**把当前这张存进相册 / 分享出去**——原图一直存在 App 私有目录里，
/// 以前只能看不能拿，导出只能整组报告，这里补上单张的出口。
class PhotoViewPage extends StatefulWidget {
  const PhotoViewPage({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.captions = const <String>[],
  });

  final List<String> items;
  final List<String> captions;
  final int initialIndex;

  @override
  State<PhotoViewPage> createState() => _PhotoViewPageState();
}

class _PhotoViewPageState extends State<PhotoViewPage> {
  late final PageController _controller;
  late int _index;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _currentPath => widget.items[_index];

  String get _currentCaption =>
      _index < widget.captions.length ? widget.captions[_index] : '查看';

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final bool ok = await saveToGallery(_currentPath);
      if (!mounted) return;
      showSnack(context, ok ? '已存到相册「ColorMatch」' : '存相册失败（权限或空间）',
          error: !ok);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      await SharePlus.instance
          .share(ShareParams(files: <XFile>[XFile(_currentPath)]));
    } catch (error) {
      if (mounted) showSnack(context, '分享失败：' + error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: _currentPath));
    if (!mounted) return;
    showSnack(context, '路径已复制');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _currentCaption,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: <Widget>[
          if (widget.items.length > 1)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  (_index + 1).toString() +
                      '/' +
                      widget.items.length.toString(),
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ),
          IconButton(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_alt),
            tooltip: '保存到相册',
          ),
          IconButton(
            onPressed: _busy ? null : _share,
            icon: const Icon(Icons.share_outlined),
            tooltip: '分享',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (String value) {
              if (value == 'copy') _copyPath();
            },
            itemBuilder: (BuildContext ctx) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'copy',
                child: Text('复制文件路径'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.items.length,
              onPageChanged: (int i) => setState(() => _index = i),
              itemBuilder: (BuildContext context, int i) {
                return InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: Image.file(
                      File(widget.items[i]),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Text('图片读取失败',
                          style: TextStyle(color: Colors.white54)),
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _save,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white30),
                      ),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('保存原图到相册'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _share,
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: const Text('分享'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
