# 构建环境梳理（Flutter / Android）

这份文档回答一个问题：**为什么换个项目、动一个版本号，构建就能卡几个小时？**

## 一、构建链路有哪几层

```
你的 Dart 代码
   │  flutter build apk
   ▼
Flutter 工具（3.13.7）          生成 Android 工程、编译 Dart（AOT）
   │
   ▼
Gradle（8.14.3）                 构建调度器：解析依赖、编排任务
   ├── AGP（8.11.1）             Android 构建插件：编译资源、打包、签名、aapt2
   ├── Kotlin 插件（2.2.20）      编译插件里的 .kt 代码
   └── JDK 17                    跑 Gradle 和 Kotlin 编译器的 Java 运行时
   │
   ▼
Android SDK（platform 37 + build-tools）   提供 android.jar、aapt2、d8
   │
   ▼
APK
```

**关键认知**：这五层是**互相约束**的，不是随便挑版本。

## 二、每层是什么、为什么是这个版本

| 层 | 是什么 | 当前值 | 为什么 |
|---|---|---|---|
| Flutter | UI 框架 + 构建工具 | 3.13.7 | 机器上装的就是它 |
| Gradle | 构建调度器（类似 make） | 8.14.3 | 本地已有完整缓存；腾讯云镜像可下 |
| AGP | Android Gradle Plugin | 8.11.1 | Flutter 3.13 要求 **≥8.11.1**；且 aapt2 8.11.1 已在本地缓存 |
| Kotlin | 编译插件 .kt 代码 | 2.2.20 | Flutter 模板要求 ≥2.2；本地缓存 |
| JDK | Java 运行时 | 17 | Gradle 8.x 只支持到 21；**Android Studio 自带的是 25，会崩** |
| compileSdk | 编译时用的 Android API | 37 | `permission_handler_android 14.x` **强制要求 37** |
| minify | R8 压缩/混淆 | false | 开着 release 要跑 27 分钟，收益很小 |

## 三、互相约束的关系

```
Flutter 3.13.7
 ├─ 要求 AGP ≥ 8.11.1
 │    └─ AGP 8.11.1 要求 Gradle ≥ 8.9   （8.14.3 ✓）
 │         └─ Gradle 8.x 要求 JDK ≤ 21   （17 ✓）
 └─ 插件 permission_handler 14.x 要求 compileSdk 37
      └─ 需要安装 Android SDK platform 37
```

**动任何一层，都要检查它上下两层的约束。**

## 四、这次踩的 7 个坑（按发生顺序）

### 坑 1：Gradle 9.3.1 下载卡死
- **现象**：卡在 `Downloading https://services.gradle.org/distributions/gradle-9.3.1-all.zip`，20 分钟不动。
- **原因**：新模板默认用 9.3.1-all（200MB+），而 `services.gradle.org` 是 Cloudflare，国内基本连不上。
- **修法**：换 `mirrors.cloud.tencent.com` 镜像 + 用本地已有的 8.14.3。

### 坑 2：AGP 9.1.0 的 aapt2 下不下来
- **现象**：卡在 Google Maven，或者离线构建时报 `No cached version of com.android.tools.build:aapt2:9.1.0`。
- **原因**：**aapt2 是硬编码从 Google Maven 下载的**，项目里配的阿里云镜像对它无效。
- **修法**：降到 AGP 8.11.1（本地缓存里有对应的 aapt2 8.11.1）。

### 坑 3：JDK 25 让 Kotlin 编译器崩
- **现象**：`java.lang.IllegalArgumentException: 25.0.3`。
- **原因**：Android Studio 自带的 JBR 升到了 JDK 25，Kotlin 2.2 的 `JavaVersion.parse` 不认。
- **修法**：把 `JAVA_HOME` 指向任意 JDK 17（不要用 Android Studio 自带的 JBR）。

### 坑 4：compileSdk 不够
- **现象**：`permission_handler_android requires Android SDK version 37 or higher`。
- **修法**：`compileSdk = 37`（机器上已装 `android-37.0`）。

### 坑 5：AGP 降太低，被 Flutter 拦
- **现象**：`AGP 8.5.2 is lower than Flutter's minimum supported 8.11.1`。
- **修法**：回到 8.11.1。

### 坑 6：R8 跑 27 分钟
- **现象**：`assembleRelease` 卡在最后阶段，CPU 不动、无输出。
- **原因**：release 默认 `isMinifyEnabled = true`，R8 要对所有依赖做全局分析。
- **修法**：`isMinifyEnabled = false` → 57 秒出包。

### 坑 7：Gradle 锁冲突
- **现象**：`Timeout waiting to lock build logic queue. Owner PID: xxx`。
- **原因**：反复 kill 构建，Gradle daemon 没退，锁还在。
- **修法**：
  ```powershell
  Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
    Where-Object { $_.CommandLine -like "*GradleDaemon*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  ```

## 五、已验证的正确组合

| 项 | 值 |
|---|---|
| Flutter | 3.13.7 |
| Gradle | 8.14.3（`mirrors.cloud.tencent.com`） |
| AGP | 8.11.1 |
| Kotlin | 2.2.20 |
| JDK | 17（不要用 Android Studio 自带 JBR，见坑 3） |
| compileSdk | 37 |
| Maven 镜像 | 阿里云 google / public / gradle-plugin |
| minify | false |
| 构建耗时 | debug ≈28s，release ≈57s |

## 六、下次怎么避免

1. **新项目别用 `flutter create` 的默认 android 配置**，直接把本项目的 `android/settings.gradle.kts`、`gradle-wrapper.properties`、`gradle.properties` 抄过去。
2. **两个镜像必须配**：Gradle 用腾讯云，Maven 用阿里云。
3. **JDK 固定 17**，构建命令前显式 `JAVA_HOME=...`，不要依赖 Android Studio 的 JBR。
4. **不要反复 kill 构建**；kill 之后先清 GradleDaemon。
5. **release 先关 minify**；要上架再开，并加 keep 规则。

## 七、快速排错对照表

| 症状 | 原因 | 处理 |
|---|---|---|
| `Could not connect to server`（21 秒超时） | github.com / Google Maven 被墙 | 换镜像；GitHub 走 API |
| 卡在 `Downloading gradle-x.x.zip` | Gradle 发行包下载 | 换腾讯云镜像 |
| `IllegalArgumentException: 25.0.3` | JDK 太新 | `JAVA_HOME` 指 17 |
| `compileSdk 37 required` | 插件要求高版本 | `compileSdk = 37` |
| `AGP version lower than minimum` | AGP 太旧 | 升到 8.11.1 |
| `Timeout waiting to lock buildLogic` | daemon 没退 | 杀 GradleDaemon |
| release 卡几十分钟 | R8 | `isMinifyEnabled = false` |
| `SDK XML version 4` 警告 | build-tools 与 AS 版本不一致 | 可忽略 |
