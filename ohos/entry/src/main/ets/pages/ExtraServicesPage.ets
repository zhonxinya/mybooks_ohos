import { router } from '@kit.ArkUI';
import { PageScaffold, SettingCell } from '../components';
import { NotificationService } from '../services/NotificationService';
import { DownloadTaskService } from '../services/DownloadTaskService';
import { TalebookApi, LibraryStatsResponse, AdminRunningTasksResponse } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';

@Entry
@Component
struct ExtraServicesPage {
  @State activeTaskCount: number = 0;
  @State librarySummary: string = '';
  @State runningTasksSummary: string = '';
  @State adminOverviewLoading: boolean = false;
  @StorageProp('unreadMessageCount') unreadCount: number = 0;
  @StorageProp('notificationTick') @Watch('refreshBadges') notificationTick: number = 0;
  @StorageProp('downloadTasksTick') @Watch('refreshBadges') downloadTasksTick: number = 0;

  aboutToAppear(): void {
    this.refreshBadges();
    void NotificationService.refreshUnreadCount();
    void this.loadAdminOverview();
  }

  private async loadAdminOverview(): Promise<void> {
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
          this.librarySummary = `共 ${total} 本（电子 ${ebook} / 实体 ${physical}）· 本月新增电子 ${monthE}、实体 ${monthP}`;
        } else {
          this.librarySummary = '暂无书库统计';
        }
      } else {
        this.librarySummary = statsRsp.msg !== undefined && statsRsp.msg.length > 0 ? statsRsp.msg : '书库统计不可用';
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

  private refreshBadges(): void {
    this.activeTaskCount = DownloadTaskService.activeCount();
  }

  private taskBadge(): string {
    return this.activeTaskCount > 0 ? `${this.activeTaskCount}` : '';
  }

  private unreadBadge(): string {
    return this.unreadCount > 0 ? `${this.unreadCount}` : '';
  }

  build() {
    Column() {
      PageScaffold({
        title: '附加服务',
        showBack: true,
        content: () => {
          this.servicesContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  servicesContent() {
    Column({ space: 12 }) {
      Column() {
        SettingCell({
          title: 'SoNovel 搜索',
          subtitle: '聚合书源搜索与下载',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/SoNovelSearchPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        SettingCell({
          title: '下载管理',
          subtitle: 'Talebook 与 SoNovel 统一下载队列',
          badgeText: this.taskBadge(),
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/DownloadManagerPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        SettingCell({
          title: 'SoNovel 服务',
          subtitle: '配置 SoNovel 地址',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/SoNovelConfigPage' }),
        });
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      Column() {
        SettingCell({
          title: 'Talebook 服务器',
          subtitle: '配置书库地址',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/TalebookConfigPage' }),
        });
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      Column({ space: 8 }) {
        Row() {
          Text('管理概览')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Text(this.adminOverviewLoading ? '刷新中…' : '刷新')
            .fontSize(12)
            .fontColor($r('app.color.on_brand'))
            .onClick(() => { void this.loadAdminOverview(); });
        }
        .width('100%');
        Text(this.librarySummary.length > 0 ? this.librarySummary : '加载书库统计…')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        Text(this.runningTasksSummary.length > 0 ? this.runningTasksSummary : '加载后台任务…')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding($r('app.float.page_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      Column() {
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
        SettingCell({
          title: '评论审核',
          subtitle: '通过、屏蔽用户书评',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/AdminBookReviewsPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        SettingCell({
          title: '导入管理',
          subtitle: '扫描导入、状态轮询与记录维护',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/AdminImportsPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        SettingCell({
          title: '系统日志',
          subtitle: '查看服务端运行日志',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/AdminSyslogPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        SettingCell({
          title: '资源导航',
          subtitle: '站长推荐的外部资源',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/AdminResourcesPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        SettingCell({
          title: '工具箱',
          subtitle: '启停、卸载与商店安装',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/AdminToolboxPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        SettingCell({
          title: '用户留言',
          subtitle: '查看与处理用户反馈',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/AdminMemosPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        SettingCell({
          title: '管理员设置',
          subtitle: '站点、用户、邮件等服务端配置',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/AdminSettingsPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
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
    .padding($r('app.float.page_padding'));
  }
}
