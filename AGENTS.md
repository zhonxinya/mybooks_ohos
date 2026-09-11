## 开源库优先（HarmonyOS 原生栈）
- **代码实现优先引入成熟开源库**，避免手写 JSON 解析、HTTP/TLS、加密等基础能力。
- C++ 层已采用：[cJSON](https://github.com/DaveGamble/cJSON)（JSON）、[libcurl](https://curl.se/libcurl/)（HTTP/HTTPS GET/POST）。
- 预编译 `libcurl.so` 位于 `ohos/entry/libs/arm64-v8a/`，头文件见 `third_party/curl/include/`。
- 自行编译 curl 参考 `ohos/entry/src/main/cpp/third_party/README.md` 与 [tpc_c_cplusplus](https://gitee.com/openharmony-sig/tpc_c_cplusplus)。
- 新增依赖时：确认许可证（MIT/Apache-2.0 等）、是否已有 HarmonyOS 移植/ohpm 包，再 vendoring 源码。

## 编码前思考
- 明确假设，不确定时询问而非猜测。
- 存在歧义时，列出多种解释，不默默选定单一方案。
- 如果任务有明显更简单的做法，直接指出优化思路。
- 发现代码矛盾、逻辑不一致时及时暂停，请求信息澄清。

## 简洁优先
- 用最少的代码解决问题，拒绝冗余实现。
- 不为一次性需求创建抽象层、复杂架构。
- 不盲目增加扩展性、可配置性，应对“未来可能用到”的场景。
- 若代码可大幅精简，主动重写优化。
- 校验标准：以资深工程师视角判断，代码若过于复杂，立即简化。

## 精准修改
- 仅修改与当前任务直接相关的代码内容。
- 不顺手优化相邻代码、注释、排版格式。
- 不重构原本可以正常运行的代码模块。
- 严格匹配项目现有代码风格，保留原有编码习惯。
- 因本次修改产生的无效导入、废弃变量，可直接删除。
- 发现项目中原有的死代码、冗余内容，仅做文字提醒，不擅自删除。

## 目标驱动执行
- 执行任务前，定义清晰、可落地的成功标准。
- 将“修复Bug”转化为：编写用例复现问题，再调试至用例正常通过。
- 将“新增校验功能”转化为：针对异常输入编写测试用例，保证全部通过。
- 将“代码重构”转化为：完成重构后，确保原有所有测试用例正常运行。
- 多步骤复杂任务，先输出简短执行计划，同时标注每一步的验证方式。

## 核心原则
- UI 线程一帧超过 16ms 就会掉帧；优化应聚焦减少 build、layout、paint 开销。
- 优先靠 Widget 树设计而不是手动调优。
- 不允许使用长命令

### 10 个可落地技巧
1. **Isolate 处理重计算**：JSON 解析、图片/音频/视频处理、大列表过滤、数据库读取等同步耗时操作应使用 `Isolate.run` 或长生命周期 Isolate，避免阻塞 UI 线程。
2. **列表懒加载与固定高度**：长列表使用 `ListView.builder` / `ListView.separated`；若子项高度固定，设置 `itemExtent` 让 Flutter 跳过 intrinsic 测量。
3. **状态更新局部化**：避免在高处调用 `setState`；使用 `ValueNotifier + ValueListenableBuilder`、`AnimatedBuilder`、`context.select` 等方式只刷新变化子树。
4. **图片解码与缓存**：使用 `cacheWidth` / `cacheHeight` 让 Flutter 按 DPR 和显示尺寸解码；尽量复用 `AuthImage`/`CachedNetworkImage` 等带磁盘/内存缓存的组件；SVG 大图避免在主线程逐帧解析。
5. **RepaintBoundary 隔离重绘**：把频繁变化的小区域（进度指示器、工具栏、动画卡片）用 `RepaintBoundary` 包裹，避免整页重绘。
6. **谨慎使用 Opacity / Clip / ShaderMask / ColorFiltered**：这些 Widget 容易触发 `saveLayer()` 创建离屏缓冲；优先使用半透明颜色 `.withOpacity()` 代替 `Opacity` Widget，用圆角容器/裁剪路径替代过度裁剪。
7. **const 构造函数**：纯展示 Widget 尽量 `const`，让 Flutter 跳过等价子树重建。
8. **优先 StatelessWidget 而非方法**：把 `_buildXxx()` 方法拆成独立 `StatelessWidget` 或 `StatefulWidget`，配合 `const` 减少 rebuild 范围。
9. **动画优化**：使用 `AnimatedBuilder`、`TweenAnimationBuilder`，避免在 `setState` 中逐帧重建整个 Widget 树；避免在 `build()` 里创建新的 `Tween`/`AnimationController`。
10. **输入防抖与避免重复请求**：搜索框、进度同步、滚动监听等使用 `debounce` / `throttle`；避免在 `build()` 中发起网络请求或做复杂计算。

### 本项目已落地对应
- `context.watch` → `context.select`（首页、音乐、阅读器等）。
- `MediaQuery.of(context)` → `MediaQuery.sizeOf` 等细粒度 API（epub_reader_page）。
- 阅读器页码/工具栏改用 `ValueNotifier + ValueListenableBuilder`。
- 通知页已读状态改用 `ValueNotifier + ValueListenableBuilder`，避免整页 setState。
- 阅读器控制面板所有状态改用 `ValueNotifier`，Slider/Tab 切换不再整页重建。
- `PhotoViewGallery`、`PDFView` 外层加 `RepaintBoundary`。
- `Image.network` 统一替换为带缓存的 `AuthImage`。
- 通知页 `Opacity` Widget 改为 `Card`/`ListTile` 颜色与 `textColor`。
- 列表页改用 `ListView.builder` 并设置 `itemExtent`（bookshelf 列表页）。
- 移除 `AnimatedOpacity`/`AnimatedSwitcher`（splash_screen, splash_app）。
- 多个页面 `ListView(` 改 `ListView.builder`（settings_page, my_books_page, kavita_series_detail_page, tachidesk_manga_detail_page, extra_services_page, reading_books_page, profile_page）。

### 检查清单（新增/修改 UI 时自查）
- [ ] 是否使用了 `const` 构造函数？
- [ ] 列表是否使用 `builder` 并尽可能设置 `itemExtent`？
- [ ] `setState` 是否只放在真正需要重建的子树？
- [ ] 是否存在 `Opacity`/`Clip`/复杂 Shader 可替换为简单颜色或 `RepaintBoundary`？
- [ ] 图片是否设置了 `cacheWidth`/`cacheHeight` 或使用缓存组件？
- [ ] `build()` 中是否没有复杂计算、JSON 解析、网络请求？
- [ ] 动画/进度更新是否没有导致整页重建？

## 参考文档: Flutter 官方性能最佳实践 (https://docs.fluttercn.cn/perf/best-practices)

### 关键原则
1. **最小化 saveLayer 调用**: `saveLayer()` 分配离屏缓冲区,触发渲染目标切换,对移动端 GPU 吞吐量干扰严重。以下组件容易触发 saveLayer:
   - `Opacity`(用半透明颜色 `.withValues(alpha:)` 替代)
   - `ShaderMask` / `ColorFilter`
   - `Chip`(当 `disabledColorAlpha != 0xff` 时)
   - `Text`(当存在 `overflowShader` 时)
   - 调试:在 DevTools 中勾选 `checkerboardOffscreenLayers` 可可视化 saveLayer 调用

2. **最小化不透明度和裁剪**:
   - 半透明颜色直接绘制比 `Opacity` Widget 更快
   - 图片淡入用 `FadeInImage`(基于 GPU 片元着色器),不用 `Opacity` 动画
   - 裁剪用 `ClipRRect`/`ClipRect` 而非 `ClipPath`

3. **控制 build() 开销**:
   - 避免在 `build()` 中执行昂贵操作(JSON 解析、正则、网络请求)
   - 拆分为小组件,通过 `const` 构造函数让 Flutter 跳过等价子树重建
   - `setState()` 限制在真正需要变化的子树,避免在树的高层调用

4. **高效构建字符串**: 循环拼接字符串用 `StringBuffer` 而非 `+` 运算符

5. **避免 IntrinsicHeight/IntrinsicWidth**: 这些组件强制 Flutter 进行两次布局传递,开销大

### 本项目已落地总结
| 实践 | 状态 | 关键位置 |
|------|------|----------|
| `context.select` 细粒度订阅 | ✅ 全项目覆盖 | pdf_reader_page, music_home_page, music_player_page |
| `MediaQuery.sizeOf` | ✅ | reader_control_panel |
| `ValueNotifier + ValueListenableBuilder` | ✅ | Page indicator, overlay page, showBar |
| `RepaintBoundary` | ✅ | PhotoViewGallery, PDFView, CBZ 页面 |
| `const` 构造函数 | ✅ 所有 Widget | 30+ Widget 类已全部 const |
| `itemExtent` 列表 | ✅ | Catalog/Bookmark/History/Album/Song 列表 |
| `ListView.builder` 代替 `ListView()` | ✅ | 所有长列表 |
| 移除 `Opacity` | ✅ | 通知页、阅读器特效已替换 |
| 章节预加载(CachingResource) | ✅ | Iridium chapter preloading |
| 漫画图片预加载(precacheImage) | ✅ | CBZ/Kavita/Tachidesk(范围 3 页) |
| 设置内存缓存 | ✅ | ReaderSettingsStorage.loadAll() |
| `AnimatedSwitcher`→`if/else` 立即切换 | ✅ | EPUB/MOBI/TXT/PDF 加载页 |
| Isolate 处理重 I/O | ✅ | (TxtReaderEngine 移除前已实现) |

### 检查清单补充
- [ ] 是否避免了 `saveLayer` 触发组件(`Opacity`/`ShaderMask`/`ColorFilter`)?
- [ ] 是否使用了 `StringBuffer` 而非 `+` 拼接循环字符串?
- [ ] 列表项高度是否固定并设置了 `itemExtent`?

## 分页机制优化要点

### 核心原则
- 避免重复请求：使用防抖/节流防止快速滚动触发多次加载
- 统一阈值：使用统一的滚动触发阈值，避免魔法数字
- 错误处理：加载更多失败应显示 SnackBar 并正确回退页码
- 预加载：在接近底部时提前触发加载，减少用户等待

### 已落地优化
| 优化项 | 状态 | 关键位置 |
|--------|------|----------|
| 统一分页常量 | ✅ | lib/utils/pagination_constants.dart |
| 统一滚动阈值 | ✅ | 所有分页页面使用 PaginationConstants.loadMoreScrollThreshold (500px) |
| 分页防抖 | ✅ | 所有分页页面使用 PaginationConstants.loadMoreDebounceMs (500ms) |
| TalebookProvider _hasMore 修复 | ✅ | 基于返回数量判断而非 total 字段 |
| meta_book_list_page 分页 | ✅ | 添加 ScrollController、_currentPage、_hasMore、_loadMore |
| admin_book_list_page 加载更多 | ✅ | 添加 ScrollController、_loadMore、滚动监听 |
| 统一错误处理 | ✅ | 所有页面加载更多失败显示 SnackBar |

### 分页页面清单
- lib/pages/books/books_tab.dart: 书城全部书籍
- lib/pages/talebook/book_list_page.dart: 热门/最近书籍
- lib/pages/talebook/talebook_book_search_page.dart: Talebook 搜索
- lib/pages/talebook/meta_book_list_page.dart: 元数据书籍列表
- lib/pages/talebook/admin_book_list_page.dart: 管理员书籍列表
- lib/pages/kavita/kavita_history_page.dart: Kavita 阅读历史

### 检查清单（新增/修改分页时自查）
- [ ] 是否使用了 PaginationConstants 中的常量而非魔法数字？
- [ ] 是否添加了防抖机制（_lastLoadTime）？
- [ ] 加载更多失败时是否显示 SnackBar？
- [ ] 失败时是否正确回退页码？
- [ ] _hasMore 判断是否基于返回数量而非 total 字段？
- [ ] 是否在 dispose 中正确释放 ScrollController？
- [ ] `context.select` 是否只选择了需要监听的字段而非整个对象?
- [ ] Widget 拆分是否合理,避免单一超大 `build()`?

## 参考文档: Flutter 官方 Isolate 并发指南 (https://docs.fluttercn.cn/perf/isolates)

### 核心原则
- 所有 Dart 代码运行在 Isolate 中,每个 Isolate 拥有独立内存,通过消息通信
- 主 Isolate 负责 UI 渲染(60fps),耗时的同步计算应卸载到辅助 Isolate
- 超过帧间隙(16ms@60Hz)的同步操作都应该考虑使用 Isolate

### 适用场景
1. **短生命周期 Isolate** (`Isolate.run`): 一次性重计算,返回结果后自动退出
   - JSON 解码/编码(大型列表)
   - 图片/音频/视频处理(压缩、裁剪、格式转换)
   - 复杂列表过滤、排序、搜索
   - 大型文件 I/O 解析
2. **长生命周期 Isolate** (`Isolate.spawn` + `ReceivePort`/`SendPort`): 需要反复交互的后台工作线程
   - 数据库持续读写
   - 推送通知处理
   - 音频流处理
   - FFI 调用需要异步支持的场景

### 消息传递
- `SendPort.send()`: 发送时复制可变消息(发送方和接收方各一份)
- `Isolate.exit()`: 发送方退出时转移消息所有权(零拷贝,更高效)
- `Isolate.run` 和 `compute` 底层使用 `Isolate.exit`
- 不可变对象(String/不可修改的字节流)通过引用传递而非复制

### 平台插件限制
- 主 Isolate 创建的 `MethodChannel` 等平台插件不能在辅助 Isolate 中使用
- Dart 侧的资源(rootBundle、dart:ui)不能在辅助 Isolate 中访问
- 需要平台插件时,必须在主 Isolate 中执行,或通过消息传递结果

### 本项目已落地对应
| 实践 | 状态 | 关键位置 |
|------|------|----------|
| `Isolate.run` JSON 解码 | ✅ | (TxtReaderEngine 移除前实现) |
| 封面图片解码 Isolate | ✅ | cover_service.dart:52(Iridium 内部) |
| DownloadManager 排序缓存 | ✅ | getBooksByType 缓存排序结果避免 build 重复排序 |
| `jsonEncode` collection-for | ✅ | reading_history_manager / download_manager |
| 列表过滤/排序 build 外预计算 | ✅ | 避免在 itemBuilder/build 中同步操作 |

### Isolate 相关检查清单
- [ ] 超过 16ms 的同步操作是否考虑 `Isolate.run`?
- [ ] JSON 解码是否在 async 方法中? 大型列表是否用 `Isolate.run`?
- [ ] 列表过滤/排序是否缓存结果而非每次 build 重复计算?
- [ ] `get` getter 中是否有同步排序/过滤操作(应在 `_records` 变更时预计算)?
- [ ] SharedPreferences 的 `jsonDecode`/`jsonEncode` 是否在 async 方法中?
- [ ] 平台插件/`dart:ui`/`rootBundle` 是否在 Isolate 中被访问(应避免)?

## 参考文档: Flutter 性能 FAQ (https://docs.fluttercn.cn/perf/faq)

### 关键要点
1. **高开销操作**(触发 `saveLayer` 或离屏渲染):
   - `Opacity` Widget → 用半透明颜色 `.withValues(alpha:)` 替代
   - `Clip.antiAliasWithSaveLayer` → 用 `ClipRRect`/`ClipRect`(不触发 saveLayer)替代
   - `ImageFilter` → 谨慎使用,每帧触发离屏渲染
   - `ShaderMask` / `ColorFilter` → 同属 saveLayer 触发组件

2. **调试 Widget 重建**:
   - 设置 `debugProfileBuildsEnabled = true`(在 `widgets/debug.dart` 中),在 DevTools Timeline 中可视化 build 耗时
   - IntelliJ 勾选 "Track widget rebuilds" 可视化重建热点
   - 用 `Timeline.startSync`/`finish` 追踪 `performRebuild`

3. **性能分析工具**:
   - DevTools Performance 视图:追踪帧构建/渲染/光栅化耗时
   - Perfetto(https://ui.perfetto.dev):系统级追踪,查看 GPU/CPU 帧边界
   - Android systrace: `adb systrace` 捕获系统跟踪
   - speedscope(https://www.speedscope.app):火焰图分析热点函数
   - DevTools CPU Profiler:定位主 Isolate 热点函数

4. **修复昂贵异步函数阻塞 UI**:
   - 使用 `compute()` / `Isolate.run` 将重型计算卸载到辅助 Isolate
   - 参见上文 Isolate 并发指南

5. **查询显示刷新率**: Flutter engine 协议扩展 `_flutter.getDisplayRefreshRate`

### 本项目已落地对应
| 实践 | 状态 | 关键位置 |
|------|------|----------|
| `Opacity` 已移除 | ✅ | 通知页、阅读器特效已用半透明颜色替代 |
| `Clip.antiAliasWithSaveLayer` | ✅ 未使用 | 全局搜索无命中 |
| `ImageFilter` | ✅ 未使用 | 全局搜索无命中 |
| `ShaderMask` | ✅ 仅骨架屏一处已知取舍 | skeleton_base.dart:69 |
| debugProfileBuildsEnabled | ⚠️ 分析时使用 | 可在 DevTools 中动态启用 |

### FAQ 检查清单
- [ ] 是否存在 `Opacity`/`ImageFilter`/`Clip.antiAliasWithSaveLayer` 等触发 `saveLayer` 的组件?
- [ ] 是否使用 DevTools Performance 视图或 systrace 分析过帧率?
- [ ] 超过 16ms 的异步操作是否用了 `compute()` / `Isolate.run` 卸载?
- [ ] IntelliJ "Track widget rebuilds" 是否确认无过度重建?
- [ ] `ShaderMask`/`ColorFilter` 是否有必要(能否用简单颜色/渐变替代)?