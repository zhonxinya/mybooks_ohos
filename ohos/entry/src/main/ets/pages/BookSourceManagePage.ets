import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  PageScaffold, LoadingState, EmptyState, SearchBar, FilterChips, FilterChipItem,
  SettingCell, PrimaryButton, SecondaryButton, DangerButton, TextButton,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import {
  BookSourceApi, BookSourceItem, BookSourceImportStats, BookSourceTestSummary,
  BOOK_SOURCE_ENABLED_ALL, BOOK_SOURCE_ENABLED_ONLY, BOOK_SOURCE_ENABLED_DISABLED,
} from '../services/BookSourceApi';
import { PaginationHelper } from '../utils/PaginationHelper';

/** 书源列表每页数量（上游上限 200，默认 50）。 */
const PAGE_SIZE: number = 50;
/** 体检任务轮询间隔。 */
const CHECK_POLL_INTERVAL_MS: number = 2000;
/** 体检任务轮询次数上限（约 6 分钟）。 */
const CHECK_POLL_MAX: number = 180;
/** 导入文件的最大读取字节数（2MB，足够容纳数千条书源）。 */
const IMPORT_FILE_MAX_BYTES: number = 2 * 1024 * 1024;
/** 导出预览的最大展示字符数（复制时仍复制完整内容）。 */
const EXPORT_PREVIEW_MAX: number = 20000;

/** 编辑器模式：新增。 */
const EDITOR_CREATE: string = 'create';
/** 编辑器模式：编辑。 */
const EDITOR_EDIT: string = 'edit';

// ---- 底部面板模式（同一节点只能生效一个 bindSheet，故用单面板 + 模式分发） ----
const SHEET_IMPORT: string = 'import';
const SHEET_EXPORT: string = 'export';
const SHEET_EDITOR: string = 'editor';
const SHEET_TEST: string = 'test';

/** 体检状态码 → 中文标签。 */
function checkStatusLabel(status: string): string {
  if (status === 'ok') {
    return '通过';
  }
  if (status === 'pending') {
    return '待检测';
  }
  if (status === 'failed' || status === 'check_failed') {
    return '检测失败';
  }
  if (status === 'js_unsupported') {
    return '规则依赖 JS';
  }
  if (status === 'incomplete') {
    return '规则不完整';
  }
  if (status === 'dns_failed') {
    return 'DNS 失败';
  }
  if (status === 'ssl_failed') {
    return 'SSL 校验失败';
  }
  if (status === 'connect_failed') {
    return '连接失败';
  }
  if (status === 'invalid') {
    return '格式无效';
  }
  return status.length > 0 ? status : '未知';
}

/**
 * 书源管理（管理员，talebook 专有）：书源列表 / 启停 / 测试 / 新增 / 编辑 / 删除 /
 * 导入（粘贴 JSON、选择本地文件、远端 URL）/ 导出 / 种子填充 / 批量体检。
 *
 * 端点与响应结构见 `services/BookSourceApi.ets`（逐项对照上游
 * `docs/talebook/webserver/handlers/booksource_admin.py`）。
 * 体检为「POST 触发 + 轮询 check/status」异步模式；导入后上游会为新增书源自动排队体检。
 * ⚠️ 上游编辑端点为 `PUT /api/admin/booksource`，客户端 native 通道无 PUT（走 PATCH），
 * 未适配的服务端会返回 HTTP 405，详见 `BookSourceApi.updateSource` 注释。
 */
@Entry
@Component
struct BookSourceManagePage {
  @State sources: BookSourceItem[] = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State loadingMore: boolean = false;
  @State hasMore: boolean = false;
  @State totalCount: number = 0;
  @State keyword: string = '';
  @State enabledFilter: number = 0;
  @State selecting: boolean = false;
  @State selectedIds: number[] = [];
  @State working: boolean = false;
  @State checking: boolean = false;
  @State checkText: string = '';
  @State showSheet: boolean = false;
  @State sheetMode: string = '';
  @State importText: string = '';
  @State importUrl: string = '';
  @State importing: boolean = false;
  @State importResult: string = '';
  @State exporting: boolean = false;
  @State exportError: string = '';
  @State exportPreview: string = '';
  @State exportCount: number = 0;
  @State editorMode: string = EDITOR_CREATE;
  @State editorBusy: boolean = false;
  @State createText: string = '';
  @State editId: number = 0;
  @State editName: string = '';
  @State editGroup: string = '';
  @State editWeight: string = '0';
  @State editEnabled: boolean = true;
  @State testId: number = 0;
  @State testName: string = '';
  @State testKey: string = '剑来';
  @State testing: boolean = false;
  @State testError: string = '';
  @State testResult: BookSourceTestSummary | null = null;
  private featureSupported: boolean = ServerRegistry.supports(ServerFeature.BOOK_SOURCES);
  private filterItems: FilterChipItem[] = [
    { label: '全部', value: 0 },
    { label: '已启用', value: 1 },
    { label: '已停用', value: 2 },
  ];
  private page: number = 1;
  private lastLoadTime: number = 0;
  private checkTimer: number = -1;
  private checkPolls: number = 0;
  private fullExportJson: string = '';

