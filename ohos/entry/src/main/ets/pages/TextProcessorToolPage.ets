import {
  PageScaffold, PrimaryButton, SecondaryButton, SettingCell, LoadingState
} from '../components';
import { TalebookApi } from '../services/TalebookApi';
import { TalebookService, ApiEnvelope } from '../services/TalebookService';
import { BookItem, BookDetail } from '../services/BookModels';

class TpRule {
  keyword: string = '';
  style: string = 'bold';
}

@Entry
@Component
struct TextProcessorToolPage {
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State message: string = '';
  @State isError: boolean = false;

  @State inputText: string = '';
  @State htmlCode: string = '';
  @State previewPlain: string = '';

  @State rules: TpRule[] = [];
  @State newKeyword: string = '';
  @State newStyle: string = 'bold';

  @State bookQuery: string = '';
  @State bookResults: BookItem[] = [];
  @State selectedBookId: number = 0;
  @State selectedBookTitle: string = '';

  private readonly styleKeys: string[] = ['bold', 'big', 'bold-big', 'color'];

  aboutToAppear(): void {
    this.resetDefaultRules();
    void this.bootstrap();
  }

  private resetDefaultRules(): void {
    const defaults: TpRule[] = [];
    const pairs: string[][] = [
      ['重要', 'bold'],
      ['注意', 'bold-big'],
      ['警告', 'color'],
      ['提示', 'bold'],
      ['关键', 'bold-big'],
    ];
    for (let i = 0; i < pairs.length; i++) {
      const r = new TpRule();
      r.keyword = pairs[i][0];
      r.style = pairs[i][1];
      defaults.push(r);
    }
    this.rules = defaults;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private setMsg(text: string, error: boolean): void {
    this.message = text;
    this.isError = error;
  }

  private styleLabel(style: string): string {
    if (style === 'bold') {
      return '加粗';
    }
    if (style === 'big') {
      return '加大';
    }
    if (style === 'bold-big') {
      return '加粗加大';
    }
    if (style === 'color') {
      return '高亮色';
    }
    return style;
  }

  private cycleNewStyle(): void {
    const idx = this.styleKeys.indexOf(this.newStyle);
    const next = idx < 0 ? 0 : (idx + 1) % this.styleKeys.length;
    this.newStyle = this.styleKeys[next];
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.setMsg('请先配置 Talebook 服务器', true);
        return;
      }
      await TalebookService.ensureAuthenticated();
      this.setMsg('处理在本地完成；可选搜书后写回简介', false);
    } finally {
      this.loading = false;
    }
  }

  private escapeHtml(str: string): string {
    return str
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  private escapeRegExp(str: string): string {
    return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  private formatBookNames(text: string): string {
    return text.replace(/《([^》]+)》/g, '<b>《$1》</b>');
  }

  private applyRules(escapedLine: string): string {
    let processed = escapedLine;
    const sorted: TpRule[] = this.rules.slice().sort((a: TpRule, b: TpRule) => {
      return b.keyword.length - a.keyword.length;
    });
    for (let i = 0; i < sorted.length; i++) {
      const rule = sorted[i];
      if (rule.keyword.length === 0) {
        continue;
      }
      const escapedKeyword = this.escapeHtml(rule.keyword);
      const regex = new RegExp(this.escapeRegExp(escapedKeyword), 'g');
      let replacement = escapedKeyword;
      if (rule.style === 'bold') {
        replacement = `<span class="highlight-bold">${escapedKeyword}</span>`;
      } else if (rule.style === 'big' || rule.style === 'bold-big') {
        replacement = `<h2>${escapedKeyword}</h2>`;
      } else if (rule.style === 'color') {
        replacement = `<span class="highlight-color">${escapedKeyword}</span>`;
      }
      processed = processed.replace(regex, replacement);
    }
    return processed;
  }

  private stripTags(html: string): string {
    return html
      .replace(/<\/(p|div|h[1-6]|li|tr|blockquote)>/gi, '\n\n')
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  private processText(): void {
    const raw = this.inputText;
    if (raw.trim().length === 0) {
      this.htmlCode = '';
      this.previewPlain = '';
      return;
    }
    const normalized = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const paragraphs = normalized.split(/\n{2,}/).filter((p: string) => p.trim().length > 0);
    const htmlParts: string[] = [];
    for (let i = 0; i < paragraphs.length; i++) {
      const para = paragraphs[i];
      const lines = para.trim().split('\n').filter((l: string) => l.trim().length > 0);
      if (lines.length === 0) {
        continue;
      }
      const escapedLines: string[] = [];
      for (let j = 0; j < lines.length; j++) {
        escapedLines.push(this.formatBookNames(this.applyRules(this.escapeHtml(lines[j]))));
      }
      htmlParts.push(`<p>${escapedLines.join('<br>')}</p>`);
    }
    this.htmlCode = htmlParts.join('\n');
    this.previewPlain = this.stripTags(this.htmlCode);
  }

  private addRule(): void {
    const keyword = this.newKeyword.trim();
    if (keyword.length === 0) {
      this.setMsg('请填写关键词', true);
      return;
    }
    for (let i = 0; i < this.rules.length; i++) {
      if (this.rules[i].keyword === keyword && this.rules[i].style === this.newStyle) {
        this.setMsg('相同规则已存在', true);
        return;
      }
    }
    const next: TpRule[] = this.rules.slice();
    const r = new TpRule();
    r.keyword = keyword;
    r.style = this.newStyle;
    next.push(r);
    this.rules = next;
    this.newKeyword = '';
    this.processText();
    this.setMsg('已添加规则', false);
  }

  private removeRule(index: number): void {
    if (index < 0 || index >= this.rules.length) {
      return;
    }
    const next: TpRule[] = [];
    for (let i = 0; i < this.rules.length; i++) {
      if (i !== index) {
        next.push(this.rules[i]);
      }
    }
    this.rules = next;
    this.processText();
  }

  private async searchBooks(): Promise<void> {
    if (this.busy) {
      return;
    }
    const q = this.bookQuery.trim();
    if (q.length === 0) {
      this.setMsg('请输入书名关键字', true);
      return;
    }
    this.busy = true;
    try {
      const items: BookItem[] = await TalebookApi.search(q, 1, 20);
      this.bookResults = items;
      if (items.length === 0) {
        this.setMsg('未找到书籍', true);
      } else {
        this.setMsg(`找到 ${items.length} 本`, false);
      }
    } catch (e) {
      this.setMsg(`${e}`, true);
      this.bookResults = [];
    } finally {
      this.busy = false;
    }
  }

  private async pickBook(book: BookItem): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      this.selectedBookId = book.id;
      this.selectedBookTitle = book.title;
      this.bookResults = [];
      const detail: BookDetail | null = await TalebookApi.getBookDetail(book.id);
      const comments = detail !== null ? detail.comments : '';
      this.inputText = this.stripTags(comments.length > 0 ? comments : '');
      this.processText();
      this.setMsg(`已载入「${book.title}」简介`, false);
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private async updateBookComments(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.selectedBookId <= 0) {
      this.setMsg('请先搜索并选择一本书', true);
      return;
    }
    if (this.htmlCode.trim().length === 0) {
      this.setMsg('没有可写回的 HTML', true);
      return;
    }
    this.busy = true;
    try {
      const payload: Record<string, Object> = {
        'comments': this.htmlCode,
      };
      const envelope: ApiEnvelope = await TalebookService.editBookAsync(this.selectedBookId, payload);
      if (envelope.status >= 200 && envelope.status < 300) {
        this.setMsg(`已更新「${this.selectedBookTitle}」简介`, false);
      } else {
        this.setMsg(envelope.error.length > 0 ? envelope.error : '写回失败', true);
      }
    } catch (e) {
      this.setMsg(`${e}`, true);
    } finally {
      this.busy = false;
    }
  }

  private clearAll(): void {
    this.inputText = '';
    this.htmlCode = '';
    this.previewPlain = '';
    this.setMsg('已清空', false);
  }

  build() {
    Column() {
      PageScaffold({
        title: '文本处理',
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
          Text('按规则把纯文本转成带段落/高亮的 HTML。可搜书载入简介，处理后写回。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(13)
              .fontColor(this.isError ? $r('app.color.error') : $r('app.color.success'))
              .width('100%');
          }

          Text('规则')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%');

          Column({ space: 10 }) {
            TextInput({ placeholder: '新关键词', text: this.newKeyword })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.newKeyword = v;
              });
            SettingCell({
              title: '样式',
              subtitle: this.styleLabel(this.newStyle),
              showChevron: true,
              onTap: () => {
                this.cycleNewStyle();
              },
            });
          }
          .width('100%')
          .padding(12)
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          SecondaryButton({
            label: '添加规则',
            buttonEnabled: !this.busy,
            onTap: () => {
              this.addRule();
            },
          });

          if (this.rules.length > 0) {
            Column() {
              ForEach(this.rules, (rule: TpRule, index: number) => {
                SettingCell({
                  title: rule.keyword,
                  subtitle: `${this.styleLabel(rule.style)} · 点按删除`,
                  showChevron: false,
                  onTap: () => {
                    this.removeRule(index);
                  },
                });
              }, (rule: TpRule, index: number) => `${rule.keyword}-${rule.style}-${index}`);
            }
            .width('100%')
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }

          Text('输入文本')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%');

          TextArea({ placeholder: '粘贴或输入纯文本…', text: this.inputText })
            .height(140)
            .borderRadius(8)
            .backgroundColor($r('app.color.card_background'))
            .padding(12)
            .onChange((v: string) => {
              this.inputText = v;
            });

          PrimaryButton({
            label: '生成 HTML',
            buttonEnabled: !this.busy,
            onTap: () => {
              this.processText();
              this.setMsg(this.htmlCode.length > 0 ? '已生成 HTML' : '输入为空', this.htmlCode.length === 0);
            },
          });
          SecondaryButton({
            label: '清空',
            buttonEnabled: !this.busy,
            onTap: () => {
              this.clearAll();
            },
          });

          if (this.previewPlain.length > 0) {
            Text('预览（纯文本）')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%');
            Text(this.previewPlain)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(12)
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
          }

          if (this.htmlCode.length > 0) {
            Text('HTML 代码')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%');
            Text(this.htmlCode)
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding(12)
              .borderRadius($r('app.float.card_radius'))
              .backgroundColor($r('app.color.card_background'));
          }

          Text('写回书籍简介')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%');

          Column({ space: 10 }) {
            TextInput({ placeholder: '书名关键字', text: this.bookQuery })
              .height(40)
              .borderRadius(8)
              .backgroundColor($r('app.color.page_background'))
              .onChange((v: string) => {
                this.bookQuery = v;
              });
            if (this.selectedBookId > 0) {
              Text(`已选：${this.selectedBookTitle} (#${this.selectedBookId})`)
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
            label: this.busy ? '搜索中…' : '搜索书籍',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.searchBooks();
            },
          });

          if (this.bookResults.length > 0) {
            Column() {
              ForEach(this.bookResults, (book: BookItem) => {
                SettingCell({
                  title: book.title,
                  subtitle: book.authors.length > 0 ? book.authors.join('、') : `ID ${book.id}`,
                  showChevron: true,
                  onTap: () => {
                    void this.pickBook(book);
                  },
                });
              }, (book: BookItem) => `book-${book.id}`);
            }
            .width('100%')
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }

          PrimaryButton({
            label: this.busy ? '写回中…' : '写回简介',
            buttonEnabled: !this.busy && this.selectedBookId > 0 && this.htmlCode.length > 0,
            onTap: () => {
              void this.updateBookComments();
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
