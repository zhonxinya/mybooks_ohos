# 官方 ReadKit 小说阅读剩余实施计划

> 状态：待执行
>
> 基线提交：`8697af6f feat: 补齐ReadKit阅读进度与目录书签`
>
> 目标：在当前已接入鸿蒙官方 Reader Kit 的基础上，补齐生产级会话管理、书签完整操作、设置同步、窗口适配、真机回归和发布文档，不重新引入 Flureadium、Readium 或 PDF 阅读方案。

## 当前状态

已完成：

- Flutter 通过本地 `flutter_readkit` 插件启动原生 `ReadKitAbility`。
- 原生页使用官方 `ReadPageComponent`、`ReaderComponentController` 和 `bookParser`。
- 支持格式已经收敛为 `EPUB`、`TXT`、`MOBI`、`AZW`、`AZW3`。
- EPUB、TXT、MOBI、AZW、AZW3 均通过统一 `/reader` 入口；PDF 阅读入口已移除。
- Flureadium/Readium 依赖、旧页面和第三方源码已删除。
- 已实现 `EventChannel`，可以回传 `progress`、`closed` 和 `bookmarkAdded` 事件。
- 原生目录可以读取 `CatalogItem`，并通过官方 `getDomPosByCatalogHref()`、`getSpineList()`、`startPlay()` 跳转。
- Flutter 已将 ReadKit 位置和进度写入 `ReadingHistoryManager`，书签写入 `ReadingBookmarkManager`。
- `flutter analyze`、Flutter 测试和 `flutter build hap --debug` 已通过。

当前已知缺口：

- `updateSettings` 和 `closeReader` MethodChannel 当前仍是空操作。
- 原生书签只有添加，没有列表、删除、跳转和去重展示。
- `ready`、`error`、`settingsChanged` 等事件还没有形成完整协议。
- 进度事件中的 `totalPages` 和百分比暂时为默认值，需在真机上确认 Reader Kit 实际排版数据后再计算。
- 窗口尺寸、横竖屏、分屏、折叠和字体缩放变化尚未完整同步到 `ReaderSetting`。
- Flutter `ReaderPage` 通过生命周期观察退出原生页，尚未使用 Ability result 完成严格的一次会话闭环。
- 尚未用五种真实书籍文件完成真机回归，尤其是 TXT、MOBI、AZW、AZW3 的兼容性需要设备验证。
- README 和接口说明尚未更新为 ReadKit-only 架构。

## 目标状态

1. 每次打开只存在一个可追踪的 ReadKit 会话；重复打开返回稳定错误码，关闭后可以再次打开。
2. 原生页和 Flutter 共享稳定、版本化的请求、设置、位置、进度、书签、错误和关闭事件协议。
3. 目录支持展示层级、章节跳转和关闭；书签支持添加、展示、删除、跳转，并与 Flutter 持久化数据一致。
4. Reader Kit 的主题、字体、字号、行高、翻页模式和系统配置变化可以在原生页实时生效并持久化。
5. 五种目标格式在真实 HarmonyOS 设备上完成下载、打开、翻页、目录、书签、进度恢复和退出重开验证。
6. 构建产物不包含 Flureadium/Readium/PDF 阅读模块，文档、测试和代码结构与实际能力一致。

## 影响文件

| 文件 | 变更类型 | 目的 |
|---|---|---|
| `ohos_packages/harmony_flutter_plugin/flutter_readkit/lib/src/readkit_models.dart` | 修改 | 补充事件状态、书签操作、设置变化和稳定错误模型。 |
| `ohos_packages/harmony_flutter_plugin/flutter_readkit/lib/src/readkit_channel.dart` | 修改 | 实现会话状态、方法错误转换和事件流生命周期。 |
| `ohos_packages/harmony_flutter_plugin/flutter_readkit/ohos/src/main/ets/com.zhonxinya.talebook.readkit/FlutterReadKitPlugin.ets` | 修改 | 管理单会话、打开/关闭/更新设置和原生事件转发。 |
| `ohos_packages/harmony_flutter_plugin/flutter_readkit/ohos/src/main/ets/com.zhonxinya.talebook.readkit/ReadKitEventChannel.ets` | 修改 | 完善事件 sink 生命周期、断开处理和错误事件。 |
| `ohos/entry/src/main/ets/entryability/ReadKitAbility.ets` | 修改 | 校验 Want 参数，处理 Ability 生命周期和关闭结果。 |
| `ohos/entry/src/main/ets/pages/ReadKitReader.ets` | 修改 | 完善窗口适配、设置面板、书签列表/删除/跳转和错误回传。 |
| `lib/pages/reader/reader_page.dart` | 修改 | 接入完整事件协议，关闭时刷新历史/书签并可靠返回。 |
| `lib/services/managers/reading_history_manager.dart` | 修改 | 增加 ReadKit progress 合并和关闭时最终快照保存接口。 |
| `lib/services/managers/reading_bookmark_manager.dart` | 修改 | 支持 ReadKit 书签快照、删除和位置去重。 |
| `lib/services/managers/reader_config_service.dart` | 修改 | 明确 ReadKit 可用设置映射和旧配置迁移。 |
| `test/` | 新增/修改 | 覆盖事件协议、书签、历史合并、旧位置迁移和格式能力。 |
| `README.md`、`docs/` | 修改 | 记录 ReadKit-only 架构、格式范围、构建和真机验证要求。 |