  aboutToAppear(): void {
    if (!this.featureSupported) {
      this.loading = false;
      return;
    }
    void this.load(true);
  }

  aboutToDisappear(): void {
    this.stopCheckPoll();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private enabledParam(): string {
    if (this.enabledFilter === 1) {
      return BOOK_SOURCE_ENABLED_ONLY;
    }
    if (this.enabledFilter === 2) {
      return BOOK_SOURCE_ENABLED_DISABLED;
    }
    return BOOK_SOURCE_ENABLED_ALL;
  }

  private sourceSubtitle(source: BookSourceItem): string {
    const parts: string[] = [];
    if (source.url.length > 0) {
      parts.push(source.url);
    }
    if (source.group.length > 0) {
      parts.push(`分组：${source.group}`);
    }
    if (source.weight !== 0) {
      parts.push(`权重 ${source.weight}`);
    }
    const check = `体检：${checkStatusLabel(source.checkStatus)}`;
    parts.push(source.checkMessage.length > 0 ? `${check}（${source.checkMessage}）` : check);
    // 检测标签（上游 check_tags）：最多展示 4 个，与服务端表格列一致
    if (source.checkTags.length > 0) {
      parts.push(`标签：${source.checkTags.slice(0, 4).join('、')}`);
    }
    return parts.join(' · ');
  }

  private async load(reset: boolean): Promise<void> {
    if (reset) {
      this.page = 1;
      this.hasMore = true;
      this.sources = [];
      this.loading = true;
    } else {
      this.loadingMore = true;
    }
    const targetPage = this.page;
    if (!TalebookService.ensureTalebookConfigured()) {
      this.loading = false;
      this.loadingMore = false;
      this.loadError = '尚未配置服务器地址';
      return;
    }
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await BookSourceApi.listSources(this.enabledParam(), '', this.keyword, targetPage, PAGE_SIZE);
      if (!BookSourceApi.isOk(rsp)) {
        const message = BookSourceApi.errorMessage(rsp);
        if (reset) {
          this.loadError = message;
        } else {
          this.currentPageRollback();
          this.toast(message);
        }
        return;
      }
      const fetched = BookSourceApi.parseBookSources(rsp.items);
      this.sources = reset ? fetched : this.sources.concat(fetched);
      this.totalCount = rsp.count !== undefined ? rsp.count : this.sources.length;
      this.hasMore = PaginationHelper.computeHasMore(fetched.length, PAGE_SIZE);
    } catch (e) {
      if (reset) {
        this.loadError = `加载书源失败：${e}`;
      } else {
        this.currentPageRollback();
        this.toast(`加载更多失败：${e}`);
      }
    } finally {
      this.loading = false;
      this.loadingMore = false;
      this.lastLoadTime = Date.now();
    }
  }

  private currentPageRollback(): void {
    this.page = Math.max(1, this.page - 1);
  }

  private loadMore(): void {
    if (!PaginationHelper.canLoadMore(this.lastLoadTime, this.loadingMore, this.hasMore)) {
      return;
    }
    this.page += 1;
    void this.load(false);
  }

  private async toggleSource(source: BookSourceItem, enabled: boolean): Promise<void> {
    try {
      const rsp = await BookSourceApi.toggleSources([source.id], enabled);
      if (!BookSourceApi.isOk(rsp)) {
        this.toast(BookSourceApi.errorMessage(rsp));
        void this.load(true);
        return;
      }
      const next: BookSourceItem[] = [];
      for (const item of this.sources) {
        if (item.id === source.id) {
          const updated: BookSourceItem = {
            id: item.id,
            name: item.name,
            url: item.url,
            group: item.group,
            sourceType: item.sourceType,
            enabled: enabled,
            weight: item.weight,
            comment: item.comment,
            lastCheckOk: item.lastCheckOk,
            checkStatus: item.checkStatus,
            checkMessage: item.checkMessage,
            checkTags: item.checkTags,
            createTime: item.createTime,
            updateTime: item.updateTime,
          };
          next.push(updated);
        } else {
          next.push(item);
        }
      }
      this.sources = next;
      this.toast(enabled ? '已启用' : '已停用');
    } catch (e) {
      this.toast(`切换失败：${e}`);
      void this.load(true);
    }
  }

