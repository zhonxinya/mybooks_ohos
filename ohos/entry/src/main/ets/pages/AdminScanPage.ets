import { PageScaffold, LoadingState, EmptyState, FilterChips, FilterChipItem,
  PrimaryButton, SecondaryButton, DangerButton, SectionTitle, SettingCell, TextButton } from '../components';
import {
  AdminScanApi, AdminScanItem, AdminScanSummary, AdminScanStatusCounts,
  AdminDirectoryEntry, AdminImportDirectoryCheck, AdminImportSettings, AdminWatchStatus,
  SCAN_FILTER_ALL, SCAN_FILTER_TODO, SCAN_FILTER_DONE, SCAN_FILTER_FAILED,
  SCAN_SORT_CREATE_TIME,
  IMPORT_MODE_INDEX, IMPORT_MODE_COPY, IMPORT_MODE_MOVE,
} from '../services/AdminScanApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { PaginationHelper } from '../utils/PaginationHelper';

const SCAN_PAGE_SIZE: number = 20;
/** 轮询间隔与上限：约 3 分钟后自动停止，避免页面退出前的无界轮询。 */
const POLL_INTERVAL_MS: number = 3000;
const POLL_MAX_TICKS: number = 60;

@Entry
@Component
struct AdminScanPage {
  @State private supported: boolean = true;
  @State private view: number = 0;
  @State private items: AdminScanItem[] = [];
  @State private loading: boolean = true;
  @State private loadingMore: boolean = false;
  @State private loadError: string = '';
  @State private currentPage: number = 1;
  @State private hasMore: boolean = true;
  @State private total: number = 0;
  @State private selectedFilter: number = 0;
  @State private desc: boolean = true;
  @State private summary: AdminScanSummary = {};
  @State private scanCounts: AdminScanStatusCounts = {};
  @State private importCounts: AdminScanStatusCounts = {};
  @State private working: boolean = false;
  @State private statusLine: string = '';
  // 导入设置
  @State private scanDir: string = '';
  @State private settingsPath: string = '';
  @State private watchStatus: AdminWatchStatus = {};
  @State private dirCheck: AdminImportDirectoryCheck | undefined = undefined;
  @State private modeIndex: number = 0;
  @State private autoWatch: boolean = false;
  @State private deleteAfter: boolean = false;
  // 目录浏览
  @State private browseMode: boolean = false;
  @State private browsePath: string = '';
  @State private browseParent: string = '';
  @State private browseItems: AdminDirectoryEntry[] = [];
  private lastLoadTime: number = 0;
  private pollTimer: number = -1;
  private pollTicks: number = 0;
  private importMode: string = IMPORT_MODE_COPY;