## 执行计划

### Phase 1：稳定跨端协议与会话生命周期

- [ ] 定义事件类型：`ready`、`progress`、`bookmarkAdded`、`bookmarkRemoved`、`settingsChanged`、`error`、`closed`。
- [ ] 为每个事件补充 `bookId`、`sessionId` 和 `version`，避免多个阅读会话或旧事件串书。
- [ ] 为错误定义稳定错误码：`readerAlreadyOpen`、`invalidRequest`、`fileNotFound`、`unsupportedFormat`、`readerInitFailed`、`readerClosed`。
- [ ] `openReader` 创建唯一 session；已有会话时拒绝第二次打开，不静默覆盖。
- [ ] `closeReader` 真正关闭当前 Ability 或发送关闭请求；不能继续返回空成功值。
- [ ] Ability 使用结果协议回传最终快照；Flutter 不再只依赖生命周期猜测原生页面是否退出。
- [ ] `onDetachedFromEngine`、Ability 销毁和 EventChannel 取消监听时清理 session、sink 和控制器。
- [ ] 验证：新增 Dart 通道测试；执行 `flutter analyze`、插件测试和 `flutter build hap --debug`。

### Phase 2：完善进度与历史迁移

- [ ] 用本机 Reader Kit SDK 的 `PageDataInfo` 字段确认 `pageOffset`、页码文本和章节信息的实际含义。
- [ ] 在事件中区分 `resourceIndex`、`startDomPos`、`pageOffset`、`pageFooterContent` 和 `pageHeaderContent`，不把页偏移误当总页数。
- [ ] 真机日志确认可计算字段后再计算 `progression`；无法可靠计算时保留 `null` 或不覆盖已有百分比。
- [ ] `ReadingHistoryManager` 新增按书籍合并 ReadKit 进度的方法，避免事件频繁创建重复记录。
- [ ] 仅接受 `engine=readkit`、`version=1` 的位置恢复；旧 Flureadium Locator 保留历史展示但从头开始阅读。
- [ ] 关闭事件写入最后一次有效快照并强制保存；异常事件不得覆盖有效进度。
- [ ] 验证：旧位置迁移、连续翻页去重、异常关闭和重新打开恢复测试。

### Phase 3：完成书签管理

- [ ] 原生页展示当前书籍的书签集合；初始集合从 Flutter 通过请求传入，或通过启动后的快照事件同步。
- [ ] 支持当前位置添加书签，使用 `ReadKitLocation` 作为去重依据。
- [ ] 支持删除书签并发送 `bookmarkRemoved`，Flutter 调用 `ReadingBookmarkManager.remove()`。
- [ ] 支持点击书签跳转，通过 `startPlay(resourceIndex, domPos)` 恢复位置。
- [ ] 增加书签空状态、重复位置提示和无效位置处理。
- [ ] 旧引擎书签不参与原生跳转；首次迁移时保留存储但明确标记不可恢复。
- [ ] 验证：书签添加、重复添加、删除、跳转、重启恢复和跨页面历史一致性测试。

### Phase 4：设置和窗口适配

