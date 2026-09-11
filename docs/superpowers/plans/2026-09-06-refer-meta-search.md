# Refer 元数据搜索 Implementation Plan

> **For agentic workers:** Execute task-by-task. Steps use checkbox syntax.

**Goal:** 增强 `ReferResultPage`：可编辑 title/isbn/publisher 搜索 + 错误/缓存/简介预览；`searchRefer` 返回完整 `ReferSearchResponse`。

**Architecture:** 就地改 API 与页面；详情页补传参。

**Tech Stack:** ArkTS / `TalebookApi` / 现有 `PageScaffold`、`AuthImage`、`StarRating`。

**Spec:** `docs/superpowers/specs/2026-09-06-refer-meta-search-design.md`

## Global Constraints

- 不新建页面；不嵌 BookEditPage；不改 Admin 元数据源。
- 书名与 ISBN 皆空时不发请求，toast 提示。
- 不自动 git commit（除非用户要求）。

---

### Task 1: TalebookApi.searchRefer

**Files:** Modify `ohos/entry/src/main/ets/services/TalebookApi.ets`

- [ ] Add `export interface ReferSearchResponse { err?: string; msg?: string; cached?: boolean; books: ReferBook[]; }`
- [ ] Change `searchRefer(bookId, opts?: { title?: string; isbn?: string; publisher?: string })` to append non-empty query params and return full response (map books as today; do not swallow err)

### Task 2: ReferResultPage UI

**Files:** Modify `ohos/entry/src/main/ets/pages/ReferResultPage.ets`

- [ ] Form state + search card; auto-search on appear if title or isbn set
- [ ] Handle err/msg/cached/empty/list; disable search while loading
- [ ] Card: comments expand/collapse; keep apply menu + reset

### Task 3: BookDetailPage params

**Files:** Modify `ohos/entry/src/main/ets/pages/BookDetailPage.ets`

- [ ] Pass isbn/publisher if available on page state when opening ReferResultPage

### Task 4: Build

- [ ] `powershell -NoProfile -File scripts/build-hap.ps1` → BUILD SUCCESSFUL
