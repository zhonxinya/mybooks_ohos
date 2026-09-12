import {
  PageScaffold, LoadingState, EmptyState, SearchBar, FilterChips, FilterChipItem,
  BookCatalogView, BookListItem, BookListItemData, PrimaryButton, TextButton, ChipButton,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import {
  NetworkLibraryApi, NetworkSourceItem, NetworkAvailability, NetworkBookItem,
  NetworkCategoryItem, NetworkSearchProgress, NetworkSearchFailure,
  NETWORK_CAPABILITY_BROWSE, NETWORK_SEARCH_MODE_TOP, NETWORK_SEARCH_MODE_ALL,
  NETWORK_SEARCH_MODE_CUSTOM,
  NETWORK_AVAILABILITY_NO_PLUGINS, NETWORK_AVAILABILITY_NO_SOURCES,
} from '../services/NetworkLibraryApi';

/** 搜索任务轮询间隔（上游为后台线程池任务，需轮询 status）。 */
const SEARCH_POLL_INTERVAL_MS: number = 2000;
/** 搜索任务轮询次数上限（超出后展示已返回结果并停止轮询）。 */
const SEARCH_POLL_MAX: number = 30;

/** 列表模式：尚未开始。 */
const LIST_MODE_IDLE: string = 'idle';
/** 列表模式：关键词搜索。 */
const LIST_MODE_SEARCH: string = 'search';
/** 列表模式：书源发现页浏览。 */
const LIST_MODE_EXPLORE: string = 'explore';

// ---- 底部面板模式（同一节点只能生效一个 bindSheet，故用单面板 + 模式分发） ----
const SHEET_SOURCE: string = 'source';
const SHEET_CATEGORY: string = 'category';

/** 结果去重键：`sourceId#bookUrl`（source_id 不含 `#`，拼接无二义性）。 */
function bookKey(item: NetworkBookItem): string {
  return `${item.sourceId}#${item.bookUrl}`;
}

/** 列表行副标题：来源 / 分类 / 最新章节 / 字数。 */
function bookSubtitle(item: NetworkBookItem): string {
  const parts: string[] = [];
  if (item.sourceName.length > 0) {
    parts.push(item.sourceName);
  }
  if (item.kind.length > 0) {
    parts.push(item.kind);
  }
  if (item.lastChapter.length > 0) {
    parts.push(`最新章节：${item.lastChapter}`);
  }
  if (item.wordCount.length > 0) {
    parts.push(item.wordCount);
  }
  return parts.join(' · ');
}

/**
 * 网络书库（talebook 专有）：书源搜索 → 结果列表 → 书籍详情（章节目录）→ 章节正文。
 *
 * 端点与响应结构见 `services/NetworkLibraryApi.ets`（逐项对照上游
 * `docs/talebook/webserver/handlers/network_library.py`）。
 * 搜索为「创建任务 + 轮询 status」异步模式；正文与保存流程见 `NetworkBookDetailPage`。
 */
@Entry
@Component
struct NetworkLibraryPage {
  @State sources: NetworkSourceItem[] = [];
  @State availability: NetworkAvailability | null = null;
  @State loading: boolean = true;
  @State loadError: string = '';
  @State keyword: string = '';
  @State searchMode: number = 0;
  @State searching: boolean = false;
  @State progressText: string = '';
  @State progressDone: number = 0;
  @State progressTotal: number = 0;
  @State failedSources: NetworkSearchFailure[] = [];
  @State rows: BookListItemData[] = [];
  @State loadingMore: boolean = false;
  @State hasMore: boolean = false;
  @State mode: string = LIST_MODE_IDLE;
  @State showSheet: boolean = false;
  @State sheetMode: string = SHEET_SOURCE;
  @State selectedKeys: string[] = [];
  @State categorySourceKey: string = '';
  @State categorySourceName: string = '';
  @State categories: NetworkCategoryItem[] = [];
  @State loadingCategories: boolean = false;
  @State categoryError: string = '';
  private featureSupported: boolean = ServerRegistry.supports(ServerFeature.NETWORK_LIBRARY);
  private modeItems: FilterChipItem[] = [
    { label: '常用书源', value: 0 },
    { label: '全部书源', value: 1 },
    { label: '手选书源', value: 2 },
  ];
  /** 搜索范围序号 → 上游 `mode` 值（手选时 `sources` 参数才真正决定选源）。 */
  private modeValues: string[] = [
    NETWORK_SEARCH_MODE_TOP, NETWORK_SEARCH_MODE_ALL, NETWORK_SEARCH_MODE_CUSTOM,
  ];
  /** 已收口任务的结果（跨页累积）。 */
  private committed: NetworkBookItem[] = [];
  /** 当前任务进行中的结果（每次轮询整表替换）。 */
  private live: NetworkBookItem[] = [];
  /** 去重键集合（`sourceId#bookUrl`）。 */
  private seen: Set<string> = new Set<string>();
  /** 行 id → 书籍条目（点击进入详情时取书源与书籍 URL）。 */
  private index: Map<string, NetworkBookItem> = new Map();
  private pollTimer: number = -1;
  private polls: number = 0;
  private taskId: string = '';
  /**
   * 搜索代次：每次新搜索/停止搜索 +1，进行中的轮询发现代次不匹配即自行退出。
   * 用途与上游 `searchToken` 一致：避免停止后仍被旧任务的结果覆盖页面。
   */
  private searchToken: number = 0;
  private page: number = 1;
  private exploreSourceKey: string = '';
  private exploreSourceName: string = '';
  private exploreCategoryId: string = '';
  private exploreScope: string = '';

  aboutToAppear(): void {
    if (!this.featureSupported) {
      this.loading = false;
      return;
    }
    void this.loadSources();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private availabilityText(): string {
    const availability = this.availability;
    if (availability === null) {
      return '';
    }
    if (availability.state === NETWORK_AVAILABILITY_NO_PLUGINS) {
      return '当前没有启用的书源插件，请先在书源管理中确认插件与书源。';
    }
    if (availability.state === NETWORK_AVAILABILITY_NO_SOURCES) {
      return '尚未配置任何书源，请先在书源管理中导入或启用书源。';
    }
    return `已就绪：${availability.configuredSources} 个书源`;
  }

  private browsableSources(): NetworkSourceItem[] {
    const items: NetworkSourceItem[] = [];
    for (const source of this.sources) {
      if (source.capabilities.indexOf(NETWORK_CAPABILITY_BROWSE) >= 0) {
        items.push(source);
      }
    }
    return items;
  }

  private isSelected(key: string): boolean {
    return this.selectedKeys.indexOf(key) >= 0;
  }

  private toggleKey(key: string): void {
    const next: string[] = [];
    let removed = false;
    for (const item of this.selectedKeys) {
      if (item === key) {
        removed = true;
      } else {
        next.push(item);
      }
    }
    if (!removed) {
      next.push(key);
    }
    this.selectedKeys = next;
  }

  private async loadSources(): Promise<void> {
    if (!TalebookService.ensureTalebookConfigured()) {
      this.loading = false;
      this.loadError = '尚未配置服务器地址';
      return;
    }
    this.loading = true;
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await NetworkLibraryApi.getSources();
      if (!NetworkLibraryApi.isOk(rsp)) {
        this.loadError = NetworkLibraryApi.errorMessage(rsp);
        return;
      }
      this.sources = NetworkLibraryApi.parseSources(rsp.items);
      this.availability = NetworkLibraryApi.parseAvailability(rsp.availability);
    } catch (e) {
      this.loadError = `加载书源失败：${e}`;
    } finally {
      this.loading = false;
    }
  }

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private schedulePoll(delay: number): void {
    this.stopPoll();
    this.pollTimer = setTimeout(() => {
      void this.pollSearchStatus();
    }, delay);
  }

  private renderRows(): void {
    const merged: NetworkBookItem[] = this.committed.slice();
    for (const item of this.live) {
      merged.push(item);
    }
    const rows: BookListItemData[] = [];
    const index: Map<string, NetworkBookItem> = new Map();
    const seen: Set<string> = new Set<string>();
    for (const book of merged) {
      const key = bookKey(book);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      const row: BookListItemData = {
        id: key,
        title: book.title.length > 0 ? book.title : '未知书名',
        author: book.author,
        cover: book.coverUrl,
        subtitle: bookSubtitle(book),
        format: '',
      };
      rows.push(row);
      index.set(key, book);
    }
    this.rows = rows;
    this.index = index;
  }

  /** 把新结果并入已收口集合（按 sourceId + bookUrl 去重）。 */
  private mergeBooks(base: NetworkBookItem[], extra: NetworkBookItem[]): NetworkBookItem[] {
    const merged: NetworkBookItem[] = base.slice();
    for (const item of extra) {
      const key = bookKey(item);
      if (!this.seen.has(key)) {
        this.seen.add(key);
        merged.push(item);
      }
    }
    return merged;
  }

  private startSearch(reset: boolean): void {
    const key = this.keyword.trim();
    if (key.length === 0) {
      this.toast('请输入搜索关键字');
      return;
    }
    if (this.sources.length === 0) {
      const hint = this.availabilityText();
      this.toast(hint.length > 0 ? hint : '没有可用的书源');
      return;
    }
    // 上游：手选模式下未勾选任何书源则阻断（否则服务端会回退成「常用书源」）
    if (this.searchMode === 2 && this.selectedKeys.length === 0) {
      this.toast('请先选择要搜索的书源');
      this.openSourceSheet();
      return;
    }
    if (reset) {
      this.stopPoll();
      this.searchToken += 1;
      this.committed = [];
      this.live = [];
      this.seen.clear();
      this.page = 1;
      this.mode = LIST_MODE_SEARCH;
      this.exploreScope = '';
      this.renderRows();
    } else {
      this.page += 1;
    }
    void this.createTask();
  }

  /** 停止搜索：让进行中的轮询因代次失配退出，并保留已返回结果。 */
  private stopSearch(): void {
    this.searchToken += 1;
    this.stopPoll();
    this.taskId = '';
    this.searching = false;
    this.loadingMore = false;
    this.progressText = this.committed.length > 0
      ? `已停止，保留已返回 ${this.committed.length} 本`
      : '已停止搜索';
    this.toast('已停止搜索');
  }

  private async createTask(): Promise<void> {
    const token = this.searchToken;
    this.searching = true;
    this.loadingMore = false;
    this.progressDone = 0;
    this.progressTotal = 0;
    this.failedSources = [];
    this.progressText = `正在创建搜索任务（第 ${this.page} 页）…`;
    try {
      const mode = this.modeValues[this.searchMode] ?? NETWORK_SEARCH_MODE_TOP;
      // 非手选模式下不限制书源（与上游一致：sources 仅在 custom 时下发）
      const keys = this.searchMode === 2 ? this.selectedKeys : [];
      const rsp = await NetworkLibraryApi.search(this.keyword, this.page, keys, '', mode);
      if (token !== this.searchToken) {
        return;
      }
      if (!NetworkLibraryApi.isOk(rsp)) {
        this.settleSearch(NetworkLibraryApi.errorMessage(rsp));
        return;
      }
      const taskId = rsp.task_id ?? '';
      if (taskId.length === 0) {
        this.settleSearch('没有可用的书源，请先在书源管理中启用书源');
        return;
      }
      this.taskId = taskId;
      this.polls = 0;
      this.progressTotal = rsp.total ?? 0;
      this.progressText = `搜索中：${this.progressTotal} 个书源`;
      this.schedulePoll(600);
    } catch (e) {
      if (token === this.searchToken) {
        this.settleSearch(`搜索失败：${e}`);
      }
    }
  }

  private applyProgress(progress: NetworkSearchProgress): void {
    const live: NetworkBookItem[] = [];
    for (const group of progress.groups) {
      for (const book of group.books) {
        live.push(book);
      }
    }
    this.live = live;
    this.renderRows();
    this.progressDone = progress.done;
    if (progress.total > 0) {
      this.progressTotal = progress.total;
    }
    this.failedSources = progress.failures;
    const failText = progress.failures.length > 0 ? ` · ${progress.failures.length} 源失败` : '';
    this.progressText =
      `搜索中 ${progress.done}/${progress.total} 源 · 已返回 ${live.length} 本${failText}`;
  }

  private searchDoneText(): string {
    if (this.committed.length === 0) {
      return '没有搜索到结果，可更换关键词或指定其他书源';
    }
    return `搜索完成：共 ${this.committed.length} 本`;
  }

  /**
   * 收口当前搜索任务（成功、超时或异常），停止轮询并提示。
   * `message` 为空串时按已收口结果生成完成文案。
   */
  private settleSearch(message: string): void {
    this.stopPoll();
    this.taskId = '';
    this.searching = false;
    this.loadingMore = false;
    const pageBooks = this.live.length;
    this.committed = this.mergeBooks(this.committed, this.live);
    this.live = [];
    this.renderRows();
    this.hasMore = pageBooks > 0;
    const text = message.length > 0 ? message : this.searchDoneText();
    this.progressText = text;
    // 失败源保留展示（上游同样在完成后继续提示 partial），仅在重开搜索时清空
    this.toast(text);
  }

  private async pollSearchStatus(): Promise<void> {
    const taskId = this.taskId;
    const token = this.searchToken;
    if (taskId.length === 0) {
      this.searching = false;
      return;
    }
    try {
      const rsp = await NetworkLibraryApi.getSearchStatus(taskId);
      if (token !== this.searchToken) {
        return;
      }
      if (!NetworkLibraryApi.isOk(rsp)) {
        this.settleSearch(NetworkLibraryApi.errorMessage(rsp));
        return;
      }
      const progress = NetworkLibraryApi.parseSearchProgress(rsp);
      this.applyProgress(progress);
      if (progress.finished) {
        this.settleSearch('');
        return;
      }
    } catch (e) {
      if (token === this.searchToken) {
        this.settleSearch(`搜索状态查询失败：${e}`);
      }
      return;
    }
    this.polls += 1;
    if (this.polls >= SEARCH_POLL_MAX) {
      this.settleSearch('搜索超时，仅显示已返回结果');
      return;
    }
    this.schedulePoll(SEARCH_POLL_INTERVAL_MS);
  }

  private async explorePage(targetPage: number): Promise<void> {
    if (targetPage === 1) {
      this.stopPoll();
      this.searching = false;
      this.committed = [];
      this.live = [];
      this.seen.clear();
    }
    this.mode = LIST_MODE_EXPLORE;
    this.page = targetPage;
    this.loadingMore = targetPage > 1;
    this.progressText = `正在加载发现页（第 ${targetPage} 页）…`;
    try {
      const rsp = await NetworkLibraryApi.explore(this.exploreSourceKey, this.exploreCategoryId, targetPage);
      if (!NetworkLibraryApi.isOk(rsp)) {
        this.toast(NetworkLibraryApi.errorMessage(rsp));
        this.progressText = '';
        return;
      }
      const books = NetworkLibraryApi.parseNetworkBooks(rsp.books, this.exploreSourceKey,
        this.exploreSourceName);
      this.committed = this.mergeBooks(this.committed, books);
      this.renderRows();
      this.hasMore = books.length > 0;
      if (books.length === 0) {
        this.progressText = this.committed.length > 0 ? '该分类已没有更多书籍' : '该分类暂无书籍';
      } else {
        this.progressText = `发现 · ${this.exploreScope} · 共 ${this.committed.length} 本`;
      }
    } catch (e) {
      this.toast(`发现页加载失败：${e}`);
      this.progressText = '';
    } finally {
      this.loadingMore = false;
    }
  }

  private loadMore(): void {
    if (this.loadingMore || this.searching || !this.hasMore) {
      return;
    }
    if (this.mode === LIST_MODE_EXPLORE) {
      void this.explorePage(this.page + 1);
      return;
    }
    if (this.mode === LIST_MODE_SEARCH) {
      this.page += 1;
      void this.createTask();
    }
  }

  private openSourceSheet(): void {
    this.sheetMode = SHEET_SOURCE;
    this.showSheet = true;
  }

  private openCategorySheet(): void {
    this.categorySourceKey = '';
    this.categorySourceName = '';
    this.categories = [];
    this.categoryError = '';
    this.sheetMode = SHEET_CATEGORY;
    this.showSheet = true;
  }

  private sheetTitle(): string {
    return this.sheetMode === SHEET_CATEGORY ? '书源发现页' : '选择搜索书源';
  }

  private onSheetClosed(): void {
    this.sheetMode = SHEET_SOURCE;
  }

  private async loadCategories(source: NetworkSourceItem): Promise<void> {
    this.categorySourceKey = source.sourceKey;
    this.categorySourceName = source.name;
    this.loadingCategories = true;
    this.categoryError = '';
    try {
      const rsp = await NetworkLibraryApi.getCategories(source.sourceKey);
      if (!NetworkLibraryApi.isOk(rsp)) {
        this.categoryError = NetworkLibraryApi.errorMessage(rsp);
        return;
      }
      this.categories = NetworkLibraryApi.parseNetworkCategories(rsp.items);
    } catch (e) {
      this.categoryError = `分类加载失败：${e}`;
    } finally {
      this.loadingCategories = false;
    }
  }

  private pickCategory(category: NetworkCategoryItem): void {
    this.showSheet = false;
    this.exploreSourceKey = this.categorySourceKey;
    this.exploreSourceName = this.categorySourceName;
    this.exploreCategoryId = category.url.length > 0 ? category.url : category.id;
    this.exploreScope = `${this.categorySourceName} / ${category.name}`;
    void this.explorePage(1);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openBook(row: BookListItemData): void {
    const book = this.index.get(row.id);
    if (book === undefined) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/NetworkBookDetailPage',
      params: {
        sourceId: book.sourceId,
        bookUrl: book.bookUrl,
        bookName: book.title,
        sourceName: book.sourceName,
      },
    });
  }

  // ---- 展示辅助 ----

  /** 搜索范围说明（对齐上游：显示当前模式与参与搜索的书源数量）。 */
  private searchScopeText(): string {
    const scope = this.searchMode === 2 ? '手选书源' : (this.searchMode === 1 ? '全部书源' : '常用书源');
    if (this.searchMode === 2) {
      return `${scope} · 已选 ${this.selectedKeys.length} 个`;
    }
    return `${scope} · 共 ${this.sources.length} 个可用`;
  }

  /** 失败源名称（最多列 3 个，其余折叠为「等 N 个」）。 */
  private failedSourceNames(): string {
    const names: string[] = [];
    for (let i = 0; i < this.failedSources.length && i < 3; i++) {
      const name = this.failedSources[i].sourceName;
      names.push(name.length > 0 ? name : this.failedSources[i].sourceId);
    }
    const more = this.failedSources.length > 3 ? ` 等 ${this.failedSources.length} 个` : '';
    return `${names.join('、')}${more}`;
  }

  /** 结果中出现过的书源名（按首次出现顺序）。 */
  private sourceNames(): string[] {
    const names: string[] = [];
    for (const row of this.rows) {
      const book = this.index.get(row.id);
      if (book === undefined) {
        continue;
      }
      const name = book.sourceName.length > 0 ? book.sourceName : book.sourceId;
      if (names.indexOf(name) < 0) {
        names.push(name);
      }
    }
    return names;
  }

  /** 某个书源下的行。 */
  private rowsOfSource(name: string): BookListItemData[] {
    const result: BookListItemData[] = [];
    for (const row of this.rows) {
      const book = this.index.get(row.id);
      if (book === undefined) {
        continue;
      }
      const bookName = book.sourceName.length > 0 ? book.sourceName : book.sourceId;
      if (bookName === name) {
        result.push(row);
      }
    }
    return result;
  }

  /** 翻页：搜索模式重发任务，发现模式重拉指定页。 */
  private changePage(delta: number): void {
    if (this.loadingMore || this.searching) {
      return;
    }
    const target = this.page + delta;
    if (target < 1) {
      return;
    }
    if (this.mode === LIST_MODE_EXPLORE) {
      void this.explorePage(target);
      return;
    }
    if (this.mode === LIST_MODE_SEARCH) {
      // 换页相当于重新发起该页的搜索任务，清空当前累积结果避免串台
      this.stopPoll();
      this.searchToken += 1;
      this.committed = [];
      this.live = [];
      this.seen.clear();
      this.page = target;
      this.renderRows();
      void this.createTask();
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '网络书库',
        showBack: true,
        action: () => {
          this.headerAction();
        },
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      title: { title: this.sheetTitle() },
      onDisappear: () => {
        this.onSheetClosed();
      },
    });
  }

  @Builder
  sheetContent() {
    if (this.sheetMode === SHEET_CATEGORY) {
      this.categorySheet();
    } else {
      this.sourceSheet();
    }
  }

  @Builder
  headerAction() {
    Row({ space: 4 }) {
      Text('发现')
        .fontSize(14)
        .fontColor($r('app.color.brand_primary'))
        .padding({ left: 8, right: 8 })
        .onClick(() => this.openCategorySheet());
      if (ServerRegistry.supports(ServerFeature.BOOK_SOURCES)) {
        Text('书源')
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .padding({ left: 8, right: 16 })
          .onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/BookSourceManagePage' }));
      }
    }
  }

  @Builder
  pageContent() {
    if (!this.featureSupported) {
      EmptyState({
        message: `${ServerRegistry.profile().displayName} 服务端不支持网络书库`,
        detail: '网络书库依赖书源插件与 Legado 书源。',
      });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({
        message: this.loadError,
        detail: '请检查服务器地址与登录状态。',
        actionLabel: '重新加载',
        onAction: () => {
          void this.loadSources();
        },
      });
    } else {
      Column({ space: 8 }) {
        SearchBar({
          placeholder: '搜索书名 / 作者',
          keyword: $keyword,
          onSearch: () => this.startSearch(true),
        });
        FilterChips({
          items: this.modeItems,
          selected: $searchMode,
          onChange: (value: number) => {
            // 切到「手选书源」时直接弹出选择面板（上游在此模式下展开多选框）
            if (value === 2) {
              this.openSourceSheet();
              return;
            }
            if (this.keyword.trim().length > 0) {
              this.startSearch(true);
            }
          },
        });
        Row({ space: 8 }) {
          Text(this.searchScopeText())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1);
          TextButton({
            // 共享 TextButton 的 label 是普通成员（不重绘），故用静态文案
            label: '选择书源',
            onTap: () => this.openSourceSheet(),
          });
        }
        .width('100%')
        .padding({ left: 16, right: 16 });
        if (this.searching && this.progressTotal > 0) {
          Column({ space: 4 }) {
            Progress({ value: this.progressDone, total: this.progressTotal, type: ProgressType.Linear })
              .width('100%')
              .color($r('app.color.brand_primary'));
            Row({ space: 8 }) {
              Text(`已完成 ${this.progressDone}/${this.progressTotal} 个书源`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1);
              TextButton({
                label: '停止搜索',
                tone: 'danger',
                onTap: () => this.stopSearch(),
              });
            }
            .width('100%');
          }
          .width('100%')
          .padding({ left: 16, right: 16 });
        }
        if (this.failedSources.length > 0) {
          Text(`有 ${this.failedSources.length} 个书源未返回结果：${this.failedSourceNames()}`)
            .fontSize(12)
            .fontColor($r('app.color.warning'))
            .backgroundColor($r('app.color.warning_light'))
            .borderRadius(8)
            .padding(8)
            .width('100%')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 16, right: 16 });
        }
        if (this.progressText.length > 0) {
          Text(this.progressText)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 16, right: 16 });
        }
        if (this.rows.length === 0) {
          EmptyState({
            message: this.searching ? '正在搜索…' : '搜索网络书源',
            detail: this.availabilityText(),
            actionLabel: this.sources.length === 0 && ServerRegistry.supports(ServerFeature.BOOK_SOURCES)
              ? '去书源管理' : (this.progressText.length > 0 ? '重试' : ''),
            onAction: () => {
              if (this.sources.length === 0 && ServerRegistry.supports(ServerFeature.BOOK_SOURCES)) {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/BookSourceManagePage' });
                return;
              }
              this.startSearch(true);
            },
          });
        } else if (this.mode === LIST_MODE_SEARCH) {
          this.groupedResults();
        } else {
          BookCatalogView({
            items: this.rows,
            isListMode: true,
            loadingMore: this.loadingMore || this.searching,
            onItemTap: (item: BookListItemData) => this.openBook(item),
            onLoadMore: () => this.loadMore(),
          });
        }
        this.pagerRow();
      }
      .width('100%')
      .height('100%');
    }
  }

  /**
   * 搜索结果按书源分组展示（对齐上游：每个书源一个标题 + 该源返回的书）。
   * 分组标题用内联 Row 而非共享 SectionTitle（后者的参数是普通成员，不会随状态重绘）。
   */
  @Builder
  groupedResults() {
    List({ space: 8 }) {
      ForEach(this.sourceNames(), (name: string) => {
        ListItem() {
          Row({ space: 8 }) {
            Column()
              .width(4)
              .height(16)
              .borderRadius(2)
              .backgroundColor($r('app.color.brand_primary'));
            Text(name)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
            Text(`${this.rowsOfSource(name).length} 本`)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'));
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 2 });
        }
        ForEach(this.rowsOfSource(name), (row: BookListItemData) => {
          ListItem() {
            BookListItem({
              item: row,
              onTap: () => this.openBook(row),
            });
          }
          .height($r('app.float.list_item_height'))
          .padding({ left: 16, right: 16 });
        }, (row: BookListItemData) => `grp-${name}-${row.id}`);
      }, (name: string) => `grp-head-${name}`);
      if (this.loadingMore || this.searching) {
        ListItem() {
          LoadingState({ hint: this.searching ? '搜索中…' : '加载更多…' });
        }
      }
    }
    .layoutWeight(1)
    .width('100%')
    .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
    .cachedCount(8)
    .onReachEnd(() => this.loadMore());
  }

  /** 上一页 / 第 N 页 / 下一页（搜索与发现页共用）。 */
  @Builder
  pagerRow() {
    if (this.rows.length > 0 || this.page > 1) {
      Row({ space: 12 }) {
        TextButton({
          label: '上一页',
          onTap: () => this.changePage(-1),
        });
        Text(`第 ${this.page} 页`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'));
        TextButton({
          label: '下一页',
          onTap: () => this.changePage(1),
        });
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 4, bottom: 12 });
    }
  }

  @Builder
  sourceSheet() {
    Column({ space: 12 }) {
      Text('不指定时按「常用 / 全部书源」模式搜索；切到「手选书源」或在此勾选后，只搜索选中的书源。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
      Row({ space: 8 }) {
        Text(`已选 ${this.selectedKeys.length} 个`)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        TextButton({
          label: '清空',
          onTap: () => {
            this.selectedKeys = [];
          },
        });
      }
      .width('100%');
      if (this.sources.length === 0) {
        EmptyState({ message: '没有可用的书源' });
      } else {
        List({ space: 8 }) {
          ForEach(this.sources, (source: NetworkSourceItem) => {
            ListItem() {
              ChipButton({
                label: this.isSelected(source.sourceKey) ? `${source.name} ✓` : source.name,
                selected: this.isSelected(source.sourceKey),
                onTap: () => this.toggleKey(source.sourceKey),
              });
            }
          }, (source: NetworkSourceItem) => source.sourceKey);
        }
        .layoutWeight(1)
        .width('100%');
      }
      PrimaryButton({
        label: '应用并搜索',
        onTap: () => {
          // 勾选即视为手选模式，下次提交才会下发 sources
          this.searchMode = this.selectedKeys.length > 0 ? 2 : this.searchMode;
          this.showSheet = false;
          this.startSearch(true);
        },
      });
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 });
  }

  @Builder
  categorySheet() {
    Column({ space: 12 }) {
      if (this.categorySourceKey.length === 0) {
        Text('选择一个支持「发现」的书源')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
        if (this.browsableSources().length === 0) {
          EmptyState({ message: '当前书源都不支持发现页', detail: '请检查书源是否配置了 exploreUrl。' });
        } else {
          List({ space: 8 }) {
            ForEach(this.browsableSources(), (source: NetworkSourceItem) => {
              ListItem() {
                ChipButton({
                  label: source.name,
                  selected: false,
                  onTap: () => {
                    void this.loadCategories(source);
                  },
                });
              }
            }, (source: NetworkSourceItem) => source.sourceKey);
          }
          .layoutWeight(1)
          .width('100%');
        }
      } else if (this.loadingCategories) {
        LoadingState({});
      } else if (this.categoryError.length > 0) {
        EmptyState({
          message: this.categoryError,
          actionLabel: '返回',
          onAction: () => {
            this.categorySourceKey = '';
          },
        });
      } else if (this.categories.length === 0) {
        EmptyState({
          message: '该书源没有解析到发现页分类',
          actionLabel: '返回',
          onAction: () => {
            this.categorySourceKey = '';
          },
        });
      } else {
        Row({ space: 8 }) {
          Text(`分类 · ${this.categorySourceName}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1);
          TextButton({
            label: '换书源',
            onTap: () => {
              this.categorySourceKey = '';
              this.categories = [];
            },
          });
        }
        .width('100%');
        List({ space: 8 }) {
          ForEach(this.categories, (category: NetworkCategoryItem) => {
            ListItem() {
              ChipButton({
                label: category.name,
                selected: false,
                onTap: () => this.pickCategory(category),
              });
            }
          }, (category: NetworkCategoryItem) => `${this.categorySourceKey}-${category.id}`);
        }
        .layoutWeight(1)
        .width('100%');
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 });
  }
}
