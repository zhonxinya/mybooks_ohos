import { PageScaffold, PrimaryButton, LoadingState, ChipButton } from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookApi, MetaNameCount } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';


@Entry
@Component
struct BookEditPage {
  @State bookId: number = 0;
  @State title: string = '';
  @State author: string = '';
  @State publisher: string = '';
  @State tags: string = '';
  @State description: string = '';
  @State isbn: string = '';
  @State series: string = '';
  @State seriesIndex: string = '';
  @State ratingStars: number = 0;
  @State language: string = '';
  @State translators: string = '';
  @State pubdate: string = '';
  @State saving: boolean = false;
  @State loading: boolean = true;
  @State message: string = '';
  @State authorHints: MetaNameCount[] = [];
  @State showAuthorHints: boolean = false;
  private lastHintTime: number = 0;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.bookId = Number(params['bookId'] ?? 0);
    void this.loadDetail();
  }

  private async loadDetail(): Promise<void> {
    this.loading = true;
    try {
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      const envelope = await TalebookService.getBookDetailAsync(this.bookId);
      const body = envelope.body ?? {};
      const book = (body['book'] as Record<string, Object> | undefined) ?? body;
      this.title = String(book['title'] ?? '');
      const authorList = (book['authors'] as string[] | undefined) ?? [];
      this.author = authorList.length > 0 ? authorList.join(', ') : String(book['author'] ?? '');
      this.publisher = String(book['publisher'] ?? '');
      const tagList = (book['tags'] as string[] | undefined) ?? [];
      this.tags = tagList.length > 0 ? tagList.join(', ') : String(book['tag'] ?? '');
      this.description = String(book['description'] ?? book['comments'] ?? '');
      this.isbn = String(book['isbn'] ?? '');
      this.series = String(book['series'] ?? '');
      const seriesIndex = book['series_index'];
      this.seriesIndex = seriesIndex !== null && seriesIndex !== undefined ? String(seriesIndex) : '';
      const rating = Number(book['rating'] ?? 0);
      this.ratingStars = rating > 0 ? Math.round(rating / 2) : 0;
      this.language = String(book['languages'] ?? '');
      const translatorList = (book['translators'] as string[] | undefined) ?? [];
      this.translators = translatorList.join(', ');
      this.pubdate = String(book['pubdate'] ?? '');
    } finally {
      this.loading = false;
    }
  }

  /** 作者输入联想（防抖 400ms）。 */
  private onAuthorInput(value: string): void {
    this.author = value;
    const query = value.trim();
    if (query.length === 0) {
      this.showAuthorHints = false;
      this.authorHints = [];
      return;
    }
    const now = Date.now();
    if (now - this.lastHintTime < 400) {
      return;
    }
    this.lastHintTime = now;
    if (!ServerRegistry.supports(ServerFeature.AUTHOR_SEARCH)) {
      this.authorHints = [];
      this.showAuthorHints = false;
      return;
    }
    TalebookApi.searchAuthors(query)
      .then((hints: MetaNameCount[]) => {
        this.authorHints = hints.slice(0, 8);
        this.showAuthorHints = this.authorHints.length > 0;
      })
      .catch(() => {
        this.authorHints = [];
        this.showAuthorHints = false;
      });
  }

  private splitToList(text: string): string[] {
    const result: string[] = [];
    const parts = text.split(/[,，、]/);
    for (let i = 0; i < parts.length; i++) {
      const trimmed = parts[i].trim();
      if (trimmed.length > 0) {
        result.push(trimmed);
      }
    }
    return result;
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.message = '';
    const payload: Record<string, Object> = {
      'title': this.title.trim(),
      'authors': this.splitToList(this.author),
      'publisher': this.publisher.trim(),
      'comments': this.description.trim(),
      'tags': this.splitToList(this.tags),
      'isbn': this.isbn.trim(),
      'series': this.series.trim(),
      'languages': this.language.trim(),
      'translators': this.splitToList(this.translators),
    };
    if (this.seriesIndex.trim().length > 0) {
      payload['series_index'] = Number(this.seriesIndex) || 1;
    }
    if (this.ratingStars > 0) {
      payload['rating'] = this.ratingStars * 2;
    }
    if (this.pubdate.trim().length > 0) {
      payload['pubdate'] = this.pubdate.trim();
    }
    const envelope = await TalebookService.editBookAsync(this.bookId, payload);
    if (envelope.status >= 200 && envelope.status < 300) {
      this.getUIContext().getPromptAction().showToast({ message: '保存成功' });
      this.getUIContext().getRouter().back();
    } else {
      this.message = envelope.error.length > 0 ? envelope.error : '保存失败';
    }
    this.saving = false;
  }

  build() {
    Column() {
      PageScaffold({
        title: '编辑书籍',
        showBack: true,
        content: () => {
          this.editContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  fieldInput(placeholder: string, text: string, onChange: (value: string) => void) {
    TextInput({ text: text, placeholder: placeholder })
      .width('100%')
      .height(42)
      .onChange(onChange);
  }

  @Builder
  editContent() {
    if (this.loading) {
      LoadingState({});
    } else {
      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 12 }) {
            this.fieldInput('书名', this.title, (value: string) => {
              this.title = value;
            });
            Column({ space: 4 }) {
              this.fieldInput('作者（多个用逗号分隔）', this.author, (value: string) => {
                this.onAuthorInput(value);
              });
              if (this.showAuthorHints) {
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.authorHints, (hint: MetaNameCount) => {
                    ChipButton({
                      label: `${hint.name} (${hint.count})`,
                      onTap: () => {
                        this.author = hint.name;
                        this.showAuthorHints = false;
                      },
                    })
                      .margin({ right: 8, bottom: 4 });
                  }, (hint: MetaNameCount) => `hint-${hint.name}`);
                }
                .width('100%');
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%');
            this.fieldInput('译者（多个用逗号分隔）', this.translators, (value: string) => {
              this.translators = value;
            });
            this.fieldInput('出版社', this.publisher, (value: string) => {
              this.publisher = value;
            });
            this.fieldInput('标签（逗号分隔）', this.tags, (value: string) => {
              this.tags = value;
            });
            this.fieldInput('丛书', this.series, (value: string) => {
              this.series = value;
            });
            this.fieldInput('丛书序号', this.seriesIndex, (value: string) => {
              this.seriesIndex = value;
            });
            this.fieldInput('ISBN', this.isbn, (value: string) => {
              this.isbn = value;
            });
            this.fieldInput('语言（如 chi/eng）', this.language, (value: string) => {
              this.language = value;
            });
            this.fieldInput('出版日期（2026-05-10 / 2026-05 / 2026）', this.pubdate, (value: string) => {
              this.pubdate = value;
            });
            Column({ space: 6 }) {
              Text('评分')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'));
              Row({ space: 6 }) {
                ForEach([1, 2, 3, 4, 5], (index: number) => {
                  Column() {
                    SymbolGlyph(index <= this.ratingStars ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
                      .fontSize(26)
                      .fontColor([index <= this.ratingStars ?
                        $r('app.color.brand_primary') : $r('app.color.divider')]);
                  }
                  .onClick(() => {
                    this.ratingStars = index;
                  });
                }, (index: number) => `star-${index}-${this.ratingStars}`);
                if (this.ratingStars > 0) {
                  Text('清除')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .onClick(() => {
                      this.ratingStars = 0;
                    });
                }
              }
              .width('100%');
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%');
            TextArea({ text: this.description, placeholder: '简介' })
              .height(120)
              .onChange((value: string) => {
                this.description = value;
              });
          }
          .width('100%');

          if (this.message.length > 0) {
            Text(this.message)
              .fontColor($r('app.color.error'))
              .fontSize(14);
          }

          PrimaryButton({
            label: this.saving ? '保存中...' : '保存',
            buttonEnabled: !this.saving,
            onTap: () => {
              void this.save();
            },
          });
        }
        .width('100%')
        .padding(16);
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off);
    }
  }
}
