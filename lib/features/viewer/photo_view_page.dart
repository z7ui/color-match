import 'dart:io';

import 'package:flutter/material.dart';

/// 全屏看图：多张图左右滑，支持双指缩放。
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _index < widget.captions.length ? widget.captions[_index] : '查看',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text('${_index + 1}/${widget.items.length}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ),
          ),
        ],
      ),
      body: PageView.builder(
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
                errorBuilder: (_, __, ___) => const Text('图片读取失败',
                    style: TextStyle(color: Colors.white54)),
              ),
            ),
          );
        },
      ),
    );
  }
}
