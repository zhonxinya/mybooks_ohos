import { PageScaffold, PrimaryButton, SecondaryButton, TextButton, EmptyState } from '../components';
import { AiService } from '../services/AiService';
import { AiBookService, RecommendedBook, ShelfProfile } from '../services/AiBookService';
import { ShelfApi, BookListResponse } from '../services/ShelfApi';
import { TalebookService, ApiEnvelope } from '../services/TalebookService';
import { AppRouter } from '../utils/AppRouter';
import { BookItem, parseBookItem } from '../services/BookModels';
import { hasSameBook } from '../utils/LibraryMatch';
import { ErrorFormat } from '../utils/ErrorFormat';

/**
 * AI 书单推荐：用书架偏好生成推荐，再拿书名去服务端书库检索。
 *
 * 关键约束：模型只负责「推荐什么」，不负责「书库里有没有」。
 * 因此每条推荐都跟着一次检索，命中才给详情入口，避免点进去空结果。
 */
@Entry
@Component
struct AiRecommendPage {
  @State configured: boolean = false;
  @State loading: boolean = false;
  @State preparing: boolean = true;
  @State errorText: string = '';
  @State items: RecommendedBook[] = [];
  @State mood: string = '';
  /** 每条推荐在书库里的命中情况：-1 未查、0 未命中、>0 为 bookId。 */
  @State matchedIds: number[] = [];
  @State shelfCount: number = 0;
  private requestId: number = 0;

  onPageShow(): void {
    this.configured = AiService.isReady();
  }

  aboutToDisappear(): void {
    this.requestId++;
  }

  aboutToAppear(): void {
    this.configured = AiService.isReady();
    void this.loadShelfCount();
  }

  private async loadShelfCount(): Promise<void> {
    this.preparing = true;
    try {
      const rsp: BookListResponse = await ShelfApi.getShelf();
      this.shelfCount = (rsp.books ?? []).length;
    } catch (_error) {
      this.shelfCount = 0;
    } finally {
      this.preparing = false;
    }
  }

  /** 只取书名/作者/标签做偏好画像，不发送账号、阅读进度或正文。 */
  private async buildProfile(): Promise<ShelfProfile> {
    const rsp: BookListResponse = await ShelfApi.getShelf();
    const books: Record<string, Object>[] = rsp.books ?? [];
    const titles: string[] = [];
    const authors: string[] = [];
    const tags: string[] = [];
    for (let i = 0; i < books.length && i < 80; i++) {
      const book: Record<string, Object> = books[i];
      const title: string = String(book['title'] ?? '').trim();
      if (title.length > 0) {
        titles.push(title);
      }
      const bookAuthors: string[] = Array.isArray(book['authors'])
        ? (book['authors'] as string[]) : [String(book['author'] ?? '')];
      for (let j = 0; j < bookAuthors.length; j++) {
        const author: string = String(bookAuthors[j]).trim();
        if (author.length > 0 && authors.indexOf(author) < 0) {
          authors.push(author);
        }
      }
      // 服务端标签字段不统一：可能是数组或逗号串
      const rawTags = book['tags'];
      const bookTags: string[] = Array.isArray(rawTags)
        ? (rawTags as string[]) : String(rawTags ?? '').split(/[,，、]/);
      for (let j = 0; j < bookTags.length; j++) {
        const tag: string = String(bookTags[j]).trim();
        if (tag.length > 0 && tags.indexOf(tag) < 0) {
          tags.push(tag);
        }
      }
    }
    return { titles: titles, authors: authors, tags: tags };
  }

  private async generate(): Promise<void> {
    if (this.loading) {
      return;
    }
    if (!AiService.isReady()) {
      this.configured = false;
      return;
    }
    const requestId: number = ++this.requestId;
    this.configured = true;
    this.loading = true;
    this.errorText = '';
    this.items = [];
    this.matchedIds = [];
    try {
      const profile: ShelfProfile = await this.buildProfile();
      if (requestId !== this.requestId) {
        return;
      }
      if (profile.titles.length === 0) {
        this.errorText = '书架为空或未登录，AI 没有可参考的偏好';
        return;
      }
      const result: RecommendedBook[] = await AiBookService.recommend(profile, 6, this.mood.trim());
      if (requestId !== this.requestId) {
        return;
      }
      this.items = result;
      const marks: number[] = [];
      for (let i = 0; i < result.length; i++) {
        marks.push(-1);
      }
      this.matchedIds = marks;
      // 不 await：列表先出来，命中状态在后台逐条补齐
      void this.matchAll(result, requestId);
    } catch (error) {
      if (requestId === this.requestId) {
        this.errorText = ErrorFormat.message(error);
      }
    } finally {
      this.loading = false;
    }
  }

