# Changelog

## [0.1.9] - 2026-11-21

修复与重构（按代码评审结论逐条处理）：

### 修复

- **标定页手势冲突**：同时注册 pan 与 scale，Flutter 直接抛
  「Having both a pan gesture recognizer and a scale gesture recognizer」；
  debug 下必崩、release 下双指缩放失效。改为只用 scale，按 `pointerCount` 分流。
- **重新标定不失效旧结果**：改白点后旧的 ΔE 仍显示，等于给出错误结论。
  现在参照重新标定会清空该会话全部对比，目标重新标定会清空它自己的对比。
- **删参照留下孤儿对比**：`deleteCapture` 只删「目标侧」，改为同事务删两侧。
- **数据库并发双开**：懒加载没有缓存 Future，两个页面同时首次访问会 open 两次。
- **首页数据库异常无限转圈**：补错误态与重试。
- **三处 setState after dispose**：`_reload()` 前补 `mounted` 判断。
- **相机**：切后台/切摄像头时用到已 dispose 的 controller，且不跟随生命周期；
  现在先断开引用再 dispose，并实现 `WidgetsBindingObserver`。
- **主线程解码大图**：所有图像处理搬到 isolate（`image_pipeline.dart`），
  批量对比不再卡 UI。
- **参照图未缩放解码**：内存峰值降一个数量级。
- **EXIF 方向不一致**：统一 `bakeOrientation`，预览与采样坐标一致。
- **白平衡在 gamma 空间做**：改到线性光空间；增益上下限改为 0.25–12
  （原来卡 4 倍，白点 100 的室内照片标定完还是灰的）。
- **校正前/后基准不一致**：校正前改为「原始 vs 原始」，校正后为「标定 vs 标定」。
- **「换图」只是追加**：改为真正替换参照图（先删旧的再拍）。
- **批量对比期间行内按钮仍可点**：统一受 `_busy` 保护。
- **导出报告标签是 UUID 前四位**：改为 `T1 dE 2.3 -> 0.4` 这类可读标签。

### 优化

- 采集与标定用的工作副本限制长边（1600 / 1200 / 1400 / 1000），并按用途区分。
- 列表缩略图加 `cacheWidth`，滚动不再解码原图。
- 标定拖动时用 4 倍降采样采样，松手后精算。
- `Comparison` 增加 `deltaEBefore` 字段（原来塞在 `note` 里且从不读取）。
- `updateCaptureCalibration` 按列更新，不再重建整个 `Capture` 实体。

### 清理

- 删除未使用的依赖 `shared_preferences` / `cupertino_icons`，pubspec 去掉模板注释。
- `analysis_options.yaml` 换成有取舍的真实规则（当前 `flutter analyze` 0 error / 0 warning / 0 info）。
- 删掉 `test/widget_test.dart`（文件名是 widget 测试，内容里没有一个 widget 测试），
  换成 `calibration_test.dart` / `compare_test.dart`，含 Sharma 标准样本与基准一致性用例。
- `buildAppBar` 去掉从不使用的 `context` 参数。
- Android `build.gradle.kts`：去掉模板 TODO；release 无密钥时回退 debug 签名。
- `scripts/push_via_api.py`：提交信息改为读取 `git log -1`，不再写死。
