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

### 两端包名不同

| 端 | 包名 | 来源 |
|---|---|---|
| HarmonyOS | `com.zhonxinya.mybooks.harmonyos` | `ohos/AppScope/app.json5` 的 `app.bundleName` |
| Android | `com.zhonxinya.mybooks.android` | `scripts/android-shell-overlay.sh` 覆写生成的 `app/build.gradle` |

ace 会用 `app.bundleName` 同时充当 Android 壳工程的清单 `package` 与 `applicationId`，两端同名会在同一台
设备上互相覆盖安装，故 Android 侧由 overlay 覆写 `applicationId`（清单 `package` 仍取自 bundleName，
充当命名空间；二者不同是 AGP 允许的组合）。由此：

- **provider 的 authority 必须写成固定字面量**（`com.zhonxinya.mybooks.android.apkprovider`），不能由
  `bundleManager.getBundleInfoForSelfSync()` 推导——它返回的是 ArkUI-X 的 bundleName（`.harmonyos`），与清单对不上；
- 鸿蒙签名 profile 绑定 bundleName，改包名后需重新签发（`.hapsign/`）。

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
| 电量显示 | `batteryInfo` | **已实现**：SDK 无 `batteryinfo` 插件，改经原生桥 `apiGetBatteryInfo` 读 Android `BatteryManager`（JSON `{level,charging}`） | `ui/ReaderBattery.ets`<br>`android-overlay/java/.../BatteryReader.java` |
| 翻页动效帧回调 | `displaySync` | **已降级**：SDK 无 `graphics_displaysync` 插件，退化为 **16ms 定时器帧源** | `ui/ReaderFlipAnimator.ets` |
| 本地导入（文件选择） | `picker.DocumentViewPicker` | **可用（类型过滤降级）**：能拉起系统文件选择器；但类型过滤在 Android 上不生效——file_picker 在 Java 侧用 `URLConnection.guessContentTypeFromName` 把后缀映射成 MIME（每条都过这张表，传 MIME 串也救不了），azw/azw3 查不到即得到 `null`，整组 MIME 失效，故导入由应用侧后缀校验兜底 | `services/LocalBookService.ets` |
| 复制到剪贴板 | `pasteboard` | **已适配**：APK 打包 `libpasteboard.so`（同 Kit 导入机制，与已验证可用的 `file_picker`/`intl` 同一套加载链）；应用内仅写入、无读取 | `pages/UserSettingsPage.ets` 等 |
| 国际化 / 本地化 | `intl` | **已适配**：APK 打包 `libintl.so`，运行期已加载 | — |
| 应用内升级 | 不支持（HAP 需自行签名安装，仍走外链下载） | 下载 `.apk` 附件 → 系统安装器 | `services/ApkUpdater.ets` |
| 用 Want 打开外部链接 | `startAbility({action: viewData, uri})` | **不可用**（见下节第 1 点），Android 端按钮无反应 | `pages/UpdatePage.ets` |

### 应用内升级（Android）

`services/ApkUpdater.ets` 把 release 里的 `.apk` 附件下载到 `filesDir/updates`，再交给系统安装器。
两个平台坑（均为实测结论）：

1. **`context.startAbility` 在 Android 上拉不起系统组件**：隐式 Want 只在 ArkUI-X 自己的 bundle 内解析目标，
   解析不到就直接抛 `Internal error`（用 `viewData` 打开 https 链接同样失败）。因此安装改走原生桥
   `libentry.apiInstallApk(uri)`：Android 侧用 JNI 取 JavaVM（`JNI_OnLoad` 优先，兜底 `dlopen libart.so`
   + `JNI_GetCreatedJavaVMs`），再调用 `android-overlay/java/.../ApkInstaller.java` 构造 Intent。
   注意**应用类加载器只在 `JNI_OnLoad` 里可用**，故由 `ApkInstaller.init`（provider 的 `onCreate` 调用）
   触发 `System.loadLibrary("entry")` 并把类缓存成全局引用；否则从 ArkTS 线程 `FindClass` 只会命中系统类加载器。
2. **ArkTS 的 `context.filesDir` ≠ Android 的 `getFilesDir()`**：ArkUI-X 的
   `StageApplicationDelegate#createStagePath` 把 filesDir 设为 `getFilesDir() + "/files"`，
   因此 provider 按 `<getFilesDir>/files/updates` 读取安装包。

