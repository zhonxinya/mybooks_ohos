# 鸿蒙客户端 API 对照（MyBooks / Talebook WebAPI）

> 对照来源：`docs/mybooks/document/WebAPI.md` + `docs/mybooks/webserver/handlers` 路由，与上游 `docs/talebook/webserver/handlers` 路由；鸿蒙端 `TalebookApi.ets` / `BookListApi.ets` / `BookUploadService.ets` / `TalebookService.ets` + `ServerProfile.ets` + C++ NAPI（`mybooks_core`）。
>
> 生成日期：2026-09-06（2026-09-12 补充服务端兼容层；同日补充原生核心与 talebook 专有功能 UI）
>
> 状态：`已实现` = 有封装；`未实现` = 服务端有、客户端未见；`非移动端优先` / `资源路径` = 通常不必在鸿蒙 JSON API 层封装。

## 服务端兼容层（2026-09-12）

客户端同时支持两套服务端，差异集中在 `ohos/entry/src/main/ets/services/ServerProfile.ets`（抽象类 + 两套子类），其余 ArkTS 代码只依赖抽象名，新增服务端 = 新增一个 `ServerProfile` 子类。

| 服务端 | 参考源码 | 全部书籍端点 | 元数据末位键 | 有声书端点 |
|---|---|---|---|---|
| MyBooks（PoxenStudio/mybooks） | `docs/mybooks/` | `/api/all` | `language` | `/api/audiobooks` |
| Talebook（talebook/talebook） | `docs/talebook/` | `/api/library` | `format` | `/api/audios` |

两套服务端共用同一个 native 模块 `ohos/mybooks_core`（`libmybooks_core.so`）的 HTTP 通道：
`talebookGet` / `talebookPost` / `talebookPostForm` / `talebookPatch` / `talebookPut` / `talebookDelete` / `talebookDeleteWithBody` / `talebookUpload*`。

> `talebookPatch` 用于 talebook 回收站（`PATCH /api/admin/trash`）；`talebookPut` 用于标注更新
> （`PUT /api/book/{id}/annotations/{aid}`）与书源编辑（`PUT /api/admin/booksource`）。

**选择方式**：设置 → 服务器配置 → 服务端类型下拉；持久化于偏好键 `server_kind`，启动时由 `TalebookService.applyLocalConfig()` 恢复为当前 `ServerProfile`。

### 已适配差异

| 差异项 | 处理方式 |
|---|---|
| 列表分页参数 | 两端 ListHandler 系只识别 `start`（偏移）+ `size`（每页），统一由 `ServerProfile.listQuery` 生成 |
| 全部书籍列表 | `ServerProfile.allBooksPath`（/api/all ↔ /api/library） |
| 管理端书籍列表 | `adminBooksPath` + `adminBooksQuery`（mybooks start/size；talebook page/num） |
| 元数据键 | `metaTypes` + `resolveMetaType`（language ↔ format） |
| 有声书列表 | `audiobooksPath` |
| 回收站 | `trashBooksPath` / `trashRestore` / `trashPurge`（mybooks：POST + `book_ids`；talebook：PATCH/DELETE `/api/admin/trash` + `idlist` + `confirm`） |
| 系统日志 | `adminSyslogPath`（`/api/admin/syslog` ↔ `/api/admin/log`） |
| 能力门控 | `ServerFeature` 枚举 + `supports()`；页面入口按能力显隐（如 talebook 下不显示工具箱/资源导航/评论审核/管理概览/求书期望/我的留言，实体书列表给出不支持提示） |

### 功能 UI 覆盖（2026-09-12 第二轮）

本轮为「原生核心已封装但无页面」与「talebook 上游专有能力」补齐 UI。新增页面均按 `ServerFeature` 门控，
不支持的服务端整页显示 `EmptyState` 且不发起请求。

| 功能组 | 服务端 | 页面（路由） | API 服务文件 |
|---|---|---|---|
| 数据同步 | mybooks | `SyncPage` | `SyncApi` |
| 批量添加实体书 | mybooks | `AdminBatchAddPage` | `AdminImportApi` |
| 有声书导入 | mybooks | `AdminAudioImportPage` | `AdminImportApi` |
| TXT 读取/解析/路径/位置 | mybooks | `TxtBookPage` | `AdminImportApi` |
| 作者/出版商元数据 | mybooks | `AuthorMetaPage` | `AuthorMetaApi` |
| 书内标注（全部 / 单书） | talebook | `AnnotationsPage`、`BookAnnotationsPage` | `AnnotationApi` |
| 主题 | talebook | `ThemesPage` | `ThemeApi` |
| 人机验证 | talebook | （登录/注册/重置表单内嵌） | `CaptchaApi` + `components/CaptchaField` |
| 书架 | talebook | `ShelfPage` | `ShelfApi` |
| 阅读进度/可见范围/媒体类型 | talebook | `ReadingProgressPage` | `ShelfApi` |
| 在线书库 | talebook | `OnlineLibraryPage` | `ShelfApi` |
| 漫画阅读 | talebook | `ComicReaderPage` | `ComicApi` |
| 网络书库 | talebook | `NetworkLibraryPage`、`NetworkBookDetailPage` | `NetworkLibraryApi` |
| 书源管理 | talebook | `BookSourceManagePage` | `BookSourceApi` |
| 插件中心 | talebook | `AdminPluginsPage` | `AdminPluginsApi` |
| 扫描与导入 | talebook | `AdminScanPage` | `AdminScanApi` |
| OPDS 源 | talebook | `AdminOpdsPage` | `AdminOpdsApi` |
| 服务端维护 | talebook | `AdminMaintenancePage` | `AdminMaintenanceApi` |

