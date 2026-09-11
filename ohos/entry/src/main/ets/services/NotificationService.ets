import { TalebookService } from './TalebookService';

export class NotificationService {
  private static readonly UNREAD_KEY: string = 'unreadMessageCount';
  private static readonly TICK_KEY: string = 'notificationTick';

  static init(): void {
    AppStorage.setOrCreate(NotificationService.UNREAD_KEY, 0);
    AppStorage.setOrCreate(NotificationService.TICK_KEY, 0);
  }

  private static messageData(msg: Record<string, Object>): Record<string, Object> {
    const raw = msg['data'];
    if (raw === null || raw === undefined) {
      return {};
    }
    if (typeof raw === 'string') {
      try {
        return JSON.parse(raw) as Record<string, Object>;
      } catch (_error) {
        return {};
      }
    }
    return raw as Record<string, Object>;
  }

  static messageText(msg: Record<string, Object>): string {
    const data = NotificationService.messageData(msg);
    const text = String(data['message'] ?? data['msg'] ?? data['content'] ?? '').trim();
    if (text.length > 0) {
      return text;
    }
    return String(msg['title'] ?? '').trim();
  }

  static messageTitle(msg: Record<string, Object>): string {
    const title = String(msg['title'] ?? '').trim();
    if (title.length > 0) {
      return title;
    }
    const text = NotificationService.messageText(msg);
    if (text.length > 0) {
      return text;
    }
    return NotificationService.statusLabel(msg);
  }

  static messageSummary(msg: Record<string, Object>): string {
    const title = String(msg['title'] ?? '').trim();
    const text = NotificationService.messageText(msg);
    if (title.length > 0 && text.length > 0 && text !== title) {
      return text;
    }
    return '';
  }

  static messageTime(msg: Record<string, Object>): string {
    return String(msg['create_time'] ?? msg['created_at'] ?? msg['update_time'] ?? '');
  }

  static statusLabel(msg: Record<string, Object>): string {
    const status = String(msg['status'] ?? '').trim().toLowerCase();
    if (status === 'error') {
      return '错误通知';
    }
    if (status === 'success') {
      return '成功通知';
    }
    if (status === 'warning') {
      return '警告通知';
    }
    if (status === 'info') {
      return '系统通知';
    }
    if (status.length > 0) {
      return '系统通知';
    }
    return '通知';
  }

  static isMessageRead(msg: Record<string, Object>): boolean {
    if (Boolean(msg['_localRead'])) {
      return true;
    }
    if (msg['unread'] === false) {
      return true;
    }
    const status = String(msg['status'] ?? '');
    if (status === 'read') {
      return true;
    }
    return Boolean(msg['read'] ?? msg['is_read'] ?? false);
  }

  static countUnread(messages: Record<string, Object>[]): number {
    let count = 0;
    for (let i = 0; i < messages.length; i++) {
      if (!NotificationService.isMessageRead(messages[i])) {
        count++;
      }
    }
    return count;
  }

  static setUnreadCount(count: number): void {
    const next = Math.max(0, count);
    const prev = AppStorage.get<number>(NotificationService.UNREAD_KEY) ?? 0;
    AppStorage.setOrCreate(NotificationService.UNREAD_KEY, next);
    // 仅在数量变化时 bump tick，避免 Settings 页 Watch 触发无限刷新
    if (next !== prev) {
      AppStorage.set(NotificationService.TICK_KEY, Date.now());
    }
  }

  static decrementUnread(): void {
    const current = AppStorage.get<number>(NotificationService.UNREAD_KEY) ?? 0;
    NotificationService.setUnreadCount(Math.max(0, current - 1));
  }

  static async refreshUnreadCount(): Promise<number> {
    if (!TalebookService.hasAuthCredentials()) {
      NotificationService.setUnreadCount(0);
      return 0;
    }
    if (!TalebookService.ensureTalebookConfigured()) {
      NotificationService.setUnreadCount(0);
      return 0;
    }
    try {
      await TalebookService.ensureAuthenticated();
      const envelope = await TalebookService.getMessagesAsync(1, 50);
      if (!TalebookService.isApiSuccess(envelope)) {
        return AppStorage.get<number>(NotificationService.UNREAD_KEY) ?? 0;
      }
      const body = envelope.body ?? {};
      const messages = (body['messages'] as Record<string, Object>[] | undefined) ?? [];
      const unread = NotificationService.countUnread(messages);
      NotificationService.setUnreadCount(unread);
      return unread;
    } catch (_error) {
      return AppStorage.get<number>(NotificationService.UNREAD_KEY) ?? 0;
    }
  }
}
