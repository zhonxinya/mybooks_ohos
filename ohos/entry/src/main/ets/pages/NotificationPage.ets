import { PageScaffold, EmptyState, LoadingState, LazyDataSource, TextButton } from '../components';
import { TalebookService } from '../services/TalebookService';
import { TalebookApi } from '../services/TalebookApi';
import { NotificationService } from '../services/NotificationService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { PaginationConstants, PaginationHelper } from '../utils/PaginationHelper';

/** 逐个标记已读时的单页大小（talebook 无「清空」端点，只能逐条打）。 */
const CLEAR_PAGE_SIZE: number = 100;
/** 逐条标记的轮次上限：防止服务端异常时无限循环。 */
const CLEAR_MAX_ROUNDS: number = 50;

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
  @State clearing: boolean = false;
  private scrollController: Scroller = new Scroller();
  private lastLoadTime: number = 0;
  private messagesSource: LazyDataSource<Record<string, Object>> =
    new LazyDataSource<Record<string, Object>>();

  /** messages 变更后同步 LazyForEach 数据源，避免逐处手写 update。 */
  private onMessagesChanged(): void {
    this.messagesSource.update(this.messages);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
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

  /** @throws 内部调用可能抛出异常，由调用方处理 */
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
      } else {
        this.messages = this.messages.concat(fetched);
      }
      this.syncUnreadCount();
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

  /** @throws 内部调用可能抛出异常，由调用方处理 */
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
      this.syncUnreadCount();
    }
  }

  /**
   * 未读条数：必须以「未读」为准，不能拿列表长度当未读数。
   * （单条已读会把该条移出列表，用长度会让角标少算甚至直接归零。）
   */
  private syncUnreadCount(): void {
    NotificationService.setUnreadCount(NotificationService.countUnread(this.messages));
  }

  private clearButtonLabel(): string {
    if (this.clearing) {
      return '清除中…';
    }
    return this.messages.length > 0 ? `全部清除(${this.messages.length})` : '全部清除';
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private confirmClearAll(): void {
    if (this.clearing || this.messages.length === 0) {
      return;
    }
    const count = this.messages.length;
    const direct: boolean = ServerRegistry.supports(ServerFeature.USER_MESSAGES_CLEAR);
    this.getUIContext().showAlertDialog({
      title: '清除全部通知',
      message: direct
        ? `确定清除全部 ${count} 条通知吗？清除后服务端不再返回这些消息，无法恢复。`
        : `确定清除全部 ${count} 条通知吗？服务端将逐条标记为已读，无法恢复。`,
      primaryButton: {
        value: '全部清除',
        action: () => {
          void this.clearAll(direct);
        },
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        },
      },
    });
  }

  /**
   * 一键清除全部通知。
   *
   * 两套服务端的等价实现不同（依据各自上游源码）：
   * - mybooks：`POST /api/user/messages/clear` 一次清空（`handlers/user.py::UserMessagesClear`）；
   * - talebook：**没有**该路由（只有 `GET/POST /api/user/messages`），因此逐条 `POST` 标记已读。
   *
   * 两端的 `GET /api/user/messages` 都只返回**未读**消息，所以 talebook 分支循环
   * 「取一页 → 逐条标记已读 → 再取」直到服务端返回空，避免只清掉当前已加载的那一页。
   */
  private async clearAll(direct: boolean): Promise<void> {
    if (this.clearing) {
      return;
    }
    this.clearing = true;
    try {
      await TalebookService.ensureAuthenticated();
      let failed: number = 0;
      if (direct) {
        const rsp = await TalebookApi.clearUserMessages();
        if (rsp.err !== undefined && rsp.err !== 'ok') {
          this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '清除失败');
          return;
        }
      } else {
        failed = await this.clearByMarkingRead();
      }
      // 清空后服务端已无未读，直接以空列表收尾（不再请求，避免清空瞬间的空页竞态）
      this.messages = [];
      this.messagesSource.update([]);
      this.currentPage = 1;
      this.hasMore = false;
      this.expandedId = -1;
      NotificationService.setUnreadCount(0);
      if (failed > 0) {
        this.toast(`已清除，${failed} 条标记失败，请下拉重试`);
      } else {
        this.toast('通知已全部清除');
      }
    } catch (error) {
      this.toast(`清除失败：${error}`);
    } finally {
      this.clearing = false;
    }
  }

  /** talebook 等价实现：循环取未读页并逐条标记已读，返回标记失败的条数。 */
  private async clearByMarkingRead(): Promise<number> {
    let failed: number = 0;
    for (let round = 0; round < CLEAR_MAX_ROUNDS; round++) {
      const envelope = await TalebookService.getMessagesAsync(1, CLEAR_PAGE_SIZE);
      if (!TalebookService.isApiSuccess(envelope)) {
        break;
      }
      const body = envelope.body ?? {};
      const pending = (body['messages'] as Record<string, Object>[] | undefined) ?? [];
      if (pending.length === 0) {
        break;
      }
      for (let i = 0; i < pending.length; i++) {
        const id = this.messageId(pending[i]);
        if (id <= 0) {
          continue;
        }
        const rsp = await TalebookService.markMessageReadAsync(id);
        if (!TalebookService.isApiSuccess(rsp)) {
          failed++;
        }
      }
      // 整页都打不动时立即退出，避免把轮次浪费在同一个坏页上
      if (failed >= pending.length) {
        break;
      }
    }
    return failed;
  }

  build() {
    Column() {
      PageScaffold({
        title: '通知',
        showBack: true,
        action: () => {
          this.clearAction();
        },
        content: () => {
          this.notificationContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  clearAction() {
    // 无可清除内容时不显示入口（未登录 / 加载中 / 列表为空）
    if (!this.needLogin && !this.loading && this.messages.length > 0) {
      TextButton({
        label: this.clearButtonLabel(),
        tone: 'danger',
        onTap: () => this.confirmClearAll(),
      });
    }
  }

  @Builder
  notificationContent() {
    if (this.loading) {
      LoadingState({});
    } else if (this.needLogin) {
      EmptyState({
        message: this.errorMessage,
        actionLabel: '去配置账号',
        onAction: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/TalebookConfigPage' }),
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