入口位置：`数据同步/网络书库/我的书架/在线书库` 与各管理项已统一收进「设置」页的**可折叠分组**（默认折叠）；
`服务端主题` 在「设置 → 外观」；
`书内标注/TXT 工具/阅读进度与属性/漫画阅读` 在书籍详情的「更多」面板；`我的标注` 在个人中心。

### 尚未适配

- talebook 管理端 OPDS 源的**增/改/删**：上游为 `POST/PUT/DELETE /api/admin/opds/sources`，本轮仅实现列表浏览（`PUT` 通道已具备，如需要可补）。
- talebook 极验（geetest）型验证码：需浏览器 JS SDK，`CaptchaApi.isEnabled` 仅对 `image` 型返回 true。
- 在线书库「连载状态」写接口 `/api/network/status`（仅过渡命名空间存在），未封装。
- 上游 `/api/annotations`（Delete）为按 `source_*` 清理外部来源，非通用删除，未实现。

> ⚠️ 以上 talebook 分支均**未经运行期验证**（当前环境无可用的 talebook 服务端实例与 HarmonyOS 设备，
> 仅完成编译级验证）；mybooks 分支行为保持既有实现。
>
> 标注更新与书源编辑已改用 native `talebookPut` 直发上游 `PUT` 端点（不再走等价绕过实现）。
> 上游 `/api/author/{name}/update`、`/api/publisher/{name}/update` 的 handler 调用了不存在的 `do_book_update`，
> 可能返回 HTTP 500（上游实现缺陷，非客户端问题）。

## 总览

| 指标 | 数量 |
|------|------|
| 服务端路由总数 | 256 |
| 已实现 | 215 |
| 未实现 | 5 |
| 非 JSON / 非移动端优先 | 35 |

### 客户端封装入口

| 层级 | 位置 | 职责 |
|------|------|------|
| ArkTS API 门面 | `ohos/entry/src/main/ets/services/TalebookApi.ets` | 大多数 `/api/*` typed 封装 |
| 书单 | `BookListApi.ets` | 书单 CRUD / 点赞 / 加书 |
| 上传 | `BookUploadService.ets` | 分片上传 `/api/book/upload/chunk` |
| 兼容门面 | `TalebookService.ets` | 部分能力走 C++ `api*`（如收藏） |
| C++ NAPI | `talebook_core` + `TalebookCoreService` | HTTP/Cookie、垃圾桶/导入/工具箱等 |

### 建议补齐优先级（未实现且移动端相关）

1. **用户认证补全**：`/api/access`、`/api/user/sign_up`、`/api/user/reset`、`/api/user/whoami`
2. **书籍动作**：`/api/book/{id}/delete`、整本 `/api/book/upload`、批量 `upload/batch*`
3. **同步**：`/api/sync` HTTP 已封装；`/api/sync/events` WebSocket 待接
4. **发现**：`tags/search` / `author/info` / meta list 已封装
5. **音频进阶**：conversion / collection / purchase 已封装
6. **工具箱**：管理类 + 各工具强类型方法 + 通用 toolboxGet/Post/Upload 已封装

## 01. 用户与认证

已实现 **14** / 未实现 **0** / 本组 **14**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/access` | AccessCode | ArkTS: TalebookApi.ets::getAccessStatus / submitAccessCode |
| 已实现 | `/api/active/(.*)/(.*)` | UserActive | ArkTS: TalebookApi.ets::userActivePath / activateUser（path helper；服务端重定向） |
| 已实现 | `/api/done/` | Done | ArkTS: TalebookApi.ets::oauthDonePath（资源路径/已提供 path helper） |
| 已实现 | `/api/user/active/send` | UserSendActive | ArkTS: TalebookApi.ets::sendActiveEmail |
| 已实现 | `/api/user/avatar` | UserAvatar | ArkTS: TalebookApi.ets::deleteExpectedItem, TalebookApi.ets::uploadAvatar |
| 已实现 | `/api/user/info` | UserInfo | ArkTS + C++: TalebookApi.ets::getUserInfo |
| 已实现 | `/api/user/new` | UserNew | ArkTS: TalebookApi.ets::createAdminUser |
| 已实现 | `/api/user/reset` | UserReset | ArkTS: TalebookApi.ets::resetPassword |
| 已实现 | `/api/user/sign_in` | SignIn | ArkTS + C++: TalebookApi.ets::signIn |
| 已实现 | `/api/user/sign_out` | SignOut | ArkTS + C++: TalebookApi.ets::signOut |
| 已实现 | `/api/user/sign_up` | SignUp | ArkTS: TalebookApi.ets::signUp |
| 已实现 | `/api/user/update` | UserUpdate | ArkTS: TalebookApi.ets::getSoledBooks, TalebookApi.ets::updateUserSettings |
| 已实现 | `/api/user/vip` | UserVipInfo | ArkTS: TalebookApi.ets::getVipInfo |
| 已实现 | `/api/user/whoami` | WhoAmI | ArkTS: TalebookApi.ets::whoAmI |

## 02. 用户消息/便签/设备/历史

已实现 **10** / 未实现 **0** / 本组 **10**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/user/devices` | UserDevices | ArkTS: TalebookApi.ets::getReleaseNotes, TalebookApi.ets::getUserDevices |
| 已实现 | `/api/user/expected` | UserExpectedItems | ArkTS: TalebookApi.ets::createMemo, TalebookApi.ets::getExpectedItems, TalebookApi.ets::createExpectedItem, TalebookApi.ets::deleteExpectedItem |
| 已实现 | `/api/user/history` | UserReadingHistory | ArkTS: TalebookApi.ets::searchSameTitleBooks, TalebookApi.ets::getOnlineReadingHistory |
| 已实现 | `/api/user/history/clear` | UserHistoryClear | ArkTS: TalebookApi.ets::getOnlineReadingHistory, TalebookApi.ets::clearOnlineReadingHistory |
| 已实现 | `/api/user/memo` | UserMemo | ArkTS + C++: TalebookApi.ets::updateUserSettings, TalebookApi.ets::getUserMemos, TalebookApi.ets::createMemo |
| 已实现 | `/api/user/messages` | UserMessages | ArkTS + C++: TalebookApi.ets::getMessages |
| 已实现 | `/api/user/messages/clear` | UserMessagesClear | ArkTS: TalebookApi.ets::clearUserMessages |
| 已实现 | `/api/user/pin` | PinItem | ArkTS: TalebookApi.ets::searchAuthors, TalebookApi.ets::pinItem |
| 已实现 | `/api/user/reading_stats` | UserReadingDashboard | ArkTS: TalebookApi.ets::getCurrentReadingBooks, TalebookApi.ets::getReadingDashboard |
| 已实现 | `/api/user/unpin` | UnpinItem | ArkTS: TalebookApi.ets::pinItem, TalebookApi.ets::unpinItem |

