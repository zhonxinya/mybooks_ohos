# 联网引用元数据搜索（Refer）设计

> 日期：2026-09-06  
> 状态：待用户审阅  
> 范围：增强鸿蒙 `ReferResultPage` + `TalebookApi.searchRefer`  
> 完成度：可编辑搜索（title/isbn/publisher）+ 体验完善（错误提示、简介预览、加载态）

## 1. 背景与目标

详情页「引用信息」已能打开 `ReferResultPage` 并按书名调用 `GET /api/book/:id/refer`，支持应用（全部/仅元数据/仅封面）与重置。缺口：

1. 服务端支持 `title` / `isbn` / `publisher`，客户端目前几乎只传书名，无法改关键词重搜。
2. `searchRefer` 在 `err !== ok` 时直接返回空数组，超时/失败信息丢失。
3. 结果卡缺少简介预览与明确失败态。

成功标准：

- 用户可编辑书名、ISBN、出版社后点击「搜索」重新拉取结果。
- 超时、失败时展示服务端 `msg`（或可读中文），并提供重试。
- 结果卡可查看简介；应用/重置行为与现网一致。
- `scripts/build-hap.ps1` 编译通过。

## 2. 非目标

- 新建独立搜索页或拆成两页路由。
- 把搜索嵌进 `BookEditPage`。
- 修改 Admin 元数据源配置、新增数据源插件。
- AI 补全与本页混用。

## 3. API 变更

文件：`ohos/entry/src/main/ets/services/TalebookApi.ets`

### 3.1 返回类型

新增（或等价命名）：

```typescript
export interface ReferSearchResponse {
  err?: string;
  msg?: string;
  cached?: boolean;
  books: ReferBook[];
}
```

### 3.2 `searchRefer` 签名

```typescript
static async searchRefer(
  bookId: number,
  opts?: { title?: string; isbn?: string; publisher?: string },
): Promise<ReferSearchResponse>
```

- Query：非空时才附加 `title` / `isbn` / `publisher`。
- 解析服务端 JSON：保留 `err`/`msg`/`cached`；`books` 映射逻辑与现有一致。
- **不再**在 `err !== 'ok'` 时静默返回 `[]`；调用方根据 `err`/`msg`/`books` 决定 UI。

兼容：详情页旧调用 `searchRefer(id, title)` 改为 `searchRefer(id, { title })`。

## 4. UI（`ReferResultPage`）

### 4.1 状态

| 状态 | 字段 |
|------|------|
| 路由入参 | `bookId`；可选预填 `title` / `isbn` / `publisher` |
| 搜索表单 | `@State queryTitle` / `queryIsbn` / `queryPublisher` |
| 列表 | `entries: ReferBook[]` |
| 加载 | `loading` |
| 错误文案 | `errorMessage`（空结果与失败可共用，文案区分） |
| 缓存提示 | `fromCache` |
| 简介展开 | 按 index 或 `provider_value` 记录展开项 |
| 应用中 | `applying`（已有） |

### 4.2 布局

1. **搜索卡**：三个输入（书名 / ISBN / 出版社）+「搜索」主按钮。  
2. **提示行**：若 `fromCache` 显示「结果来自缓存」。  
3. **内容区**：  
   - loading → `LoadingState`  
   - 有错误且无书 → `EmptyState`（message + 重试）  
   - 有书 → 列表；若 `err` 为 timeout/failed 但仍有 fallback 书，顶部短提示 `msg`  
   - 无书无硬错误 →「未找到相关引用信息」+ 重试  
4. **结果卡**：封面、标题、作者、评分、来源；简介默认两行，点击「展开/收起」；整卡点击仍弹出应用菜单。  
5. **顶栏**：保留「重置」。

### 4.3 搜索行为

- `aboutToAppear`：用路由参数预填；若书名或 ISBN 非空则自动搜索一次。  
- 点「搜索」：trim 后调用 API；书名与 ISBN 皆空时 toast「请填写书名或 ISBN」且不请求（与服务端「不完整则查库」不同，显式搜索要求用户至少填一项，避免误触空搜）。  
- 应用成功仍 `router.back()`。

### 4.4 入口传参（`BookDetailPage`）

跳转 `ReferResultPage` 时尽量传入：

```typescript
params: {
  bookId: this.bookId,
  title: this.title,
  isbn: this.isbn,       // 若详情已有字段
  publisher: this.publisher,
}
```

若某字段详情页尚无，仅传已有字段。

## 5. 文件清单

| 文件 | 变更 |
|------|------|
| `TalebookApi.ets` | `ReferSearchResponse`；`searchRefer` 改签名与解析 |
| `ReferResultPage.ets` | 搜索表单、错误/缓存/简介展开 |
| `BookDetailPage.ets` | 跳转 params 补全（若字段可用） |

## 6. 验收清单

- [ ] 可改书名/ISBN/出版社后重搜  
- [ ] 超时/失败显示可读提示并可重试  
- [ ] 有 fallback 结果时仍能列表展示并看到警告文案  
- [ ] 简介可展开；应用三种模式与重置可用  
- [ ] 详情入口预填合理  
- [ ] HAP 编译通过  

## 7. 风险

- 联网搜索可能较慢（服务端默认约 60s）；保持 loading，勿重复连点（搜索按钮在 loading 时禁用）。  
- ArkTS 禁止结构类型：`ReferSearchResponse` 与页面状态显式声明，避免匿名对象字面量作类型。
