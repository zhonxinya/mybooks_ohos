import {
  PageScaffold, EmptyState, LoadingState, PrimaryButton, SecondaryButton,
  AuthImage, StarRating,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookApi, ReferSearchOpts, ReferSearchResponse } from '../services/TalebookApi';
import { ReferBook } from '../common/ApiTypes';
import { BookshelfRefresh } from '../utils/BookshelfRefresh';

@Entry
@Component
struct ReferResultPage {
  @State bookId: number = 0;
  @State queryTitle: string = '';
  @State queryIsbn: string = '';
  @State queryPublisher: string = '';
  @State entries: ReferBook[] = [];
  @State loading: boolean = false;
  @State errorMessage: string = '';
  @State warningMessage: string = '';
  @State fromCache: boolean = false;
  @State applying: boolean = false;
  @State expandedKey: string = '';

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.bookId = Number(params['bookId'] ?? 0);
    this.queryTitle = String(params['title'] ?? '');
    this.queryIsbn = String(params['isbn'] ?? '');
    this.queryPublisher = String(params['publisher'] ?? '');
    if (this.queryTitle.trim().length > 0 || this.queryIsbn.trim().length > 0) {
      void this.loadRefer();
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private entryKey(entry: ReferBook): string {
    const pv = entry.provider_value !== undefined ? entry.provider_value : '';
    const pk = entry.provider_key !== undefined ? entry.provider_key : '';
    const title = entry.title !== undefined ? entry.title : '';
    return `${entry.source}-${pk}-${pv}-${title}`;
  }

  private async loadRefer(): Promise<void> {
    const title = this.queryTitle.trim();
    const isbn = this.queryIsbn.trim();
    const publisher = this.queryPublisher.trim();
    if (title.length === 0 && isbn.length === 0) {
      this.toast('请填写书名或 ISBN');
      return;
    }
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    this.warningMessage = '';
    this.fromCache = false;
    try {
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      const opts: ReferSearchOpts = {};
      if (title.length > 0) {
        opts.title = title;
      }
      if (isbn.length > 0) {
        opts.isbn = isbn;
      }
      if (publisher.length > 0) {
        opts.publisher = publisher;
      }
      const rsp: ReferSearchResponse = await TalebookApi.searchRefer(this.bookId, opts);
      this.entries = rsp.books;
      this.fromCache = rsp.cached === true;
      const err = rsp.err;
      const msg = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '';
      if (err !== undefined && err !== 'ok') {
        if (this.entries.length > 0) {
          this.warningMessage = msg.length > 0 ? msg : err;
        } else {
          this.errorMessage = msg.length > 0 ? msg : err;
        }
      } else if (this.entries.length === 0) {
        this.errorMessage = '未找到相关引用信息';
      }
    } catch (error) {
      this.entries = [];
      this.errorMessage = error instanceof Error ? error.message : `${error}`;
    } finally {
      this.loading = false;
    }
  }

  private applyEntry(entry: ReferBook): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: `应用「${entry.title ?? ''}」的信息`,
      buttons: [
        { text: '应用全部（元数据+封面）', color: '#007DFF' },
        { text: '仅元数据', color: '#007DFF' },
        { text: '仅封面', color: '#007DFF' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        void this.doApply(entry, false, false);
      } else if (result.index === 1) {
        void this.doApply(entry, true, false);
      } else if (result.index === 2) {
        void this.doApply(entry, false, true);
      }
    }).catch(() => {});
  }

  private async doApply(entry: ReferBook, onlyMeta: boolean, onlyCover: boolean): Promise<void> {
    if (this.applying) {
      return;
    }
    this.applying = true;
    try {
      const rsp = await TalebookApi.applyRefer(this.bookId, entry, onlyMeta, onlyCover);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast('引用信息已应用');
      // 标题/作者/标签/封面都变了：通知书架与小说导航页重取；详情页返回时会自己静默重取
      BookshelfRefresh.notify();
      BookshelfRefresh.notifyBooksTab();
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.toast(`应用失败：${error}`);
    } finally {
      this.applying = false;
    }
  }

  private confirmReset(): void {
    this.getUIContext().showAlertDialog({
      title: '重置引用',
      message: '确定用当前本地信息覆盖互联网元数据吗？',
      primaryButton: {
        value: '重置',
        action: () => {
          void this.doReset();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async doReset(): Promise<void> {
    try {
      const rsp = await TalebookApi.resetRefer(this.bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        return;
      }
      this.toast('已重置');
      BookshelfRefresh.notify();
      BookshelfRefresh.notifyBooksTab();
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.toast(`重置失败：${error}`);
    }
  }

  private toggleExpand(key: string): void {
    this.expandedKey = this.expandedKey === key ? '' : key;
  }

  private metaLine(entry: ReferBook): string {
    const parts: string[] = [];
    if (entry.publisher !== undefined && entry.publisher.length > 0) {
      parts.push(entry.publisher);
    }
    if (entry.pubdate !== undefined && entry.pubdate.length > 0) {
      parts.push(entry.pubdate);
    }
    if (entry.series !== undefined && entry.series.length > 0) {
      parts.push(`丛书：${entry.series}`);
    }
    return parts.join(' · ');
  }

  @Builder
  resetAction() {
    Text('重置')
      .fontSize(14)
      .fontColor($r('app.color.brand_primary'))
      .onClick(() => this.confirmReset());
  }

  build() {
    Column() {
      PageScaffold({
        title: '引用信息',
        showBack: true,
        action: () => {
          this.resetAction();
        },
        content: () => {
          this.resultContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  searchForm() {
    Column({ space: 8 }) {
      TextInput({ text: this.queryTitle, placeholder: '书名' })
        .height(40)
        .width('100%')
        .onChange((value: string) => {
          this.queryTitle = value;
        });
      TextInput({ text: this.queryIsbn, placeholder: 'ISBN' })
        .height(40)
        .width('100%')
        .onChange((value: string) => {
          this.queryIsbn = value;
        });
      TextInput({ text: this.queryPublisher, placeholder: '出版社（可选）' })
        .height(40)
        .width('100%')
        .onChange((value: string) => {
          this.queryPublisher = value;
        });
      PrimaryButton({
        label: this.loading ? '搜索中…' : '搜索',
        buttonEnabled: !this.loading && !this.applying,
        onTap: () => {
          void this.loadRefer();
        },
      });
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  referCard(entry: ReferBook) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        if (entry.cover_url !== undefined && entry.cover_url.length > 0) {
          AuthImage({
            url: TalebookService.resolveCoverUrl(entry.cover_url),
            imageWidth: 60,
            imageHeight: 86,
          });
        }
        Column({ space: 4 }) {
          Text(entry.title ?? '')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(entry.author_sort ?? '')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Row({ space: 8 }) {
            if (entry.rating !== undefined && entry.rating > 0) {
              StarRating({
                rating: entry.rating / 2,
                starSize: 11,
              });
            }
            if (entry.source !== undefined && entry.source.length > 0) {
              Text(entry.source)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'));
            }
          }
          .width('100%');
          if (entry.publisher !== undefined && entry.publisher.length > 0 ||
            entry.pubdate !== undefined && entry.pubdate.length > 0 ||
            entry.series !== undefined && entry.series.length > 0) {
            Text(this.metaLine(entry))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%');
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
      }
      .width('100%')
      .alignItems(VerticalAlign.Top);

      if (entry.comments !== undefined && entry.comments.length > 0) {
        Text(entry.comments)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(this.expandedKey === this.entryKey(entry) ? 20 : 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Text(this.expandedKey === this.entryKey(entry) ? '收起简介' : '展开简介')
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => this.toggleExpand(this.entryKey(entry)));
      }

      SecondaryButton({
        label: this.applying ? '应用中…' : '应用此结果',
        compact: true,
        fullWidth: true,
        buttonEnabled: !this.applying && !this.loading,
        onTap: () => this.applyEntry(entry),
      });
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  resultContent() {
    Column({ space: 12 }) {
      this.searchForm();
      if (this.fromCache) {
        Text('结果来自缓存')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      if (this.warningMessage.length > 0) {
        Text(this.warningMessage)
          .fontSize(12)
          .fontColor($r('app.color.error'))
          .width('100%');
      }
      if (this.loading && this.entries.length === 0) {
        LoadingState({});
      } else if (!this.loading && this.entries.length === 0) {
        EmptyState({
          message: this.errorMessage.length > 0 ? this.errorMessage : '填写书名或 ISBN 后搜索',
          actionLabel: '重新搜索',
          onAction: () => {
            void this.loadRefer();
          },
        });
      } else {
        Text('选择结果并应用元数据/封面')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
        List({ space: 10 }) {
          ForEach(this.entries, (entry: ReferBook) => {
            ListItem() {
              this.referCard(entry);
            }
          }, (entry: ReferBook) => this.entryKey(entry));
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off);
      }
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.page_padding'));
  }
}
