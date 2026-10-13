# ArkUI-X 跨端（Android）迁移指南

本项目在保持鸿蒙端 HAP 构建的前提下，通过 [ArkUI-X](https://gitcode.com/arkui-x) 支持 Android APK
构建。**当前状态：HAP 与 APK 均由同一套 ACE Tools（不同 target）构建，APK 已在 Android 14 (x86_64)
模拟器上安装运行，书架页 / 设置页正常渲染。**

> **Linux 桌面尚未实现**：ArkUI-X 官方支持 OpenHarmony / HarmonyOS / Android / iOS，
> Linux 桌面仍标注为「规划中」，因此本次只落地 Android。

## 两条构建链

| 目标 | 命令 | target | 产物 |
|---|---|---|---|
| 鸿蒙 | `scripts/build-hap.sh [debug\|release]` | `ace build hap` | `ohos/entry/build/default/outputs/default/entry-default-unsigned.hap` |
| Android | `scripts/build-apk.sh [release\|debug] [arm64\|x86_64]` | `ace build apk` | `ohos/.arkui-x/android/app/build/outputs/apk/<buildType>/app-<buildType>.apk` |

两者共用同一份 ArkTS 源码（`ohos/entry/src/main/ets`），工具链也同一套——**ACE Tools**。
仅 `target` 不同，由 `ace` 子命令区分。

## 平台差异如何处理

### 为什么不用 `//#if` 条件编译

ArkUI-X 文档支持 `//#if ANDROID` / `//#if OHOS` 构建期裁剪，但**本工程的 CLI 构建链不处理该语法**：
实测把整文件包进 `//#if OHOS` 后，两个 target 的报错数量一字不差（`ace` 的源码里也不含任何
条件编译预处理逻辑），即 `//#if` 只是普通注释。

因此平台分支**一律用运行时判断**：`common/PlatformTarget.ets` 依据 `deviceInfo.osFullName`
判定 Android，再调用对应实现。代价是两端产物里都含另一分支代码，但平台层方法体都很小。

### 跨端静态检查（11706007）如何放行

ArkUI-X 的 ArkTS 编译器带一份「跨端 API 白名单」检查：调用了鸿蒙专属 API（AssetStore、
AVSession、ReaderKit 等）会报 `11706007 can't support crossplatform application` 并**中断编译**
（本工程初始 430 个错误，分布在 7 个文件）。

静态检查无法识别运行期守卫（`PlatformTarget` 分派），故在 `.arkui-x/arkui-x-config.json5` 里
把该检查从 error 降级为 warning：

```json5
{
  crossplatform: true,
  modules: ['entry'],
  buildOption: { ignoreCrossPlatform: true },   // ← 必需，否则 APK 编不出来
}
```

> 该文件已入库（`ohos/.arkui-x/*` 的其余生成物仍忽略）。**平台专属代码的正确性由运行时分派保证**：
> 每个调用点都先经 `PlatformTarget` 判定，Android 端不会执行鸿蒙专属分支。

### 平台能力对照

| 能力 | 鸿蒙实现 | Android 实现 | 位置 |
|---|---|---|---|
| 平台判定 | — | 运行时检测 `osFullName` | `common/PlatformTarget.ets` |
| 路由导航 | `UIContext.getRouter()` | 取不到（返回 undefined）→ 统一走 `AppRouter`（回退全局 `router`） | `utils/AppRouter.ets` |
| 轻提示 toast | `promptAction` | 已适配：`build-apk.sh` 补拷插件 `libpromptaction.so`（ace 漏拷 Kit 形式导入的模块） | `scripts/build-apk.sh` |
| 密码存储 | Asset Store（关键资产存储） | AES-256-GCM 密文 + 原生密钥文件 | `services/SecureStore.ets`（鸿蒙）<br>`services/SecureStoreAndroid.ets`（Android） |
| 阅读器引擎 | 优先系统 ReaderKit | 一律用内置阅读器 | `services/ReaderLauncher.ets` |
| 朗读（TTS） | `@kit.CoreSpeechKit` | **不提供**（Android 端无调用方） | `services/ReaderTtsService.ets` |
| 音频播放 | AVPlayer + AVSession + 后台长时任务 | AVPlayer，前台播放 | `services/AudioPlatformOhos.ets`<br>`services/AudioPlatformAndroid.ets` |
| 电量显示 | `batteryInfo` | **待适配**（打开内置阅读器时调用，Android 端行为未验证） | `feature/reader/src/main/ets/ui/ReaderBattery.ets` |
| 翻页动效帧回调 | `displaySync` | **待适配**（同上，Android 端行为未验证） | `feature/reader/src/main/ets/ui/ReaderFlipAnimator.ets` |

### 原生（C/C++）层的跨端

ACE Tools 的 APK 流程**用鸿蒙工具链**编译工程内的 C++（`.cxx` 缓存 `CMAKE_SYSTEM_NAME=OHOS`），
产物链的是 `libace_napi.z.so` / `libhilog_ndk.z.so`——在 Android 上 `dlopen` 必然失败，
表现为「应用能启动但页面空白」。因此 Android 目标必须用 **NDK 重新交叉编译**，由
`scripts/build-apk.sh` 自动完成（编译产物直接投放 gradle 的 jniLibs `app/libs/<abi>/`）。

各模块 `CMakeLists.txt` 已加平台分支：

| 项 | 鸿蒙 | Android（ArkUI-X） |
|---|---|---|
| NAPI / hilog | `libace_napi.z.so` + `libhilog_ndk.z.so` | 引擎库 **`libarkui_android.so`**（导出 205 个 `napi_*` 与 `HiLogPrint`） |
| hilog 头文件 | 鸿蒙 SDK 自带 `hilog/log.h` | 工程内 shim：`third_party/arkuix_android/include/hilog/log.h` |
| C++ 标准库 | 系统 | **`-DANDROID_STL=c++_static`** |
| curl / mbedTLS | arm64 用预编译 `libcurl.so`；x86_64 源码构建 | 一律源码构建（鸿蒙预编译库为 musl，Android bionic 装不上） |

> **为什么 C++ 标准库必须静态链接**：ArkUI-X 引擎自带 libc++ 的命名空间是 `std::__n1`
> （OHOS 风格），而 NDK 编出来的是 `std::__ndk1`，二者不兼容且同名 `libc++_shared.so`
> 同进程只能存在一份。静态链接后业务模块自包含，引擎继续用自己的 libc++。

> **插件库按需补拷**：ace 只拷贝它识别到的 ArkUI-X 插件 `.so`，以 **Kit 形式**导入的模块
> （例如 `@kit.ArkUI` 里的 `promptAction`）会被漏拷，运行期表现为
> `moduleName:promptAction ... libpromptaction.so not found` + 功能**静默失效**（toast 不弹）。
> `scripts/build-apk.sh` 维护一份实测清单（当前：`promptaction`），按目标 ABI 从
> `<SDK>/24/arkui-x/plugins/api/lib/<plugin>/<abi>/` 补进 gradle 的 jniLibs。
> 新功能若在 Android 上无声失效，先查 logcat 里有没有 `libX.so not found`。

## 环境准备（Linux）

ArkUI-X SDK 无官方 Linux 预编译包之外的安装器，本工程按下列配对验证通过：

| 组件 | 版本 | 说明 |
|---|---|---|
| ArkUI-X SDK | 6.1.1.111（apiVersion 24） | [华为云镜像](https://repo.huaweicloud.com/arkui-crossplatform/sdk/) 下载并校验 SHA256 |
| 鸿蒙命令行工具链 | 6.1.1（hvigor 6.24.4） | 本机 GA 版；**不要用 26 Beta**（它把 ArkUI-X 钉死在未发布的 26.0.0.28） |
| hvigor 插件 / modelVersion | 4.24.1 / 6.1.1 | 与上面配对，ace 内部有张版本表决定 |
| Android SDK / NDK | 34.0.0 / 26.1.10909125 | `cmdline-tools` 安装 |
| JDK | **17** | Gradle 7.5 不支持 JDK 21（报 `Unsupported class file major version 65`） |

```bash
cp scripts/android-env.example.sh scripts/android-env.sh
$EDITOR scripts/android-env.sh    # 填 ARKUI_X_SDK / ANDROID_HOME / ANDROID_NDK_HOME / JAVA_HOME
```

**关键坑位（实测，逐条都曾卡住构建）**：
1. **SDK 目录名 = ace 版本键**：ace 只认纯数字目录（`!isNaN(name)`），且按
   「DevEco 版本 → 键」查表（6.1.1 → `24`），故实测放在 `$ARKUI_X_SDK/24/arkui-x/`；
   同时 hvigor 侧要求目录名等于 SDK 自身 `arkui-x.json` 的 `apiVersion`（本例同为 24）。
2. `$ARKUI_X_SDK/licenses/` 目录必须存在（ace 校验许可证目录）。
3. **工程配置升级提示会毁 `modelVersion`**：ace 检测到「工程需升级」时会把
   `hvigor/hvigor-config.json5` 的 `modelVersion` 清空，导致 hvigor 拒绝构建。给
   `ace config --deveco-studio-path` 指一个含 `product-info.json`（`version: 6.1.1`）的桩目录即可跳过该提示。
4. **`ohos/local.properties` 是 hvigor 侧的 SDK 根**（`arkui-x.dir` / `hwsdk.dir`），ace 会覆写它，
   两处都要指向同一真实目录。
5. **Linux 大小写**：ace 硬编码读 `APPScope/app.json5`，而工程目录是 `AppScope` → 需
   `ln -s AppScope APPScope`。
6. `ace modify` 会把 `hvigorfile.ts` / `entry/hvigorfile.ts` 换成 ArkUI-X 任务类
   （`AppTasksForArkUIX` / `HapTasks`）——**此后 HAP 也走 ace**，裸 `hvigorw` 不再适用。
7. `ace build apk --debug` 会额外编 `ohosTest`（本工程无该 target，报 `00303201`），故脚本默认 release。

## 构建与运行验证

```bash
scripts/build-hap.sh debug                     # 鸿蒙 HAP
scripts/build-apk.sh release x86_64            # Android APK（x86_64 模拟器）
scripts/build-apk.sh release                   # Android APK（arm64 真机）
```

Android 模拟器（需要有 x86_64 系统镜像；本机用 Android 14 / API 34）：

```bash
sdkmanager "emulator" "system-images;android-34;google_apis;x86_64"
avdmanager create avd -n mybooks_x64 -k "system-images;android-34;google_apis;x86_64"
emulator -avd mybooks_x64 -no-window -no-audio -gpu swiftshader_indirect &
adb wait-for-device && adb install -r <apk>
adb shell am start -n com.zhonxinya.talebook/com.zhonxinya.talebook.EntryEntryAbilityActivity
```

> 运行日志里 `libglobal_resmgr.so not found`（systemres 的 resmgr 插件）是无害告警：
> 该 SDK 未附带此插件，加载失败后自动回退，不影响 UI 渲染。

## 已知限制

1. **Linux 桌面未实现** —— ArkUI-X 官方尚未支持。
2. **Android 无后台音频保活** —— 见上文「音频播放」。
3. **Android 无朗读功能** —— TTS 依赖华为 CoreSpeechKit。
4. **Android 阅读界面待验证** —— `ReaderBattery`（`batteryInfo`）与 `ReaderFlipAnimator`
   （`displaySync`）是仅鸿蒙有实现的 API。经核对，`batteryinfo` / `displaysync` / `wantagent` /
   `avsession` / `backgroundtaskmanager` 这些模块**在 ArkUI-X 6.1.1 SDK 中根本不存在**
   （既没有 `.so` 也没有 `.abc`），所以不是「补包」能解决的，必须在 ArkTS 侧做运行期降级
   （Android 上跳过电量查询、动效帧回退为定时器）。目前验证范围只覆盖书架 / 设置 / 账号 /
   下载管理等页面；**打开书籍进入阅读器前应先加这两处守卫**。
5. **`@arkui-x.android` 模块不可直接 import** —— 类型声明仅在 ArkUI-X SDK 中存在，
   鸿蒙构建链会因「找不到模块」失败；这也是加解密改走 NAPI 的原因。
6. **签名与安装** —— 本仓库不含签名材料，HAP 产物未签名；APK 由 Gradle 用 debug 证书签名。

## 目录结构

```
scripts/
├── build-hap.sh                 # 鸿蒙 target（ace build hap）
├── build-apk.sh                 # Android target（NDK 交叉编译原生模块 + ace build apk）
└── android-env.example.sh       # 环境变量模板（本机版 android-env.sh 已 ignore）

ohos/
├── .arkui-x/arkui-x-config.json5  # 跨端标记 + ignoreCrossPlatform（已入库，其余 .arkui-x/* 忽略）
├── entry/src/main/ets/
│   ├── common/PlatformTarget.ets          # 平台判定（运行时）
│   └── services/
│       ├── SecureStore.ets                # 安全存储（鸿蒙：Asset Store）
│       ├── SecureStoreAndroid.ets         # 安全存储（Android：AES-GCM）
│       ├── AudioPlatformOhos.ets          # 音频平台层（鸿蒙：AVSession + 长时任务）
│       └── AudioPlatformAndroid.ets       # 音频平台层（Android：降级空实现）
├── third_party/arkuix_android/include/hilog/log.h   # Android 端 hilog 兼容头
├── entry/src/main/cpp/CMakeLists.txt      # 平台分支：Android 链 libarkui_android
└── mybooks_core/src/main/cpp/
    ├── CMakeLists.txt                     # 同上
    ├── include/secure_crypto.h           # AES-256-GCM 接口
    └── secure_crypto.cpp                  # mbedTLS 实现 + 密钥文件管理
```
