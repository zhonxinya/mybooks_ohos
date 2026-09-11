import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell, LoadingState
} from '../components';
import { TalebookApi, ApiMessageResult, apiErrorMessage } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { BookItem } from '../services/BookModels';

@Entry
@Component
struct MergeFormatsToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;

  @State leftQuery: string = '';
  @State leftResults: BookItem[] = [];
  @State leftId: number = 0;
  @State leftTitle: string = '';

  @State rightQuery: string = '';
  @State rightResults: BookItem[] = [];
  @State rightId: number = 0;
  @State rightTitle: string = '';

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private setMsg(text: string, error: boolean): void {
    this.message = text;
    this.isError = error;
  }

  private canMerge(): boolean {
    return this.leftId > 0 && this.rightId > 0 && this.leftId !== this.rightId;
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.setMsg('请先配置 Talebook 服务器', true);
        return;
      }
      await TalebookService.ensureAuthenticated();
      this.setMsg('左侧为来源（合并后删除），右侧为目标（保留）', false);
    } finally {
      this.loading = false;
    }
  }

  private async searchSide(side: string): Promise<void> {
    if (this.busy) {
      return;
    }
    const q = side === 'left' ? this.leftQuery.trim() : this.rightQuery.trim();
    if (q.length === 0) {
      this.setMsg('请输入书名关键字', true);
      return;
    }
    this.busy = true;
    try {
      const items: BookItem[] = await TalebookApi.search(q, 1, 20);
      if (side === 'left') {
        this.leftResults = items;
        this.leftId = 0;
        this.leftTitle = '';
      } else {
        this.rightResults = items;
        this.rightId = 0;
        this.rightTitle = '';
      }
      if (items.length === 0) {
        this.setMsg('未找到书籍', true);
      } else {
        this.setMsg(`找到 ${items.length} 本`, false);
      }
    } catch (e) {
      this.setMsg(`${e}`, true);
      if (side === 'left') {
        this.leftResults = [];
      } else {
        this.rightResults = [];
      }
    } finally {
      this.busy = false;
    }
  }

  private pickLeft(book: BookItem): void {
    if (this.leftId === book.id) {
      this.leftId = 0;
      this.leftTitle = '';
      return;
    }
    this.leftId = book.id;
    this.leftTitle = book.title;
    this.toast(`来源：${book.title}`);
  }

  private pickRight(book: BookItem): void {
    if (this.rightId === book.id) {
      this.rightId = 0;
      this.rightTitle = '';
      return;
    }
    this.rightId = book.id;
    this.rightTitle = book.title;
    this.toast(`目标：${book.title}`);
  }

  private confirmMerge(): void {
    if (this.busy) {
      return;
    }
    if (!this.canMerge()) {
      this.setMsg('请选择不同的来源书与目标书', true);
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '确认合并格式',
      message: `将来源「${this.leftTitle}」(#${this.leftId}) 的格式合并到目标「${this.rightTitle}」(#${this.rightId})，然后删除来源书。此操作不可撤销。`,
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '合并', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 1) {
        void this.doMerge();
      }
    }).catch(() => {});
  }

  private async doMerge(): Promise<void> {
    if (this.busy || !this.canMerge()) {
      return;
    }
    this.busy = true;
    try {
      const deletedId = this.leftId;
      const rsp: ApiMessageResult = await TalebookApi.mergeBookFormats(this.leftId, this.rightId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.setMsg(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '合并失败', true);
        return;
      }
      this.setMsg(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '合并成功', false);
      this.leftResults = this.leftResults.filter((b: BookItem) => b.id !== deletedId);
      this.rightResults = this.rightResults.filter((b: BookItem) => b.id !== deletedId);
      this.leftId = 0;
      this.leftTitle = '';
      this.rightId = 0;
      this.rightTitle = '';
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private bookSubtitle(book: BookItem): string {
    const authors = book.authors.length > 0 ? book.authors.join('、') : '';
    const base = authors.length > 0 ? authors : `ID ${book.id}`;
    return `${base} · #${book.id}`;
  }

  build() {
    Column() {
      PageScaffold({
        title: '格式合并',
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
      Scroll() {
        Column({ space: 12 }) {
          Text('把来源书的格式文件合并到目标书，然后删除来源书。两侧请选择不同书籍。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }

          Text('来源书（合并后删除）')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%');

          Column({ space: 10 }) {
            TextInput({ placeholder: '搜索书名', text: this.leftQuery })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.leftQuery = v;
              });
            if (this.leftId > 0) {
              Text(`已选来源：${this.leftTitle} (#${this.leftId})`)
                .fontSize(12)
                .fontColor($r('app.color.brand_primary'))
                .width('100%');
            }
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SecondaryButton({
            label: this.busy ? '搜索中…' : '搜索来源书',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.searchSide('left');
            },
          });

          if (this.leftResults.length > 0) {
            Column() {
              ForEach(this.leftResults, (book: BookItem) => {
                SettingCell({
                  title: this.leftId === book.id ? `✓ ${book.title}` : book.title,
                  subtitle: this.bookSubtitle(book),
                  showChevron: true,
                  onTap: () => {
                    this.pickLeft(book);
                  },
                });
              }, (book: BookItem) => `L-${book.id}`);
            }
            .width('100%')
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }

          Text('目标书（保留）')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%');

          Column({ space: 10 }) {
            TextInput({ placeholder: '搜索书名', text: this.rightQuery })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.rightQuery = v;
              });
            if (this.rightId > 0) {
              Text(`已选目标：${this.rightTitle} (#${this.rightId})`)
                .fontSize(12)
                .fontColor($r('app.color.brand_primary'))
                .width('100%');
            }
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SecondaryButton({
            label: this.busy ? '搜索中…' : '搜索目标书',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.searchSide('right');
            },
          });

          if (this.rightResults.length > 0) {
            Column() {
              ForEach(this.rightResults, (book: BookItem) => {
                SettingCell({
                  title: this.rightId === book.id ? `✓ ${book.title}` : book.title,
                  subtitle: this.bookSubtitle(book),
                  showChevron: true,
                  onTap: () => {
                    this.pickRight(book);
                  },
                });
              }, (book: BookItem) => `R-${book.id}`);
            }
            .width('100%')
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }

          PrimaryButton({
            label: this.busy ? '合并中…' : '合并格式',
            buttonEnabled: !this.busy && this.canMerge(),
            onTap: () => {
              this.confirmMerge();
            },
          });
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off);
    }
  }
}
