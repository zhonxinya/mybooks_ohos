# ArkUI-X 跨端（Android）迁移指南

本项目在保持鸿蒙端 HAP 构建不变的前提下，通过 [ArkUI-X](https://gitcode.com/arkui-x)
支持 Android APK 构建。本文说明现状、已做的适配，以及在 Linux 上验证/构建 Android 的方法。

> **Linux 桌面尚未实现**：ArkUI-X 官方支持 OpenHarmony / HarmonyOS / Android / iOS，
> Linux 桌面仍标注为「规划中」，因此本次只落地 Android。

## 两条构建链

| 目标 | 命令 | 工具链 | ArkUI-X SDK | 产物 |
|---|---|---|---|---|
| 鸿蒙 | `scripts/build-hap.sh` | hvigor + 官方 ArkTS SDK | 不需要 | `entry-default-unsigned.hap` |
| Android | `scripts/build-apk.sh` | ACE Tools + ArkUI-X SDK | **需要** | `app-debug.apk` |

两者共用同一份 ArkTS 源码（`ohos/entry/src/main/ets`），UI 层代码完全一致。

## 平台差异如何处理

### 为什么不使用 `//#if` 条件编译

ArkUI-X 支持 `//#if ANDROID` / `//#if OHOS` 做**构建期**裁剪，但该预处理由
**ACE Tools / ArkUI-X SDK 的构建链**驱动。官方 hvigor 构建鸿蒙时**不识别**这套语法 ——
`//#if` 只是普通注释，两个分支的代码会同时参与编译，导致 `Duplicate identifier` 等错误。

因此本工程的平台分支**一律用运行时判断**：由 `common/PlatformTarget.ets` 的
`PlatformTarget.isAndroid()`（依据 `deviceInfo.osFullName`）决定走哪个实现。

代价是两端产物里都含有另一个分支的代码，但平台层方法体都很小，
且 Android 专属实现不会在鸿蒙设备上被执行到（属于不可达代码）。

### 平台能力对照

| 能力 | 鸿蒙实现 | Android 实现 | 位置 |
|---|---|---|---|
| 平台判定 | — | 运行时检测 `osFullName` | `common/PlatformTarget.ets` |
| 密码存储 | Asset Store（关键资产存储） | AES-256-GCM 密文 + 原生密钥文件 | `services/SecureStore.ets`（鸿蒙）<br>`services/SecureStoreAndroid.ets`（Android） |
| 阅读器引擎 | 优先系统 ReaderKit | 一律用内置阅读器 | `services/ReaderLauncher.ets` |
| 朗读（TTS） | `@kit.CoreSpeechKit` | 不提供（无调用方） | `services/ReaderTtsService.ets` |
| 音频播放 | AVPlayer + AVSession + 后台长时任务 | AVPlayer，前台播放 | `services/AudioPlatformOhos.ets`<br>`services/AudioPlatformAndroid.ets` |

## 已适配的三处平台专有 API

### 1. 密码存储（Asset Store 缺失）

ArkUI-X 的 Android 端没有 `@kit.AssetStoreKit`。等价方案是 **AES-256-GCM 加密后落盘**：

- 加解密复用 `mybooks_core` 原生模块（`NativeCore.secureSeal` / `secureOpen`），
  内部用 mbedTLS 的 AES-GCM（该库本已为 curl 的 TLS 后端引入）；
- 主密钥为 32 字节随机值，存于身份根目录 `.secure_master.key`（权限 `0600`，
  先写临时文件再 `rename` 原子替换）；
- GCM 的 authTag 校验失败时返回空，**绝不返回部分明文，也绝不降级为明文存储**。

密文格式：`[12B IV][ciphertext][16B authTag]`，整体 hex 后存入 preferences。

> **与 Keystore 的差异**：Android Keystore 里密钥不可导出、由硬件保护；
> 本实现依赖「应用私有目录 + 文件权限 + 应用沙箱隔离」保护密钥。
> 若需要更强保护，可在 `secure_crypto.cpp` 处改接 JNI 调 Keystore，不影响 ArkTS 调用方。

### 2. 系统阅读器（ReaderKit 缺失）

ReaderKit 是华为侧组件，ArkUI-X Android 端没有。`ReaderLauncher.isAvailable()`
在 Android 上直接返回 `false`，从而自动回退到**内置阅读器**
（`feature/reader`，支持 EPUB / TXT / MOBI / AZW / AZW3）。

这一改动很轻：原有代码本就为「模拟器 / 非 HarmonyOS 发行版」准备了同样的回退路径，
Android 端只是复用它。

> ⚠️ 若在 Android 上访问 `ReadKitReader` 页面，会因缺少系统 HSP 而 **native abort**，
> 故 Android 端必须确保所有入口都经 `ReaderLauncher.open()` 路由，不要直接 push 该页面。

### 3. 音频播放（AVSession / 后台长时任务缺失）

ArkUI-X Android 端没有 `avSession.AVSession`（系统播控中心）与
`backgroundTaskManager`（后台长时任务）。处理方式：

- 把三类鸿蒙专属能力抽到 `AudioPlatformOhos.ets`（AVSession、元数据、封面解码、长时任务）；
- `AudioPlatformAndroid.ets` 提供同签名的**空实现**；
- `AudioPlaybackService` 只依赖统一委托，业务逻辑（拉音频列表、本地文件、章节切换）两端共用。

**这是一次能力降级**：Android 端播放页功能完整，但 App 退到后台后不保活，
无锁屏/通知栏播控。若要补齐，正确路径是用 Android 原生
`MediaSession` + `MediaBrowserService` + `MediaStyle` 通知经 NAPI 接入，
而不是在鸿蒙 API 上做条件编译。

## 在 Linux 上构建 Android

ArkUI-X SDK **没有官方 Linux 预编译包**，需注意：

### 1. 获取 ArkUI-X SDK

官方渠道是 DevEco Studio（Windows / macOS）。Linux 上可从 ArkUI-X
[Release Notes](https://gitcode.com/arkui-x/docs/blob/master/zh-cn/release-notes/README.md)
下载预编译包，或按
[SDK 构建说明](https://gitcode.com/arkui-x/docs/blob/master/zh-cn/framework-dev/tutorial/how-to-package-arkui-x-sdk.md)
从源码自行编译（需要 GN / Ninja，建议预留 30GB 与较长编译时间）。

### 2. 准备环境

```bash
# 依赖：Node 16+、JDK 11+、CMake、Ninja、Android SDK/NDK
sudo apt install -y openjdk-17-jdk cmake ninja-build

cp scripts/android-env.example.sh scripts/android-env.sh
$EDITOR scripts/android-env.sh   # 填入 ARKUI_X_SDK / ANDROID_HOME / ANDROID_NDK_HOME
```

### 3. 构建

```bash
scripts/build-apk.sh            # debug
scripts/build-apk.sh release    # release
```

## 已知限制

1. **Linux 桌面未实现** —— ArkUI-X 官方尚未支持。
2. **Android 无后台音频保活** —— 见上文「音频播放」。
3. **Android 无朗读功能** —— TTS 依赖华为 CoreSpeechKit，Android 端未提供替代实现。
4. **`@arkui-x.android` 模块不可直接 import** —— 该模块的类型声明仅在 ArkUI-X SDK 中存在，
   鸿蒙构建链会因「找不到模块」失败。这也是加解密改走 NAPI 的原因。
5. **签名与安装** —— 本仓库不含签名材料，产物默认未签名。

## 目录结构

```
ohos/
├── entry/src/main/ets/
│   ├── common/PlatformTarget.ets          # 平台判定（运行时）
│   └── services/
│       ├── SecureStore.ets                # 安全存储（鸿蒙：Asset Store）
│       ├── SecureStoreAndroid.ets         # 安全存储（Android：AES-GCM）
│       ├── AudioPlatformOhos.ets          # 音频平台层（鸿蒙：AVSession + 长时任务）
│       └── AudioPlatformAndroid.ets       # 音频平台层（Android：降级空实现）
└── mybooks_core/src/main/cpp/
    ├── include/secure_crypto.h           # AES-256-GCM 接口
    └── secure_crypto.cpp                  # mbedTLS 实现 + 密钥文件管理
```
