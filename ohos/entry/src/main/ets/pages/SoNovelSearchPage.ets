import {
  PageScaffold, SearchBar, BookCatalogView, BookViewToggleButton, BookListItemData,
  LoadingState, EmptyState, IconCircleButton, ChipButton, FilterChipItem,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookApi } from '../services/TalebookApi';
import { SoNovelService } from '../services/SoNovelService';
import { BookViewMode } from '../utils/BookViewMode';
import { DownloadTaskService } from '../services/DownloadTaskService';
import {
  MergedSoNovelResult, SoNovelMerge, SoNovelSearchItem, SoNovelSourceOption,
} from '../utils/SoNovelMerge';
import { hasSameBook, normalizeName } from '../utils/LibraryMatch';

/** 核对书库的在途请求上限：结果可能有几十本，逐个串行太慢，放开太多又会压垮书库。 */
const LIBRARY_CHECK_CONCURRENCY: number = 3;
/**
 * 单次搜索最多核对多少本。
 * 宽泛关键词（如单字）可能返回上百本，逐本查书库会打满请求；超出的部分不标角标，
 * 统计文案会注明「已核对前 N 本」，不假装全都核对过。
 */
const LIBRARY_CHECK_MAX: number = 60;
/**
 * 每次书库候选查询取多少条。
 * 用模糊检索（`name=`）而不是服务端的同名精确查询（`title=`）：书库里的书名常与书源不一致
 * （如书库存的是「《金枝》」、书源给的是「金枝」），精确查询会直接查不到，
 * 客户端连归一化比对的机会都没有。取一条较宽的候选窗口，再在客户端按归一化后的书名 + 作者严格比对。
 */
const LIBRARY_CANDIDATE_LIMIT: number = 50;
const BADGE_IN_LIBRARY: string = '已入库';
/** 筛选芯片里「全部」的取值；书源 sourceId 为服务端给定的正整数，不会冲突。 */
const SOURCE_FILTER_ALL: number = 0;

@Entry
@Component
struct SoNovelSearchPage {
  @State keyword: string = '';
  /** 本次搜索的合并结果（未筛选）。 */
  @State mergedResults: MergedSoNovelResult[] = [];
  /** 当前展示的结果（已按 selectedSourceId 筛选）；列表与计数都基于它。 */
  @State visibleResults: MergedSoNovelResult[] = [];
  /** 当前选中的书源；0 = 全部。 */
  @State selectedSourceId: number = SOURCE_FILTER_ALL;
  /** 本次结果里出现过的书源（含「全部」芯片）。 */
  @State sourceOptions: SoNovelSourceOption[] = [];
  @State loading: boolean = false;
  @State searched: boolean = false;
  @State isListMode: boolean = false;
  @State errorMessage: string = '';
  @State catalogItems: BookListItemData[] = [];
  @State activeTaskCount: number = 0;
  @State showSourceSheet: boolean = false;
  @State sheetMergedIndex: number = -1;
  /**
   * 已核对入库的条目：合并键（书名+作者）→ 是否在书库。
   *
   * 按合并键而非下标存：按书源筛选会改变展示集的下标，用下标会在切换书源后把
   * 入库角标错位到别的书上。
   */
  @State inLibraryByKey: Map<string, boolean> = new Map<string, boolean>();
  @State checkingLibrary: boolean = false;
  /** 本次已核对的结果条数（受 LIBRARY_CHECK_MAX 限制，可能少于结果总数）。 */
  @State libraryCheckedCount: number = 0;
  private searchToken: number = 0;
  /** 书名+作者 → 是否在书库（页面级会话缓存，换关键词重搜时不必重复查询）。 */
  private libraryCache: Map<string, boolean> = new Map<string, boolean>();

  aboutToAppear(): void {
    this.isListMode = BookViewMode.isListMode();
    this.refreshTaskCount();
  }

  aboutToDisappear(): void {
    this.searchToken++;
  }

  onPageShow(): void {
    this.refreshTaskCount();
  }

  private refreshTaskCount(): void {
    this.activeTaskCount = DownloadTaskService.activeCount();
  }