首次安装需用户在系统弹窗里放开「从此来源安装应用」（`REQUEST_INSTALL_PACKAGES`）。

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
> `scripts/build-apk.sh` 维护一份实测清单（`PLUGIN_LIBS`：promptaction / measure / font /
> arkui_componentutils / arkui_drawabledescriptor / overlay），按目标 ABI 从
> `<SDK>/24/arkui-x/plugins/api/lib/<plugin>/<abi>/` 补进 gradle 的 jniLibs。
> 新功能若在 Android 上无声失效，先查 logcat 里有没有 `libX.so not found`。
>
> **打包后有两道自动核对**（`build-apk.sh` 第 3 步，不满足即构建失败）：① `PLUGIN_LIBS` 每个库
> 都在 SDK 与本 ABI 的 APK 中；② 源码里 `import { x } from '@kit.*'` 且 `x` 与某插件库**同名**
> （`promptAction` → `libpromptaction.so`）的库也在 APK 中。只断言「小写开头 + 精确同名」是为了
> 零误报：大写开头是 ArkTS 类型（`Configuration` 会假命中 `libconfiguration.so`），模糊匹配也会
> 误伤（`common` → `libcommoneventmanager`、`media` → `libmediaquery`）。代价是改名映射查不到
> （`picker` → `libfile_picker.so`），这类仍以 logcat 为准。

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
adb shell am start -n com.zhonxinya.mybooks.android/com.zhonxinya.mybooks.harmonyos.EntryEntryAbilityActivity
```

> 组件名 = `<applicationId>/<清单 package>.<Activity>`：安卓的 applicationId 是 `…mybooks.android`，
> 而清单 package（命名空间）仍取自 `app.bundleName`（`…mybooks.harmonyos`），两者不同故不能省写成 `.EntryEntryAbilityActivity`。

> 运行日志里 `libglobal_resmgr.so not found`（systemres 的 resmgr 插件）是无害告警：
> 该 SDK 未附带此插件，加载失败后自动回退，不影响 UI 渲染。

## CI（GitHub Actions）

CI 的 HAP 构建（`.github/actions/build-hap`）与本地一致，走 **ACE Tools**：`ace build hap`。
裸 `hvigorw` 已不适用（工程切为 ArkUI-X 结构后，`hvigorfile.ts` 引用 ArkUI-X 任务类）。

**前提：CI 必须拿到与本工程配套的鸿蒙命令行工具链 6.1.1.x。**

- 公开的第三方镜像（`Okysu/harmony-auto-build`）**只有 6.1.0.816**，它有两处不兼容：
  1. `hvigor` 直接拒绝 `modelVersion 6.1.1`（报 `Unsupported modelVersion of Hvigor 6.1.1`，
     提示 supported is 6.1.0）；
  2. 该版本工具链要求 **ArkUI-X 6.1.0.28**，而华为云 ArkUI-X 镜像里**没有这个版本**（只有 6.0.x 与 6.1.1.x）。
- 因此工具链**已固定在本仓库的 Release** [`toolchain-6.1.1.300`](../../releases/tag/toolchain-6.1.1.300)：
  | 资产 | 说明 | SHA256 |
  |---|---|---|
  | `commandline-tools-linux-x64-6.1.1.300.zip` | 官方 6.1.1.300 解压目录重新打包（`zip -y` 保留符号链接，1.994GiB ≤ 2GiB 上限） | `456de8af…fecdf0` |
  | `arkui-x-linux-x64-6.1.1.111-Release.zip` | 华为云官方原件（含官方 `.sha256` 可对账） | `eddddab0…e674857` |
- 仓库变量已配置：`HARMONY_TOOLS_URL`（CLT）与 `ARKUIX_SDK_URL`（ArkUI-X，留空则回退华为云镜像）；
  两条工作流经 `tools-url` / `arkuix-sdk-url` 传入。
- Android SDK/NDK 仍从 Google 官方源下载（公开稳定；且 NDK 约 2.5GB 超 GitHub 单资产上限，不宜自托管）。

CI 里由 action 自动完成的准备（都是本地踩过的坑，缺一不可）：

| 步骤 | 作用 |
|---|---|
| 下载并解压 ArkUI-X SDK（校验 SHA256） | 目录名必须是纯数字 `24`（= apiVersion），另需 `<root>/licenses/` |
| 写 `ohos/local.properties` | `hwsdk.dir` + `arkui-x.dir`（hvigor 与 ace 插件都读它） |
| `ln -s AppScope ohos/APPScope` | ace 硬编码读 `APPScope`（Linux 大小写敏感） |
| 建 `sdk/24/{toolchains,sdk-pkg.json}` + `sdk/licenses` | ace 校验「数字版本目录 + 许可证目录」 |
| 建 DevEco 桩（`product-info.json` 版本 6.1.1） | 否则 ace 会把工程标记为「需升级」并清空 `modelVersion` |
| `ace config --arkui-x-sdk/--command-line-tools-path/--ohpm-dir/--openharmony-sdk/--harmonyos-sdk/--deveco-studio-path` | 注册本次下载的目录，`ace check` 全绿 |
| `ace modify --project`（平台选 `1` = Android+iOS） | 干净检出没有 `.arkui-x/android\|ios`（生成物未入库），而 ace 构建需要它 |
| `git checkout -- .arkui-x/arkui-x-config.json5` | modify 会重写该文件、丢掉 `buildOption.ignoreCrossPlatform` |

**发布流程**：`.github/workflows/release.yml` 在打 `v*` 标签时同时构建 **HAP** 与
**Android release APK（arm64）**，两个产物一并挂到 Release；APK 由
`.github/actions/build-apk` 构建（额外装 Android SDK/NDK + JDK 17，并生成
`scripts/android-env.sh`，随后走 `scripts/build-apk.sh release arm64`）。
`build.yml`（PR 编译校验）仍只构建 debug HAP，保持 CI 时长可控。

> 备选（若不想自托管 2GB 包）：让 CI 构建「鸿蒙专用形态」——用公开的 6.1.0.816 + 原始
> `hvigorfile.ts` + `modelVersion 5.0.0` + 无 `.arkui-x`，走裸 `hvigorw assembleHap`
> （已实测 36s 出 HAP）。代价是 CI 不再校验跨端链路，且需在仓库保留一套纯 hvigor 的
> `hvigorfile` 变体供 CI 替换。

## 已知限制

1. **Linux 桌面未实现** —— ArkUI-X 官方尚未支持。
2. **Android 无后台音频保活** —— 见上文「音频播放」。
3. **Android 无朗读功能** —— TTS 依赖华为 CoreSpeechKit。
4. **Android 阅读界面两处平台能力：一处走原生桥补齐、一处降级** —— `batteryinfo` 与
   `graphics_displaysync` 在 ArkUI-X SDK 中**均不存在**（既无 `.so` 也无 `.abc`）：
   - `ReaderBattery`：电量**已补上**——不使用缺失的 `batteryinfo` 插件，改由 `libentry` 原生桥
     `apiGetBatteryInfo` 调 Android `BatteryManager`（见上表）；桥返回空串时本轮留空但不锁死，
     下一轮轮询自愈。（鸿蒙端仍用系统 `batteryInfo`。）
   - `ReaderFlipAnimator`：拿不到 `displaySync` 时退化为 **16ms 定时器帧源**，翻页动画照旧逐帧推进
     （本类每帧显式赋值，不依赖系统帧回调）；已加「探测一次」缓存。
5. **`@arkui-x.android` 模块不可直接 import** —— 类型声明仅在 ArkUI-X SDK 中存在，
   鸿蒙构建链会因「找不到模块」失败；这也是加解密改走 NAPI 的原因。
6. **签名与安装** —— 本仓库不含签名材料：HAP 产物未签名（本地签名材料见 `.hapsign/`）；APK 的 release
   签名密钥不入库，CI 从 GitHub Secrets 还原（见 `.github/actions/build-apk`），本机指向 `.signing/`
   （`scripts/android-env.sh`）。签名一致才能跨版本覆盖安装。
7. **Android 端 `util` 插件编解码能力缺失**（实测 ArkUI-X 6.1.1，均已修复）：
   - `util.TextDecoder` **不支持 `gbk`**：`create('gbk')` 不抛错、却按拉丁系解码，整本 GBK 文本乱码
     → 已改为「探测引擎能力 + 内置 GBK 映射表兜底」（`feature/reader/engine/GbkTable.ets`）；
   - **taskpool 子线程里 `util.TextEncoder.encodeInto()` 返回 `undefined`** → 开书抛
     `Cannot read property byteLength of undefined`，已改为自带 UTF-8 编码（`TxtParser`）。
   排查手法备忘：ArkTS `hilog` 在 Android 上**进不了 logcat**，改用「把诊断信息写文件 / 拼进页面文本」
   再截图或 `adb` 读取；纯 JS 异常与栈**能**在 logcat 看到（`ArkCompiler` 标签）。

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
