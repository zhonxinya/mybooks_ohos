import { PageScaffold, LoadingState, EmptyState, FilterChips, FilterChipItem,
  PrimaryButton, SecondaryButton } from '../components';
import { TalebookApi, ApiMessageResult, ImportStatusResponse } from '../services/TalebookApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { PaginationHelper } from '../utils/PaginationHelper';

const IMPORT_PAGE_SIZE: number = 20;

@Entry
@Component
struct AdminImportsPage {
  @State items: Record<string, Object>[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State currentPage: number = 1;
  @State hasMore: boolean = true;
  @State totalCount: number = 0;
  @State importing: boolean = false;
  @State countDone: number = 0;
  @State countTodo: number = 0;
  @State scanDir: string = '';
  @State selectedFilter: number = 0;
  @State working: boolean = false;
  @State importStatusText: string = '';
  @State statusDetail: string = '';
  /** 导入工作流为 mybooks 专有（filelist + force），talebook 走扫描记录按 hash 导入，不支持该页。 */
  @State supported: boolean = true;
  private lastLoadTime: number = 0;
  private statusPollTimer: number = -1;

  aboutToAppear(): void {
    this.supported = ServerRegistry.supports(ServerFeature.ADMIN_IMPORT);
    if (!this.supported) {
      this.loading = false;
      return;
    }
    void this.loadImports(true);
  }

  aboutToDisappear(): void {
    this.stopStatusPoll();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private filterKey(value: number): string {
    if (value === 1) {
      return 'todo';
    }
    if (value === 2) {
      return 'done';
    }
    return 'all';
  }

  private statusLabel(status: string): string {
    if (status === 'ready') {
      return '可导入';
    }
    if (status === 'exist') {
      return '存在同名';
    }
    if (status === 'imported') {
      return '导入成功';
    }
    if (status === 'new') {
      return '待扫描';
    }
    if (status === 'drop') {
      return '文件重复';
    }
    if (status === 'invalid') {
      return '文件无效';
    }
    if (status === 'missed') {
      return '文件丢失';
    }
    if (status === 'permission') {
      return '权限不足';
    }
    return status;
  }

  private statusColor(status: string): ResourceColor {
    if (status === 'imported' || status === 'ready') {
      return $r('app.color.on_brand');
    }
    if (status === 'new') {
      return $r('app.color.text_secondary');
    }
    if (status === 'exist') {
      return $r('app.color.text_tertiary');
    }
    return $r('app.color.error');
  }


  private stopStatusPoll(): void {
    if (this.statusPollTimer >= 0) {
      clearTimeout(this.statusPollTimer);
      this.statusPollTimer = -1;
    }
  }

  private scheduleStatusPoll(): void {
    this.stopStatusPoll();
    if (!this.importing) {
      return;
    }
    this.statusPollTimer = setTimeout(() => {
      void this.refreshImportStatus(true);
    }, 3000);
  }

  private async refreshImportStatus(continuePoll: boolean = false): Promise<void> {
    if (!this.supported) {
      return;
    }
    try {
      const rsp: ImportStatusResponse = await TalebookApi.getImportStatus();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.statusDetail = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : String(rsp.err);
      } else {
        const wasImporting = this.importing;
        this.importing = Boolean(rsp.importing) || Boolean(rsp.scanning);
        const summary = rsp.summary ?? {};
        if (summary['done'] !== undefined) {
          this.countDone = Number(summary['done'] ?? 0);
        }
        if (summary['todo'] !== undefined) {
          this.countTodo = Number(summary['todo'] ?? 0);
        }
        const statusObj = rsp.status ?? {};
        const stage = String(statusObj['stage'] ?? statusObj['message'] ?? statusObj['msg'] ?? '');
        if (this.importing) {
          this.importStatusText = '导入进行中';
          this.statusDetail = stage.length > 0 ? stage : '正在扫描或导入，请稍候…';
        } else {
          this.importStatusText = '';
          this.statusDetail = stage.length > 0 ? stage : '';
          if (wasImporting) {
            void this.loadImports(true);
            return;
          }
        }
      }
    } catch (e) {
      this.statusDetail = `状态刷新失败：${e}`;
    }
    if (continuePoll) {
      this.scheduleStatusPoll();
    }
  }

  private async loadImports(reset: boolean = true): Promise<void> {
    if (!ServerRegistry.supports(ServerFeature.ADMIN_IMPORT)) {
      this.loading = false;
      return;
    }
    if (reset) {
      this.currentPage = 1;
      this.hasMore = true;
      this.items = [];
      this.loading = true;
    } else {
      this.loadingMore = true;
    }
    const page = this.currentPage;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await TalebookApi.getAdminImportList(page, IMPORT_PAGE_SIZE,
        this.filterKey(this.selectedFilter));
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
        if (!reset) {
          this.currentPage = Math.max(1, this.currentPage - 1);
        }
        return;
      }
      const fetched = rsp.items ?? [];
      this.items = reset ? fetched : this.items.concat(fetched);
      this.totalCount = rsp.total !== undefined ? rsp.total : this.items.length;
      this.hasMore = PaginationHelper.computeHasMore(fetched.length, IMPORT_PAGE_SIZE);
      this.importing = Boolean(rsp.importing);
      const summary = rsp.summary ?? {};
      this.countDone = Number(summary['done'] ?? 0);
      this.countTodo = Number(summary['todo'] ?? 0);
      this.scanDir = rsp.scan_dir !== undefined ? rsp.scan_dir : '';
    } catch (e) {
      this.toast(`加载失败：${e}`);
      if (!reset) {
        this.currentPage = Math.max(1, this.currentPage - 1);
      }
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
      if (this.importing) {
        void this.refreshImportStatus(true);
      } else {
        this.stopStatusPoll();
        this.importStatusText = '';
      }
    }
  }

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.currentPage += 1;
    void this.loadImports(false);
  }

  private onFilterChange(value: number): void {
    this.selectedFilter = value;
    void this.loadImports(true);
  }

  private handleResult(rsp: ApiMessageResult, fallback: string): void {
    if (rsp.err === undefined || rsp.err === 'ok') {
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : fallback);
    } else {
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : rsp.err);
    }
  }

  private importAll(): void {
    if (this.working) {
      return;
    }
    if (!ServerRegistry.supports(ServerFeature.ADMIN_IMPORT)) {
      return;
    }
    this.working = true;
    TalebookApi.runAdminImport('"all"', false)
      .then((rsp: ApiMessageResult) => {
        this.working = false;
        this.handleResult(rsp, '已开始扫描并导入');
        void this.loadImports(true);
      })
      .catch((e: Object) => {
        this.working = false;
        this.toast(`操作失败：${e}`);
      });
  }

  private cancelImport(): void {
    if (this.working) {
      return;
    }
    if (!ServerRegistry.supports(ServerFeature.ADMIN_IMPORT)) {
      return;
    }
    this.working = true;
    TalebookApi.cancelAdminImport()
      .then((rsp: ApiMessageResult) => {
        this.working = false;
        this.handleResult(rsp, '正在取消任务');
        void this.loadImports(true);
      })
      .catch((e: Object) => {
        this.working = false;
        this.toast(`操作失败：${e}`);
      });
  }

  private importOne(item: Record<string, Object>): void {
    if (this.working) {
      return;
    }
    if (!ServerRegistry.supports(ServerFeature.ADMIN_IMPORT)) {
      return;
    }
    const path = JSON.stringify(String(item['path'] ?? ''));
    this.working = true;
    TalebookApi.runAdminImport(`[${path}]`, true)
      .then((rsp: ApiMessageResult) => {
        this.working = false;
        this.handleResult(rsp, '已开始导入');
        void this.loadImports(true);
      })
      .catch((e: Object) => {
        this.working = false;
        this.toast(`操作失败：${e}`);
      });
  }

  private deleteRecord(item: Record<string, Object>): void {
    if (!ServerRegistry.supports(ServerFeature.ADMIN_IMPORT)) {
      return;
    }
    const hash = String(item['hash'] ?? '');
    this.getUIContext().showAlertDialog({
      title: '删除导入记录',
      message: `确定删除「${String(item['name'] ?? '')}」的导入记录吗？不会删除已入库的书籍。`,
      primaryButton: {
        value: '删除',
        action: () => {
          if (this.working) {
            return;
          }
          this.working = true;
          TalebookApi.deleteAdminImportRecords(JSON.stringify([hash]))
            .then((rsp: ApiMessageResult) => {
              this.working = false;
              this.handleResult(rsp, '记录已删除');
              void this.loadImports(true);
            })
            .catch((e: Object) => {
              this.working = false;
              this.toast(`删除失败：${e}`);
            });
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private showItemActions(item: Record<string, Object>): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: String(item['name'] ?? ''),
      buttons: [
        { text: '强制导入此文件', color: '#007DFF' },
        { text: '删除记录', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        this.importOne(item);
      } else if (result.index === 1) {
        this.deleteRecord(item);
      }
    }).catch(() => {});
  }

  build() {
    Column() {
      PageScaffold({
        title: '导入管理',
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
      EmptyState({ message: `${ServerRegistry.profile().displayName} 服务端不支持导入管理` });
    } else {
      Column() {
        this.summaryCard();
        FilterChips({
          items: [
            { label: '全部', value: 0 },
            { label: '待处理', value: 1 },
            { label: '已导入', value: 2 },
          ] as FilterChipItem[],
          selected: $selectedFilter,
          onChange: (value: number) => this.onFilterChange(value),
        });
        if (this.loading) {
          LoadingState({});
        } else if (this.items.length === 0) {
          EmptyState({ message: '暂无导入记录' });
        } else {
          List({ space: 8 }) {
            ForEach(this.items, (item: Record<string, Object>) => {
              ListItem() {
                this.itemRow(item);
              }
            }, (item: Record<string, Object>) => `import-${Number(item['id'] ?? 0)}`);
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
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  summaryCard() {
    Column({ space: 8 }) {
      Text('书籍导入')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      if (this.scanDir.length > 0) {
        Text(`扫描目录：${this.scanDir}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      Text(`已导入 ${this.countDone} · 待处理 ${this.countTodo}`
        + (this.importing ? ' · 导入进行中' : ''))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
      if (this.importStatusText.length > 0 || this.statusDetail.length > 0) {
        Text(this.importStatusText.length > 0 ? this.importStatusText : '导入状态')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_brand'));
        if (this.statusDetail.length > 0) {
          Text(this.statusDetail)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
      }
      Row({ space: 12 }) {
        PrimaryButton({
          label: this.working ? '处理中…' : '扫描并导入书籍',
          buttonEnabled: !this.working,
          fullWidth: false,
          onTap: () => this.importAll(),
        }).layoutWeight(1);
        if (this.importing) {
          SecondaryButton({
            label: '取消导入',
            buttonEnabled: !this.working,
            fullWidth: false,
            onTap: () => this.cancelImport(),
          }).layoutWeight(1);
        }
      }
      .width('100%');
      Text('将 azw3/epub/mobi/pdf/txt 文件放入扫描目录后点击导入；有声书（mp3 + cover.jpg）放入 audiobooks 子目录。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .margin({ left: 16, right: 16, top: 8 });
  }

  @Builder
  itemRow(item: Record<string, Object>) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(String(item['name'] ?? ''))
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(this.statusLabel(String(item['status'] ?? '')))
          .fontSize(11)
          .fontColor(this.statusColor(String(item['status'] ?? '')))
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 });
      }
      .width('100%');

      Text(`${String(item['title'] ?? '') || '待识别'} · ${String(item['author'] ?? '') || '未知作者'}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });

      Text(`${String(item['path'] ?? '')} · ${String(item['update_time'] ?? '')}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.showItemActions(item));
  }
}
