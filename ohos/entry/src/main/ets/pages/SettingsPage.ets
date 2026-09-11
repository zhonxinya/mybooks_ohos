import { router } from '@kit.ArkUI';
import { bundleManager, common } from '@kit.AbilityKit';
import { HarmonyTopBar, SettingCell } from '../components';
import { AppTheme } from '../theme/AppTheme';
import { StorageKeys } from '../common/Constants';
import { TalebookService } from '../services/TalebookService';
import { NotificationService } from '../services/NotificationService';
import { TalebookApi, LibraryStatsResponse, AdminRunningTasksResponse } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { AccountManager } from '../services/AccountManager';

@Component
export struct SettingsPage {
  @State themeMode: string = 'system';
  @State showBackButton: boolean = false;
  @State versionText: string = '';
  @State isLoggedIn: boolean = false;
  @State librarySummary: string = '';
  @State runningTasksSummary: string = '';
  @State adminOverviewLoading: boolean = false;
  @StorageProp('unreadMessageCount') unreadCount: number = 0;

  aboutToAppear(): void {
    this.themeMode = TalebookService.prefGet(StorageKeys.THEME_MODE, 'system');
    this.showBackButton = TalebookService.prefGet(StorageKeys.SHOW_BACK_BUTTON, 'true') === 'true';
    this.refreshAccount();
    void NotificationService.refreshUnreadCount();
    void this.loadAdminOverview();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo) => {
        this.versionText = info.versionName;
      })
      .catch(() => {});
  }

  private refreshAccount(): void {
    const saved = TalebookService.getSavedUserProfile();
    this.isLoggedIn = saved !== null && TalebookService.hasAuthCredentials();
  }

  /** 当前账号摘要：账号数与当前账号名，便于在设置页一眼看出正在用哪个账号。 */
  private accountSummary(): string {
    const count = AccountManager.list().length;
    const active = AccountManager.activeDisplayName();
    if (count === 0) {
      return '新增服务器与账号';
    }
    return active.length > 0 ? `共 ${count} 个账号 · 当前 ${active}` : `共 ${count} 个账号`;
  }

  private async loadAdminOverview(): Promise<void> {
    if (!ServerRegistry.supports(ServerFeature.ADMIN_LIBRARY_STATS)) {
      // 当前服务端无书库统计/后台任务接口，不发起必然失败的请求
      this.adminOverviewLoading = false;
      return;
    }
    this.adminOverviewLoading = true;
    try {
      await TalebookService.ensureAuthenticated();
      const statsRsp: LibraryStatsResponse = await TalebookApi.getLibraryStats();
      if (statsRsp.err === undefined || statsRsp.err === 'ok') {
        const s = statsRsp.stats;
        if (s !== undefined) {
          const total = Number(s.total_books ?? 0);
          const ebook = Number(s.ebook_count ?? 0);
          const physical = Number(s.physical_count ?? 0);
          const monthE = Number(s.month_ebook_count ?? 0);
          const monthP = Number(s.month_physical_count ?? 0);
          this.librarySummary =
            `共 ${total} 本（电子 ${ebook} / 实体 ${physical}）· 本月新增电子 ${monthE}、实体 ${monthP}`;
        } else {
          this.librarySummary = '暂无书库统计';
        }
      } else {
        this.librarySummary = statsRsp.msg !== undefined && statsRsp.msg.length > 0
          ? statsRsp.msg : '书库统计不可用';
      }

      const tasksRsp: AdminRunningTasksResponse = await TalebookApi.getAdminRunningTasks();
      if (tasksRsp.err === undefined || tasksRsp.err === 'ok') {
        const tasks = tasksRsp.tasks ?? [];
        const msgs = tasksRsp.messages ?? [];
        if (tasks.length === 0) {
          this.runningTasksSummary = msgs.length > 0
            ? `无后台任务 · ${msgs.length} 条未读管理消息`
            : '当前无后台任务';
        } else {
          const names: string[] = [];
          for (let i = 0; i < tasks.length && i < 3; i++) {
            const t = tasks[i];
            const name = String(t['name'] ?? t['title'] ?? t['type'] ?? `任务${i + 1}`);
            names.push(name);
          }
          const more = tasks.length > 3 ? ` 等 ${tasks.length} 个` : '';
          this.runningTasksSummary = `运行中：${names.join('、')}${more}`;
        }
      } else {
        this.runningTasksSummary = tasksRsp.msg !== undefined && tasksRsp.msg.length > 0
          ? tasksRsp.msg : '任务状态不可用';
      }
    } catch (_e) {
      this.librarySummary = '书库统计加载失败';
      this.runningTasksSummary = '后台任务加载失败';
    } finally {
      this.adminOverviewLoading = false;
    }
  }

  private unreadBadge(): string {
    return this.unreadCount > 0 ? `${this.unreadCount}` : '';
  }

  private applyTheme(mode: string): void {
    this.themeMode = mode;
    TalebookService.prefSet(StorageKeys.THEME_MODE, mode);
    AppTheme.applyThemeMode(getContext(this) as common.UIAbilityContext, mode);
  }

  private showThemePicker(): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: '主题模式',
      buttons: [
        { text: '跟随系统', color: '#007DFF' },
        { text: '浅色', color: '#007DFF' },
        { text: '深色', color: '#007DFF' },
      ],
    }).then((result) => {
      const modes: string[] = ['system', 'light', 'dark'];
      if (result.index >= 0 && result.index < modes.length) {
        this.applyTheme(modes[result.index]);
      }
    }).catch(() => {});
  }

  build() {
    Column() {
      HarmonyTopBar({ title: '设置' });
      Scroll() {
        Column({ space: 12 }) {
          Text('外观')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Column() {
            SettingCell({
              title: '显示返回按钮',
              showToggle: true,
              toggleOn: this.showBackButton,
              onToggle: (value: boolean) => {
                this.showBackButton = value;
                TalebookService.prefSet(StorageKeys.SHOW_BACK_BUTTON, value ? 'true' : 'false');
              },
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '主题模式',
              subtitle: AppTheme.themeModeLabel(this.themeMode),
              showChevron: true,
              onTap: () => this.showThemePicker(),
            });
            if (ServerRegistry.supports(ServerFeature.THEMES)) {
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
              SettingCell({
                title: '服务端主题',
                subtitle: '选择服务端界面主题',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/ThemesPage' }),
              });
            }
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Text('账号')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Column() {
            if (this.isLoggedIn) {
              SettingCell({
                title: '个人中心',
                subtitle: '收藏、消息与账号',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/ProfilePage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            SettingCell({
              title: '通知',
              badgeText: this.unreadBadge(),
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/NotificationPage' }),
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Text('服务')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Column() {
            SettingCell({
              title: '账号与服务器',
              subtitle: this.accountSummary(),
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/TalebookConfigPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: 'SoNovel 服务',
              subtitle: '配置 SoNovel 地址',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/SoNovelConfigPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '附加服务',
              subtitle: '扩展功能入口：下载管理、网络书库、我的书架等',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/ExtraServicesPage' }),
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Text('管理')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Column({ space: 8 }) {
            Row() {
              Text('管理概览')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1);
              Text(this.adminOverviewLoading ? '刷新中…' : '刷新')
                .fontSize(12)
                .fontColor($r('app.color.brand_primary'))
                .onClick(() => {
                  void this.loadAdminOverview();
                });
            }
            .width('100%')
            .padding({
              left: $r('app.float.page_padding'),
              right: $r('app.float.page_padding'),
              top: $r('app.float.page_padding'),
            });
            Text(this.librarySummary.length > 0 ? this.librarySummary : '加载书库统计…')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding') });
            Text(this.runningTasksSummary.length > 0 ? this.runningTasksSummary : '加载后台任务…')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding({
                left: $r('app.float.page_padding'),
                right: $r('app.float.page_padding'),
                bottom: 8,
              });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '元数据书籍',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/MetaBookListPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '管理员书籍',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/AdminBookListPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '用户管理',
              subtitle: '账号、权限与配额管理',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/AdminUsersPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            SettingCell({
              title: '回收站管理',
              subtitle: '恢复或彻底删除书籍',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/AdminTrashPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            if (ServerRegistry.supports(ServerFeature.ADMIN_BOOK_REVIEWS)) {
              SettingCell({
                title: '评论审核',
                subtitle: '通过、屏蔽用户书评',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminBookReviewsPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            if (ServerRegistry.supports(ServerFeature.ADMIN_IMPORT)) {
              SettingCell({
                title: '导入管理',
                subtitle: '扫描导入、状态轮询与记录维护',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminImportsPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            if (ServerRegistry.supports(ServerFeature.BOOK_SOURCES)) {
              SettingCell({
                title: '书源管理',
                subtitle: '书源导入导出、启停、测试与体检',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/BookSourceManagePage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            if (ServerRegistry.supports(ServerFeature.ADMIN_SCAN)) {
              SettingCell({
                title: '扫描与导入',
                subtitle: '扫描记录、目录监控与批量导入',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminScanPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            if (ServerRegistry.supports(ServerFeature.ADMIN_OPDS)) {
              SettingCell({
                title: 'OPDS 源',
                subtitle: '浏览目录、导入与失败重试',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminOpdsPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            if (ServerRegistry.supports(ServerFeature.ADMIN_PLUGINS)) {
              SettingCell({
                title: '插件中心',
                subtitle: '插件启停、连接与正文工具',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminPluginsPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            if (ServerRegistry.supports(ServerFeature.ADMIN_MAINTENANCE)) {
              SettingCell({
                title: '服务端维护',
                subtitle: '更新、SSL、数据库与音频统计',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminMaintenancePage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            SettingCell({
              title: '系统日志',
              subtitle: '查看服务端运行日志',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/AdminSyslogPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
            if (ServerRegistry.supports(ServerFeature.ADMIN_RESOURCES)) {
              SettingCell({
                title: '资源导航',
                subtitle: '站长推荐的外部资源',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminResourcesPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            if (ServerRegistry.supports(ServerFeature.ADMIN_TOOLBOX)) {
              SettingCell({
                title: '工具箱',
                subtitle: '启停、卸载与商店安装',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminToolboxPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            if (ServerRegistry.supports(ServerFeature.ADMIN_MEMOS)) {
              SettingCell({
                title: '用户留言',
                subtitle: '查看与处理用户反馈',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminMemosPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
            }
            if (ServerRegistry.supports(ServerFeature.ADMIN_SETTINGS)) {
              SettingCell({
                title: '管理员设置',
                subtitle: '站点、用户、邮件等服务端配置',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminSettingsPage' }),
              });
            }
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          Text('关于')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Column() {
            SettingCell({
              title: '版本',
              valueText: this.versionText,
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));
        }
        .padding($r('app.float.page_padding'));
      }
      .layoutWeight(1);
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'));
  }
}
