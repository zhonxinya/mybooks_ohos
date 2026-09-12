import { router, LengthMetrics } from '@kit.ArkUI';
import { PageScaffold, LoadingState, EmptyState, FilterChips, FilterChipItem,
  PrimaryButton, SecondaryButton, DangerButton, SectionTitle, SettingCell, TextButton,
  ChipButton } from '../components';
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

/**
 * 页面自有「带计数」筛选胶囊。
 * 不用共享 FilterChips：其 `items` 是普通成员，计数变化后标签不会重绘（ArkUI 陷阱）；
 * ChipButton 的 `label` 是 @Prop，故用 Row + ChipButton 自建。
 */
@Component
struct ScanFilterChips {
  @Prop labels: string[] = [];
  @Prop selected: number = 0;
  onPick?: (value: number) => void;

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.labels, (label: string, index: number) => {
          ChipButton({
            label: label,
            selected: this.selected === index,
            onTap: () => {
              if (this.onPick) {
                this.onPick(index);
              }
            },
          });
        }, (label: string, index: number) => `scan-chip-${index}-${label}`);
      }
      .padding({ left: 16, right: 16, top: 2, bottom: 6 });
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%');
  }
}

/** 概览分栏单元（数值 + 标签）。
 * 必须用 @Prop 而非 @Builder 按值传参：@Builder 内的文本/属性不会随状态变化重绘。
 */
@Component
struct ScanStatCell {
  @Prop label: string = '';
  @Prop value: number = 0;
  @Prop valueColor: ResourceColor = $r('app.color.text_primary');

  build() {
    Column({ space: 2 }) {
      Text(`${this.value}`)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.valueColor);
      Text(this.label)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'));
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 6, bottom: 6 })
    .borderRadius(8)
    .backgroundColor($r('app.color.page_background'));
  }
}

/** 概览信息胶囊（目录 / 模式 / 监控 / 最近扫描）。 */
@Component
struct ScanInfoChip {
  @Prop text: string = '';
  @Prop textColor: ResourceColor = $r('app.color.text_secondary');

  build() {
    Text(this.text)
      .fontSize(11)
      .fontColor(this.textColor)
      .backgroundColor($r('app.color.page_background'))
      .borderRadius(8)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis });
  }
}

/** 提示/警示块（目录预检、轮询进度行）。 */
@Component
struct ScanNotice {
  @Prop text: string = '';
  @Prop textColor: ResourceColor = $r('app.color.text_secondary');
  @Prop bg: ResourceColor = Color.Transparent;

  build() {
    Text(this.text)
      .fontSize(12)
      .fontColor(this.textColor)
      .backgroundColor(this.bg)
      .borderRadius(8)
      .padding(this.bg === Color.Transparent ? 0 : 8)
      .width('100%');
  }
}

/** 多选批量操作条（对齐上游选中态的「导入所选 / 删除」分支）。
 * 计数与可用态用 @Prop 下发（页面内自定义 @Prop 组件是本项目验证过的刷新方式）。
 */