## 03. 图书基础

已实现 **57** / 未实现 **0** / 本组 **58**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/all` | RecentBook | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/authors/search` | AuthorSearch | ArkTS: TalebookApi.ets::getCategories, TalebookApi.ets::searchAuthors |
| 已实现 | `/api/book/([0-9]+)` | BookDetail | ArkTS: TalebookApi.ets::getBookDetail |
| 已实现 | `/api/book/([0-9]+)/addstamp` | BookAddStamp | ArkTS: TalebookApi.ets::addStamp |
| 已实现 | `/api/book/([0-9]+)/aifill` | BookAIFill | ArkTS: TalebookApi.ets::aiFillBook |
| 已实现 | `/api/book/([0-9]+)/category` | BookCategory | ArkTS: TalebookApi.ets::setBookCategory |
| 已实现 | `/api/book/([0-9]+)/convert` | BookConverter | ArkTS: TalebookApi.ets::convertBook |
| 已实现 | `/api/book/([0-9]+)/cover` | BookCover | ArkTS: TalebookApi.ets::uploadCover, TalebookApi.ets::generateDefaultCover |
| 已实现 | `/api/book/([0-9]+)/delete` | BookDelete | ArkTS: TalebookApi.ets::deleteBook |
| 已实现 | `/api/book/([0-9]+)/delete_format` | BookDeleteFormat | ArkTS: TalebookApi.ets::deleteFormat |
| 已实现 | `/api/book/([0-9]+)/edit` | BookEdit | ArkTS: TalebookApi.ets::editBook |
| 已实现 | `/api/book/([0-9]+)/favorite` | BookFavorite | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/book/([0-9]+)/filepath` | BookFilePath | ArkTS: TalebookApi.ets::getBookFilePath |
| 已实现 | `/api/book/([0-9]+)/location` | BookLocation | ArkTS: TalebookApi.ets::setBookLocation |
| 已实现 | `/api/book/([0-9]+)/mailto` | BookSendToMail | ArkTS: TalebookApi.ets::sendToMail |
| 已实现 | `/api/book/([0-9]+)/read` | BookRead | ArkTS: TalebookApi.ets::bookReadPath（path helper；Web 阅读器跳转） |
| 已实现 | `/api/book/([0-9]+)/reading_stats` | BookFormatReadingStats | ArkTS: TalebookApi.ets::getFormatReadingStats |
| 已实现 | `/api/book/([0-9]+)/readstate` | BookReadingState | ArkTS: TalebookApi.ets::setReadState |
| 已实现 | `/api/book/([0-9]+)/refer` | BookRefer | ArkTS: TalebookApi.ets::searchRefer, TalebookApi.ets::applyRefer, TalebookApi.ets::resetRefer |
| 已实现 | `/api/book/([0-9]+)/savemeta` | BookSaveMeta | ArkTS: TalebookApi.ets::saveBookMeta |
| 已实现 | `/api/book/([0-9]+)/send_to_device` | BookSendToDevice | ArkTS: TalebookApi.ets::sendToDevice |
| 已实现 | `/api/book/([0-9]+)/separate` | BookSperate | ArkTS: TalebookApi.ets::separateFormat |
| 已实现 | `/api/book/([0-9]+)/setsole` | BookSetSole | ArkTS: TalebookApi.ets::setSole |
| 已实现 | `/api/book/([0-9]+)/suggestion` | BookSuggestion | ArkTS: TalebookApi.ets::getBookSuggestions |
| 已实现 | `/api/book/([0-9]+)/tags` | BookTags | ArkTS: TalebookApi.ets::updateBookTags |
| 已实现 | `/api/book/([0-9]+)/topdf` | BookToPDF | ArkTS: TalebookApi.ets::convertBookToPdf |
| 已实现 | `/api/book/([0-9]+)/wants` | BookWantToRead | ArkTS: TalebookApi.ets::setWants |
| 已实现 | `/api/book/([0-9]+\..+)` | BookDownload | ArkTS: TalebookApi.ets::bookDownloadPath（path helper；二进制下载） |
| 已实现 | `/api/book/add` | BookAddByISBN | ArkTS: TalebookApi.ets::exchangeBookType, TalebookApi.ets::addBookByIsbn |
| 已实现 | `/api/book/category` | BookCategoryBatch | ArkTS: TalebookApi.ets::batchSetBookCategory |
| 已实现 | `/api/book/crop_cover` | BookCropCover | ArkTS: TalebookApi.ets::generateDefaultCover, TalebookApi.ets::cropCover, TalebookApi.ets::cropCovers |
| 已实现 | `/api/book/download_quota` | BookDownloadQuota | ArkTS: TalebookApi.ets::addStamp, TalebookApi.ets::getDownloadQuota |
| 已实现 | `/api/book/exchange_type` | BookExchangeType | ArkTS: TalebookApi.ets::getDownloadQuota, TalebookApi.ets::exchangeBookType |
| 已实现 | `/api/book/nav` | BookNav | ArkTS + C++: TalebookApi.ets::getBookNav |
| 已实现 | `/api/book/txt/parser` | BookTxtParser | ArkTS: TalebookApi.ets::parseTxtBook |
| 已实现 | `/api/book/update_tags` | BookUpdateTags | ArkTS: TalebookApi.ets::updateBooksTagsByTag |
| 已实现 | `/api/book/upload` | BookUpload | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/book/upload/batch` | BookUploadBatch | ArkTS+C++: TalebookApi.ets::uploadBookBatch |
| 已实现 | `/api/book/upload/batch/cancel` | BookUploadBatchCancel | ArkTS: TalebookApi.ets::cancelUploadBatch |
| 已实现 | `/api/book/upload/batch/status` | BookUploadBatchStatus | ArkTS: TalebookApi.ets::getUploadBatchStatus |
| 已实现 | `/api/book/upload/chunk` | BookUploadChunk | ArkTS: TalebookApi.ets::addBookByIsbn, TalebookApi.ets::uploadBookChunk |
| 已实现 | `/api/books/batch-remove-state` | BookStateBatch | ArkTS: TalebookApi.ets::unpinItem, TalebookApi.ets::batchRemoveState |
| 已实现 | `/api/categories` | BookCategories | ArkTS: TalebookApi.ets::cropCovers, TalebookApi.ets::getCategories |
| 已实现 | `/api/clear_rare_tags` | ClearRareTags | ArkTS: TalebookApi.ets::clearRareTags |
| 已实现 | `/api/favorites` | BookFavorite | ArkTS + C++: TalebookApi.ets::getFavorites |
| 已实现 | `/api/hot` | HotBook | ArkTS + C++: TalebookApi.ets::getHot |
| 已实现 | `/api/index` | Index | ArkTS + C++: TalebookApi.ets::getIndex, TalebookApi.ets::getReadingDashboard, TalebookApi.ets::getIndexHome |
| 已实现 | `/api/printbooks` | PrintBooks | ArkTS: TalebookService.ets::getMetaBooksAsync |
| 已实现 | `/api/read/txt/([0-9]+)` | TxtRead | ArkTS: TalebookApi.ets::readTxtContent |
| 已实现 | `/api/read-done` | BookReadDone | ArkTS: TalebookApi.ets::getWantsBooks, TalebookApi.ets::getReadDoneBooks |
| 已实现 | `/api/reading` | BookReading | ArkTS + C++: TalebookApi.ets::getReadingBooks |
| 已实现 | `/api/reading/stats` | BookReadingStats | ArkTS: TalebookApi.ets::deleteReview, TalebookApi.ets::getReadingStats, TalebookApi.ets::getCurrentReadingBooks |
| 已实现 | `/api/recent` | RecentBook | ArkTS + C++: TalebookApi.ets::getRecent |
| 已实现 | `/api/search` | SearchBook | ArkTS + C++: TalebookApi.ets::search, TalebookApi.ets::getBookSuggestions, TalebookApi.ets::searchSameTitleBooks |
| 已实现 | `/api/soledbooks` | BookSoled | ArkTS: TalebookApi.ets::getReadDoneBooks, TalebookApi.ets::getSoledBooks |
| 已实现 | `/api/tags/search` | TagSearch | ArkTS: TalebookApi.ets::searchTags |
| 已实现 | `/api/wants` | BookWantToRead | ArkTS: TalebookApi.ets::getIndexHome, TalebookApi.ets::getWantsBooks |
| 非移动端优先 | `/read/([0-9]+)` | BookRead | -: Web/Kindle/OPDS 场景 |