  private hasSoNovelConfig(): boolean {
    return TalebookService.secureGet('sonovel_url').length > 0;
  }

  private async search(): Promise<void> {
    const trimmed = this.keyword.trim();
    if (trimmed.length === 0 || this.loading) {
      return;
    }
    const token = ++this.searchToken;
    this.loading = true;
    this.searched = true;
    this.errorMessage = '';
    this.mergedResults = [];
    this.visibleResults = [];
    this.sourceOptions = [];
    this.selectedSourceId = SOURCE_FILTER_ALL;
    this.catalogItems = [];
    this.inLibraryByKey = new Map<string, boolean>();
    this.checkingLibrary = false;
    this.libraryCheckedCount = 0;
    try {
      const url = TalebookService.secureGet('sonovel_url');
      if (url.length > 0) {
        TalebookService.setBaseUrl('sonovel', url);
      }
      const envelope = await SoNovelService.search(trimmed);
      if (token !== this.searchToken) {
        return;
      }
      if (envelope.error.length > 0) {
        this.errorMessage = envelope.error;
        this.mergedResults = [];
        this.visibleResults = [];
        this.catalogItems = [];
        return;
      }
      const body = envelope.body ?? {};
      const raw = (body['data'] as Record<string, Object>[] | undefined) ?? [];
      const items: SoNovelSearchItem[] = [];
      for (let i = 0; i < raw.length; i++) {
        items.push(SoNovelMerge.fromRecord(raw[i]));
      }
      // 书源清单必须在 merge 之后提取：芯片数字要与筛选结果条数一致，而合并会把同名同作者
      // 的多条合成一条，用原始条数统计时「阅读库（21）」点进去只剩 19 本，看起来像丢了结果。
      this.mergedResults = SoNovelMerge.merge(items);
      this.sourceOptions = SoNovelMerge.sourceOptions(this.mergedResults);
      this.applySourceFilter();
      // 不 await：先出结果，入库角标随后补齐，避免书库查询拖慢搜索
      void this.checkLibraryMembership(token);
    } catch (error) {
      if (token !== this.searchToken) {
        return;
      }
      this.errorMessage = error instanceof Error ? error.message : `${error}`;
      this.mergedResults = [];
      this.visibleResults = [];
      this.catalogItems = [];
    } finally {
      if (token === this.searchToken) {
        this.loading = false;
      }
    }
  }

  /** 重新按 `selectedSourceId` 计算展示集（切换芯片、搜索完成时调用）。 */
  private applySourceFilter(): void {
    this.visibleResults = SoNovelMerge.filterBySource(this.mergedResults, this.selectedSourceId);
    this.syncCatalogItems();
  }

  /**
   * 筛选芯片项：首位固定「全部（N）」，其余为本次命中的书源（按能看到的书数降序）。
   *
   * 芯片文案带条数：同时命中多个书源时，用户一眼能看出哪个源收录得多。
   */
  private sourceChipItems(): FilterChipItem[] {
    const items: FilterChipItem[] = [
      { label: `全部（${this.mergedResults.length}）`, value: SOURCE_FILTER_ALL },
    ];
    for (let i = 0; i < this.sourceOptions.length; i++) {
      const option = this.sourceOptions[i];
      items.push({
        label: `${SoNovelMerge.sourceLabel(option.sourceId, option.sourceName)}（${option.count}）`,
        value: option.sourceId,
      });
    }
    return items;
  }

  private onSourceFilterChanged(value: number): void {
    if (this.selectedSourceId === value) {
      return;
    }
    this.selectedSourceId = value;
    this.applySourceFilter();
  }