  aboutToAppear(): void {
    this.supported = ServerRegistry.supports(ServerFeature.ADMIN_SCAN);
    if (this.supported) {
      void this.loadScans(true);
      void this.loadSettings();
    } else {
      this.loading = false;
    }
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private messageOf(err: string | undefined, msg: string | undefined, fallback: string): string {
    if (msg !== undefined && msg.length > 0) {
      return msg;
    }
    if (err !== undefined && err !== 'ok') {
      return err;
    }
    return fallback;
  }

  // ---- 轮询 ----

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private startPoll(): void {
    this.stopPoll();
    this.pollTicks = 0;
    this.schedulePoll();
  }

  private schedulePoll(): void {
    this.stopPoll();
    if (this.pollTicks >= POLL_MAX_TICKS) {
      this.statusLine = '任务仍在进行，已停止自动刷新（可下拉/切换筛选手动刷新）';
      return;
    }
    this.pollTimer = setTimeout(() => {
      this.pollTicks += 1;
      void this.refreshStatus(true);
    }, POLL_INTERVAL_MS);
  }

  private isScanActive(): boolean {
    const pending: number = this.scanCounts.new !== undefined ? this.scanCounts.new : 0;
    return pending > 0;
  }

  private isImportActive(): boolean {
    const importing: number = this.importCounts.importing !== undefined ? this.importCounts.importing : 0;
    const queued: number = this.importCounts.queued !== undefined ? this.importCounts.queued : 0;
    return importing + queued > 0;
  }

  private async refreshStatus(continuePoll: boolean): Promise<void> {
    try {
      const scanRsp = await AdminScanApi.getScanStatus();
      if (scanRsp.err === undefined || scanRsp.err === 'ok') {
        this.scanCounts = scanRsp.status ?? {};
        this.summary = scanRsp.summary ?? this.summary;
      }
      const importRsp = await AdminScanApi.getImportStatus();
      if (importRsp.err === undefined || importRsp.err === 'ok') {
        this.importCounts = importRsp.status ?? {};
        this.summary = importRsp.summary ?? this.summary;
      }
      const active: boolean = this.isScanActive() || this.isImportActive();
      this.statusLine = active
        ? `扫描中 ${this.scanCounts.new ?? 0} · 导入中 ${this.importCounts.importing ?? 0}`
          + ` · 待导入 ${this.importCounts.ready ?? 0}`
        : '';
      if (active) {
        if (continuePoll) {
          this.schedulePoll();
        }
      } else {
        this.stopPoll();
      }
    } catch (e) {
      this.statusLine = `状态刷新失败：${e}`;
      this.stopPoll();
    }
  }

  // ---- 列表 ----

  private filterKey(value: number): string {
    if (value === 1) {
      return SCAN_FILTER_TODO;
    }
    if (value === 2) {
      return SCAN_FILTER_DONE;
    }
    if (value === 3) {
      return SCAN_FILTER_FAILED;
    }
    return SCAN_FILTER_ALL;
  }

  private async loadScans(reset: boolean = true): Promise<void> {
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.items = [];
      this.loading = true;
      this.loadError = '';
    } else {
      this.loadingMore = true;
    }
    const page: number = this.currentPage;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await AdminScanApi.listScans(page, SCAN_PAGE_SIZE, this.filterKey(this.selectedFilter),
        SCAN_SORT_CREATE_TIME, this.desc);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        if (reset) {
          this.loadError = this.messageOf(rsp.err, rsp.msg, '加载失败');
        } else {
          this.toast(this.messageOf(rsp.err, rsp.msg, '加载失败'));
          this.currentPage = Math.max(1, this.currentPage - 1);
        }
        return;
      }
      const fetched: AdminScanItem[] = rsp.items ?? [];
      this.items = reset ? fetched : this.items.concat(fetched);
      this.total = rsp.total !== undefined ? rsp.total : this.items.length;
      this.summary = rsp.summary ?? {};
      this.scanDir = rsp.scan_dir !== undefined ? rsp.scan_dir : '';
      this.watchStatus = rsp.watch_status ?? {};
      this.hasMore = PaginationHelper.computeHasMore(fetched.length, SCAN_PAGE_SIZE);
    } catch (e) {
      if (reset) {
        this.loadError = `加载失败：${e}`;
      } else {
        this.toast(`加载失败：${e}`);
        this.currentPage = Math.max(1, this.currentPage - 1);
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
    void this.loadScans(false);
  }

  private onFilterChange(value: number): void {
    this.selectedFilter = value;
    void this.loadScans(true);
  }

  private statusLabel(status: string): string {
    if (status === 'new') {
      return '待扫描';
    }
    if (status === 'drop') {
      return '文件重复';
    }
    if (status === 'exist') {
      return '已在库中';
    }
    if (status === 'ready') {
      return '可导入';
    }
    if (status === 'queued') {
      return '排队中';
    }
    if (status === 'importing') {
      return '导入中';
    }
    if (status === 'imported') {
      return '已导入';
    }
    if (status === 'indexed') {
      return '已入库';
    }
    if (status === 'delete_failed') {
      return '删除源文件失败';
    }
    if (status === 'failed') {
      return '失败';
    }
    if (status === 'downloading') {
      return '下载中';
    }
    return status;
  }

  private statusColor(status: string): ResourceColor {
    if (status === 'imported' || status === 'indexed' || status === 'ready') {
      return $r('app.color.success');
    }
    if (status === 'failed' || status === 'delete_failed') {
      return $r('app.color.error');
    }
    return $r('app.color.text_secondary');
  }

  private itemTitle(item: AdminScanItem): string {
    const title: string = item.title !== undefined && item.title.length > 0 ? item.title : '待识别';
    const author: string = item.author !== undefined && item.author.length > 0 ? item.author : '未知作者';
    return `${title} · ${author}`;
  }

  private itemSubtitle(item: AdminScanItem): string {
    const path: string = item.path !== undefined ? item.path : '';
    const time: string = item.update_time !== undefined ? item.update_time : '';
    return `${path} · ${time}`;
  }

  // ---- 操作 ----

  private runScan(): void {
    if (this.working) {
      return;
    }
    this.working = true;
    AdminScanApi.runScan().then((rsp) => {
      this.working = false;
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '已开始扫描'));
        this.startPoll();
        void this.loadScans(true);
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '扫描启动失败'));
      }
    }).catch((e: Object) => {
      this.working = false;
      this.toast(`扫描启动失败：${e}`);
    });
  }

  private confirmImportAll(): void {
    this.getUIContext().showAlertDialog({
      title: '导入待导入书籍',
      message: this.importMode === IMPORT_MODE_MOVE
        ? '当前为「剪切」模式：导入成功后源文件会被删除，确定继续？'
        : '将导入全部「可导入」状态的书籍，确定继续？',
      primaryButton: {
        value: '导入',
        action: () => {
          this.runImportAll();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private runImportAll(): void {
    if (this.working) {
      return;
    }
    this.working = true;
    AdminScanApi.runImportAll(this.deleteAfter, this.importMode).then((rsp) => {
      this.working = false;
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '已开始导入'));
        this.startPoll();
        void this.loadScans(true);
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '导入启动失败'));
      }
    }).catch((e: Object) => {
      this.working = false;
      this.toast(`导入启动失败：${e}`);
    });
  }

  private importOne(item: AdminScanItem): void {
    const hash: string = item.hash !== undefined ? item.hash : '';
    if (hash.length === 0 || this.working) {
      return;
    }
    this.working = true;
    AdminScanApi.runImport([hash], this.deleteAfter, this.importMode).then((rsp) => {
      this.working = false;
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '已开始导入'));
        this.startPoll();
        void this.loadScans(true);
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '导入失败'));
      }
    }).catch((e: Object) => {
      this.working = false;
      this.toast(`导入失败：${e}`);
    });
  }

  private markRecord(item: AdminScanItem): void {
    if (this.working) {
      return;
    }
    this.working = true;
    AdminScanApi.markScans().then((rsp) => {
      this.working = false;
      this.toast(this.messageOf(rsp.err, rsp.msg, `已标记「${item.title ?? ''}」`));
      void this.loadScans(true);
    }).catch((e: Object) => {
      this.working = false;
      this.toast(`标记失败：${e}`);
    });
  }

  private confirmDelete(item: AdminScanItem): void {
    const hash: string = item.hash !== undefined ? item.hash : '';
    if (hash.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除扫描记录',
      message: `确定删除「${item.title ?? item.path ?? ''}」的扫描记录吗？已入库的书籍不受影响。`,
      primaryButton: {
        value: '删除',
        action: () => {
          this.working = true;
          AdminScanApi.deleteScans([hash]).then((rsp) => {
            this.working = false;
            if (rsp.err === undefined || rsp.err === 'ok') {
              this.toast(this.messageOf(rsp.err, rsp.msg, '记录已删除'));
              void this.loadScans(true);
            } else {
              this.toast(this.messageOf(rsp.err, rsp.msg, '删除失败'));
            }
          }).catch((e: Object) => {
            this.working = false;
            this.toast(`删除失败：${e}`);
          });
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private confirmDeleteAll(): void {
    this.getUIContext().showAlertDialog({
      title: '清空扫描记录',
      message: '将删除全部扫描记录（不会删除已入库书籍，也不会删除源文件）。确定继续？',
      primaryButton: {
        value: '清空',
        action: () => {
          this.working = true;
          AdminScanApi.deleteAllScans().then((rsp) => {
            this.working = false;
            if (rsp.err === undefined || rsp.err === 'ok') {
              const count: number = rsp.count !== undefined ? rsp.count : 0;
              this.toast(`已删除 ${count} 条记录`);
              void this.loadScans(true);
            } else {
              this.toast(this.messageOf(rsp.err, rsp.msg, '清空失败'));
            }
          }).catch((e: Object) => {
            this.working = false;
            this.toast(`清空失败：${e}`);
          });
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private showItemActions(item: AdminScanItem): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: item.title !== undefined ? item.title : '',
      buttons: [
        { text: '导入此书', color: '#007DFF' },
        { text: '标记', color: '#007DFF' },
        { text: '删除记录', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        this.importOne(item);
      } else if (result.index === 1) {
        this.markRecord(item);
      } else if (result.index === 2) {
        this.confirmDelete(item);
      }
    }).catch(() => {});
  }

  // ---- 导入设置 ----

  private async loadSettings(): Promise<void> {
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await AdminScanApi.getImportSettings();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        return;
      }
      const settings: AdminImportSettings | undefined = rsp.settings;
      if (settings === undefined) {
        return;
      }
      this.settingsPath = settings.scan_upload_path !== undefined ? settings.scan_upload_path : '';
      this.importMode = settings.import_mode !== undefined ? settings.import_mode : IMPORT_MODE_COPY;
      this.modeIndex = this.modeIndexOf(this.importMode);
      this.autoWatch = settings.auto_watch_enabled === true;
      this.watchStatus = settings.watch_status ?? {};
      this.dirCheck = settings.directory_check;
    } catch (e) {
      this.toast(`导入设置加载失败：${e}`);
    }
  }

  private modeIndexOf(mode: string): number {
    if (mode === IMPORT_MODE_INDEX) {
      return 1;
    }
    if (mode === IMPORT_MODE_MOVE) {
      return 2;
    }
    return 0;
  }

  private modeOf(index: number): string {
    if (index === 1) {
      return IMPORT_MODE_INDEX;
    }
    if (index === 2) {
      return IMPORT_MODE_MOVE;
    }
    return IMPORT_MODE_COPY;
  }

  private saveSettings(path: string): void {
    if (this.working) {
      return;
    }
    this.working = true;
    AdminScanApi.saveImportSettings(path, this.modeOf(this.modeIndex), this.autoWatch)
      .then((rsp) => {
        this.working = false;
        if (rsp.err === undefined || rsp.err === 'ok') {
          this.toast(this.messageOf(rsp.err, rsp.msg, '导入设置已保存'));
          this.browseMode = false;
          void this.loadSettings();
          void this.loadScans(true);
        } else {
          this.toast(this.messageOf(rsp.err, rsp.msg, '保存失败'));
          const check: AdminImportDirectoryCheck | undefined = rsp.directory_check;
          this.dirCheck = check;
        }
      }).catch((e: Object) => {
        this.working = false;
        this.toast(`保存失败：${e}`);
      });
  }

  private checkDirectory(): void {
    if (this.working) {
      return;
    }
    this.working = true;
    AdminScanApi.checkImportDirectory(this.settingsPath).then((rsp) => {
      this.working = false;
      this.dirCheck = rsp.directory;
      const detail: string = rsp.msg !== undefined && rsp.msg.length > 0
        ? rsp.msg
        : this.directorySummary(rsp.directory);
      this.toast(detail);
    }).catch((e: Object) => {
      this.working = false;
      this.toast(`检查失败：${e}`);
    });
  }

  private directorySummary(dir: AdminImportDirectoryCheck | undefined): string {
    if (dir === undefined) {
      return '无目录信息';
    }
    return `${dir.path ?? ''} · 支持格式 ${dir.supported_file_count ?? 0} 个`
      + ` · ${dir.writable === true ? '可写' : '只读'}`;
  }

  private openDirectoryBrowser(): void {
    this.browseMode = true;
    void this.loadDirectory(this.settingsPath);
  }

  private async loadDirectory(path: string): Promise<void> {
    try {
      const rsp = await AdminScanApi.listImportDirectories(path);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '目录读取失败'));
        return;
      }
      this.browsePath = rsp.path !== undefined ? rsp.path : path;
      this.browseParent = rsp.parent !== undefined ? rsp.parent : '';
      this.browseItems = rsp.items ?? [];
    } catch (e) {
      this.toast(`目录读取失败：${e}`);
    }
  }

  private confirmUseDirectory(): void {
    this.getUIContext().showAlertDialog({
      title: '使用此目录',
      message: `将导入目录设置为「${this.browsePath}」，并按当前模式保存，确定继续？`,
      primaryButton: {
        value: '保存',
        action: () => {
          this.saveSettings(this.browsePath);
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private directoryLabel(entry: AdminDirectoryEntry): string {
    const name: string = entry.name !== undefined ? entry.name : '';
    const readable: boolean = entry.readable === true;
    const writable: boolean = entry.writable === true;
    const allowed: boolean = entry.in_allowed_roots === true;
    return `${name}${writable ? ' · 可写' : readable ? ' · 只读' : ' · 不可读'}${allowed ? '' : ' · 越界'}`;
  }

  private watchLabel(): string {
    const state: string = this.watchStatus.state !== undefined ? this.watchStatus.state : 'off';
    const message: string = this.watchStatus.message !== undefined ? this.watchStatus.message : '';
    return `${state}${message.length > 0 ? ` · ${message}` : ''}`;
  }

  build() {
    Column() {
      PageScaffold({
        title: '扫描与导入',
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
    if (!this.supported) {
      EmptyState({ message: '当前服务端不支持扫描记录管理（需要 Talebook）' });
    } else if (this.browseMode) {
      this.browseView();
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError, actionLabel: '重试', onAction: () => { void this.loadScans(true); } });
    } else {
      Column() {
        FilterChips({
          items: [
            { label: '扫描记录', value: 0 },
            { label: '导入设置', value: 1 },
          ] as FilterChipItem[],
          selected: $view,
          onChange: (value: number) => {
            this.view = value;
            if (value === 1) {
              void this.loadSettings();
            }
          },
        });
        if (this.view === 1) {
          Scroll() {
            Column() {
              this.settingsSection();
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 24 });
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.Top);
        } else {
          this.summaryCard();
          FilterChips({
            items: [
              { label: '全部', value: 0 },
              { label: '待处理', value: 1 },
              { label: '已完成', value: 2 },
              { label: '失败', value: 3 },
            ] as FilterChipItem[],
            selected: $selectedFilter,
            onChange: (value: number) => this.onFilterChange(value),
          });
          if (this.items.length === 0) {
            EmptyState({ message: '暂无扫描记录，先在上方运行一次扫描' });
          } else {
            List({ space: 8 }) {
              ForEach(this.items, (item: AdminScanItem) => {
                ListItem() {
                  this.itemRow(item);
                }
              }, (item: AdminScanItem) => `scan-${item.id ?? 0}`);
              if (this.loadingMore) {
                ListItem() {
                  LoadingState({ hint: '加载更多...' });
                }
              }
            }
            .layoutWeight(1)
            .width('100%')
            .onReachEnd(() => this.loadMore());
          }
        }
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  summaryCard() {
    Column({ space: 8 }) {
      Text(`扫描目录：${this.scanDir.length > 0 ? this.scanDir : this.settingsPath}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Text(`共 ${this.summary.total ?? this.total} · 完成 ${this.summary.done ?? 0}`
        + ` · 待处理 ${this.summary.todo ?? 0} · 失败 ${this.summary.failed ?? 0}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      if (this.statusLine.length > 0) {
        Text(this.statusLine)
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
          .width('100%');
      }
      Row({ space: 12 }) {
        PrimaryButton({
          label: this.working ? '处理中…' : '运行扫描',
          buttonEnabled: !this.working,
          fullWidth: false,
          onTap: () => this.runScan(),
        }).layoutWeight(1);
        PrimaryButton({
          label: '导入待导入',
          buttonEnabled: !this.working,
          fullWidth: false,
          onTap: () => this.confirmImportAll(),
        }).layoutWeight(1);
      }
      .width('100%');
      Row({ space: 12 }) {
        SecondaryButton({
          label: this.desc ? '按时间倒序' : '按时间正序',
          fullWidth: false,
          compact: true,
          onTap: () => {
            this.desc = !this.desc;
            void this.loadScans(true);
          },
        }).layoutWeight(1);
        SecondaryButton({
          label: '标记',
          fullWidth: false,
          compact: true,
          onTap: () => this.markRecord({}),
        }).layoutWeight(1);
        DangerButton({
          label: '清空记录',
          buttonEnabled: !this.working,
          fullWidth: false,
          onTap: () => this.confirmDeleteAll(),
        }).layoutWeight(1);
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .margin({ left: 16, right: 16, top: 8, bottom: 8 });
  }

  @Builder
  itemRow(item: AdminScanItem) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(this.itemTitle(item))
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(this.statusLabel(item.status ?? ''))
          .fontSize(11)
          .fontColor(this.statusColor(item.status ?? ''))
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
      }
      .width('100%');
      Text(this.itemSubtitle(item))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Row({ space: 8 }) {
        TextButton({
          label: '导入',
          onTap: () => this.importOne(item),
        });
        TextButton({
          label: '标记',
          onTap: () => this.markRecord(item),
        });
        TextButton({
          label: '删除',
          tone: 'danger',
          onTap: () => this.confirmDelete(item),
        });
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .onClick(() => this.showItemActions(item));
  }

  @Builder
  settingsSection() {
    SectionTitle({ title: '导入设置' });
    Column({ space: 8 }) {
      Text(`当前目录：${this.settingsPath.length > 0 ? this.settingsPath : '（未配置）'}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      if (this.dirCheck !== undefined) {
        Text(this.directorySummary(this.dirCheck))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      Text(`监控：${this.watchLabel()}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      SettingCell({
        title: '自动监控目录',
        subtitle: '开启后按服务端间隔自动扫描并导入新文件',
        showToggle: true,
        toggleOn: this.autoWatch,
        onToggle: (value: boolean) => {
          this.autoWatch = value;
        },
      });
      SettingCell({
        title: '导入后删除源文件',
        subtitle: '仅对复制/索引模式生效（剪切模式始终删除源文件）',
        showToggle: true,
        toggleOn: this.deleteAfter,
        onToggle: (value: boolean) => {
          this.deleteAfter = value;
        },
      });
      Text(`导入模式：${this.modeOf(this.modeIndex)}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      FilterChips({
        items: [
          { label: '复制', value: 0 },
          { label: '仅索引', value: 1 },
          { label: '剪切', value: 2 },
        ] as FilterChipItem[],
        selected: $modeIndex,
        onChange: (value: number) => {
          this.modeIndex = value;
        },
      });
      Row({ space: 12 }) {
        SecondaryButton({
          label: '选择目录',
          fullWidth: false,
          onTap: () => this.openDirectoryBrowser(),
        }).layoutWeight(1);
        SecondaryButton({
          label: '检查目录',
          buttonEnabled: !this.working,
          fullWidth: false,
          onTap: () => this.checkDirectory(),
        }).layoutWeight(1);
      }
      .width('100%');
      PrimaryButton({
        label: '保存导入设置',
        buttonEnabled: !this.working,
        onTap: () => this.saveSettings(this.settingsPath),
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  browseView() {
    Column({ space: 8 }) {
      Text(`当前目录：${this.browsePath}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Row({ space: 12 }) {
        SecondaryButton({
          label: '上级目录',
          buttonEnabled: this.browseParent.length > 0,
          fullWidth: false,
          compact: true,
          onTap: () => {
            void this.loadDirectory(this.browseParent);
          },
        }).layoutWeight(1);
        PrimaryButton({
          label: '使用此目录',
          buttonEnabled: !this.working,
          fullWidth: false,
          onTap: () => this.confirmUseDirectory(),
        }).layoutWeight(1);
      }
      .width('100%');
      SecondaryButton({
        label: '取消',
        fullWidth: false,
        onTap: () => {
          this.browseMode = false;
        },
      });
      if (this.browseItems.length === 0) {
        EmptyState({ message: '该目录下没有子目录' });
      } else {
        List({ space: 8 }) {
          ForEach(this.browseItems, (entry: AdminDirectoryEntry) => {
            ListItem() {
              Text(this.directoryLabel(entry))
                .fontSize(14)
                .fontColor(entry.in_allowed_roots === true
                  ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
                .width('100%')
                .padding($r('app.float.page_padding'))
                .backgroundColor($r('app.color.card_background'))
                .borderRadius($r('app.float.card_radius'));
            }
            .onClick(() => {
              void this.loadDirectory(entry.path !== undefined ? entry.path : '');
            })
          }, (entry: AdminDirectoryEntry) => `dir-${entry.path ?? entry.name ?? ''}`);
        }
        .layoutWeight(1)
        .width('100%');
      }
    }
    .width('100%')
    .height('100%')
    .padding(16);
  }
}