## 03b. 书单

已实现 **14** / 未实现 **0** / 本组 **14**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/book/([0-9]+)/booklists` | BookBookListsHandler | ArkTS: BookListApi.ets::getBookBooklists |
| 已实现 | `/api/booklist/([0-9]+)` | BookListDetailHandler | ArkTS: BookListApi.ets::getBooklistDetail |
| 已实现 | `/api/booklist/([0-9]+)/books/add` | BookListBooksAddHandler | ArkTS: BookListApi.ets::addBooks |
| 已实现 | `/api/booklist/([0-9]+)/books/remove` | BookListBooksRemoveHandler | ArkTS: BookListApi.ets::removeBook |
| 已实现 | `/api/booklist/([0-9]+)/delete` | BookListDeleteHandler | ArkTS: BookListApi.ets::deleteBooklist |
| 已实现 | `/api/booklist/([0-9]+)/like` | BookListLikeHandler | ArkTS: BookListApi.ets::toggleLike |
| 已实现 | `/api/booklist/([0-9]+)/sticky` | BookListStickyHandler | ArkTS: BookListApi.ets::setSticky |
| 已实现 | `/api/booklist/([0-9]+)/update` | BookListDetailHandler | ArkTS: BookListApi.ets::updateBooklist |
| 已实现 | `/api/booklist/([0-9]+)/view` | BookListViewHandler | ArkTS: BookListApi.ets::bumpView |
| 已实现 | `/api/booklist/create` | BookListCreateHandler | ArkTS: BookListApi.ets::createBooklist |
| 已实现 | `/api/booklists/homepage` | BookListHomepageHandler | ArkTS: BookListApi.ets::getHomepageBooklists |
| 已实现 | `/api/booklists/liked` | BookListLikedHandler | ArkTS: BookListApi.ets::getLikedBooklists |
| 已实现 | `/api/booklists/mine` | BookListMineHandler | ArkTS: BookListApi.ets::getMyBooklists |
| 已实现 | `/api/booklists/public` | BookListPublicHandler | ArkTS: BookListApi.ets::getPublicBooklists |

## 03c. 书评与社交

已实现 **7** / 未实现 **0** / 本组 **7**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/admin/book-reviews` | AdminBookReviews | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/book/([0-9]+)/review` | BookReviewHandler | ArkTS: TalebookApi.ets::getOwnReview, TalebookApi.ets::submitReview, TalebookApi.ets::deleteReview |
| 已实现 | `/api/book/([0-9]+)/reviews` | BookReviewListHandler | ArkTS: TalebookApi.ets::getBookReviews |
| 已实现 | `/api/book/([0-9]+)/social-stats` | BookSocialStatsHandler | ArkTS: TalebookApi.ets::getSocialStats |
| 已实现 | `/api/toolbox/epub_beautify/preview` | AdminEpubBeautifyPreview | ArkTS: TalebookApi.ets::epubBeautifyPreview |
| 已实现 | `/api/toolbox/review_book_language` | AdminReviewBookLanguage | ArkTS: TalebookApi.ets::reviewBookLanguage |
| 已实现 | `/api/toolbox/text_replace/preview` | AdminTextReplacePreview | ArkTS: TalebookApi.ets::textReplacePreview |

## 03d. 同步

已实现 **3** / 未实现 **1** / 本组 **4**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/sync` | SyncHandler | ArkTS: TalebookApi.ets::syncPull / syncPush |
| 未实现 | `/api/sync/events` | SyncWebSocketHandler | WebSocket 通道，需单独接（本批未做） |
| 已实现 | `/api/sync/import` | SyncImportHandler | ArkTS: TalebookApi.ets::syncImport |
| 已实现 | `/api/sync/import/clear` | SyncImportClearHandler | ArkTS: TalebookApi.ets::syncImportClear |

