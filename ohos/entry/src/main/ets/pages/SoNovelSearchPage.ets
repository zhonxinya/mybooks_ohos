import {
  PageScaffold, SearchBar, BookCatalogView, BookViewToggleButton, BookListItemData,
  LoadingState, EmptyState, IconCircleButton,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { SoNovelService } from '../services/SoNovelService';
import { BookViewMode } from '../utils/BookViewMode';
import { DownloadTaskService } from '../services/DownloadTaskService';
import { MergedSoNovelResult, SoNovelMerge, SoNovelSearchItem } from '../utils/SoNovelMerge';

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
  private searchToken: number = 0;

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
      };
    });
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
          Text(`共 ${this.mergedResults.length} 本`)
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