  private syncCatalogItems(): void {
    const merged = this.visibleResults;
    this.catalogItems = merged.map((item: MergedSoNovelResult): BookListItemData => {
      const sourceCount = item.sources.length;
      return {
        // id 用条目自身标识（书名+作者），**不能用展示下标**：
        // `BookCatalogView` 的 LazyForEach key 是 `list-${id}-${badge}`，按下标做 id 时
        // 筛选后新列表的 id 又从 0 开始，key 大面积重复 → 复用旧组件，列表看着没变。
        id: SoNovelMerge.mergeKey(item.bookName, item.author),
        title: item.bookName.length > 0 ? item.bookName : '未知',
        author: item.author,
        subtitle: SoNovelMerge.subtitle(item),
        format: sourceCount > 1 ? `${sourceCount}源` : 'EPUB',
        badge: this.isInLibrary(item) ? BADGE_IN_LIBRARY : '',
      };
    });
  }

  /**
   * 入库标记按**合并键**（书名+作者）查，不用下标。
   *
   * 筛选会改变展示集的下标，而入库标记是按未筛选的全集存的，
   * 用下标查会在切换书源后把入库角标错位到别的书上。
   */
  private isInLibrary(item: MergedSoNovelResult): boolean {
    const flag = this.inLibraryByKey.get(SoNovelMerge.mergeKey(item.bookName, item.author));
    return flag !== undefined && flag;
  }

  /** 入库数：从合并键映射里统计，与当前筛选无关（统计的是本次搜索整体）。 */
  private libraryMatchCount(): number {
    let count = 0;
    this.inLibraryByKey.forEach((hit: boolean) => {
      if (hit) {
        count++;
      }
    });
    return count;
  }

  private resultSummary(): string {
    const total = this.selectedSourceId === SOURCE_FILTER_ALL
      ? `共 ${this.mergedResults.length} 本`
      : `筛选出 ${this.visibleResults.length} / ${this.mergedResults.length} 本`;
    if (this.checkingLibrary) {
      return `${total} · 正在核对书库…`;
    }
    const matched = this.libraryMatchCount();
    const checked = this.libraryCheckedCount;
    if (checked > 0 && checked < this.mergedResults.length) {
      return `${total} · 已核对前 ${checked} 本，${matched} 本已入库`;
    }
    return matched > 0 ? `${total} · ${matched} 本已入库` : total;
  }

  /**
   * 核对每本搜索结果是否已在书库（书名 + 作者都相同）。
   *
   * 书库候选走 `GET /api/search?name=`（模糊检索），严格的同名 + 同作者判定在客户端做，
   * 见 `LibraryMatch`；并发受 `LIBRARY_CHECK_CONCURRENCY` 限制、总量受 `LIBRARY_CHECK_MAX` 限制；
   * 查询失败按「未入库」处理，不影响搜索结果本身。
   *
   * @throws 内部调用可能抛出异常，由调用方处理
   */
  private async checkLibraryMembership(token: number): Promise<void> {
    const results = this.mergedResults;
    if (results.length === 0) {
      return;
    }
    const total = Math.min(results.length, LIBRARY_CHECK_MAX);
    this.checkingLibrary = true;
    this.libraryCheckedCount = 0;
    const flags = new Map<string, boolean>();
    let next = 0;
    const worker = async (): Promise<void> => {
      while (next < total) {
        const index = next;
        next++;
        const item = results[index];
        flags.set(SoNovelMerge.mergeKey(item.bookName, item.author),
          await this.isBookInLibrary(item.bookName, item.author));
      }
    };
    const workers: Promise<void>[] = [];
    const workerCount = Math.min(LIBRARY_CHECK_CONCURRENCY, total);
    for (let i = 0; i < workerCount; i++) {
      workers.push(worker());
    }
    await Promise.all(workers);
    if (token !== this.searchToken) {
      return;
    }
    this.inLibraryByKey = flags;
    this.libraryCheckedCount = total;
    this.checkingLibrary = false;
    this.syncCatalogItems();
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async isBookInLibrary(title: string, author: string): Promise<boolean> {
    const key = `${normalizeName(title)}|${normalizeName(author)}`;
    const cached = this.libraryCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    let hit = false;
    try {
      const candidates = await TalebookApi.search(title, 1, LIBRARY_CANDIDATE_LIMIT);
      hit = hasSameBook(candidates, title, author);
    } catch (_error) {
      // 书库查询失败（未配置书库/网络异常）时按未入库处理，不打断搜索结果展示
      hit = false;
    }
    this.libraryCache.set(key, hit);
    return hit;
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openSource(item: SoNovelSearchItem): void {
    const payload = SoNovelMerge.toPayload(item);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/SoNovelBookDetailPage',
      params: {
        sourceId: payload.sourceId,
        sourceName: payload.sourceName,
        url: payload.url,
        bookName: payload.bookName,
        author: payload.author,
        category: payload.category ?? '',
        latestChapter: payload.latestChapter ?? '',
        lastUpdateTime: payload.lastUpdateTime ?? '',
        status: payload.status ?? '',
      },
    });
  }

