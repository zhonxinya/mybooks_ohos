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
import { DownloadTaskService } from '../services/DownloadTaskService';

/** 折叠分组键：默认全部折叠，仅展开态渲染子项。 */
const SECTION_APPEARANCE: string = 'appearance';
const SECTION_ACCOUNT: string = 'account';
const SECTION_SERVICE: string = 'service';
const SECTION_ADMIN: string = 'admin';
const SECTION_ABOUT: string = 'about';

/**
 * 设置页分组头：整行可点切换折叠态，右侧箭头指示展开状态。
 * 用 `@Prop` 而非 `@Builder` 传参：按值传参的 `@Builder` 不会在状态变化后重绘，
 * 会导致摘要（主题/书库统计/版本）停留在首次渲染的值。
 */
@Component
struct SettingsSectionHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop expanded: boolean = false;
  onToggle?: () => void;

  build() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
        .fontSize(16)
        .fontColor([$r('app.color.text_tertiary')]);
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 6 })
    // 必须先给常态底色，否则 pressed 态不会复位（与 SettingCell / QuickActionGrid 写法一致）
    .backgroundColor(Color.Transparent)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => {
      if (this.onToggle) {
        this.onToggle();
      }
    });
  }
}

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
  @StorageProp('downloadTasksTick') @Watch('refreshBadges') downloadTasksTick: number = 0;
  @State activeTaskCount: number = 0;
  @State expandedSections: string[] = [];
  /** 可升级的版本号（由 UpdateService 经 AppStorage 发布，空串表示无提示）。 */
  @StorageProp('update_hint_version') updateAvailableVersion: string = '';

  aboutToAppear(): void {
    this.themeMode = TalebookService.prefGet(StorageKeys.THEME_MODE, 'system');
    this.showBackButton = TalebookService.prefGet(StorageKeys.SHOW_BACK_BUTTON, 'true') === 'true';
    this.refreshAccount();
    this.refreshBadges();
    this.applySectionParam();
    void NotificationService.refreshUnreadCount();
    void this.loadAdminOverview();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo) => {
        this.versionText = info.versionName;
      })
      .catch(() => {});
  }

  private refreshAccount(): void {
    // 以「凭据已保存」作为判定：新账号刚切换时资料尚未拉取（或曾因服务端不可达而拿不到），
    // 若以「已缓存用户资料」为门槛，「个人中心」入口会整个消失。
    this.isLoggedIn = TalebookService.hasAuthCredentials();
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

  /**
   * 外部深链（如 EPUB 修复页的「查看运行中任务」）可带 `section` 参数直达分组，
   * 避免默认折叠后无法直接看到目标内容。未传参时保持“全部折叠”。
   */
  private applySectionParam(): void {
    const params: Record<string, Object> | null = router.getParams() as Record<string, Object> | null;
    if (params === null || params === undefined) {
      return;
    }
    const section: Object | undefined = params['section'];
    if (section !== undefined) {
      const key: string = String(section);
      if (key.length > 0 && !this.isExpanded(key)) {
        this.toggleSection(key);
      }
    }
  }

  private isExpanded(key: string): boolean {
    return this.expandedSections.indexOf(key) >= 0;
  }

  private toggleSection(key: string): void {
    const next: string[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.expandedSections.length; i++) {
      if (this.expandedSections[i] === key) {
        removed = true;
      } else {
        next.push(this.expandedSections[i]);
      }
    }
    if (!removed) {
      next.push(key);
    }
    this.expandedSections = next;
  }

  private refreshBadges(): void {
    this.activeTaskCount = DownloadTaskService.activeCount();
  }

  private taskBadge(): string {
    return this.activeTaskCount > 0 ? `${this.activeTaskCount}` : '';
  }

  private accountSectionSubtitle(): string {
    return this.isLoggedIn ? '个人中心与消息通知' : '登录后可查看个人中心';
  }

  private adminSectionSubtitle(): string {
    if (!ServerRegistry.supports(ServerFeature.ADMIN_LIBRARY_STATS)) {
      return '服务端管理入口';
    }
    return this.librarySummary.length > 0 ? this.librarySummary : '服务端管理入口与统计';
  }

  private aboutSectionSubtitle(): string {
    const base: string = this.versionText.length > 0 ? `版本 ${this.versionText}` : '版本信息';
    return this.updateAvailableVersion.length > 0
      ? `${base} · 有新版本 v${this.updateAvailableVersion}`
      : base;
  }

  build() {
    Column() {
      HarmonyTopBar({ title: '设置' });
      Scroll() {
        Column({ space: 12 }) {
          SettingsSectionHeader({
            title: '外观',
            subtitle: AppTheme.themeModeLabel(this.themeMode),
            expanded: this.isExpanded(SECTION_APPEARANCE),
            onToggle: () => this.toggleSection(SECTION_APPEARANCE),
          });
          if (this.isExpanded(SECTION_APPEARANCE)) {
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
            }
            .width('100%')
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }

          SettingsSectionHeader({
            title: '账号',
            subtitle: this.accountSectionSubtitle(),
            expanded: this.isExpanded(SECTION_ACCOUNT),
            onToggle: () => this.toggleSection(SECTION_ACCOUNT),
          });
          if (this.isExpanded(SECTION_ACCOUNT)) {
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
          }

          SettingsSectionHeader({
            title: '服务',
            subtitle: this.accountSummary(),
            expanded: this.isExpanded(SECTION_SERVICE),
            onToggle: () => this.toggleSection(SECTION_SERVICE),
          });
          if (this.isExpanded(SECTION_SERVICE)) {
            Column() {
              SettingCell({
                title: '账号与服务器',
                subtitle: this.accountSummary(),
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/TalebookConfigPage' }),
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
              SettingCell({
                title: '下载管理',
                subtitle: '服务端与 SoNovel 统一下载队列',
                badgeText: this.taskBadge(),
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/DownloadManagerPage' }),
              });
              if (ServerRegistry.supports(ServerFeature.SYNC)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '数据同步',
                  subtitle: '拉取 / 推送 / 批注导入',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/SyncPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.NETWORK_LIBRARY)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '网络书库',
                  subtitle: '按书源搜索、阅读并保存到本地书库',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/NetworkLibraryPage' }),
                });
              }
            }
            .width('100%')
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }

          SettingsSectionHeader({
            title: '管理',
            subtitle: this.adminSectionSubtitle(),
            expanded: this.isExpanded(SECTION_ADMIN),
            onToggle: () => this.toggleSection(SECTION_ADMIN),
          });
          if (this.isExpanded(SECTION_ADMIN)) {
            Column({ space: 8 }) {
              // 与 loadAdminOverview 的能力门控保持一致：不支持的服务端不渲染永远停在“加载…”的卡
              if (ServerRegistry.supports(ServerFeature.ADMIN_LIBRARY_STATS)) {
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
              }
              SettingCell({
                title: '元数据书籍',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/MetaBookListPage' }),
              });
              if (ServerRegistry.supports(ServerFeature.AUTHOR_META_EDIT)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '作者元数据',
                  subtitle: '作者简介/头像与作者、出版商书籍刷新',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AuthorMetaPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_BATCH_ADD)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '批量添加实体书',
                  subtitle: 'CSV 导入实体书并轮询进度',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminBatchAddPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_AUDIO_IMPORT)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '有声书导入',
                  subtitle: '扫描音频目录入库、测试音频服务',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminAudioImportPage' }),
                });
              }
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
              if (ServerRegistry.supports(ServerFeature.ADMIN_BOOK_REVIEWS)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '评论审核',
                  subtitle: '通过、屏蔽用户书评',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminBookReviewsPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_IMPORT)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '导入管理',
                  subtitle: '扫描导入、状态轮询与记录维护',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminImportsPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.BOOK_SOURCES)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '书源管理',
                  subtitle: '书源导入导出、启停、测试与体检',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/BookSourceManagePage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_SCAN)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '扫描与导入',
                  subtitle: '扫描记录、目录监控与批量导入',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminScanPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_OPDS)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: 'OPDS 源',
                  subtitle: '浏览目录、导入与失败重试',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminOpdsPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_PLUGINS)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '插件中心',
                  subtitle: '插件启停、连接、能力测试与全局设置',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminPluginsPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_MAINTENANCE)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '服务端维护',
                  subtitle: '更新、SSL、数据库与音频统计',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminMaintenancePage' }),
                });
              }
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
              SettingCell({
                title: '系统日志',
                subtitle: '查看服务端运行日志',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/AdminSyslogPage' }),
              });
              if (ServerRegistry.supports(ServerFeature.ADMIN_RESOURCES)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '资源导航',
                  subtitle: '站长推荐的外部资源',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminResourcesPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_TOOLBOX)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '工具箱',
                  subtitle: '启停、卸载与商店安装',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminToolboxPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_MEMOS)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '用户留言',
                  subtitle: '查看与处理用户反馈',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminMemosPage' }),
                });
              }
              if (ServerRegistry.supports(ServerFeature.ADMIN_SETTINGS)) {
                Divider().color($r('app.color.divider')).strokeWidth(0.5);
                SettingCell({
                  title: '管理员设置',
                  subtitle: '站点、用户、邮件等服务端配置',
                  showChevron: true,
                  onTap: () => router.pushUrl({ url: 'pages/AdminSettingsPage' }),
                });
              }
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
          }

          SettingsSectionHeader({
            title: '关于',
            subtitle: this.aboutSectionSubtitle(),
            expanded: this.isExpanded(SECTION_ABOUT),
            onToggle: () => this.toggleSection(SECTION_ABOUT),
          });
          if (this.isExpanded(SECTION_ABOUT)) {
            Column() {
              SettingCell({
                title: '版本',
                valueText: this.versionText,
              });
              Divider().color($r('app.color.divider')).strokeWidth(0.5);
              SettingCell({
                title: '检查更新',
                subtitle: this.updateAvailableVersion.length > 0
                  ? `发现新版本 v${this.updateAvailableVersion}`
                  : '从 GitHub 获取最新发布版本与升级内容',
                badgeText: this.updateAvailableVersion.length > 0 ? '有更新' : '',
                showChevron: true,
                onTap: () => router.pushUrl({ url: 'pages/UpdatePage' }),
              });
            }
            .width('100%')
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'));
          }
        }
        .padding($r('app.float.page_padding'));
      }
      .layoutWeight(1)
      // 全部折叠时内容不满一屏，显式顶对齐，避免 Scroll 把内容垂直居中
      .align(Alignment.Top);
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'));
  }
}
