import {
  PageScaffold, SearchBar, BookCatalogView, BookViewToggleButton, BookListItemData,
  LoadingState, EmptyState, IconCircleButton,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookApi } from '../services/TalebookApi';
import { SoNovelService } from '../services/SoNovelService';
import { BookViewMode } from '../utils/BookViewMode';
import { DownloadTaskService } from '../services/DownloadTaskService';
import { MergedSoNovelResult, SoNovelMerge, SoNovelSearchItem } from '../utils/SoNovelMerge';
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

@Entry
@Component
struct SoNovelSearchPage {
  @State keyword: string = '';
  @State mergedResults: MergedSoNovelResult[] = [];
  @State loading: boolean = false;
  @State searched: boolean = false;
  @State isListMode: boolean = false;
  @State errorMessage: string = '';
  @State catalogItems: BookListItemData[] = [];
  @State activeTaskCount: number = 0;
  @State showSourceSheet: boolean = false;
  @State sheetMergedIndex: number = -1;
  /** 与 mergedResults 同序：该书是否已在书库。 */
  @State inLibrary: boolean[] = [];
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
    this.catalogItems = [];
    this.inLibrary = [];
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
        this.catalogItems = [];
        return;
      }
      const body = envelope.body ?? {};
      const raw = (body['data'] as Record<string, Object>[] | undefined) ?? [];
      const items: SoNovelSearchItem[] = [];
      for (let i = 0; i < raw.length; i++) {
        items.push(SoNovelMerge.fromRecord(raw[i]));
      }
      this.mergedResults = SoNovelMerge.merge(items);
      this.syncCatalogItems();
      // 不 await：先出结果，入库角标随后补齐，避免书库查询拖慢搜索
      void this.checkLibraryMembership(token);
    } catch (error) {
      if (token !== this.searchToken) {
        return;
      }
      this.errorMessage = error instanceof Error ? error.message : `${error}`;
      this.mergedResults = [];
      this.catalogItems = [];
    } finally {
      if (token === this.searchToken) {
        this.loading = false;
      }
    }
  }

  private syncCatalogItems(): void {
    this.catalogItems = this.mergedResults.map((merged: MergedSoNovelResult, index: number): BookListItemData => {
      const sourceCount = merged.sources.length;
      return {
        id: `${index}`,
        title: merged.bookName.length > 0 ? merged.bookName : '未知',
        author: merged.author,
        subtitle: SoNovelMerge.subtitle(merged),
        format: sourceCount > 1 ? `${sourceCount}源` : 'EPUB',
        badge: this.isInLibrary(index) ? BADGE_IN_LIBRARY : '',
      };
    });
  }

  private isInLibrary(index: number): boolean {
    return index < this.inLibrary.length && this.inLibrary[index];
  }

  private libraryMatchCount(): number {
    let count = 0;
    for (let i = 0; i < this.inLibrary.length; i++) {
      if (this.inLibrary[i]) {
        count++;
      }
    }
    return count;
  }

  private resultSummary(): string {
    const total = `共 ${this.mergedResults.length} 本`;
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
    const flags: boolean[] = [];
    for (let i = 0; i < results.length; i++) {
      flags.push(false);
    }
    let next = 0;
    const worker = async (): Promise<void> => {
      while (next < total) {
        const index = next;
        next++;
        const item = results[index];
        flags[index] = await this.isBookInLibrary(item.bookName, item.author);
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
    this.inLibrary = flags;
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

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private openMerged(index: number): void {
    if (index < 0 || index >= this.mergedResults.length) {
      return;
    }
    const merged = this.mergedResults[index];
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
  private downloadMerged(index: number): void {
    if (index < 0 || index >= this.mergedResults.length) {
      return;
    }
    const merged = this.mergedResults[index];
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
    if (this.sheetMergedIndex < 0 || this.sheetMergedIndex >= this.mergedResults.length) {
      return null;
    }
    return this.mergedResults[this.sheetMergedIndex];
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
      if (this.isInLibrary(this.sheetMergedIndex)) {
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

        BookCatalogView({
          items: this.catalogItems,
          isListMode: this.isListMode,
          loadingMore: false,
          onItemTap: (item: BookListItemData) => this.openMerged(Number(item.id)),
          onItemLongPress: (item: BookListItemData) => this.downloadMerged(Number(item.id)),
          onLoadMore: () => {},
        });
      }
    }
    .width('100%')
    .height('100%');
  }
}
