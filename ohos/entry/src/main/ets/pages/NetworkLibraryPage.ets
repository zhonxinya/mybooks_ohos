import { router } from '@kit.ArkUI';
import {
  PageScaffold, LoadingState, EmptyState, SearchBar, FilterChips, FilterChipItem,
  BookCatalogView, BookListItemData, PrimaryButton, TextButton, ChipButton,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import {
  NetworkLibraryApi, NetworkSourceItem, NetworkAvailability, NetworkBookItem,
  NetworkCategoryItem, NetworkSearchProgress,
  NETWORK_CAPABILITY_BROWSE, NETWORK_SEARCH_MODE_TOP, NETWORK_SEARCH_MODE_ALL,
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
  @State rows: BookListItemData[] = [];
  @State loadingMore: boolean = false;
  @State hasMore: boolean = false;
  @State mode: string = LIST_MODE_IDLE;
  @State showSourceSheet: boolean = false;
  @State showCategorySheet: boolean = false;
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
    this.getUIContext().getPromptAction().showToast({ message: message });
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
    if (reset) {
      this.stopPoll();
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

  private async createTask(): Promise<void> {
    this.searching = true;
    this.loadingMore = false;
    this.progressText = `正在创建搜索任务（第 ${this.page} 页）…`;
    try {
      const mode = this.searchMode === 1 ? NETWORK_SEARCH_MODE_ALL : NETWORK_SEARCH_MODE_TOP;
      const rsp = await NetworkLibraryApi.search(this.keyword, this.page, this.selectedKeys, '', mode);
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
      this.progressText = `搜索中：${rsp.total !== undefined ? rsp.total : 0} 个书源`;
      this.schedulePoll(600);
    } catch (e) {
      this.settleSearch(`搜索失败：${e}`);
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
    this.toast(text);
  }

  private async pollSearchStatus(): Promise<void> {
    const taskId = this.taskId;
    if (taskId.length === 0) {
      this.searching = false;
      return;
    }
    try {
      const rsp = await NetworkLibraryApi.getSearchStatus(taskId);
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
      this.settleSearch(`搜索状态查询失败：${e}`);
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
    this.showSourceSheet = true;
  }

  private openCategorySheet(): void {
    this.categorySourceKey = '';
    this.categorySourceName = '';
    this.categories = [];
    this.categoryError = '';
    this.showCategorySheet = true;
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
    this.showCategorySheet = false;
    this.exploreSourceKey = this.categorySourceKey;
    this.exploreSourceName = this.categorySourceName;
    this.exploreCategoryId = category.url.length > 0 ? category.url : category.id;
    this.exploreScope = `${this.categorySourceName} / ${category.name}`;
    void this.explorePage(1);
  }

  private openBook(row: BookListItemData): void {
    const book = this.index.get(row.id);
    if (book === undefined) {
      return;
    }
    router.pushUrl({
      url: 'pages/NetworkBookDetailPage',
      params: {
        sourceId: book.sourceId,
        bookUrl: book.bookUrl,
        bookName: book.title,
        sourceName: book.sourceName,
      },
    });
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
    .bindSheet($$this.showSourceSheet, this.sourceSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      title: { title: '选择搜索书源' },
    })
    .bindSheet($$this.showCategorySheet, this.categorySheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      title: { title: '书源发现页' },
    });
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
          .onClick(() => router.pushUrl({ url: 'pages/BookSourceManagePage' }));
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
          onChange: () => {
            if (this.keyword.trim().length > 0) {
              this.startSearch(true);
            }
          },
        });
        Row({ space: 8 }) {
          Text(this.selectedKeys.length > 0 ? `已指定 ${this.selectedKeys.length} 个书源` : '全部可用书源')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1);
          TextButton({
            label: '筛选书源',
            onTap: () => this.openSourceSheet(),
          });
        }
        .width('100%')
        .padding({ left: 16, right: 16 });
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
            actionLabel: this.progressText.length > 0 ? '重试' : '',
            onAction: () => this.startSearch(true),
          });
        } else {
          BookCatalogView({
            items: this.rows,
            isListMode: true,
            loadingMore: this.loadingMore || this.searching,
            onItemTap: (item: BookListItemData) => this.openBook(item),
            onLoadMore: () => this.loadMore(),
          });
        }
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  sourceSheet() {
    Column({ space: 12 }) {
      Text('不指定时按「常用 / 全部书源」模式搜索；勾选后可只在指定书源中搜索。')
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
          this.showSourceSheet = false;
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
