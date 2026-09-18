import { TalebookApi } from '../services/TalebookApi';
import { BookItem } from '../services/BookModels';
import { SettingCell } from './SettingCell';
import { SecondaryButton } from './SecondaryButton';
import { TextButton } from './TextButton';

/**
 * 书籍 ID 选择器：手动填写 ID + 按书名/作者搜索后点选。
 *
 * - 单选（默认）：点选后直接覆盖 `bookIdText`。
 * - 多选（`multi=true`，如 EPUB 美化）：点选后追加 ID（去重），可清空。
 *
 * 宿主用法：
 * ```
 * BookIdPicker({ bookIdText: $bookIdText })
 * BookIdPicker({ bookIdText: $bookIdsText, multi: true })
 * ```
 */
@Component
export struct BookIdPicker {
  @Link bookIdText: string;
  multi: boolean = false;
  @State private query: string = '';
  @State private results: BookItem[] = [];
  @State private searching: boolean = false;
  @State private searchHint: string = '';
  @State private pickedId: number = 0;
  @State private pickedTitle: string = '';

  private placeholder(): string {
    return this.multi ? '书籍 ID（多个用逗号分隔，可手动填写）' : '书籍 ID（可手动填写）';
  }

  private subtitle(book: BookItem): string {
    const authors = book.authors.length > 0 ? book.authors.join('、') : '';
    const base = authors.length > 0 ? authors : `ID ${book.id}`;
    return `${base} · #${book.id}`;
  }

  private parseIds(): number[] {
    const raw = this.bookIdText.replace(/，/g, ',');
    const parts = raw.split(/[,\s]+/);
    const ids: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const n = Number(parts[i].trim());
      if (n > 0 && ids.indexOf(n) < 0) {
        ids.push(n);
      }
    }
    return ids;
  }

  private isPicked(id: number): boolean {
    if (this.multi) {
      return this.parseIds().indexOf(id) >= 0;
    }
    if (this.pickedId > 0) {
      return this.pickedId === id;
    }
    return this.bookIdText.trim() === `${id}`;
  }

  private multiSummary(): string {
    const ids = this.parseIds();
    if (ids.length === 0) {
      return '';
    }
    return `已选 ${ids.length} 本：${ids.join('、')}`;
  }

  private hasSinglePicked(): boolean {
    return this.pickedId > 0 && this.bookIdText.trim() === `${this.pickedId}`;
  }

  private singleSummary(): string {
    if (!this.hasSinglePicked()) {
      return '';
    }
    return `已选：${this.pickedTitle} (#${this.pickedId})`;
  }

  private manualSummary(): string {
    const id = this.bookIdText.trim();
    if (id.length === 0 || this.hasSinglePicked()) {
      return '';
    }
    return `当前 ID：${id}`;
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private async searchBooks(): Promise<void> {
    if (this.searching) {
      return;
    }
    const q = this.query.trim();
    if (q.length === 0) {
      this.searchHint = '请输入书名/作者关键字后搜索';
      return;
    }
    this.searching = true;
    this.searchHint = '';
    try {
      const items: BookItem[] = await TalebookApi.search(q, 1, 20);
      this.results = items;
      this.searchHint = items.length === 0 ? '未找到书籍，可换关键词或手动填写 ID' : `找到 ${items.length} 本，点选即可填入`;
    } catch (e) {
      this.results = [];
      this.searchHint = `搜索失败：${e}`;
    } finally {
      this.searching = false;
    }
  }

  private pick(book: BookItem): void {
    if (this.multi) {
      const ids = this.parseIds();
      if (ids.indexOf(book.id) < 0) {
        ids.push(book.id);
        this.bookIdText = ids.join(',');
      }
      this.toast(`已加入：${book.title} (#${book.id})`);
      return;
    }
    this.bookIdText = `${book.id}`;
    this.pickedId = book.id;
    this.pickedTitle = book.title;
    this.toast(`已选择：${book.title} (#${book.id})`);
  }

  private clearPicked(): void {
    this.bookIdText = '';
    this.pickedId = 0;
    this.pickedTitle = '';
  }

  build() {
    Column({ space: 8 }) {
      TextInput({ placeholder: this.placeholder(), text: this.bookIdText })
        .height(40)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'))
        .onChange((v: string) => {
          this.bookIdText = v;
        });
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索书名/作者后点选', text: this.query })
          .layoutWeight(1)
          .height(40)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((v: string) => {
            this.query = v;
          })
          .onSubmit(() => {
            void this.searchBooks();
          });
        SecondaryButton({
          label: this.searching ? '搜索中…' : '搜索',
          buttonEnabled: !this.searching,
          fullWidth: false,
          compact: true,
          onTap: () => {
            void this.searchBooks();
          },
        });
      }
      .width('100%');

      this.pickedInfo();

      if (this.searchHint.length > 0) {
        Text(this.searchHint)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }

      if (this.results.length > 0) {
        Column() {
          ForEach(this.results, (book: BookItem) => {
            SettingCell({
              title: this.isPicked(book.id) ? `✓ ${book.title}` : book.title,
              subtitle: this.subtitle(book),
              showChevron: true,
              onTap: () => {
                this.pick(book);
              },
            });
          }, (book: BookItem) => `bip-${book.id}`);
        }
        .width('100%')
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.page_background'));
      }
    }
    .width('100%');
  }

  @Builder
  pickedInfo() {
    if (this.multi && this.multiSummary().length > 0) {
      Row({ space: 8 }) {
        Text(this.multiSummary())
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        TextButton({
          label: '清空',
          tone: 'danger',
          onTap: () => {
            this.clearPicked();
          },
        });
      }
      .width('100%');
    }
    if (!this.multi && this.singleSummary().length > 0) {
      Row({ space: 8 }) {
        Text(this.singleSummary())
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        TextButton({
          label: '清除',
          tone: 'danger',
          onTap: () => {
            this.clearPicked();
          },
        });
      }
      .width('100%');
    }
    if (!this.multi && this.singleSummary().length === 0 && this.manualSummary().length > 0) {
      Text(this.manualSummary())
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
  }
}
