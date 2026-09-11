# talebook

HarmonyOS 原生多源聚合阅读器（ArkTS UI + C++ 核心层）。

## 架构

- **ArkTS**：页面、导航、Reader Kit 阅读器 UI
- **C++ NAPI**（`ohos/entry/src/main/cpp/`）：HTTP、Cookie、持久化、Talebook/SoNovel API
- **Reader Kit**：EPUB / TXT / MOBI / AZW / AZW3 原生阅读

## 构建

```powershell
# 完整构建（含清理）
.\scripts\build.ps1

# 增量快速构建
.\scripts\quick-build.ps1

# 构建并安装到真机
.\scripts\build-and-install.ps1 -Launch
```

等价 hvigor 命令（在 `ohos/` 目录下）：

```powershell
..\scripts\hvigorw.ps1 assembleHap -p product=default -p buildMode=debug --no-daemon
```

构建产物：`ohos/entry/build/default/outputs/default/entry-default-signed.hap`

依赖：需存在 `ohos/entry/libs/arm64-v8a/libcurl.so`（见 `third_party/README.md`）。

或在 DevEco Studio 中打开 `ohos/` 目录构建。

## 配置

1. 设置 → 附加服务 → 配置 Talebook / SoNovel 服务器地址
2. 设置 → 登录 Talebook 账号
3. 书架页查看本地下载书籍，点击阅读打开 Reader Kit

## 目录

```
ohos/entry/src/main/
├── cpp/           # C++ NAPI 核心
├── ets/pages/     # ArkTS 页面
├── ets/services/  # TalebookService / ReadKitSession
└── ets/components/
```
