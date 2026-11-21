# Changelog

## [0.1.10] - 2026-11-21

**纠正 0.1.9 里做反的逻辑：参照（家里）是基准，不能再被标定改成别的颜色。**

### 修复

- **家里的照片不再被「拉到 255」**：0.1.9 及更早版本标定会生成一张 `_calibrated.jpg`
  并把整图按白点增益改写——于是你要对比的那张照片自己先变了色，对比失去意义。
  现在标定**只记录白点数值**，不写任何图、不改任何像素（顺带把旧版本残留的校正图删掉）。
- **对比只作用于工地那张**：`transferWhite(工地 → 家里白点)`，
  ΔE 拆成「原始 vs 原始」和「工地拉到家里 vs 家里原图」两个都自洽的口径。
- 缩略图、结果区左半边、导出报告左栏一律使用**原图**，不再出现「被处理过的基准」。
- 单测新增两条硬约束：对比过程中参照图与目标原图的像素**一个都不能变**。

### 优化

- 标定从「解码 + 逐像素 + 编码」变成「只写 3 个整数」，几乎瞬间完成，也不再占用存储。

## [0.1.9] - 2026-11-21

### 修复

- **标定页手势冲突**：同时注册 pan 与 scale，Flutter 直接抛
  「Having both a pan gesture recognizer and a scale gesture recognizer」；
  debug 下必崩、release 下双指缩放失效。改为只用 scale，按 `pointerCount` 分流。
- **重新标定不失效旧结果**：改白点后旧的 ΔE 仍显示。现在参照重标 → 清空会话全部对比，
  目标重标 → 清它自己的对比。
- **删参照留下孤儿对比**：`deleteCapture` 只删「目标侧」，改为同事务删两侧。
- **数据库并发双开**：懒加载没有缓存 Future，两个页面同时首次访问会 open 两次。
- **首页数据库异常无限转圈**：补错误态与重试。
- **三处 setState after dispose**：`_reload()` 前补 `mounted`。
- **相机**：切后台/切摄像头时用到已 dispose 的 controller，且不跟随生命周期。
- **主线程解码大图**：所有图像处理搬到 isolate。
- **参照图未缩放解码**：内存峰值降一个数量级。
- **EXIF 方向不一致**：统一 `bakeOrientation`。
- **白平衡在 gamma 空间做**：改到线性光空间（增益 0.1–12）。
- **「换图」只是追加**：改为真正替换参照图。
- **批量对比期间行内按钮仍可点**：统一受 `_busy` 保护。
- **导出报告标签是 UUID 前四位**：改为 `T1 dE 8.2 -> 0.4`。

### 优化

- 工作副本按用途限制长边（1200 / 1400 / 1000）。
- 列表缩略图加 `cacheWidth`。
- 标定拖动时 4 倍降采样采样，松手精算。
- `Comparison` 增加 `deltaEBefore` 字段（原来塞在 `note` 里且从不读取）。
- `updateCaptureCalibration` 按列更新。

### 清理

- 删无用依赖 `shared_preferences` / `cupertino_icons`，pubspec 去模板注释。
- `analysis_options.yaml` 换成有取舍的真实规则（0 / 0 / 0）。
- 删掉假的 `test/widget_test.dart`，换成算法单测（含 Sharma CIEDE2000 标准样本）。
- `buildAppBar` 去掉从不使用的 `context` 参数。
- Android `build.gradle.kts`：去模板 TODO；release 无密钥回退 debug 签名。
- `scripts/push_via_api.py`：提交信息改为读 `git log -1`。
