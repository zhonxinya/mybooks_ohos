import { PageScaffold, LoadingState, EmptyState, DangerButton } from '../components';
import { TalebookApi } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { ApiMessageResult } from '../services/TalebookApi';

const KB: number = 1024;
const MB: number = 1024 * 1024;
const GB: number = 1024 * 1024 * 1024;
const CLEAR_THRESHOLD_BYTES: number = 10 * MB;

@Entry
@Component
struct AdminTrashPage {
  @State books: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State trashSize: number = 0;
  @State uploadSize: number = 0;
  @State working: boolean = false;

  aboutToAppear(): void {
    void this.load();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private async load(): Promise<void> {
    this.loading = this.books.length === 0;
    try {
      await TalebookService.ensureAuthenticated();
      const booksRsp = await TalebookApi.getTrashBooks();
      if (booksRsp.err !== undefined && booksRsp.err !== 'ok') {
        this.toast(booksRsp.msg !== undefined && booksRsp.msg.length > 0 ? booksRsp.msg : booksRsp.err);
      } else {
        this.books = booksRsp.books ?? [];
      }
      const sizeRsp = await TalebookApi.getTrashSize();
      if (sizeRsp.err === undefined || sizeRsp.err === 'ok') {
        const sizes = sizeRsp.sizes ?? {};
        this.trashSize = Number(sizes['trash'] ?? 0);
        this.uploadSize = Number(sizes['upload'] ?? 0);
      }
    } catch (e) {
      this.toast(`加载失败：${e}`);
    } finally {
      this.loading = false;
    }
  }

  private formatSize(size: number): string {
    if (size < KB) {
      return `${size} B`;
    }
    if (size < MB) {
      return `${(size / KB).toFixed(1)} KB`;
    }
    if (size < GB) {
      return `${(size / MB).toFixed(2)} MB`;
    }
    return `${(size / GB).toFixed(2)} GB`;
  }

  private formatTime(timestamp: number): string {
    if (timestamp <= 0) {
      return '未知';
    }
    const ms = timestamp < 100000000000 ? timestamp * 1000 : timestamp;
    const date = new Date(ms);
    const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
      `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  private handleResult(rsp: ApiMessageResult, fallback: string): void {
    if (rsp.err === undefined || rsp.err === 'ok') {
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : fallback);
    } else {
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
    }
  }

  private restoreBook(bookId: number): void {
    if (this.working) {
      return;
    }
    this.working = true;
    TalebookApi.restoreTrashBooks([bookId])
      .then((rsp: ApiMessageResult) => {
        this.working = false;
        this.handleResult(rsp, '已恢复');
        void this.load();
      })
      .catch((e: Object) => {
        this.working = false;
        this.toast(`恢复失败：${e}`);
      });
  }

  private purgeBook(book: Record<string, Object>): void {
    const bookId = Number(book['book_id'] ?? 0);
    this.getUIContext().showAlertDialog({
      title: '彻底删除',
      message: `确定彻底删除「${String(book['title'] ?? '')}」吗？文件将被永久删除，无法恢复。`,
      primaryButton: {
        value: '彻底删除',
        action: () => {
          if (this.working) {
            return;
          }
          this.working = true;
          TalebookApi.purgeTrashBooks([bookId])
            .then((rsp: ApiMessageResult) => {
              this.working = false;
              this.handleResult(rsp, '已彻底删除');
              void this.load();
            })
            .catch((e: Object) => {
              this.working = false;
              this.toast(`删除失败：${e}`);
            });
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private clearTrash(): void {
    this.getUIContext().showAlertDialog({
      title: '清理回收站',
      message: '确定清理回收站（library/.caltrash）及上传临时目录（upload）吗？此操作不可恢复。',
      primaryButton: {
        value: '确认清理',
        action: () => {
          if (this.working) {
            return;
          }
          this.working = true;
          TalebookApi.clearTrash()
            .then((rsp: ApiMessageResult) => {
              this.working = false;
              this.handleResult(rsp, '已清理');
              void this.load();
            })
            .catch((e: Object) => {
              this.working = false;
              this.toast(`清理失败：${e}`);
            });
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private showBookActions(book: Record<string, Object>): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: String(book['title'] ?? ''),
      buttons: [
        { text: '恢复到书库', color: '#007DFF' },
        { text: '彻底删除', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        this.restoreBook(Number(book['book_id'] ?? 0));
      } else if (result.index === 1) {
        this.purgeBook(book);
      }
    }).catch(() => {});
  }

  build() {
    Column() {
      PageScaffold({
        title: '回收站管理',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  pageContent() {
    if (this.loading) {
      LoadingState({});
    } else {
      List({ space: 12 }) {
        ListItem() {
          this.sizeCard();
        }
        if (this.books.length === 0) {
          ListItem() {
            EmptyState({ message: '回收站为空' });
          }
        } else {
          ForEach(this.books, (book: Record<string, Object>) => {
            ListItem() {
              this.bookRow(book);
            }
          }, (book: Record<string, Object>) => `trash-${Number(book['book_id'] ?? 0)}`);
        }
        ListItem() {
          DangerButton({
            label: this.working ? '处理中…' : '清理回收站与上传目录',
            buttonEnabled: !this.working && this.trashSize + this.uploadSize > CLEAR_THRESHOLD_BYTES,
            onTap: () => this.clearTrash(),
          });
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      .scrollBar(BarState.Off);
    }
  }

  @Builder
  sizeCard() {
    Column({ space: 8 }) {
      Text('空间占用')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Text(`Calibre 回收站：${this.formatSize(this.trashSize)}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'));
      Text(`上传临时目录：${this.formatSize(this.uploadSize)}`)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'));
      Text('删除的书籍保留在回收站中，可随时恢复；总占用超过 10MB 时可执行清理。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  bookRow(book: Record<string, Object>) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(String(book['title'] ?? ''))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${String(book['author'] ?? '')} · 删除于 ${this.formatTime(Number(book['deleted_at'] ?? 0))}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.showBookActions(book));
  }
}