  private openActions(source: BookSourceItem): void {
    this.getUIContext().getPromptAction().showDialog({
      title: source.name,
      message: source.url,
      buttons: [
        { text: '测试', color: '#007DFF' },
        { text: '编辑', color: '#007DFF' },
        { text: '删除', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 0) {
        this.openTest(source);
      } else if (result.index === 1) {
        this.openEdit(source);
      } else if (result.index === 2) {
        this.confirmDelete(source.id, source.name);
      }
    }).catch(() => {
    });
  }

  private confirmDelete(id: number, name: string): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除书源',
      message: `确定删除「${name}」？该操作不可恢复。`,
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '删除', color: '#E84026' },
      ],
    }).then((result) => {
      if (result.index === 1) {
        void this.removeSource(id);
      }
    }).catch(() => {
    });
  }

  private async removeSource(id: number): Promise<void> {
    try {
      const rsp = await BookSourceApi.deleteSources([id]);
      if (!BookSourceApi.isOk(rsp)) {
        this.toast(BookSourceApi.errorMessage(rsp));
        return;
      }
      this.toast(`已删除 ${rsp.deleted !== undefined ? rsp.deleted : 1} 个书源`);
      void this.load(true);
    } catch (e) {
      this.toast(`删除失败：${e}`);
    }
  }

  private stopCheckPoll(): void {
    if (this.checkTimer >= 0) {
      clearTimeout(this.checkTimer);
      this.checkTimer = -1;
    }
  }

  private scheduleCheckPoll(delay: number): void {
    this.stopCheckPoll();
    this.checkTimer = setTimeout(() => {
      void this.pollCheckStatus();
    }, delay);
  }

  private async runCheck(cleanInvalid: boolean): Promise<void> {
    if (this.checking) {
      this.toast('体检正在进行中');
      return;
    }
    this.working = true;
    this.checkText = '正在提交体检任务…';
    try {
      const rsp = cleanInvalid ? await BookSourceApi.cleanInvalid() : await BookSourceApi.checkAll();
      if (!BookSourceApi.isOk(rsp)) {
        this.checkText = '';
        this.toast(BookSourceApi.errorMessage(rsp));
        return;
      }
      const total = rsp.total !== undefined ? rsp.total
        : (rsp.checking !== undefined ? rsp.checking : 0);
      this.checking = true;
      this.checkPolls = 0;
      this.checkText = `体检中 0/${total}`;
      this.scheduleCheckPoll(1000);
    } catch (e) {
      this.checkText = '';
      this.toast(`启动体检失败：${e}`);
    } finally {
      this.working = false;
    }
  }

  private async pollCheckStatus(): Promise<void> {
    try {
      const rsp = await BookSourceApi.getCheckStatus();
      if (!BookSourceApi.isOk(rsp)) {
        this.finishCheck(BookSourceApi.errorMessage(rsp));
        return;
      }
      const task = BookSourceApi.parseCheckStatus(rsp);
      if (task.running) {
        this.checkText = `体检中 ${task.done}/${task.total}`;
      } else {
        const message = task.lastError.length > 0
          ? `体检结束（存在错误）：${task.lastError}`
          : `体检完成：共检测 ${task.total} 个书源`;
        this.finishCheck(message);
        return;
      }
    } catch (e) {
      this.finishCheck(`体检状态查询失败：${e}`);
      return;
    }
    this.checkPolls += 1;
    if (this.checkPolls >= CHECK_POLL_MAX) {
      this.finishCheck('体检仍在后台进行，可稍后刷新列表查看结果');
      return;
    }
    this.scheduleCheckPoll(CHECK_POLL_INTERVAL_MS);
  }

  private finishCheck(message: string): void {
    this.stopCheckPoll();
    this.checking = false;
    this.checkText = message;
    this.toast(message);
    void this.load(true);
  }

  private importSummary(stats: BookSourceImportStats): string {
    let text = `新增 ${stats.added} · 跳过（已存在）${stats.skipped} · 失败 ${stats.failed.length}`;
    if (stats.checking > 0) {
      text = `${text} · 已提交 ${stats.checking} 个后台体检`;
    }
    if (stats.failed.length > 0) {
      text = `${text}\n首个失败项：${stats.failed[0].name}（${stats.failed[0].reason}）`;
    }
    return text;
  }

  private watchImportChecks(checking: number): void {
    if (checking <= 0 || this.checking) {
      return;
    }
    this.checking = true;
    this.checkPolls = 0;
    this.checkText = '导入后正在后台体检…';
    this.scheduleCheckPoll(2000);
  }

  private async submitImport(): Promise<void> {
    const json = this.importText.trim();
    const url = this.importUrl.trim();
    if (json.length === 0 && url.length === 0) {
      this.toast('请粘贴书源 JSON 或填写书源订阅 URL');
      return;
    }
    this.importing = true;
    this.importResult = '';
    try {
      const rsp = json.length > 0
        ? await BookSourceApi.importSources(json)
        : await BookSourceApi.importFromUrl(url);
      if (!BookSourceApi.isOk(rsp)) {
        this.toast(BookSourceApi.errorMessage(rsp));
        return;
      }
      const stats = BookSourceApi.parseImportStats(rsp);
      this.importResult = this.importSummary(stats);
      this.toast('导入完成');
      this.importText = '';
      this.importUrl = '';
      this.showSheet = false;
      void this.load(true);
      this.watchImportChecks(stats.checking);
    } catch (e) {
      this.toast(`导入失败：${e}`);
    } finally {
      this.importing = false;
    }
  }

  private confirmSeed(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '导入内置种子书源',
      message: '将导入仓库内置的种子书源（同 URL 的书源会被跳过），并为新增书源排队后台体检。',
      buttons: [
        { text: '取消', color: '#999999' },
        { text: '导入', color: '#007DFF' },
      ],
    }).then((result) => {
      if (result.index === 1) {
        void this.runSeed();
      }
    }).catch(() => {
    });
  }

  private async runSeed(): Promise<void> {
    this.working = true;
    try {
      const rsp = await BookSourceApi.fillSeeds();
      if (!BookSourceApi.isOk(rsp)) {
        this.toast(BookSourceApi.errorMessage(rsp));
        return;
      }
      const stats = BookSourceApi.parseImportStats(rsp);
      this.toast('种子书源导入完成');
      this.importResult = this.importSummary(stats);
      this.checkText = this.importResult;
      void this.load(true);
      this.watchImportChecks(stats.checking);
    } catch (e) {
      this.toast(`种子导入失败：${e}`);
    } finally {
      this.working = false;
    }
  }

  private async doExport(): Promise<void> {
    this.exporting = true;
    this.exportError = '';
    this.exportPreview = '';
    this.fullExportJson = '';
    this.exportCount = 0;
    try {
      const rsp = await BookSourceApi.exportSources();
      if (!BookSourceApi.isOk(rsp)) {
        this.exportError = BookSourceApi.errorMessage(rsp);
        return;
      }
      const list = rsp.sources;
      if (Array.isArray(list)) {
        this.exportCount = (list as Array<Object>).length;
      }
      this.fullExportJson = JSON.stringify(list ?? []);
      const truncated = this.fullExportJson.length > EXPORT_PREVIEW_MAX;
      this.exportPreview = truncated
        ? `${this.fullExportJson.substring(0, EXPORT_PREVIEW_MAX)}\n…（预览已截断，复制可获得完整内容）`
        : this.fullExportJson;
    } catch (e) {
      this.exportError = `导出失败：${e}`;
    } finally {
      this.exporting = false;
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private copyExport(): void {
    if (this.fullExportJson.length === 0) {
      this.toast('暂无可复制的导出内容');
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.fullExportJson);
    pasteboard.getSystemPasteboard().setData(data);
    this.toast('导出内容已复制到剪贴板');
  }

  private openCreate(): void {
    this.editorMode = EDITOR_CREATE;
    this.createText = '';
    this.sheetMode = SHEET_EDITOR;
    this.showSheet = true;
  }

  private openEdit(source: BookSourceItem): void {
    this.editorMode = EDITOR_EDIT;
    this.editId = source.id;
    this.editName = source.name;
    this.editGroup = source.group;
    this.editWeight = `${source.weight}`;
    this.editEnabled = source.enabled;
    this.sheetMode = SHEET_EDITOR;
    this.showSheet = true;
  }

  private async submitEditor(): Promise<void> {
    if (this.editorMode === EDITOR_CREATE) {
      await this.submitCreate();
      return;
    }
    await this.submitEdit();
  }

  private async submitCreate(): Promise<void> {
    const raw = this.createText.trim();
    if (raw.length === 0) {
      this.toast('请粘贴书源 JSON（Legado 单条书源对象）');
      return;
    }
    this.editorBusy = true;
    try {
      const rsp = await BookSourceApi.createSource(raw);
      if (!BookSourceApi.isOk(rsp)) {
        this.toast(BookSourceApi.errorMessage(rsp));
        return;
      }
      this.toast(rsp.id !== undefined ? `已新增书源（ID ${rsp.id}）` : '已新增书源');
      this.showSheet = false;
      this.createText = '';
      void this.load(true);
    } catch (e) {
      this.toast(`新增失败：${e}`);
    } finally {
      this.editorBusy = false;
    }
  }

  private async submitEdit(): Promise<void> {
    const parsed = Number(this.editWeight.trim());
    const weight = Number.isNaN(parsed) ? 0 : parsed;
    this.editorBusy = true;
    try {
      const rsp = await BookSourceApi.updateSource(this.editId, this.editGroup, weight, this.editEnabled);
      if (!BookSourceApi.isOk(rsp)) {
        this.toast(BookSourceApi.errorMessage(rsp));
        return;
      }
      this.toast('书源已更新');
      this.showSheet = false;
      void this.load(true);
    } catch (e) {
      this.toast(`更新失败：${e}`);
    } finally {
      this.editorBusy = false;
    }
  }

  // ---- 多选与批量操作（对齐上游：全选 + 批量启用/停用/删除） ----

  private toggleSelecting(): void {
    this.selecting = !this.selecting;
    if (!this.selecting) {
      this.selectedIds = [];
    }
  }

  private allSelected(): boolean {
    return this.sources.length > 0 && this.selectedIds.length === this.sources.length;
  }

  private isSourceSelected(id: number): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  private toggleSourceSelected(id: number): void {
    const next: number[] = [];
    let removed = false;
    for (const item of this.selectedIds) {
      if (item === id) {
        removed = true;
      } else {
        next.push(item);
      }
    }
    if (!removed) {
      next.push(id);
    }
    this.selectedIds = next;
  }

  private listHintText(): string {
    if (this.selecting) {
      return `共 ${this.totalCount} 个书源 · 多选模式：点击行可勾选`;
    }
    return `共 ${this.totalCount} 个书源 · 长按书源可测试 / 编辑 / 删除`;
  }

  /** 批量启用/停用（POST /api/admin/booksource/toggle，body `{ids, enabled}`）。 */
  private runBatchToggle(enabled: boolean): void {
    if (this.selectedIds.length === 0) {
      this.toast('请先选择书源');
      return;
    }
    if (this.working) {
      return;
    }
    const ids = this.selectedIds.slice();
    this.working = true;
    BookSourceApi.toggleSources(ids, enabled).then((rsp) => {
      this.working = false;
      if (!BookSourceApi.isOk(rsp)) {
        this.toast(BookSourceApi.errorMessage(rsp));
        return;
      }
      const updated = rsp.updated !== undefined ? rsp.updated : ids.length;
      this.toast(`已${enabled ? '启用' : '停用'} ${updated} 个书源`);
      this.selectedIds = [];
      void this.load(true);
    }).catch((e: Object) => {
      this.working = false;
      this.toast(`批量操作失败：${e}`);
    });
  }

  private confirmBatchDelete(): void {
    if (this.selectedIds.length === 0) {
      this.toast('请先选择书源');
      return;
    }
    const count = this.selectedIds.length;
    this.getUIContext().showAlertDialog({
      title: '批量删除书源',
      message: `将删除选中的 ${count} 个书源，且无法恢复；已保存的书籍不受影响。确定继续？`,
      primaryButton: {
        value: '删除',
        action: () => {
          this.runBatchDelete();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  /** 批量删除（DELETE /api/admin/booksource，ids 走查询参数）。 */
  private runBatchDelete(): void {
    if (this.working) {
      return;
    }
    const ids = this.selectedIds.slice();
    this.working = true;
    BookSourceApi.deleteSources(ids).then((rsp) => {
      this.working = false;
      if (!BookSourceApi.isOk(rsp)) {
        this.toast(BookSourceApi.errorMessage(rsp));
        return;
      }
      const deleted = rsp.deleted !== undefined ? rsp.deleted : ids.length;
      this.toast(`已删除 ${deleted} 个书源`);
      this.selectedIds = [];
      void this.load(true);
    }).catch((e: Object) => {
      this.working = false;
      this.toast(`批量删除失败：${e}`);
    });
  }

  /** 多选模式下的行：左侧勾选框 + 名称/副标题，整行可点。 */
  @Builder
  selectableRow(source: BookSourceItem) {
    Row({ space: 12 }) {
      Toggle({ type: ToggleType.Checkbox, isOn: this.isSourceSelected(source.id) })
        .onChange(() => {
          this.toggleSourceSelected(source.id);
        });
      Column({ space: 2 }) {
        Text(source.name.length > 0 ? source.name : source.url)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Text(this.sourceSubtitle(source))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .padding($r('app.float.page_padding'))
    .onClick(() => this.toggleSourceSelected(source.id));
  }

  private openTest(source: BookSourceItem): void {    this.testId = source.id;
    this.testName = source.name;
    this.testResult = null;
    this.testError = '';
    this.sheetMode = SHEET_TEST;
    this.showSheet = true;
  }

  private async runTest(): Promise<void> {
    this.testing = true;
    this.testError = '';
    this.testResult = null;
    try {
      const rsp = await BookSourceApi.testSource(this.testId, this.testKey);
      if (!BookSourceApi.isOk(rsp)) {
        this.testError = BookSourceApi.errorMessage(rsp);
        return;
      }
      const summary = BookSourceApi.parseTestSummary(rsp);
      this.testResult = summary;
      if (!summary.ok) {
        this.testError = summary.jsSkipped ? '该书源关键规则依赖 JS，服务端暂不支持' : '未返回搜索结果';
      }
      void this.load(true);
    } catch (e) {
      this.testError = `测试失败：${e}`;
    } finally {
      this.testing = false;
    }
  }

  private async pickImportFile(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.json', '.txt'];
    try {
      const viewPicker = new picker.DocumentViewPicker(context);
      const uris = await viewPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const text = this.readTextFile(uris[0]);
      if (text.length === 0) {
        this.toast('文件为空或无法读取');
        return;
      }
      this.importText = text;
      this.toast(`已载入文件（${text.length} 字符）`);
    } catch (e) {
      this.toast(`选择文件失败：${e}`);
    }
  }

  private readTextFile(uri: string): string {
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(file.fd);
        const size = Math.min(stat.size, IMPORT_FILE_MAX_BYTES);
        if (size <= 0) {
          return '';
        }
        const buffer = new ArrayBuffer(size);
        const readLength = fs.readSync(file.fd, buffer, { offset: 0, length: size });
        const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        return decoder.decodeToString(new Uint8Array(buffer, 0, readLength));
      } finally {
        fs.closeSync(file.fd);
      }
    } catch (e) {
      this.toast(`读取文件失败：${e}`);
      return '';
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '书源管理',
        showBack: true,
        action: () => {
          this.headerAction();
        },
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      title: { title: this.sheetTitle() },
      onDisappear: () => {
        this.sheetMode = '';
      },
    });
  }

  private sheetTitle(): string {
    if (this.sheetMode === SHEET_IMPORT) {
      return '导入书源';
    }
    if (this.sheetMode === SHEET_EXPORT) {
      return '导出书源';
    }
    if (this.sheetMode === SHEET_TEST) {
      return `测试 · ${this.testName}`;
    }
    return this.editorMode === EDITOR_CREATE ? '新增书源' : '编辑书源';
  }

  @Builder
  sheetContent() {
    if (this.sheetMode === SHEET_IMPORT) {
      this.importSheet();
    } else if (this.sheetMode === SHEET_EXPORT) {
      this.exportSheet();
    } else if (this.sheetMode === SHEET_TEST) {
      this.testSheet();
    } else {
      this.editorSheet();
    }
  }

  @Builder
  headerAction() {
    Text('刷新')
      .fontSize(14)
      .fontColor($r('app.color.brand_primary'))
      .padding({ left: 8, right: 16 })
      .onClick(() => {
        if (!this.loading) {
          void this.load(true);
        }
      });
  }

  @Builder
  pageContent() {
    if (!this.featureSupported) {
      EmptyState({
        message: `${ServerRegistry.profile().displayName} 服务端不支持书源管理`,
        detail: '书源管理依赖 Legado 书源插件。',
      });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({
        message: this.loadError,
        detail: '请确认使用管理员账号登录。',
        actionLabel: '重试',
        onAction: () => {
          void this.load(true);
        },
      });
    } else {
      Column({ space: 8 }) {
        SearchBar({
          placeholder: '搜索书源名称',
          keyword: $keyword,
          onSearch: () => {
            void this.load(true);
          },
        });
        FilterChips({
          items: this.filterItems,
          selected: $enabledFilter,
          onChange: () => {
            void this.load(true);
          },
        });
        Scroll() {
          Row({ space: 8 }) {
            SecondaryButton({
              label: '新增',
              compact: true,
              fullWidth: false,
              onTap: () => this.openCreate(),
            });
            SecondaryButton({
              label: '导入',
              compact: true,
              fullWidth: false,
              onTap: () => {
                this.importResult = '';
                this.sheetMode = SHEET_IMPORT;
                this.showSheet = true;
              },
            });
            SecondaryButton({
              label: '导出',
              compact: true,
              fullWidth: false,
              onTap: () => {
                this.sheetMode = SHEET_EXPORT;
                this.showSheet = true;
                void this.doExport();
              },
            });
          }
          .padding({ left: 16, right: 16 });
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%');
        Scroll() {
          Row({ space: 8 }) {
            SecondaryButton({
              label: '体检',
              compact: true,
              fullWidth: false,
              buttonEnabled: !this.checking && !this.working,
              onTap: () => {
                void this.runCheck(false);
              },
            });
            SecondaryButton({
              label: '清理无效',
              compact: true,
              fullWidth: false,
              buttonEnabled: !this.checking && !this.working,
              onTap: () => {
                void this.runCheck(true);
              },
            });
            SecondaryButton({
              label: '种子书源',
              compact: true,
              fullWidth: false,
              buttonEnabled: !this.working && !this.checking,
              onTap: () => this.confirmSeed(),
            });
            SecondaryButton({
              // 共享 SecondaryButton 的 label 是普通成员（不会重绘），故用静态文案；
              // 多选态与退出入口由下方 batchBar 的 Text 表达。
              label: '多选',
              compact: true,
              fullWidth: false,
              onTap: () => this.toggleSelecting(),
            });
            if (ServerRegistry.supports(ServerFeature.ADMIN_PLUGINS)) {
              SecondaryButton({
                label: '插件配置',
                compact: true,
                fullWidth: false,
                onTap: () => {
                  // 上游书源工作台内嵌的「全局配置」实为 legado 插件连接配置，跳插件中心维护
                  this.getUIContext().getRouter().pushUrl({ url: 'pages/AdminPluginsPage' });
                },
              });
            }
          }
          .padding({ left: 16, right: 16 });
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%');
        if (this.selecting) {
          this.batchBar();
        }        Text(this.listHintText())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16 });
        if (this.checkText.length > 0) {
          Text(this.checkText)
            .fontSize(12)
            .fontColor(this.checking ? $r('app.color.brand_primary') : $r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 16, right: 16 });
        }
        if (this.sources.length === 0) {
          EmptyState({
            message: '暂无书源',
            detail: '可通过「导入」粘贴 JSON、选择本地文件或拉取订阅 URL，也可导入内置种子书源。',
          });
        } else {
          List({ space: 8 }) {
            ForEach(this.sources, (source: BookSourceItem) => {
              ListItem() {
                this.sourceRow(source);
              }
              .padding({ left: 16, right: 16 })
            }, (source: BookSourceItem) => `source-${source.id}-${source.updateTime}`);
            if (this.loadingMore) {
              ListItem() {
                LoadingState({ hint: '加载更多…' });
              }
            }
          }
          .layoutWeight(1)
          .width('100%')
          .cachedCount(10)
          .onReachEnd(() => this.loadMore());
        }
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  batchBar() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(`已选 ${this.selectedIds.length} / 本页 ${this.sources.length}`)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        TextButton({
          label: this.allSelected() ? '取消全选' : '全选',
          onTap: () => {
            if (this.allSelected()) {
              this.selectedIds = [];
            } else {
              this.selectedIds = this.sources.map((item: BookSourceItem) => item.id);
            }
          },
        });
        Text('退出多选')
          .fontSize(13)
          .fontColor($r('app.color.brand_primary'))
          .padding({ left: 8, right: 8 })
          .onClick(() => this.toggleSelecting());
      }
      .width('100%');
      Row({ space: 8 }) {
        TextButton({
          label: '启用',
          onTap: () => this.runBatchToggle(true),
        });
        TextButton({
          label: '停用',
          onTap: () => this.runBatchToggle(false),
        });
        TextButton({
          label: '删除',
          tone: 'danger',
          onTap: () => this.confirmBatchDelete(),
        });
        Blank().layoutWeight(1);
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .margin({ left: 16, right: 16 })
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  sourceRow(source: BookSourceItem) {
    Column() {
      if (this.selecting) {
        this.selectableRow(source);
      } else {
        SettingCell({
          title: source.name.length > 0 ? source.name : source.url,
          subtitle: this.sourceSubtitle(source),
          showToggle: true,
          toggleOn: source.enabled,
          onToggle: (value: boolean) => {
            void this.toggleSource(source, value);
          },
        });
      }
    }
    .width('100%')
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => this.openActions(source)),
    );
  }

  @Builder
  importSheet() {
    Column({ space: 10 }) {
      Text('方式一：粘贴 Legado 书源 JSON（数组或单条对象均可）')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      TextArea({ text: this.importText, placeholder: '[{"bookSourceName": "…", "bookSourceUrl": "…"}]' })
        .width('100%')
        .height(160)
        .fontSize(12)
        .onChange((value: string) => {
          this.importText = value;
        });
      Row({ space: 8 }) {
        SecondaryButton({
          label: '选择本地文件',
          compact: true,
          fullWidth: false,
          onTap: () => {
            void this.pickImportFile();
          },
        });
        TextButton({
          label: '清空',
          onTap: () => {
            this.importText = '';
          },
        });
      }
      .width('100%');
      Text('方式二：远端订阅地址（粘贴 JSON 时优先使用方式一）')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      TextInput({ text: this.importUrl, placeholder: 'https://…/booksources.json' })
        .width('100%')
        .height(44)
        .fontSize(13)
        .onChange((value: string) => {
          this.importUrl = value;
        });
      if (this.importResult.length > 0) {
        Text(this.importResult)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
      }
      Text('同 URL 的书源会被跳过（上游导入不覆盖已存在的书源）。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      PrimaryButton({
        label: this.importing ? '导入中…' : '开始导入',
        buttonEnabled: !this.importing,
        onTap: () => {
          void this.submitImport();
        },
      });
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 });
  }

  @Builder
  exportSheet() {
    Column({ space: 10 }) {
      if (this.exporting) {
        LoadingState({ hint: '正在导出…' });
      } else if (this.exportError.length > 0) {
        EmptyState({
          message: this.exportError,
          actionLabel: '重试',
          onAction: () => {
            void this.doExport();
          },
        });
      } else {
        Text(`共导出 ${this.exportCount} 个书源，内容为可直接再导入的 Legado JSON 数组。`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        Scroll() {
          Text(this.exportPreview.length > 0 ? this.exportPreview : '（空）')
            .fontSize(11)
            .fontColor($r('app.color.text_primary'))
            .copyOption(CopyOptions.LocalDevice)
            .width('100%');
        }
        .layoutWeight(1)
        .width('100%')
        .padding(8)
        .borderRadius(8)
        .backgroundColor($r('app.color.page_background'));
        Row({ space: 8 }) {
          PrimaryButton({
            label: '复制全部',
            fullWidth: false,
            onTap: () => this.copyExport(),
          });
          SecondaryButton({
            label: '重新导出',
            compact: true,
            fullWidth: false,
            onTap: () => {
              void this.doExport();
            },
          });
        }
        .width('100%');
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 });
  }

  @Builder
  editorSheet() {
    Column({ space: 10 }) {
      if (this.editorMode === EDITOR_CREATE) {
        Text('粘贴单条 Legado 书源 JSON 对象（需含 bookSourceName 与 bookSourceUrl）。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        TextArea({ text: this.createText, placeholder: '{"bookSourceName": "…", "bookSourceUrl": "…"}' })
          .width('100%')
          .height(200)
          .fontSize(12)
          .onChange((value: string) => {
            this.createText = value;
          });
      } else {
        Text(`编辑：${this.editName}`)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Text('分组')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        TextInput({ text: this.editGroup, placeholder: '书源分组（可留空）' })
          .width('100%')
          .height(44)
          .fontSize(13)
          .onChange((value: string) => {
            this.editGroup = value;
          });
        Text('权重')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        TextInput({ text: this.editWeight, placeholder: '0' })
          .width('100%')
          .height(44)
          .fontSize(13)
          .type(InputType.Number)
          .onChange((value: string) => {
            this.editWeight = value;
          });
        Row({ space: 8 }) {
          Text('启用该书源')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: $$this.editEnabled })
            .selectedColor($r('app.color.brand_primary'));
        }
        .width('100%');
        Text('⚠️ 上游编辑端点仅实现 PUT，客户端通道（PATCH）在不支持的服务端会提示 HTTP 405。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      Row({ space: 8 }) {
        PrimaryButton({
          label: this.editorBusy
            ? '提交中…'
            : (this.editorMode === EDITOR_CREATE ? '新增' : '保存'),
          buttonEnabled: !this.editorBusy,
          fullWidth: false,
          onTap: () => {
            void this.submitEditor();
          },
        });
        if (this.editorMode === EDITOR_EDIT) {
          DangerButton({
            label: '删除该书源',
            fullWidth: false,
            onTap: () => {
              this.showSheet = false;
              this.confirmDelete(this.editId, this.editName);
            },
          });
        }
      }
      .width('100%');
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 });
  }

  @Builder
  testSheet() {
    Column({ space: 10 }) {
      Text('用关键词在该书源内搜索，命中后会继续抓取详情、目录与首章样例（服务端最多串行数十秒）。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Row({ space: 8 }) {
        TextInput({ text: this.testKey, placeholder: '关键词' })
          .layoutWeight(1)
          .height(44)
          .fontSize(13)
          .onChange((value: string) => {
            this.testKey = value;
          });
        SecondaryButton({
          label: '测试',
          compact: true,
          fullWidth: false,
          buttonEnabled: !this.testing,
          onTap: () => {
            void this.runTest();
          },
        });
      }
      .width('100%');
      if (this.testing) {
        LoadingState({ hint: '正在测试书源…' });
      } else if (this.testResult !== null) {
        Text(`耗时 ${this.testResult.elapsedMs} ms · 命中 ${this.testResult.books.length} 本 · 目录 ${this.testResult.tocCount} 章`)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        if (this.testResult.books.length > 0) {
          Text(`首本：${this.testResult.books[0].title}（${this.testResult.books[0].author}）`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
        }
        if (this.testResult.jsSkipped) {
          Text('该书源关键规则依赖 JS，服务端暂不支持。')
            .fontSize(12)
            .fontColor($r('app.color.error'))
            .width('100%');
        }
        if (this.testResult.sampleContent.length > 0) {
          Text('正文样例：')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
          Scroll() {
            Text(this.testResult.sampleContent)
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .copyOption(CopyOptions.LocalDevice)
              .width('100%');
          }
          .layoutWeight(1)
          .width('100%')
          .padding(8)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'));
        }
      } else if (this.testError.length > 0) {
        EmptyState({
          message: this.testError,
          actionLabel: '重试',
          onAction: () => {
            void this.runTest();
          },
        });
      } else {
        Text('点击「测试」开始连通性验证。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      if (this.testError.length > 0 && this.testResult !== null) {
        Text(this.testError)
          .fontSize(12)
          .fontColor($r('app.color.error'))
          .width('100%');
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 });
  }
}