  /** 按条目 id（书名+作者）在当前展示集里定位；找不到返回 -1。 */
  private visibleIndexOf(id: string): number {
    for (let i = 0; i < this.visibleResults.length; i++) {
      const item = this.visibleResults[i];
      if (SoNovelMerge.mergeKey(item.bookName, item.author) === id) {
        return i;
      }
    }
    return -1;
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openMerged(id: string): void {
    const index = this.visibleIndexOf(id);
    if (index < 0) {
      return;
    }
    const merged = this.visibleResults[index];
    if (merged.sources.length === 0) {
      return;
    }
    this.openSource(merged.sources[0]);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private startDownload(item: SoNovelSearchItem): void {
    if (item.sourceId <= 0 || item.url.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '书源信息不完整' });
      return;
    }
    const payload = SoNovelMerge.toPayload(item);
    const existing = DownloadTaskService.getTasks().find((task) =>
      task.payload !== undefined &&
      task.payload.sourceId === payload.sourceId &&
      task.payload.url === payload.url &&
      (task.status === 'pending' || task.status === 'downloading'));
    DownloadTaskService.enqueue(payload);
    DownloadTaskService.processQueue();
    this.refreshTaskCount();
    if (existing !== undefined) {
      this.getUIContext().getPromptAction().showToast({
        message: `《${payload.bookName}》已在下载队列中`,
      });
      return;
    }
    this.getUIContext().getPromptAction().showToast({
      message: SoNovelMerge.isUnstableSource(payload.sourceId)
        ? `《${payload.bookName}》已加入队列（顶点书源不稳定）`
        : `《${payload.bookName}》已加入 EPUB 下载队列`,
    });
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private downloadMerged(id: string): void {
    const index = this.visibleIndexOf(id);
    if (index < 0) {
      return;
    }
    const merged = this.visibleResults[index];
    if (merged.sources.length === 0) {
      return;
    }
    if (merged.sources.length === 1) {
      this.startDownload(merged.sources[0]);
      return;
    }
    this.sheetMergedIndex = index;
    this.showSourceSheet = true;
  }

  private sheetMerged(): MergedSoNovelResult | null {
    if (this.sheetMergedIndex < 0 || this.sheetMergedIndex >= this.visibleResults.length) {
      return null;
    }
    return this.visibleResults[this.sheetMergedIndex];
  }

  /** 下载面板里的「已在书库」提示（下标是展示集下标，故需再取一次条目）。 */
  private sheetMergedInLibrary(): boolean {
    const merged = this.sheetMerged();
    return merged !== null && this.isInLibrary(merged);
  }

  @Builder
  sourceSheet() {
    Column({ space: 12 }) {
      Text(this.sheetMerged()?.bookName ?? '选择下载书源')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      if (this.sheetMerged()?.author !== undefined && (this.sheetMerged()?.author.length ?? 0) > 0) {
        Text(this.sheetMerged()?.author ?? '')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
      }
      Text('默认下载 EPUB 格式')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      if (this.sheetMergedInLibrary()) {
        Text('这本书已在书库中，无需重复下载')
          .fontSize(12)
          .fontColor($r('app.color.success'))
          .width('100%');
      }
      List({ space: 8 }) {
        ForEach(this.sheetMerged()?.sources ?? [], (source: SoNovelSearchItem) => {
          ListItem() {
            Row({ space: 8 }) {
              Column({ space: 4 }) {
                Text(source.sourceName.length > 0 ? source.sourceName : `书源 ${source.sourceId}`)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'));
                if (source.latestChapter.length > 0) {
                  Text(source.latestChapter)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis });
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
              SymbolGlyph($r('sys.symbol.arrow_down_circle'))
                .fontSize(18)
                .fontColor([$r('app.color.brand_primary')]);
            }
            .width('100%')
            .padding(12)
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.page_background'))
            .onClick(() => {
              this.showSourceSheet = false;
              this.startDownload(source);
            });
          }
        }, (source: SoNovelSearchItem) => `${source.sourceId}-${source.url}`);
      }
      .width('100%')
      .height(320);
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }

  @Builder
  viewModeAction() {
    Row({ space: 4 }) {
      if (this.activeTaskCount > 0) {
        IconCircleButton({
          icon: $r('sys.symbol.arrow_down_circle'),
          variant: 'ghost',
          onTap: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/DownloadManagerPage' }),
        });
      }
      BookViewToggleButton({ isListMode: $isListMode });
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: 'SoNovel 搜索',
        showBack: true,
        action: () => {
          this.viewModeAction();
        },
        content: () => {
          this.searchContent();
        },
      });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showSourceSheet, this.sourceSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: '选择下载书源' },
      onDisappear: () => {
        this.sheetMergedIndex = -1;
      },
    });
  }

  @Builder
  searchContent() {
    Column() {
      SearchBar({
        placeholder: '搜索书名或作者',
        keyword: $keyword,
        onSearch: () => {
          this.search();
        },
      });

      if (!this.hasSoNovelConfig() && !this.searched) {
        EmptyState({
          message: '请先配置 SoNovel 服务地址',
          actionLabel: '去配置',
          // SoNovel 地址已并入「账号与服务器」，统一引导到该页，避免出现两个配置入口
          onAction: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/TalebookConfigPage' }),
        });
      } else if (this.loading) {
        LoadingState({ hint: '正在聚合搜索，请稍候…' });
      } else if (!this.searched) {
        EmptyState({ message: '输入关键词搜索 SoNovel 书源' });
      } else if (this.errorMessage.length > 0) {
        EmptyState({ message: this.errorMessage });
      } else if (this.mergedResults.length === 0) {
        EmptyState({ message: '未找到相关书籍' });
      } else {
        if (this.sourceOptions.length > 1) {
          this.sourceFilterRow();
        }
        Row() {
          Text(this.resultSummary())
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          Blank().layoutWeight(1);
          Text('点击查看详情，长按下载 EPUB')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'));
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 });

        if (this.visibleResults.length === 0) {
          EmptyState({ message: '该来源没有相关书籍', detail: '点其它书源芯片或选「全部」查看所有结果' });
        } else {
          BookCatalogView({
            items: this.catalogItems,
            isListMode: this.isListMode,
            loadingMore: false,
            onItemTap: (item: BookListItemData) => this.openMerged(item.id),
            onItemLongPress: (item: BookListItemData) => this.downloadMerged(item.id),
            onLoadMore: () => {},
          });
        }
      }
    }
    .width('100%')
    .height('100%');
  }

  /**
   * 书源筛选芯片行。
   *
   * 手写而非复用 `FilterChips`：芯片数量与文案都随搜索结果变化，而 `FilterChips` 的
   * `items` 是普通成员（非 `@Prop`），父级状态更新不会刷新它；书源名又长（如
   * 「全本小说网(quanben.io)」），必须横向滚动，而这些能力只本页需要，不值得改动
   * 被多处复用的公共组件。
   */
  @Builder
  sourceFilterRow() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.sourceChipItems(), (chip: FilterChipItem) => {
          ChipButton({
            label: chip.label,
            selected: this.selectedSourceId === chip.value,
            onTap: () => this.onSourceFilterChanged(chip.value),
          });
        }, (chip: FilterChipItem) => `source-${chip.value}-${chip.label}`);
      }
      .padding({ left: 16, right: 16, top: 4, bottom: 8 });
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%');
  }
}