- [ ] 将 `ReadKitSettings` 扩展为可回传的设置快照，支持 `settingsChanged`。
- [ ] `updateSettings` 调用原生 `setPageConfig()`，不再是空操作。
- [ ] 原生设置面板支持主题、字体、字号、行高和仿真/横滑翻页，并使用 `Value` 或局部状态更新。
- [ ] 复用官方 Demo 的 `display.on('change')` 和窗口尺寸监听，更新 `viewPortWidth`、`viewPortHeight`、`scaledDensity`。
- [ ] 系统深色模式、字体缩放、横竖屏、平板/2in1、多窗口变化时保存位置并重新排版。
- [ ] Flutter 收到设置变化后更新 `ReaderConfigService`，下次打开使用最新快照。
- [ ] 验证：设置实时生效、重启恢复、横竖屏、分屏和系统字体缩放测试。

### Phase 5：五格式真机回归

- [ ] 准备真实样本：一个 EPUB、TXT、MOBI、AZW、AZW3，记录文件大小、编码、来源和预期章节数。
- [ ] 在当前 HarmonyOS 设备上构建并安装 HAP；确认使用当前 API 23/24 设备进行验证。
- [ ] 逐格式验证详情页下载、文件校验、ReadKit 打开、首次排版和退出。
- [ ] 验证书架重开、阅读历史重开、位置恢复、目录跳转、书签操作和进度保存。
- [ ] 验证无效文件、空文件、HTML 错误页、路径失效、重复打开和 Reader Kit 初始化失败提示。
- [ ] 验证后台/前台、横竖屏、分屏、字体缩放和应用重启。
- [ ] 用 `hilog` 或设备日志确认没有重复 `pageShow`、事件串书、控制器重复释放或未处理异常。
- [ ] 设备验证完成后再决定是否扩大 `deviceTypes` 到 `tablet`、`2in1`。

### Phase 6：文档、清理与发布

- [ ] 更新 `README.md`：明确官方 ReadKit 是唯一小说阅读器，支持五种格式，不支持 PDF。
- [ ] 更新 `docs/ReaderKitDemo` 引用说明，记录 Talebook 插件桥接、最低系统/API 和设备限制。
- [ ] 删除本阶段构建生成的 `oh_modules`、临时日志和未跟踪过程文件；禁止提交生成依赖。
- [ ] 搜索确认源码、pubspec、lockfile、OHOS 配置和文档中无 `flureadium`、`ReadiumReaderWidget`、`/epub-reader`、`/pdf-reader`。
- [ ] 运行 `flutter analyze`、全量 `flutter test`、`flutter build hap --debug`。
- [ ] 仅暂存本阶段相关文件，保留用户无关的未提交改动。
- [ ] 提交信息使用中文规范：`feat: 完善ReadKit小说阅读体验`。

## 验证清单

### 自动化验证

```powershell
flutter analyze
flutter test
flutter build hap --debug
```

预期：三条命令均返回 0，HAP 生成于 `build/ohos/hap/entry-default-signed.hap`。

### 设备验证

```powershell
.\scripts\build-and-install.ps1 -SkipClean -Launch
```

验证结果必须记录：

- 设备型号、HarmonyOS 版本和 API 版本。
- 五种文件格式的打开结果。
- 目录、书签、进度、设置和退出恢复结果。
- 失败样本及对应错误码。
- 日志中是否出现重复事件、崩溃或资源释放异常。

## 回滚方案

1. 自动化验证失败：只回滚当前阶段提交，不恢复已经删除的 Flureadium；上一阶段提交保持可构建。
2. EventChannel 或 Ability 生命周期异常：先关闭新增事件转发，保留原生 ReadKit 基础打开能力，修复协议后再恢复事件。
3. 某一格式真机解析失败：保留下载文件和记录，将该格式标记为设备/版本不兼容，不重新引入旧阅读器。
4. 设置或窗口适配导致排版异常：回退动态设置和窗口监听，保留默认 `ReaderSetting` 与稳定位置协议。
5. 发现用户已有未提交改动：只操作本计划涉及文件，不使用破坏性 Git 命令，不覆盖 `AGENTS.md` 或其他用户改动。

## 风险与约束

- Reader Kit 的 `PageDataInfo` 字段语义必须以目标设备实际日志为准，不能把 `pageOffset` 直接当作总页数。
- `EventChannel` 只能传递可序列化数据，Reader Kit 控制器和 handler 必须始终由 ArkTS 持有。
- 原生 Ability 和 Flutter 页面之间不能依赖隐式全局状态完成多会话管理，sessionId 必须进入事件协议。
- 不支持 DRM/LCP、PDF、漫画/CBZ、网络服务端格式转换和跨设备同步。
- 构建会生成插件 `oh_modules`，它只能用于本地编译，不能进入 Git 提交。