## 04. 元数据

已实现 **7** / 未实现 **0** / 本组 **7**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/(author|publisher|tag|rating|series|language)` | MetaList | ArkTS: TalebookApi.ets::getMetaList |
| 已实现 | `/api/(author|publisher|tag|rating|series|language)/(.*)` | MetaBooks | ArkTS: TalebookApi.ets::getBooksByMeta |
| 已实现 | `/api/author/(.*)/update` | AuthorBooksUpdate | ArkTS: TalebookApi.ets::updateAuthorBooks（302 重定向，parseJsonOrOk） |
| 已实现 | `/api/author/bio` | AdminAuthorBio | ArkTS: TalebookApi.ets::updateAuthorBio |
| 已实现 | `/api/author/info` | AuthorInfo | ArkTS: TalebookApi.ets::getAuthorInfo |
| 已实现 | `/api/author_avatar` | AuthorAvatarUploadHandler | ArkTS: TalebookApi.ets::uploadAuthorAvatar |
| 已实现 | `/api/publisher/(.*)/update` | PubBooksUpdate | ArkTS: TalebookApi.ets::updatePublisherBooks（302 重定向，parseJsonOrOk） |

## 05. 音频图书

已实现 **9** / 未实现 **0** / 本组 **9**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/audio/([0-9]+)` | AudioDetail | ArkTS: TalebookApi.ets::getAudioList |
| 已实现 | `/api/audio/([0-9]+)/([^/]+)` | AudioFile | ArkTS: TalebookApi.ets::audioFilePath（相对路径） |
| 已实现 | `/api/audio/([0-9]+)/cancel` | AudioConversionCancel | ArkTS: TalebookApi.ets::cancelAudioConversion |
| 已实现 | `/api/audio/([0-9]+)/conversion` | AudioConversion | ArkTS: TalebookApi.ets::getAudioConversionStatus / startAudioConversion |
| 已实现 | `/api/audio/([0-9]+)/delete` | AudioDelete | ArkTS: TalebookApi.ets::deleteAudio |
| 已实现 | `/api/audio/([0-9]+)/purchase` | AudioPurchase | ArkTS: TalebookApi.ets::purchaseAudio |
| 已实现 | `/api/audiobooks` | AudioBooks | ArkTS: TalebookApi.ets::getAudiobooks |
| 已实现 | `/api/audios/([0-9]+)/collection` | AudioCollection | ArkTS: TalebookApi.ets::createAudioCollectionDownload |
| 已实现 | `/api/audios/([0-9]+)/collection/download` | AudioCollectionDownloadFile | ArkTS: TalebookApi.ets::audioCollectionDownloadPath（相对路径） |

## 06. 管理员