@Component
struct ScanBatchBar {
  @Prop selectedCount: number = 0;
  @Prop pageCount: number = 0;
  @Prop allSelected: boolean = false;
  @Prop importEnabled: boolean = false;
  @Prop deleteEnabled: boolean = false;
  onToggleAll?: () => void;
  onExit?: () => void;
  onImport?: () => void;
  onDelete?: () => void;

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(`已选 ${this.selectedCount} / 本页 ${this.pageCount}`)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        ChipButton({
          label: this.allSelected ? '取消全选' : '全选',
          onTap: () => {
            if (this.onToggleAll) {
              this.onToggleAll();
            }
          },
        });
        Text('退出多选')
          .fontSize(13)
          .fontColor($r('app.color.brand_primary'))
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (this.onExit) {
              this.onExit();
            }
          });
      }
      .width('100%');

      Row({ space: 12 }) {
        // 复用共享按钮组件：胶囊/圆角与全应用保持一致，避免各页手写出一套自己的形态
        PrimaryButton({
          label: `导入所选${this.selectedCount > 0 ? `（${this.selectedCount}）` : ''}`,
          fullWidth: false,
          buttonEnabled: this.importEnabled,
          onTap: () => {
            if (this.onImport) {
              this.onImport();
            }
          },
        })
          .layoutWeight(1);
        DangerButton({
          label: '删除所选',
          fullWidth: false,
          buttonEnabled: this.deleteEnabled,
          onTap: () => {
            if (this.onDelete) {
              this.onDelete();
            }
          },
        })
          .layoutWeight(1);
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .margin({ left: 16, right: 16, bottom: 8 })
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }
}

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
  // 多选批量操作（对齐上游表格 show-select：导入所选 / 删除所选）
  @State private selecting: boolean = false;
  @State private selectedHashes: string[] = [];
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
    // 服务端字段可能为 JSON null，统一用 ?? 避免 .length 崩溃
    const text: string = msg ?? '';
    if (text.length > 0) {
      return text;
    }
    const code: string = err ?? '';
    if (code.length > 0 && code !== 'ok') {
      return code;
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

  /** 状态徽标底色：按语义分组着色（对齐上游彩色 chip，而不是一律灰底）。 */
  private statusChipBg(status: string): ResourceColor {
    if (status === 'imported' || status === 'indexed' || status === 'ready') {
      return $r('app.color.success_light');
    }
    if (status === 'failed' || status === 'delete_failed') {
      return $r('app.color.error_light');
    }
    if (status === 'queued' || status === 'importing' || status === 'downloading') {
      return $r('app.color.brand_primary_light');
    }
    if (status === 'drop') {
      return $r('app.color.warning_light');
    }
    return $r('app.color.page_background');
  }

  /** 在途状态：需要展示进度感（对齐上游 info 色）。 */
  private statusTextColor(status: string): ResourceColor {
    if (status === 'queued' || status === 'importing' || status === 'downloading') {
      return $r('app.color.brand_primary');
    }
    if (status === 'drop') {
      return $r('app.color.warning');
    }
    return this.statusColor(status);
  }

  // ---- 概览语义（对齐上游 imports.vue 的 computed） ----

  /** 监控状态文案：上游按 state 给出差异化描述，而不是直接打印原始值。 */
  private watchStatusText(): string {
    const state: string = this.watchStatus.state ?? 'off';
    if (!this.autoWatch && state === 'off') {
      return '未开启';
    }
    if (state === 'scanning') {
      return '正在扫描目录';
    }
    if (state === 'queued') {
      return `已排队 ${this.watchStatus.queued ?? 0} 项`;
    }
    if (state === 'importing') {
      return `正在导入 ${this.watchStatus.running ?? 0} 项`;
    }
    if (state === 'failed') {
      return `有 ${this.watchStatus.failed ?? 0} 项失败`;
    }
    if (state === 'starting') {
      return '正在启动监控';
    }
    if (state === 'idle') {
      return '待命中';
    }
    return this.autoWatch ? '监控中' : '未开启';
  }

  private watchStatusColor(): ResourceColor {
    const state: string = this.watchStatus.state ?? 'off';
    if (state === 'failed') {
      return $r('app.color.error');
    }
    if (state === 'scanning' || state === 'queued' || state === 'importing' || state === 'starting') {
      return $r('app.color.brand_primary');
    }
    if (this.autoWatch) {
      return $r('app.color.success');
    }
    return $r('app.color.text_secondary');
  }

  /** 最近扫描时间（上游：空则「从未扫描」）。 */
  private lastScanText(): string {
    const at: string = this.watchStatus.last_scan_at ?? '';
    return at.length > 0 ? at : '从未扫描';
  }

  /** 目录预检：仅当 status 非 ok 且带 msg 时给出警示（上游 directoryAlert）。 */
  private directoryAlertIsError(): boolean {
    const check = this.dirCheck;
    return check !== undefined && check.status === 'error';
  }

  private directoryAlertMessage(): string {
    const check = this.dirCheck;
    if (check === undefined) {
      return '';
    }
    const status: string = check.status ?? '';
    const msg: string = check.msg ?? '';
    if (status === 'ok' || msg.length === 0) {
      return '';
    }
    return msg;
  }

  /** 需要关注：目录预检 error 或监控 failed（上游 needsSettingsAttention）。 */
  private needsSettingsAttention(): boolean {
    return this.directoryAlertIsError() || (this.watchStatus.state ?? '') === 'failed';
  }

  /** 目录预检 error 时上游会禁用扫描/导入动作，避免必然失败的任务。 */
  private importActionsDisabled(): boolean {
    return this.working || this.directoryAlertIsError();
  }

  private importModeLabel(): string {
    const mode: string = this.importMode;
    if (mode === IMPORT_MODE_INDEX) {
      return '仅索引';
    }
    if (mode === IMPORT_MODE_MOVE) {
      return '剪切';
    }
    return '复制';
  }

  /** delete_failed 的失败原因（上游 tooltip 取 item.data.delete_error）。 */
  private deleteErrorMessage(item: AdminScanItem): string {
    const data = item.data;
    if (data === undefined || data === null) {
      return '';
    }
    const value = data['delete_error'];
    if (value === undefined || value === null) {
      return '';
    }
    return `${value}`;
  }

  /**
   * 概览区「状态签名」。
   * ArkUI 陷阱：概览行内的文本/@Prop 在纯状态变化下不保证刷新（实测：勾选后计数不更新），
   * 因此用签名作为 ForEach 的 key 强制重建该区块。任何会影响展示的字段都必须纳入签名。
   */
  private overviewKey(): string {
    const check: AdminImportDirectoryCheck | undefined = this.dirCheck;
    return `ov-${this.summary.total ?? this.total}-${this.summary.done ?? 0}-${this.summary.todo ?? 0}`
      + `-${this.summary.failed ?? 0}-${this.scanDir}-${this.settingsPath}-${this.importMode}-${this.autoWatch}`
      + `-${this.watchStatus.state ?? ''}-${this.watchStatus.queued ?? 0}-${this.watchStatus.running ?? 0}`
      + `-${this.watchStatus.failed ?? 0}-${this.watchStatus.last_scan_at ?? ''}-${this.statusLine}`
      + `-${check === undefined ? 'none' : `${check.status ?? ''}|${check.msg ?? ''}`}`;
  }

  /** 列表头部（计数胶囊 + 批量条）的「状态签名」，同上用于强制重建。 */
  private listHeaderKey(): string {
    return `lh-${this.countOf(0)}-${this.countOf(1)}-${this.countOf(2)}-${this.countOf(3)}`
      + `-${this.selectedFilter}-${this.selectedHashes.length}-${this.selectableHashes().length}`
      + `-${this.allSelected()}-${this.importActionsDisabled()}-${this.working}`;
  }

  /** 当前筛选下的计数（供带计数的筛选胶囊使用；上游页签同源 summary）。 */
  private countOf(filter: number): number {
    if (filter === 1) {
      return this.summary.todo ?? 0;
    }
    if (filter === 2) {
      return this.summary.done ?? 0;
    }
    if (filter === 3) {
      return this.summary.failed ?? 0;
    }
    return this.summary.total ?? this.total;
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

  /**
   * ForEach key 必须包含行内会变化的字段：导入后 status / book_id / 时间会变，
   * 若只用 id 则行不会重建，界面会停留在旧状态（ArkUI 陷阱）。
   */
  private itemKey(item: AdminScanItem): string {
    return `scan-${item.id ?? 0}-${item.status ?? ''}-${item.book_id ?? 0}-${item.update_time ?? ''}`;
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
    // 长按/点击「详情」查看完整信息（path/hash/失败原因），避免与行内按钮抢点击
    const hash: string = item.hash ?? '';
    const detail: string[] = [];
    if (hash.length > 0) {
      detail.push(`hash：${hash}`);
    }
    const path: string = item.path ?? '';
    if (path.length > 0) {
      detail.push(`路径：${path}`);
    }
    const created: string = item.create_time ?? '';
    if (created.length > 0) {
      detail.push(`入库时间：${created}`);
    }
    const updated: string = item.update_time ?? '';
    if (updated.length > 0) {
      detail.push(`更新时间：${updated}`);
    }
    const bookId = item.book_id ?? 0;
    if (bookId > 0) {
      detail.push(`已关联书籍 #${bookId}`);
    }
    const deleteError: string = this.deleteErrorMessage(item);
    if (deleteError.length > 0) {
      detail.push(`删除源文件失败：${deleteError}`);
    }
    this.getUIContext().showAlertDialog({
      title: item.title ?? '扫描记录',
      message: detail.length > 0 ? detail.join('\n') : '无更多信息',
      primaryButton: {
        value: '导入此书',
        action: () => this.importOne(item),
      },
      secondaryButton: { value: '关闭', action: () => {} },
    });
  }

  // ---- 多选批量（对齐上游表格 show-select 的导入所选 / 删除所选） ----

  private toggleSelecting(): void {
    this.selecting = !this.selecting;
    if (!this.selecting) {
      this.selectedHashes = [];
    }
  }

  private isSelected(hash: string): boolean {
    return hash.length > 0 && this.selectedHashes.indexOf(hash) >= 0;
  }

  /**
   * 幂等写入单行勾选态。
   * ⚠️ 必须幂等：行级 onClick 与 Toggle.onChange 会作用于同一行，
   * 若两者都做「取反」，会出现「刚勾上又被撤销」（实测选中恒为 0）。
   */
  private setSelected(hash: string, wanted: boolean): void {
    if (hash.length === 0) {
      return;
    }
    if (this.isSelected(hash) === wanted) {
      return;
    }
    const next: string[] = [];
    for (const item of this.selectedHashes) {
      if (item !== hash) {
        next.push(item);
      }
    }
    if (wanted) {
      next.push(hash);
    }
    this.selectedHashes = next;
  }

  private toggleSelected(hash: string): void {
    this.setSelected(hash, !this.isSelected(hash));
  }

  private selectableHashes(): string[] {
    const result: string[] = [];
    for (const item of this.items) {
      const hash: string = item.hash ?? '';
      if (hash.length > 0) {
        result.push(hash);
      }
    }
    return result;
  }

  private allSelected(): boolean {
    const all: string[] = this.selectableHashes();
    return all.length > 0 && this.selectedHashes.length >= all.length;
  }

  private toggleSelectAll(): void {
    this.selectedHashes = this.allSelected() ? [] : this.selectableHashes();
  }

  /** 导入所选（POST /api/admin/import/run，hashlist 为哈希数组）。 */
  private runImportSelected(): void {
    if (this.selectedHashes.length === 0 || this.importActionsDisabled()) {
      return;
    }
    const hashes: string[] = this.selectedHashes.slice();
    this.working = true;
    AdminScanApi.runImport(hashes, this.deleteAfter, this.importMode).then((rsp) => {
      this.working = false;
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, `已开始导入 ${hashes.length} 本`));
        this.selectedHashes = [];
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

  private confirmDeleteSelected(): void {
    if (this.selectedHashes.length === 0) {
      return;
    }
    const count: number = this.selectedHashes.length;
    this.getUIContext().showAlertDialog({
      title: '删除所选扫描记录',
      message: `将删除选中的 ${count} 条扫描记录（不影响已入库书籍与源文件）。确定继续？`,
      primaryButton: {
        value: '删除',
        action: () => {
          const hashes: string[] = this.selectedHashes.slice();
          this.working = true;
          AdminScanApi.deleteScans(hashes).then((rsp) => {
            this.working = false;
            if (rsp.err === undefined || rsp.err === 'ok') {
              this.toast(this.messageOf(rsp.err, rsp.msg, `已删除 ${count} 条记录`));
              this.selectedHashes = [];
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

  /**
   * 关于「标记」：上游 `POST /api/admin/scan/mark` 是**空实现占位**，
   * 恒返回 `{err:'ok'}` 且无任何副作用，因此本页不提供该入口，避免造成假成功
   * （见 AdminScanApi.markScans 上方注释）。
   */

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
          ScanFilterChips({
            labels: [
              `全部 (${this.countOf(0)})`,
              `待处理 (${this.countOf(1)})`,
              `已完成 (${this.countOf(2)})`,
              `失败 (${this.countOf(3)})`,
            ],
            selected: this.selectedFilter,
            onPick: (value: number) => this.onFilterChange(value),
          });
          if (this.selecting) {
            ScanBatchBar({
              selectedCount: this.selectedHashes.length,
              pageCount: this.selectableHashes().length,
              allSelected: this.allSelected(),
              importEnabled: this.selectedHashes.length > 0 && !this.importActionsDisabled(),
              deleteEnabled: this.selectedHashes.length > 0 && !this.working,
              onToggleAll: () => this.toggleSelectAll(),
              onExit: () => this.toggleSelecting(),
              onImport: () => this.runImportSelected(),
              onDelete: () => this.confirmDeleteSelected(),
            });
          }
          if (this.items.length === 0) {
            EmptyState({ message: '暂无扫描记录，先在上方运行一次扫描' });
          } else {
            List({ space: 8 }) {
              ForEach(this.items, (item: AdminScanItem) => {
                ListItem() {
                  this.itemRow(item);
                }
                .padding({ left: 16, right: 16 })
              }, (item: AdminScanItem) => this.itemKey(item));
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
    Column({ space: 10 }) {
      // 标题行：设置关注警示 + 导入设置入口
      Row({ space: 8 }) {
        Text('导入概览')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        if (this.needsSettingsAttention()) {
          Text('需关注')
            .fontSize(11)
            .fontColor($r('app.color.warning'))
            .backgroundColor($r('app.color.warning_light'))
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        }
      }
      .width('100%');

      // 分栏统计：总数 / 已完成 / 待处理 / 失败
      Row({ space: 8 }) {
        ScanStatCell({ label: '总记录', value: this.summary.total ?? this.total,
          valueColor: $r('app.color.text_primary') }).layoutWeight(1);
        ScanStatCell({ label: '已完成', value: this.summary.done ?? 0,
          valueColor: $r('app.color.success') }).layoutWeight(1);
        ScanStatCell({ label: '待处理', value: this.summary.todo ?? 0,
          valueColor: $r('app.color.brand_primary') }).layoutWeight(1);
        ScanStatCell({ label: '失败', value: this.summary.failed ?? 0,
          valueColor: $r('app.color.error') }).layoutWeight(1);
      }
      .width('100%');

      // 关键设置一览（目录 / 模式 / 监控 / 最近扫描）
      Row({ space: 6 }) {
        ScanInfoChip({
          text: `目录：${this.scanDir.length > 0 ? this.scanDir : (this.settingsPath.length > 0 ? this.settingsPath : '未配置')}`,
        }).layoutWeight(1);
        ScanInfoChip({ text: `模式：${this.importModeLabel()}` });
      }
      .width('100%');

      Row({ space: 6 }) {
        ScanInfoChip({ text: `自动监控：${this.watchStatusText()}`, textColor: this.watchStatusColor() })
          .layoutWeight(1);
        ScanInfoChip({ text: `最近扫描：${this.lastScanText()}` });
      }
      .width('100%');

      // 目录预检警示（上游 directoryAlert：status=error/warning 且带 msg）
      if (this.directoryAlertIsError()) {
        ScanNotice({
          text: this.directoryAlertMessage(),
          textColor: $r('app.color.error'),
          bg: $r('app.color.error_light'),
        });
        ScanNotice({
          text: '导入目录预检未通过，扫描/导入已禁用；请先到「导入设置」修正目录。',
          textColor: $r('app.color.text_tertiary'),
        });
      } else if (this.directoryAlertMessage().length > 0) {
        ScanNotice({
          text: this.directoryAlertMessage(),
          textColor: $r('app.color.warning'),
          bg: $r('app.color.warning_light'),
        });
      }

      ScanNotice({ text: '导入为异步任务：启动后可在本页查看进度，逐条状态会随轮询刷新。',
        textColor: $r('app.color.text_tertiary') });

      if (this.statusLine.length > 0) {
        ScanNotice({ text: this.statusLine, textColor: $r('app.color.brand_primary') });
      }

      // 主操作
      Row({ space: 12 }) {
        PrimaryButton({
          label: this.working ? '处理中…' : '运行扫描',
          buttonEnabled: !this.working && !this.importActionsDisabled(),
          fullWidth: false,
          onTap: () => this.runScan(),
        }).layoutWeight(1);
        PrimaryButton({
          label: '导入待导入',
          buttonEnabled: !this.working && !this.importActionsDisabled(),
          fullWidth: false,
          onTap: () => this.confirmImportAll(),
        }).layoutWeight(1);
      }
      .width('100%');

      // 次操作（换行排列：窄屏自动折行，避免按钮被裁切或隐藏）
      // 用 ChipButton 而非 SecondaryButton：后者 label 是普通成员，动态文案（正/倒序、多选）不会重绘。
      Flex({
        wrap: FlexWrap.Wrap,
        justifyContent: FlexAlign.Start,
        space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) },
      }) {
        ChipButton({
          label: this.desc ? '时间倒序' : '时间正序',
          onTap: () => {
            this.desc = !this.desc;
            void this.loadScans(true);
          },
        });
        ChipButton({
          label: this.selecting ? '退出多选' : '多选',
          selected: this.selecting,
          onTap: () => this.toggleSelecting(),
        });
        if (ServerRegistry.supports(ServerFeature.ADMIN_OPDS)) {
          ChipButton({
            label: 'OPDS 导入',
            onTap: () => router.pushUrl({ url: 'pages/AdminOpdsPage' }),
          });
        }
        ChipButton({
          label: '导入设置',
          onTap: () => {
            this.view = 1;
            void this.loadSettings();
          },
        });
        ChipButton({
          label: '清空记录',
          onTap: () => this.confirmDeleteAll(),
        });
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
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        if (this.selecting) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.isSelected(item.hash ?? '') })
            .onChange((isOn: boolean) => this.setSelected(item.hash ?? '', isOn));
        }
        Text(this.itemTitle(item))
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(this.statusLabel(item.status ?? ''))
          .fontSize(11)
          .fontColor(this.statusTextColor(item.status ?? ''))
          .backgroundColor(this.statusChipBg(item.status ?? ''))
          .borderRadius(8)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
      }
      .width('100%');

      Text(this.itemSubtitle(item))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');

      // 删除源文件失败时展示上游 tooltip 中的原因
      if ((item.status ?? '') === 'delete_failed' && this.deleteErrorMessage(item).length > 0) {
        Text(`原因：${this.deleteErrorMessage(item)}`)
          .fontSize(11)
          .fontColor($r('app.color.error'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }

      if (!this.selecting) {
        Row({ space: 8 }) {
          TextButton({
            label: '导入',
            onTap: () => this.importOne(item),
          });
          TextButton({
            label: '详情',
            onTap: () => this.showItemActions(item),
          });
          TextButton({
            label: '删除',
            tone: 'danger',
            onTap: () => this.confirmDelete(item),
          });
        }
        .width('100%');
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .onClick(() => {
      if (this.selecting) {
        this.toggleSelected(item.hash ?? '');
      }
    });
  }

  @Builder
  settingsSection() {
    SectionTitle({ title: '导入设置' });
    Column({ space: 8 }) {
      ScanNotice({
        text: `当前目录：${this.settingsPath.length > 0 ? this.settingsPath : '（未配置）'}`,
      });
      if (this.dirCheck !== undefined) {
        ScanNotice({ text: this.directorySummary(this.dirCheck), textColor: $r('app.color.text_tertiary') });
      }
      ScanNotice({ text: `监控：${this.watchStatusText()}`, textColor: this.watchStatusColor() });
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
        subtitle: '运行时选项（不随设置保存）；仅复制/索引模式生效',
        showToggle: true,
        toggleOn: this.deleteAfter,
        onToggle: (value: boolean) => {
          this.deleteAfter = value;
        },
      });
      ScanNotice({ text: `导入模式：${this.importModeLabel()}`, textColor: $r('app.color.text_secondary') });
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
      ScanNotice({ text: `当前目录：${this.browsePath}` });
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
