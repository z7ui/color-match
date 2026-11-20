# 选色助手（color-match）

装修选色对比：把不同环境（家里 / 门窗厂 / 建材市场）拍的照片**拉到同一光线基准**，排除「照肉灯」这类光源干扰，判断瓷砖、门、美缝到底是不是同一个颜色。

## 下载

- 介绍文章：<https://www.z7ui.cn/color-match/>
- 直接下载 APK：<https://www.z7ui.cn/tile-api/apk/color-match/color-match-0.1.0.apk>
- GitHub Release：<https://github.com/z7ui/color-match/releases/tag/v0.1.0>

## 核心链路

```
拍照/上传 → 标定（框选白纸/灰卡）→ 拉到基准 → 对比 → 存库 → 导出
```

## 已实现（0.1.0）

- **拍照**：全屏预览 + A4 比例构图框（把白纸/灰卡放进框里）
- **上传**：从相册选图
- **标定（穷人版）**：拖动/缩放选框，实时显示平均色，一键把白点拉到 255
- **对比**：把「目标」拉到「参照」的白点，输出校正前后 ΔE00（CIEDE2000）
- **存储**：SQLite（会话 / 采集 / 对比），照片存手机内部目录
- **关于页**：版本、检查更新、公告
- **算法**：sRGB→Lab、ΔE00、白平衡增益、白点迁移、并排拼图

## 待实现

- 多对一对比（一个参照 vs 多个目标）
- 富人版标定（24 色卡 → 3×3 CCM）
- 自动对齐（ORB 特征点）
- 完整对比报告导出（原图×2 + 校正图 + ΔE + 参数）
- 光照梯度自检（复用 A4 灰阶靶工具包的判定规则）

## 技术栈

- Flutter（Android）
- `camera`：相机预览与拍照
- `image`：解码、缩放、逐像素白平衡
- `sqflite`：本地库
- `share_plus`：导出分享

## 算法说明

**白平衡（穷人版）**

```
白点 = 框选区域的平均 RGB
增益 = 255 / 白点（逐通道）
输出 = 原图 × 增益
```

**拉到参照**

```
目标图 × (参照白点 / 目标白点)   // 保留参照方的白点，不强行拉纯白
```

**色差**

sRGB → 线性 RGB → XYZ(D65) → Lab → CIEDE2000。

判定参考（沿用 A4 灰阶靶工具包）：

| 指标 | 阈值 |
|---|---|
| 白参考 | ≥ 235 |
| 光照梯度 | ≤ 6 |
| 块内跨度 | ≤ 15 |

## 构建

```bash
flutter pub get
flutter build apk --release
```

## 数据位置

`getApplicationDocumentsDirectory()/color_match.db`
`getApplicationDocumentsDirectory()/captures/<session>/...`
