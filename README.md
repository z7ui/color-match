# 选色助手（color-match）

装修选色对比：把不同环境（家里 / 门窗厂 / 建材市场）拍的照片**拉到同一光线基准**，
排除「照肉灯」这类光源干扰，判断瓷砖、门、美缝到底是不是同一个颜色。

- 文章：<https://www.z7ui.cn/color-match/>
- 下载：<https://www.z7ui.cn/tile-api/apk/color-match/>

## 核心链路

```
拍照/上传 → 标定（框选白纸）→ 拉到基准 → 对比 → 存库 → 导出
```

## 功能

- **拍照**：全屏预览 + 构图引导（中间主体框、左下角白纸框），支持切换前后摄
- **上传**：从相册选图（Android 13+ 走系统照片选择器）
- **标定**：拖动/缩放选框，实时显示平均色与块内均匀度；自动按 A4 灰阶靶的指标给出「这块白能不能用」
- **对比**：
  - 校正前 ΔE —— 两张**原始照片**直接比（你在现场看到的差异）
  - 校正后 ΔE —— 两张都标定到 255 基准后比（排除光源后的真实色差）
  - 改善比例、多目标切换、按住看原图
- **存储**：SQLite（会话 / 采集 / 对比），照片存应用内部目录
- **导出**：每行「参照 | 目标原图 | 目标校正后」拼成一张图，写入应用目录并另存相册
- **关于页**：版本、检查更新、公告、权限说明

## 算法

**白平衡**（在**线性光**空间做，不是在 gamma 编码值上直接乘）

```
线性增益 = lin(255) / lin(白点)      // 夹在 0.25 ~ 12 之间
输出     = sRGB( lin(输入) × 增益 )
```

**拉到参照**

```
增益 = lin(参照白点) / lin(目标白点)
```

**色差**：sRGB → 线性 RGB → XYZ(D65) → Lab → CIEDE2000。
实现与 Sharma 等人的参考数据对齐（单元测试里用标准样本校验）。

判定参考（沿用 A4 灰阶靶工具包）：

| 指标 | 阈值 |
|---|---|
| 白参考亮度 | ≥ 235 |
| 光照梯度 | ≤ 6 |
| 块内跨度 | ≤ 15 |

## 工程约定

- **图像重活全部在后台 isolate**（`lib/core/image_pipeline.dart`）：解码、EXIF 摆正、白平衡、拼图、JPEG 编码，UI 线程不解码大图；
- **EXIF 统一摆正**（`bakeOrientation`），避免「预览是竖的、采样到的是横的」；
- **重新标定会让旧对比失效**：改白点后旧的 ΔE 会作废，需要重新对比；
- **数据库改动走事务**，删参照会连带删掉以它为基准的对比结果；
- 有 `android/key.properties` 就用正式签名，没有就退回 debug（保证别人 clone 下来能构建）。

## 构建

```bash
flutter pub get --offline     # 依赖已在本地缓存时用离线；没有就 flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

服务器地址在编译期定死（默认 `https://www.z7ui.cn/tile-api`），要换环境就：

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://你的地址
```

## 数据位置

```
getApplicationDocumentsDirectory()/color_match.db
getApplicationDocumentsDirectory()/captures/<session>/...
```

导出的报告图在应用目录 + 相册「ColorMatch」相簿（卸载不丢的那份在相册）。
