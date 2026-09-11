import { router } from '@kit.ArkUI';
import {
  PageScaffold, EmptyState, SwipeDeleteAction, LoadingState, AuthImage, IconCircleButton,
  SectionTitle, LazyDataSource, BookListItem, BookListItemData,
} from '../components';
import { DownloadRecord, ReadingHistoryItem, TalebookService } from '../services/TalebookService';
import { TalebookApi } from '../services/TalebookApi';
import { BookItem as ApiBookItem } from '../services/BookModels';
import { ReadingStatsSummary } from '../models/HomeModels';
import { DateFormat } from '../utils/DateFormat';

interface OnlineBook {
  id: number;
  title: string;
  cover: string;
}

/** 列表行：分组标题或历史卡片，统一走 LazyForEach 保持懒加载。 */
interface HistoryRow {
  isHeader: boolean;
  key: string;
  title: string;
  author: string;
  cover: string;
  subtitle: string;
  format: string;
  bookId: string;
  filePath: string;
  location: string;
}

const GROUP_TODAY: number = 0;
const GROUP_YESTERDAY: number = 1;
const GROUP_WEEK: number = 2;
const GROUP_EARLIER: number = 3;
const GROUP_LABELS: string[] = ['今天', '昨天', '7 天内', '更早'];
const DAY_MS: number = 86400000;

@Entry
@Component
struct ReadingHistoryPage {
  @State records: ReadingHistoryItem[] = [];
  @State onlineBooks: OnlineBook[] = [];
  @State stats: ReadingStatsSummary | null = null;
  @State loadingOnline: boolean = false;
  @State onlineError: string = '';
  private historySource: LazyDataSource<HistoryRow> = new LazyDataSource<HistoryRow>();

  aboutToAppear(): void {
    this.reloadHistory();
    void this.loadOnlineData();
  }

  onPageShow(): void {
    this.reloadHistory();
  }

  private reloadHistory(): void {
    this.records = TalebookService.getReadingHistory();
    this.historySource.update(this.buildRows(this.records));
  }

  private groupOf(timestamp: number): number {
    const now = new Date();
    const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    if (timestamp >= startOfToday) {
      return GROUP_TODAY;
    }
    if (timestamp >= startOfToday - DAY_MS) {
      return GROUP_YESTERDAY;
    }
    if (timestamp >= startOfToday - 6 * DAY_MS) {
      return GROUP_WEEK;
    }
    return GROUP_EARLIER;
  }

  private progressText(item: ReadingHistoryItem): string {
    if (item.chapterName !== undefined && item.chapterName.length > 0) {
      return `读到：${item.chapterName}`;
    }
    if (item.progressPercent !== undefined && item.progressPercent >= 0) {
      return `已读 ${Math.round(item.progressPercent)}%`;
    }
    const totalPages = item.totalPages ?? 0;
    if (item.currentPage !== undefined && totalPages > 0) {
      return `${item.currentPage}/${totalPages} 页`;
    }
    return '';
  }

  private subtitleOf(item: ReadingHistoryItem): string {
    const parts: string[] = [];
    const progress = this.progressText(item);
    if (progress.length > 0) {
      parts.push(progress);
    }
    const lastRead = DateFormat.lastReadLabel(item.lastReadTime);
    if (lastRead.length > 0) {
      parts.push(lastRead);
    }
    return parts.join(' · ');
  }

  /** 历史记录不含封面/作者，按 bookId 或 filePath 回查下载记录补齐。 */
  private buildRows(records: ReadingHistoryItem[]): HistoryRow[] {
    const downloadMap = new Map<string, DownloadRecord>();
    for (const record of TalebookService.getDownloads()) {
      if (record.bookId.length > 0) {
        downloadMap.set(record.bookId, record);
      }
      const recordPath = record.filePath ?? '';
      if (recordPath.length > 0) {
        downloadMap.set(recordPath, record);
      }
    }
    const sorted = records.slice().sort((a: ReadingHistoryItem, b: ReadingHistoryItem) =>
      b.lastReadTime - a.lastReadTime);
    const rows: HistoryRow[] = [];
    let currentGroup = -1;
    for (const item of sorted) {
      const group = this.groupOf(item.lastReadTime);
      if (group !== currentGroup) {
        currentGroup = group;
        rows.push({
          isHeader: true,
          key: `group-${group}`,
          title: GROUP_LABELS[group],
          author: '',
          cover: '',
          subtitle: '',
          format: '',
          bookId: '',
          filePath: '',
          location: '',
        });
      }
      rows.push(this.toRow(item, downloadMap));
    }
    return rows;
  }

  private toRow(item: ReadingHistoryItem, downloadMap: Map<string, DownloadRecord>): HistoryRow {
    const filePath = item.filePath ?? '';
    let download = downloadMap.get(item.bookId);
    if (download === undefined && filePath.length > 0) {
      download = downloadMap.get(filePath);
    }
    const coverUrl = item.coverUrl !== undefined && item.coverUrl.length > 0
      ? item.coverUrl
      : (download?.coverUrl ?? '');
    const author = item.author !== undefined && item.author.length > 0
      ? item.author
      : (download?.author ?? '');
    const format = item.format !== undefined && item.format.length > 0
      ? item.format
      : (download?.format ?? '');
    return {
      isHeader: false,
      key: `item-${item.bookId}-${filePath}`,
      title: item.title,
      author: author,
      cover: coverUrl.length > 0 ? TalebookService.resolveCoverUrl(coverUrl) : '',
      subtitle: this.subtitleOf(item),
      format: format,
      bookId: item.bookId,
      filePath: filePath,
      location: item.location ?? '',
    };
  }

