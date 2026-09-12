import { router } from '@kit.ArkUI';
import { PageScaffold, EmptyState, LoadingState, LazyDataSource } from '../components';
import { TalebookService } from '../services/TalebookService';
import { NotificationService } from '../services/NotificationService';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';

@Entry
@Component
struct NotificationPage {
  @State @Watch('onMessagesChanged') messages: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State needLogin: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State errorMessage: string = '';
  @State expandedId: number = -1;
  private scrollController: Scroller = new Scroller();
  private lastLoadTime: number = 0;
  private messagesSource: LazyDataSource<Record<string, Object>> =
    new LazyDataSource<Record<string, Object>>();

  /** messages 变更后同步 LazyForEach 数据源，避免逐处手写 update。 */
  private onMessagesChanged(): void {
    this.messagesSource.update(this.messages);
  }

  aboutToAppear(): void {
    if (!TalebookService.ensureTalebookConfigured()) {
      this.needLogin = true;
      this.loading = false;
      this.errorMessage = '请先配置 Talebook 服务器';
      return;
    }
    if (!TalebookService.hasAuthCredentials()) {
      this.needLogin = true;
      this.loading = false;
      this.errorMessage = '登录后可查看消息通知';
      return;
    }
    void this.loadMessages(true);
  }

  private async loadMessages(reset: boolean = true): Promise<void> {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.messages = [];
      this.loading = true;
      this.errorMessage = '';
    } else {
      this.loadingMore = true;
    }
    const page = this.currentPage;
    try {
      await TalebookService.ensureAuthenticated();
      const envelope = await TalebookService.getMessagesAsync(page, PaginationConstants.PAGE_SIZE);
      if (envelope.status < 200 || envelope.status >= 300) {
        const message = envelope.error.length > 0 ? envelope.error : '加载失败';
        if (reset) {
          this.errorMessage = message;
        } else {
          this.currentPage = Math.max(1, this.currentPage - 1);
          this.getUIContext().getPromptAction().showToast({ message: message });
        }
        return;
      }
      const body = envelope.body ?? {};
      const fetched = (body['messages'] as Record<string, Object>[] | undefined) ?? [];
      if (reset) {
        this.messages = fetched;
        NotificationService.setUnreadCount(fetched.length);
      } else {
        this.messages = this.messages.concat(fetched);
        NotificationService.setUnreadCount(this.messages.length);
      }
      this.hasMore = PaginationHelper.computeHasMore(fetched.length);
    } catch (error) {
      const message = `${error}`;
      if (reset) {
        this.errorMessage = message;
      } else {
        this.currentPage = Math.max(1, this.currentPage - 1);
        this.getUIContext().getPromptAction().showToast({ message: message });
      }
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    void this.loadMessages(false);
  }

  private messageId(msg: Record<string, Object>): number {
    return Number(msg['id'] ?? 0);
  }

  private hasTitle(msg: Record<string, Object>): boolean {
    return String(msg['title'] ?? '').trim().length > 0;
  }

  private previewText(msg: Record<string, Object>): string {
    const summary = NotificationService.messageSummary(msg);
    if (summary.length > 0) {
      return summary;
    }
    return NotificationService.messageText(msg);
  }

  private async markRead(msg: Record<string, Object>): Promise<void> {
    const messageId = this.messageId(msg);
    if (messageId > 0) {
      this.expandedId = this.expandedId === messageId ? -1 : messageId;
      // 展开态不属于数据源，LazyForEach 需显式通知才会重绘
      this.messagesSource.update(this.messages);
    }
    if (NotificationService.isMessageRead(msg)) {
      return;
    }
    if (messageId <= 0) {
      return;
    }
    const envelope = await TalebookService.markMessageReadAsync(messageId);
    if (envelope.status >= 200 && envelope.status < 300) {
      // 按 id 移除，避免依赖列表下标（LazyForEach 不下发 index）
      this.messages = this.messages.filter((item: Record<string, Object>) =>
        this.messageId(item) !== messageId);
      NotificationService.setUnreadCount(this.messages.length);
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '通知',
        showBack: true,
        content: () => {
          this.notificationContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  notificationContent() {
    if (this.loading) {
      LoadingState({});
    } else if (this.needLogin) {
      EmptyState({
        message: this.errorMessage,
        actionLabel: '去配置账号',
        onAction: () => router.pushUrl({ url: 'pages/TalebookConfigPage' }),
      });
    } else if (this.messages.length === 0) {
      EmptyState({ message: this.errorMessage.length > 0 ? this.errorMessage : '暂无通知' });
    } else {
      List({ scroller: this.scrollController }) {
        LazyForEach(this.messagesSource, (msg: Record<string, Object>) => {
          ListItem() {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                if (!NotificationService.isMessageRead(msg)) {
                  Circle({ width: 8, height: 8 })
                    .fill($r('app.color.brand_primary'));
                }
                Column({ space: 4 }) {
                  Text(NotificationService.messageTitle(msg))
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(this.expandedId === this.messageId(msg) ? 0 : 2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis });
                  if (this.hasTitle(msg)) {
                    Text(this.previewText(msg))
                      .fontSize(14)
                      .fontColor($r('app.color.text_secondary'))
                      .maxLines(this.expandedId === this.messageId(msg) ? 0 : 3)
                      .textOverflow({ overflow: TextOverflow.Ellipsis });
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);
                Text(NotificationService.statusLabel(msg))
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'));
              }
              .width('100%')
              .alignItems(VerticalAlign.Top);
              Text(NotificationService.messageTime(msg))
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'));
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding($r('app.float.card_padding'))
            .backgroundColor(NotificationService.isMessageRead(msg) ? $r('app.color.card_background') :
              $r('app.color.unread_background'))
            .onClick(() => {
              void this.markRead(msg);
            });
          }
        }, (msg: Record<string, Object>, index: number) => `${msg['id'] ?? index}`);
        if (this.loadingMore) {
          ListItem() {
            LoadingState({ hint: '加载更多...' });
          }
        }
      }
      .layoutWeight(1)
      .onReachEnd(() => this.loadMore());
    }
  }
}