  /** 串行查询，并把结果绑定到生成时的书单，避免旧搜索覆盖新推荐。 */
  private async matchAll(items: RecommendedBook[], requestId: number): Promise<void> {
    for (let i = 0; i < items.length; i++) {
      if (requestId !== this.requestId) {
        return;
      }
      let matchedId: number = 0;
      try {
        const envelope: ApiEnvelope = await TalebookService.searchAsync(items[i].title, 1, 5);
        const books: Record<string, Object>[] = envelope.body !== null
          ? ((envelope.body['books'] as Record<string, Object>[] | undefined) ?? [])
          : [];
        for (let j = 0; j < books.length; j++) {
          const book: BookItem = parseBookItem(books[j]);
          if (book.id > 0 && hasSameBook([book], items[i].title, items[i].author)) {
            matchedId = book.id;
            break;
          }
        }
      } catch (_error) {
        // 检索失败仍保留手动搜索入口
      }
      if (requestId !== this.requestId) {
        return;
      }
      this.matchedIds[i] = matchedId;
      this.matchedIds = this.matchedIds.slice();
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: 'AI 书单推荐',
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
    Column({ space: 12 }) {
      Column({ space: 6 }) {
        Row() {
          Text('书架概况')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          Blank();
          Text(this.preparing ? '读取中…' : `共 ${this.shelfCount} 本`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%');
        Text('只把书名、作者与标签发给模型，不发送账号、阅读进度或书籍内容。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      if (!this.configured) {
        Column({ space: 12 }) {
          Text('尚未配置 AI 模型')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'));
          SecondaryButton({
            label: '去配置',
            fullWidth: false,
            onTap: () => AppRouter.pushUrl(this.getUIContext(), { url: 'pages/AiSettingsPage' }),
          });
        }
        .width('100%')
        .padding(20)
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));
      } else {
        Row({ space: 10 }) {
          TextInput({ placeholder: '想看什么样的？（可留空）', text: this.mood })
            .layoutWeight(1)
            .height(44)
            .borderRadius(22)
            .backgroundColor($r('app.color.card_background'))
            .onChange((v: string) => this.mood = v);
          PrimaryButton({
            label: this.loading ? '推荐中…' : '生成书单',
            fullWidth: false,
            buttonEnabled: !this.loading,
            onTap: () => {
              void this.generate();
            },
          });
        }
        .width('100%');

        if (this.errorText.length > 0) {
          Text(this.errorText)
            .fontSize(12)
            .fontColor($r('app.color.error'))
            .width('100%');
        }

        if (this.loading) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color($r('app.color.brand_primary'));
            Text('正在分析书架偏好')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'));
          }
          .width('100%');
        }

        if (this.items.length > 0) {
          List({ space: 10 }) {
            ForEach(this.items, (item: RecommendedBook, index: number) => {
              ListItem() {
                this.itemView(item, index);
              }
            }, (item: RecommendedBook, index: number) => `rec-${index}-${item.title}`);
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off);
        } else if (!this.loading) {
          // #1671：生成前/生成后无结果时不再整页空白
          EmptyState({ message: '暂无推荐', detail: '点上方「生成推荐」让 AI 根据书架偏好算一份' });
        }
      }
      Blank();
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.page_padding'))
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  itemView(item: RecommendedBook, index: number) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(item.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        if (this.matchedIds[index] > 0) {
          Text('书库已有')
            .fontSize(10)
            .fontColor($r('app.color.success'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .backgroundColor($r('app.color.success_light'));
        } else if (this.matchedIds[index] === 0) {
          Text('书库未找到')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'));
        }
      }
      .width('100%');
      if (item.author.length > 0) {
        Text(item.author)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
      }
      Text(item.reason)
        .fontSize(13)
        .lineHeight(20)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Start);
      Row({ space: 12 }) {
        if (this.matchedIds[index] > 0) {
          TextButton({
            label: '查看详情',
            onTap: () => AppRouter.pushUrl(this.getUIContext(), {
              url: 'pages/BookDetailPage',
              params: { bookId: this.matchedIds[index] },
            }),
          });
        }
        TextButton({
          label: '在书库搜索',
          onTap: () => AppRouter.pushUrl(this.getUIContext(), {
            url: 'pages/TalebookBookSearchPage',
            params: { keyword: item.title },
          }),
        });
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }
}