已实现 **37** / 未实现 **9** / 本组 **46**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/admin/ai/test` | AdminAITestConnection | ArkTS: TalebookApi.ets::testAdminAI |
| 已实现 | `/api/admin/audio/test` | AudioTestConnection | ArkTS: TalebookApi.ets::testAudioConnection |
| 已实现 | `/api/admin/audio_import/run` | AudioImportRun | ArkTS: TalebookApi.ets::runAudioImport |
| 已实现 | `/api/admin/audio_import/status` | AudioImportStatus | ArkTS: TalebookApi.ets::getAudioImportStatus |
| 已实现 | `/api/admin/barcode` | BarcodeRecognition | ArkTS: TalebookApi.ets::recognizeBarcode |
| 已实现 | `/api/admin/batch_add/run` | BatchAddRun | ArkTS: TalebookApi.ets::runBatchAdd |
| 已实现 | `/api/admin/batch_add/status` | BatchAddStatus | ArkTS: TalebookApi.ets::getBatchAddStatus |
| 已实现 | `/api/admin/book/aifill` | AdminBookAIFill | ArkTS: TalebookApi.ets::aiFillAdminBooks |
| 已实现 | `/api/admin/book/epubconvert` | AdminBookConvertEpub | ArkTS: TalebookApi.ets::epubConvertAdminBooks |
| 已实现 | `/api/admin/book/fill` | AdminBookFill | ArkTS: TalebookApi.ets::fillAdminBooks |
| 已实现 | `/api/admin/book/list` | AdminBookList | ArkTS: TalebookApi.ets::getAdminBookList |
| 已实现 | `/api/admin/book/reset_cover` | AdminResetCover | ArkTS: TalebookApi.ets::resetAdminCover |
| 已实现 | `/api/admin/book/update_all_dynamic_cover` | AdminUpdateDynamicCover | ArkTS: TalebookApi.ets::updateAdminDynamicCover |
| 已实现 | `/api/admin/book/update_all_meta` | AdminUpdateAllMeta | ArkTS: TalebookApi.ets::updateAllAdminMeta |
| 已实现 | `/api/admin/book/update_title_sort` | AdminBookUpdateTitleSort | ArkTS: TalebookApi.ets::updateAdminTitleSort |
| 已实现 | `/api/admin/bookbarn/token/apply` | AdminBookbarnTokenApply | ArkTS: TalebookApi.ets::applyBookbarnToken |
| 已实现 | `/api/admin/books/delete` | AdminDeleteBooks | ArkTS: TalebookApi.ets::deleteAdminBooks |
| 已实现 | `/api/admin/books/save_meta` | AdminSaveMeta | ArkTS: TalebookApi.ets::saveAdminMetaToFiles |
| 已实现 | `/api/admin/clear/invalid/items` | ClearInvalidItems | ArkTS: TalebookApi.ets::clearAdminInvalidItems |
| 已实现 | `/api/admin/import/cancel` | ImportCancel | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/import/delete` | ImportDelete | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/import/list` | ImportList | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/import/run` | ImportRun | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/import/status` | ImportStatus | ArkTS: TalebookApi.ets::getImportStatus |
| 已实现 | `/api/admin/install` | AdminInstall | ArkTS: TalebookApi.ets::getInstallStatus / runInstall |
| 已实现 | `/api/admin/release/notes` | ReleaseNotes | ArkTS: TalebookApi.ets::uploadAvatar, TalebookApi.ets::getReleaseNotes |
| 已实现 | `/api/admin/resources` | AdminResources | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/restart` | AdminRestartServer | ArkTS: TalebookApi.ets::restartAdminServer |
| 已实现 | `/api/admin/settings` | AdminSettings | ArkTS: TalebookApi.ets::getAdminSettings, TalebookApi.ets::saveAdminSettings |
| 已实现 | `/api/admin/ssl` | AdminSSL | ArkTS+C++: TalebookApi.ets::uploadAdminSsl（talebookUploadFiles；需 native 重建） |
| 已实现 | `/api/admin/stamp` | AdminStamp | ArkTS: TalebookApi.ets::getStampStatus / uploadStamp |
| 已实现 | `/api/admin/syslog` | AdminSyslog | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/syslog/download` | AdminSyslogDownload | ArkTS: TalebookApi.ets::adminSyslogDownloadPath（资源路径） |
| 已实现 | `/api/admin/tasks/running` | AdminRunningTasks | ArkTS: TalebookApi.ets::getAdminRunningTasks |
| 已实现 | `/api/admin/testmail` | AdminTestMail | ArkTS: TalebookApi.ets::testAdminMail |
| 已实现 | `/api/admin/thanks/notes` | ThanksTo | ArkTS: TalebookApi.ets::getThanksNotes |
| 已实现 | `/api/admin/token` | AdminTokenHandler | ArkTS: TalebookApi.ets::generateAdminToken |
| 已实现 | `/api/admin/trash/books` | AdminTrashBooks | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/trash/books/purge` | AdminTrashBooksPurge | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/trash/books/restore` | AdminTrashBooksRestore | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/trash/clear` | AdminTrashClear | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/trash/size` | AdminTrashSize | C++ NAPI: TalebookCoreService / native |
| 已实现 | `/api/admin/update_author` | AdminUpdateAuthor | ArkTS: TalebookApi.ets::adminUpdateAuthor |
| 已实现 | `/api/admin/users` | AdminUsers | ArkTS + C++: TalebookApi.ets::getAdminUserList, TalebookApi.ets::updateAdminUser |
| 已实现 | `/api/library/stats` | LibraryStats | ArkTS: TalebookApi.ets::getLibraryStats |
| 已实现 | `/api/sysinfo` | AdminSysInfo | ArkTS: TalebookApi.ets::getSysInfo |

## 09. OPDS

已实现 **0** / 未实现 **0** / 本组 **5**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 非移动端优先 | `/opds/?` | OpdsIndex | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/opds/category/(.*)/(.*)` | OpdsCategory | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/opds/categorygroup/(.*)/(.*)` | OpdsCategoryGroup | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/opds/nav/(.*)` | OpdsNav | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/opds/search/(.*)` | OpdsSearch | -: Web/Kindle/OPDS 场景 |

## 10. 静态文件

已实现 **0** / 未实现 **0** / 本组 **10**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 资源路径 | `/(.*)` | web | -: 静态/封面资源 |
| 资源路径 | `/api/favicon/(.*)` | FaviconHandler | -: 静态/封面资源 |
| 资源路径 | `/get/(.*)/(.*)` | ImageHandler | -: 静态/封面资源 |
| 资源路径 | `/get/author/avatar/(.*)` | AuthorAvatarHandler | -: 静态/封面资源 |
| 资源路径 | `/get/extract/([0-9]+)/(.*)` | EpubReader | -: 静态/封面资源 |
| 资源路径 | `/get/pcover` | ProxyImageHandler | -: 静态/封面资源 |
| 资源路径 | `/get/progress/([0-9]+)` | ProgressHandler | -: 静态/封面资源 |
| 资源路径 | `/get/tool/([^/]+)/icon` | ToolIconHandler | -: 静态/封面资源 |
| 资源路径 | `/get/tool/([a-z0-9_]+)/assets/(.*)` | ToolFrontendAssetHandler | -: 静态/封面资源 |
| 资源路径 | `/get/tool/([a-z0-9_]+)/index\.html` | ToolFrontendIndexHandler | -: 静态/封面资源 |

## 11. Podcast

已实现 **0** / 未实现 **0** / 本组 **9**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 非移动端优先 | `/podcast/([a-zA-Z0-9]+)/book/([0-9]+)` | PodcastTokenBook | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/podcast/?` | PodcastIndex | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/podcast/all` | PodcastAll | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/podcast/audio/([0-9]+)/([a-zA-Z0-9]+)/(.+)` | PodcastAudioFile | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/podcast/author/(.+)` | PodcastAuthor | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/podcast/book/([0-9]+)` | PodcastBook | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/podcast/book/([0-9]+)/opml` | PodcastBookOpml | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/podcast/category/(.+)` | PodcastCategory | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/podcast/tag/(.+)` | PodcastTag | -: Web/Kindle/OPDS 场景 |

## 12. AI助手

已实现 **0** / 未实现 **1** / 本组 **1**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 未实现 | `/api/assistant/ws` | AssistantWebSocketHandler | - |

## 13. MCP

已实现 **0** / 未实现 **2** / 本组 **2**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 未实现 | `/api/mcp/health` | MCPHealthHandler | - |
| 未实现 | `/api/mcp/stream` | MCPHandler | - |

## 14. 工具箱
> 工具细接口均已提供强类型封装；通用 toolboxGet / toolboxPost / toolboxUpload 仍可用于扩展/未列路径。


已实现 **48** / 未实现 **0** / 本组 **48**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 已实现 | `/api/toolbox/([a-z0-9_]+)` | AdminToolUninstall | ArkTS: TalebookApi.ets::uninstallToolboxTool |
| 已实现 | `/api/toolbox/([a-z0-9_]+)/disable` | AdminToolDisable | ArkTS: TalebookApi.ets::disableToolboxTool |
| 已实现 | `/api/toolbox/([a-z0-9_]+)/enable` | AdminToolEnable | ArkTS: TalebookApi.ets::enableToolboxTool |
| 已实现 | `/api/toolbox/([a-z0-9_]+)/install` | AdminToolStoreInstall | ArkTS: TalebookApi.ets::installToolboxStoreTool |
| 已实现 | `/api/toolbox/([a-z0-9_]+)/update/upload` | AdminToolUpdateUpload | ArkTS: TalebookApi.ets::updateToolboxUpload |
| 已实现 | `/api/toolbox/author_clean` | AdminAuthorClean | ArkTS: TalebookApi.ets::authorClean |
| 已实现 | `/api/toolbox/bookbarn_acceptor/apply_token` | AdminBookBarnAcceptorApplyToken | ArkTS: TalebookApi.ets::bookbarnAcceptorApplyToken |
| 已实现 | `/api/toolbox/bookbarn_acceptor/set_collection_hour` | AdminBookBarnAcceptorSetCollectionHour | ArkTS: TalebookApi.ets::bookbarnAcceptorSetCollectionHour |
| 已实现 | `/api/toolbox/bookbarn_acceptor/status` | AdminBookBarnAcceptorStatus | ArkTS: TalebookApi.ets::bookbarnAcceptorStatus |
| 已实现 | `/api/toolbox/bookbarn_acceptor/toggle` | AdminBookBarnAcceptorToggle | ArkTS: TalebookApi.ets::bookbarnAcceptorToggle |
| 已实现 | `/api/toolbox/chinese_converter/convert` | AdminChineseConverterConvert | ArkTS: TalebookApi.ets::chineseConverterConvert |
| 已实现 | `/api/toolbox/chinese_converter/progress` | AdminChineseConverterProgress | ArkTS: TalebookApi.ets::chineseConverterProgress |
| 已实现 | `/api/toolbox/epub_beautify/bg_delete` | AdminEpubBeautifyBgDelete | ArkTS: TalebookApi.ets::epubBeautifyBgDelete |
| 已实现 | `/api/toolbox/epub_beautify/bg_meta` | AdminEpubBeautifyBgMeta | ArkTS: TalebookApi.ets::epubBeautifyBgMeta |
| 已实现 | `/api/toolbox/epub_beautify/bg_raw` | AdminEpubBeautifyBgRaw | ArkTS: TalebookApi.ets::epubBeautifyBgRawPath |
| 已实现 | `/api/toolbox/epub_beautify/bg_upload` | AdminEpubBeautifyBgUpload | ArkTS: TalebookApi.ets::epubBeautifyBgUpload / epubBeautifyBgUploadBuiltin |
| 已实现 | `/api/toolbox/epub_beautify/progress` | AdminEpubBeautifyProgress | ArkTS: TalebookApi.ets::epubBeautifyProgress |
| 已实现 | `/api/toolbox/epub_beautify/run` | AdminEpubBeautifyRun | ArkTS: TalebookApi.ets::epubBeautifyRun |
| 已实现 | `/api/toolbox/epub_fixer/fix` | AdminEpubFixerFix | ArkTS: TalebookApi.ets::epubFixerFix |
| 已实现 | `/api/toolbox/epub_split/chapters` | AdminEpubSplitChapters | ArkTS: TalebookApi.ets::epubSplitChapters |
| 已实现 | `/api/toolbox/epub_split/generate` | AdminEpubSplitGenerate | ArkTS: TalebookApi.ets::epubSplitGenerate |
| 已实现 | `/api/toolbox/formats_pruning/progress` | AdminFormatsPruningProgress | ArkTS: TalebookApi.ets::formatsPruningProgress |
| 已实现 | `/api/toolbox/formats_pruning/start` | AdminFormatsPruningStart | ArkTS: TalebookApi.ets::formatsPruningStart |
| 已实现 | `/api/toolbox/install/upload` | AdminToolInstallUpload | ArkTS: TalebookApi.ets::installToolboxUpload |
| 已实现 | `/api/toolbox/list` | AdminToolList | ArkTS: TalebookApi.ets::getAdminToolList |
| 已实现 | `/api/toolbox/merge_formats/merge` | AdminMergeFormatsMerge | ArkTS: TalebookApi.ets::mergeBookFormats |
| 已实现 | `/api/toolbox/mimo_tts/clone/audio` | AdminMimoTTSCloneAudio | ArkTS: TalebookApi.ets::mimoTtsCloneAudioPath |
| 已实现 | `/api/toolbox/mimo_tts/clone/delete` | AdminMimoTTSCloneDelete | ArkTS: TalebookApi.ets::mimoTtsCloneDelete |
| 已实现 | `/api/toolbox/mimo_tts/clone/list` | AdminMimoTTSCloneList | ArkTS: TalebookApi.ets::mimoTtsCloneList |
| 已实现 | `/api/toolbox/mimo_tts/clone/upload` | AdminMimoTTSCloneUpload | ArkTS: TalebookApi.ets::mimoTtsCloneUpload |
| 已实现 | `/api/toolbox/mimo_tts/config` | AdminMimoTTSConfig | ArkTS: TalebookApi.ets::mimoTtsGetConfig / mimoTtsDeleteConfig |
| 已实现 | `/api/toolbox/mimo_tts/convert` | AdminMimoTTSConvert | ArkTS: TalebookApi.ets::mimoTtsConvert |
| 已实现 | `/api/toolbox/mimo_tts/progress` | AdminMimoTTSProgress | ArkTS: TalebookApi.ets::mimoTtsProgress |
| 已实现 | `/api/toolbox/mimo_tts/prompt/delete` | AdminMimoTTSPromptDelete | ArkTS: TalebookApi.ets::mimoTtsPromptDelete |
| 已实现 | `/api/toolbox/mimo_tts/prompt/list` | AdminMimoTTSPromptList | ArkTS: TalebookApi.ets::mimoTtsPromptList |
| 已实现 | `/api/toolbox/mimo_tts/prompt/save` | AdminMimoTTSPromptSave | ArkTS: TalebookApi.ets::mimoTtsPromptSave |
| 已实现 | `/api/toolbox/mimo_tts/test` | AdminMimoTTSTest | ArkTS: TalebookApi.ets::mimoTtsTest |
| 已实现 | `/api/toolbox/minify_pdf/download` | AdminMinifyPdfDownload | ArkTS: TalebookApi.ets::minifyPdfDownloadPath |
| 已实现 | `/api/toolbox/minify_pdf/process` | AdminMinifyPdfProcess | ArkTS: TalebookApi.ets::minifyPdfProcess |
| 已实现 | `/api/toolbox/minify_pdf/progress` | AdminMinifyPdfProgress | ArkTS: TalebookApi.ets::minifyPdfProgress |
| 已实现 | `/api/toolbox/minify_pdf/upload` | AdminMinifyPdfUpload | ArkTS: TalebookApi.ets::minifyPdfUpload |
| 已实现 | `/api/toolbox/rare_book_downloader` | AdminRareBookDownloader | ArkTS: TalebookApi.ets::rareBookDownload |
| 已实现 | `/api/toolbox/store/index` | AdminToolStoreIndex | ArkTS: TalebookApi.ets::getToolboxStoreIndex |
| 已实现 | `/api/toolbox/text_replace/progress` | AdminTextReplaceProgress | ArkTS: TalebookApi.ets::textReplaceProgress |
| 已实现 | `/api/toolbox/text_replace/run` | AdminTextReplaceRun | ArkTS: TalebookApi.ets::textReplaceRun |
| 已实现 | `/api/toolbox/txt_encoding_fixer/analyze` | AdminTxtEncodingFixerAnalyze | ArkTS: TalebookApi.ets::txtEncodingFixerAnalyze |
| 已实现 | `/api/toolbox/txt_encoding_fixer/fix` | AdminTxtEncodingFixerFix | ArkTS: TalebookApi.ets::txtEncodingFixerFix |
| 已实现 | `/api/toolbox/txt_encoding_fixer/progress` | AdminTxtEncodingFixerProgress | ArkTS: TalebookApi.ets::txtEncodingFixerProgress |

## 15. TTS

已实现 **0** / 未实现 **1** / 本组 **1**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 未实现 | `/api/tts/edge` | EdgeTTSProxy | - |

## 16. WAP

已实现 **1** / 未实现 **0** / 本组 **11**

| 状态 | 路径 | Handler | 客户端 |
|------|------|---------|--------|
| 非移动端优先 | `/wap/?` | WapIndex | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/wap/authors` | WapAuthors | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/wap/categories` | WapCategories | -: Web/Kindle/OPDS 场景 |
| 已实现 | `/wap/favorites` | WapFavorites | C++ NAPI: TalebookCoreService / native |
| 非移动端优先 | `/wap/languages` | WapLanguages | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/wap/login` | WapLogin | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/wap/logout` | WapLogout | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/wap/reading` | WapReading | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/wap/search` | WapSearch | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/wap/wants` | WapWants | -: Web/Kindle/OPDS 场景 |
| 非移动端优先 | `/wap/welcome` | WapWelcome | -: Web/Kindle/OPDS 场景 |

## 附录：状态判定规则

1. ArkTS 源码出现对应 `/api/...`（含模板字面量）→ 已实现（ArkTS）。
2. C++ / `TalebookCoreService` 出现对应路径或专用包装 → 已实现（C++ NAPI）。
3. 收藏等仅经 `TalebookService.setFavorite` → 仍计已实现。
4. OPDS / Podcast / WAP / `/get/*` 默认非移动端优先或资源路径。
5. 本文不替代 `WebAPI.md` 的请求/响应字段说明。
