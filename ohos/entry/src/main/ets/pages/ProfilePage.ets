import { router } from '@kit.ArkUI';
import { PageScaffold, SettingCell, LoadingState, DangerButton } from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { AccountManager } from '../services/AccountManager';
import { NotificationService } from '../services/NotificationService';

@Entry
@Component
struct ProfilePage {
  @State nickname: string = '';
  @State username: string = '';
  @State isLogin: boolean = false;
  @State loading: boolean = true;
  @StorageProp('unreadMessageCount') unreadCount: number = 0;

  aboutToAppear(): void {
    void this.loadProfile();
    void NotificationService.refreshUnreadCount();
  }

  private unreadBadge(): string {
    return this.unreadCount > 0 ? `${this.unreadCount}` : '';
  }

  private async loadProfile(): Promise<void> {
    this.loading = true;
    try {
      TalebookService.applyLocalConfig();
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
        const saved = TalebookService.getSavedUserProfile();
        if (saved !== null) {
          this.applyUser(saved);
          return;
        }
      }
      const envelope = await TalebookService.getUserInfoAsync();
      if (TalebookService.isLoggedInEnvelope(envelope) && envelope.body !== null) {
        const body = envelope.body ?? {};
        const user = (body['user'] as Record<string, Object> | undefined) ?? body;
        this.applyUser(user);
        TalebookService.saveUserProfile(user);
        return;
      }
      const saved = TalebookService.getSavedUserProfile();
      if (saved !== null) {
        this.applyUser(saved);
        if (TalebookService.hasAuthCredentials()) {
          this.isLogin = true;
        }
      }
    } finally {
      this.loading = false;
    }
  }

  /** 当前账号摘要（用于「账号与服务器」入口副标题）。 */
  private accountSummary(): string {
    const count = AccountManager.list().length;
    const active = AccountManager.activeDisplayName();
    if (count === 0) {
      return '新增服务器与账号';
    }
    return active.length > 0 ? `共 ${count} 个账号 · 当前 ${active}` : `共 ${count} 个账号`;
  }

  private applyUser(user: Record<string, Object>): void {
    this.nickname = String(user['nickname'] ?? user['name'] ?? '');
    this.username = String(user['username'] ?? '');
    this.isLogin = Boolean(user['is_login'] ?? false);
  }

  build() {
    Column() {
      PageScaffold({
        title: '个人中心',
        showBack: true,
        content: () => {
          this.profileContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  profileContent() {
    if (this.loading) {
      LoadingState({});
    } else {
      Column({ space: 12 }) {
        Column() {
          Row({ space: 16 }) {
            Column() {
              Text((this.nickname.length > 0 ? this.nickname : '?').substring(0, 1))
                .fontSize(24)
                .fontColor($r('app.color.on_brand'));
            }
            .width(64)
            .height(64)
            .borderRadius(32)
            .backgroundColor($r('app.color.brand_primary'))
            .justifyContent(FlexAlign.Center);
            Column({ space: 4 }) {
              Text(this.nickname.length > 0 ? this.nickname : '未登录')
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'));
              Text(this.isLogin ? this.username : '登录后可同步阅读与收藏')
                .fontColor($r('app.color.text_secondary'));
            }
            .alignItems(HorizontalAlign.Start);
          }
          .padding($r('app.float.page_padding'));
        }
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        Column() {
          Column() {
            if (!this.isLogin) {
              SettingCell({
                title: '登录账号',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/LoginPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            SettingCell({
              title: '我的阅读',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/ReadingBooksPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '我的书籍',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/MyBooksPage' }),
            });
            if (ServerRegistry.supports(ServerFeature.BOOK_SHELF)) {
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
              SettingCell({
                title: '我的书架',
                subtitle: '服务端书架（阅读计划）',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/ShelfPage' }),
              });
            }
            if (ServerRegistry.supports(ServerFeature.LIBRARY_ONLINE)) {
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
              SettingCell({
                title: '在线书库',
                subtitle: '已保存的网络书，可按连载状态筛选',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/OnlineLibraryPage' }),
              });
            }
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '账号与服务器',
              subtitle: this.accountSummary(),
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/TalebookConfigPage' }),
            });
            if (this.isLogin) {
              if (ServerRegistry.supports(ServerFeature.ANNOTATIONS)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '我的标注',
                  subtitle: '查看与导出全部书内标注',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AnnotationsPage' }),
                });
              }
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
              SettingCell({
                title: '消息通知',
                badgeText: this.unreadBadge(),
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/NotificationPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
              SettingCell({
                title: '个人设置',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/UserSettingsPage' }),
              });
              if (ServerRegistry.supports(ServerFeature.USER_MEMO)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '我的留言',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/UserMemosPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.USER_EXPECTED)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '求书期望',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/ExpectedBooksPage' }),
                });
              }
            }
          }
        }
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));

        if (this.isLogin) {
          DangerButton({
            label: '退出登录',
            onTap: () => {
              TalebookService.signOut();
              this.isLogin = false;
              this.nickname = '';
              this.username = '';
              this.getUIContext().getPromptAction().showToast({ message: '已退出登录' });
              router.back();
            },
          });
        }
      }
      .padding($r('app.float.page_padding'));
    }
  }
}
