import { router } from '@kit.ArkUI';
import { PageScaffold, SettingCell } from '../components';
import { NotificationService } from '../services/NotificationService';
import { DownloadTaskService } from '../services/DownloadTaskService';
import { TalebookApi, LibraryStatsResponse, AdminRunningTasksResponse } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

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
          subtitle: '服务端与 SoNovel 统一下载队列',
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
          title: '服务器配置',
          subtitle: '配置书库地址与服务端类型',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/TalebookConfigPage' }),
        });
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      if (ServerRegistry.supports(ServerFeature.SYNC) ||
        ServerRegistry.supports(ServerFeature.NETWORK_LIBRARY) ||
        ServerRegistry.supports(ServerFeature.BOOK_SHELF) ||
        ServerRegistry.supports(ServerFeature.LIBRARY_ONLINE)) {
        Column() {
          if (ServerRegistry.supports(ServerFeature.SYNC)) {
            SettingCell({
              title: '数据同步',
              subtitle: '拉取 / 推送 / 批注导入',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/SyncPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
          }
          if (ServerRegistry.supports(ServerFeature.NETWORK_LIBRARY)) {
            SettingCell({
              title: '网络书库',
              subtitle: '按书源搜索、阅读并保存到本地书库',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/NetworkLibraryPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
          }
          if (ServerRegistry.supports(ServerFeature.BOOK_SHELF)) {
            SettingCell({
              title: '我的书架',
              subtitle: '服务端书架（阅读计划）',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/ShelfPage' }),
            });
            Divider().color($r('app.color.divider')).strokeWidth(0.5);
          }
          if (ServerRegistry.supports(ServerFeature.LIBRARY_ONLINE)) {
            SettingCell({
              title: '在线书库',
              subtitle: '已保存的网络书，可按连载状态筛选',
              showChevron: true,
              onTap: () => router.pushUrl({ url: 'pages/OnlineLibraryPage' }),
            });
          }
        }
        .width('100%')
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));
      }

      if (ServerRegistry.supports(ServerFeature.ADMIN_LIBRARY_STATS)) {
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
      }

      Column() {
        SettingCell({
          title: '元数据书籍',
          showChevron: true,
          onTap: () => router.pushUrl({ url: 'pages/MetaBookListPage' }),
        });
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        if (ServerRegistry.supports(ServerFeature.AUTHOR_META_EDIT)) {
          SettingCell({
            title: '作者元数据',
            subtitle: '作者简介/头像与作者、出版商书籍刷新',
            showChevron: true,
            onTap: () => router.pushUrl({ url: 'pages/AuthorMetaPage' }),
          });
          Divider().color($r('app.color.divider')).strokeWidth(0.5);
        }
        if (ServerRegistry.supports(ServerFeature.ADMIN_BATCH_ADD)) {
          SettingCell({
            title: '批量添加实体书',
            subtitle: 'CSV 导入实体书并轮询进度',
            showChevron: true,
            onTap: () => router.pushUrl({ url: 'pages/AdminBatchAddPage' }),
          });
          Divider().color($r('app.color.divider')).strokeWidth(0.5);
        }
        if (ServerRegistry.supports(ServerFeature.ADMIN_AUDIO_IMPORT)) {
          SettingCell({
            title: '有声书导入',
            subtitle: '扫描音频目录入库、测试音频服务',
            showChevron: true,
            onTap: () => router.pushUrl({ url: 'pages/AdminAudioImportPage' }),
          });
          Divider().color($r('app.color.divider')).strokeWidth(0.5);
        }
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
    .padding($r('app.float.page_padding'));
  }
}