  private toListItem(row: HistoryRow): BookListItemData {
    return {
      id: row.bookId,
      title: row.title,
      author: row.author,
      cover: row.cover,
      subtitle: row.subtitle,
      format: row.format,
    };
  }

  private async loadOnlineData(): Promise<void> {
    if (!TalebookService.hasAuthCredentials()) {
      return;
    }
    this.loadingOnline = true;
    this.onlineError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const historyPromise = TalebookApi.getOnlineReadingHistory();
      const statsPromise = TalebookApi.getReadingStats();
      const history = await historyPromise;
      const stats = await statsPromise;
      this.onlineBooks = history.map((item: ApiBookItem): OnlineBook => ({
        id: item.id,
        title: item.title,
        cover: TalebookService.resolveCoverUrl(item.coverUrl),
      }));
      this.stats = stats;
    } catch (error) {
      this.onlineError = error instanceof Error ? error.message : `${error}`;
    } finally {
      this.loadingOnline = false;
    }
  }

  private confirmClearOnlineHistory(): void {
    this.getUIContext().showAlertDialog({
      title: '清空在线阅读历史',
      message: '确定清空服务端的在线阅读历史吗？该操作不可恢复。',
      primaryButton: {
        value: '清空',
        action: () => {
          TalebookApi.clearOnlineReadingHistory()
            .then((rsp) => {
              if (rsp.err === undefined || rsp.err === 'ok') {
                this.getUIContext().getPromptAction().showToast({ message: '已清空' });
                void this.loadOnlineData();
              } else {
                this.getUIContext().getPromptAction().showToast({
                  message: rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err,
                });
              }
            })
            .catch((e: Object) => {
              this.getUIContext().getPromptAction().showToast({ message: `清空失败：${e}` });
            });
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private deleteItem(row: HistoryRow): void {
    TalebookService.removeHistoryItem(row.bookId, row.filePath);
    this.reloadHistory();
    this.getUIContext().getPromptAction().showToast({ message: '已删除' });
  }

  private openBook(bookId: number): void {
    router.pushUrl({ url: 'pages/BookDetailPage', params: { bookId: bookId } });
  }

  private openHistory(row: HistoryRow): void {
    if (row.filePath.length > 0) {
      router.pushUrl({
        url: 'pages/ReadKitReader',
        params: {
          filePath: row.filePath,
          bookId: row.bookId,
          bookTitle: row.title,
          format: row.format,
          location: row.location,
        },
      });
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: '未找到本地文件，无法继续阅读' });
  }

  @Builder
  historyRow(row: HistoryRow) {
    if (row.isHeader) {
      Text(row.title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ top: 12, bottom: 2 });
    } else {
      BookListItem({
        item: this.toListItem(row),
        onTap: () => this.openHistory(row),
      });
    }
  }

  @Builder
  rowActions(row: HistoryRow) {
    if (!row.isHeader) {
      SwipeDeleteAction({ onDelete: () => this.deleteItem(row) });
    }
  }

  @Builder
  clearHistoryAction() {
    if (this.onlineBooks.length > 0) {
      IconCircleButton({
        icon: $r('sys.symbol.trash'),
        variant: 'soft',
        iconSize: 16,
        buttonSize: 32,
        onTap: () => this.confirmClearOnlineHistory(),
      });
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '阅读历史',
        showBack: true,
        action: () => {
          this.clearHistoryAction();
        },
        content: () => {
          this.historyContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  statCell(label: string, value: number) {
    Column({ space: 4 }) {
      Text(`${value}`)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  onlineSection() {
    Column({ space: 4 }) {
      if (this.stats !== null) {
        Row() {
          this.statCell('总在读', this.stats.totalReading);
          this.statCell('总读完', this.stats.totalReadDone);
          this.statCell('本月在读', this.stats.monthReading);
          this.statCell('本月读完', this.stats.monthReadDone);
        }
        .width('100%')
        .padding($r('app.float.card_padding'))
        .margin({ left: 16, right: 16, top: 8 })
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));
      }
      if (this.onlineBooks.length > 0) {
        SectionTitle({ title: '在线阅读' });
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.onlineBooks, (book: OnlineBook) => {
              Column({ space: 4 }) {
                AuthImage({
                  url: book.cover,
                  imageWidth: 78,
                  imageHeight: 110,
                });
                Text(book.title)
                  .fontSize(11)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width(78);
              }
              .alignItems(HorizontalAlign.Start)
              .onClick(() => this.openBook(book.id));
            }, (book: OnlineBook) => `online-${book.id}`);
          }
          .padding({ left: 16, right: 16 });
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%');
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  historyContent() {
    if (this.loadingOnline && this.onlineBooks.length === 0 && this.records.length === 0) {
      LoadingState({});
    } else if (this.onlineError.length > 0 && this.records.length === 0) {
      EmptyState({ message: this.onlineError });
    } else if (this.records.length === 0 && this.onlineBooks.length === 0 &&
      this.stats === null) {
      EmptyState({
        message: '暂无阅读历史',
        detail: '打开任意书籍开始阅读后，这里会记录你的阅读进度',
        actionLabel: '去书架',
        onAction: () => router.pushUrl({ url: 'pages/MainTabs' }),
      });
    } else {
      List({ space: 8 }) {
        ListItem() {
          this.onlineSection();
        }
        LazyForEach(this.historySource, (row: HistoryRow) => {
          ListItem() {
            this.historyRow(row);
          }
          .padding({ left: 16, right: 16 })
          .swipeAction({
            end: {
              builder: () => {
                this.rowActions(row);
              },
            },
          });
        }, (row: HistoryRow) => row.key);
      }
      .layoutWeight(1)
      .cachedCount(8);
    }
  }
}

