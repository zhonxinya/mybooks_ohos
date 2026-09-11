import { PageScaffold, LoadingState, EmptyState, FilterChips, FilterChipItem,
  PrimaryButton, SecondaryButton, SearchBar, SectionTitle, SettingCell, TextButton } from '../components';
import {
  AdminPluginsApi,
  AdminPluginDefinition, AdminPluginInstallation, AdminPluginConnection,
  AdminPluginRun, AdminPluginRunItem, AdminToolBookOption, AdminTextReplaceSample,
  AdminTextReplacePayload, AdminTextReplaceRunPayload, AdminTxtFixerRunPayload,
  AdminZhConverterRunPayload, AdminToolRunResponse, AdminTxtFixerAnalyzeResponse,
  AdminPluginPreferencesPayload, AdminPluginMetadataPrefs, AdminPluginServiceState,
  PLUGIN_ACTION_TEST, PLUGIN_ACTION_PREVIEW, PLUGIN_ACTION_RUN, PLUGIN_ACTION_RETRY,
  PLUGIN_ACTION_ROLLBACK, TOOL_OUTPUT_MODE_NEW, TOOL_OUTPUT_MODE_OVERWRITE,
} from '../services/AdminPluginsApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

/** 繁简转换方向（上游 zh_converter 支持 8 种，这里列常用 4 种）。 */
const ZH_DIRECTIONS: string[] = ['t2s', 'tw2s', 's2t', 's2tw'];
const ZH_DIRECTION_LABELS: string[] = ['简↔简(A5)', '台繁→简', '简→繁', '简→台繁'];

@Entry
@Component
struct AdminPluginsPage {
  @State private supported: boolean = true;
  @State private loading: boolean = true;
  @State private loadError: string = '';
  @State private tab: number = 0;
  @State private definitions: AdminPluginDefinition[] = [];
  @State private installations: AdminPluginInstallation[] = [];
  @State private connections: AdminPluginConnection[] = [];
  @State private runs: AdminPluginRun[] = [];
  @State private openRunId: number = 0;
  @State private openRunItems: AdminPluginRunItem[] = [];
  @State private working: string = '';
  // 插件偏好
  @State private autoFillMeta: boolean = false;
  @State private autoFillKeepCover: boolean = false;
  // OPDS 总开关（读 builtin_state 的 service_enabled）
  @State private opdsServiceKey: string = '';
  @State private opdsServiceEnabled: boolean = false;
  // 工具
  @State private toolKeyword: string = '';
  @State private toolBooks: AdminToolBookOption[] = [];
  @State private toolBookId: number = 0;
  @State private pattern: string = '';
  @State private replacement: string = '';
  @State private useRegex: boolean = false;
  @State private overwriteMode: boolean = false;
  @State private zhDirection: string = ZH_DIRECTIONS[0];
  @State private zhUseA5: boolean = false;
  @State private zhConvertTitle: boolean = true;
  @State private zhReplace: boolean = false;
  @State private toolResult: string = '';
  @State private previewSamples: AdminTextReplaceSample[] = [];
  @State private toolBusy: boolean = false;

  aboutToAppear(): void {
    this.supported = ServerRegistry.supports(ServerFeature.ADMIN_PLUGINS);
    if (this.supported) {
      void this.load();
    } else {
      this.loading = false;
    }
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

  private async load(): Promise<void> {
    this.loading = this.definitions.length === 0;
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await AdminPluginsApi.listPlugins();
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.loadError = this.messageOf(rsp.err, rsp.msg, '加载失败');
        return;
      }
      this.definitions = rsp.definitions ?? [];
      this.installations = rsp.installations ?? [];
      this.resolveOpdsToggle(rsp.builtin_state ?? {});
      await this.loadConnections();
      await this.loadRuns();
      await this.loadPreferences();
    } catch (e) {
      this.loadError = `加载失败：${e}`;
    } finally {
      this.loading = false;
    }
  }

  /** 从 builtin_state 里找出以 opds 为服务开关的插件，读取 service_enabled。 */
  private resolveOpdsToggle(state: Record<string, AdminPluginServiceState>): void {
    for (let i = 0; i < this.definitions.length; i++) {
      const def: AdminPluginDefinition = this.definitions[i];
      const ui: Record<string, Object> | undefined = def.ui;
      if (ui === undefined || ui['service_toggle'] !== 'opds') {
        continue;
      }
      const key: string = def.plugin_key !== undefined ? def.plugin_key : '';
      this.opdsServiceKey = key;
      const entry: AdminPluginServiceState | undefined = state[key];
      if (entry !== undefined && entry.service_enabled !== undefined) {
        this.opdsServiceEnabled = entry.service_enabled;
      }
      return;
    }
  }

  private async loadConnections(): Promise<void> {
    const rsp = await AdminPluginsApi.listConnections();
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      this.toast(this.messageOf(rsp.err, rsp.msg, '连接列表加载失败'));
      return;
    }
    this.connections = rsp.connections ?? [];
  }

  private async loadRuns(): Promise<void> {
    const rsp = await AdminPluginsApi.listRuns(0, false);
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      this.toast(this.messageOf(rsp.err, rsp.msg, '运行记录加载失败'));
      return;
    }
    this.runs = rsp.runs ?? [];
    this.openRunId = 0;
    this.openRunItems = [];
  }

  private async loadPreferences(): Promise<void> {
    const rsp = await AdminPluginsApi.getPreferences();
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return;
    }
    const meta: AdminPluginMetadataPrefs | undefined = rsp.metadata;
    this.autoFillMeta = meta !== undefined && meta.auto_fill_meta === true;
    this.autoFillKeepCover = meta !== undefined && meta.auto_fill_keep_cover === true;
  }

  private savePreferences(): void {
    const meta: AdminPluginMetadataPrefs = {
      auto_fill_meta: this.autoFillMeta,
      auto_fill_keep_cover: this.autoFillKeepCover,
    };
    const payload: AdminPluginPreferencesPayload = { metadata: meta };
    this.working = 'prefs';
    AdminPluginsApi.savePreferences(payload).then((rsp) => {
      this.working = '';
      this.toast(this.messageOf(rsp.err, rsp.msg, '偏好已保存'));
    }).catch((e: Object) => {
      this.working = '';
      this.toast(`保存失败：${e}`);
    });
  }

  private toggleOpdsService(): void {
    if (this.opdsServiceKey.length === 0 || this.working.length > 0) {
      return;
    }
    const next: boolean = !this.opdsServiceEnabled;
    this.working = 'opds';
    AdminPluginsApi.setOpdsServiceEnabled(next).then((rsp) => {
      this.working = '';
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.opdsServiceEnabled = next;
        this.toast(next ? 'OPDS 服务已开启' : 'OPDS 服务已关闭');
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '切换失败'));
      }
    }).catch((e: Object) => {
      this.working = '';
      this.toast(`切换失败：${e}`);
    });
  }

  // ---- 插件列表 ----

  private installationFor(pluginKey: string): AdminPluginInstallation | undefined {
    for (let i = 0; i < this.installations.length; i++) {
      if (this.installations[i].plugin_key === pluginKey) {
        return this.installations[i];
      }
    }
    return undefined;
  }

  private installationToggle(pluginKey: string): boolean {
    const inst: AdminPluginInstallation | undefined = this.installationFor(pluginKey);
    return inst !== undefined && inst.enabled === true;
  }

  private installationSubtitle(inst: AdminPluginInstallation | undefined): string {
    if (inst === undefined) {
      return '未安装';
    }
    const version: string = inst.version !== undefined ? inst.version : '-';
    const status: string = inst.status !== undefined ? inst.status : '-';
    return `v${version} · ${status} · ${inst.enabled === true ? '已启用' : '已停用'}`;
  }

  private definitionTitle(def: AdminPluginDefinition): string {
    if (def.name !== undefined && def.name.length > 0) {
      return def.name;
    }
    return def.plugin_key !== undefined ? def.plugin_key : '未知插件';
  }

  private definitionSubtitle(def: AdminPluginDefinition): string {
    const key: string = def.plugin_key !== undefined ? def.plugin_key : '';
    const capabilities: string[] = def.capabilities ?? [];
    return `${key} · ${capabilities.length} 项能力`;
  }

  private setInstallationEnabled(pluginKey: string, enabled: boolean): void {
    const inst: AdminPluginInstallation | undefined = this.installationFor(pluginKey);
    if (inst === undefined || inst.id === undefined || this.working.length > 0) {
      return;
    }
    this.working = pluginKey;
    AdminPluginsApi.setInstallationEnabled(inst.id, enabled).then((rsp) => {
      this.working = '';
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(enabled ? '已启用' : '已停用');
        void this.load();
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '操作失败'));
      }
    }).catch((e: Object) => {
      this.working = '';
      this.toast(`操作失败：${e}`);
    });
  }

  private installPlugin(pluginKey: string): void {
    if (this.working.length > 0) {
      return;
    }
    this.working = pluginKey;
    AdminPluginsApi.installPlugin(pluginKey, [], {}).then((rsp) => {
      this.working = '';
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast('安装完成');
        void this.load();
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '安装失败'));
      }
    }).catch((e: Object) => {
      this.working = '';
      this.toast(`安装失败：${e}`);
    });
  }

  // ---- 连接 ----

  private connectionTitle(conn: AdminPluginConnection): string {
    const name: string = conn.name !== undefined ? conn.name : 'default';
    const role: string = conn.role !== undefined ? conn.role : 'default';
    return `${name} (${role})`;
  }

  private connectionSubtitle(conn: AdminPluginConnection): string {
    const health: string = conn.health !== undefined ? conn.health : 'unknown';
    const message: string = conn.health_message !== undefined ? conn.health_message : '';
    const secretOk: boolean = conn.secret !== undefined && conn.secret.configured === true;
    const scopes: string[] = conn.scopes ?? [];
    return `#${conn.id ?? 0} · ${health}${message.length > 0 ? ` · ${message}` : ''}`
      + ` · 凭据${secretOk ? '已配置' : '未配置'} · ${scopes.length} 项授权`;
  }

  private runConnectionAction(conn: AdminPluginConnection, action: string): void {
    if (conn.id === undefined || this.working.length > 0) {
      return;
    }
    const connectionId: number = conn.id;
    this.working = `${connectionId}-${action}`;
    AdminPluginsApi.runConnectionAction(connectionId, action, {}).then((rsp) => {
      this.working = '';
      if (rsp.err === undefined || rsp.err === 'ok') {
        const runId: string = rsp.run !== undefined && rsp.run.id !== undefined ? String(rsp.run.id) : '-';
        this.toast(`${action} 已排队（run #${runId}）`);
        void this.loadRuns();
        void this.loadConnections();
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, `${action} 失败`));
      }
    }).catch((e: Object) => {
      this.working = '';
      this.toast(`${action} 失败：${e}`);
    });
  }

  private confirmRollback(conn: AdminPluginConnection): void {
    this.getUIContext().showAlertDialog({
      title: '回滚插件变更',
      message: `确定对连接「${this.connectionTitle(conn)}」执行回滚吗？回滚会按运行记录撤销已写入的数据。`,
      primaryButton: {
        value: '回滚',
        action: () => {
          this.runConnectionAction(conn, PLUGIN_ACTION_ROLLBACK);
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private setConnectionEnabled(conn: AdminPluginConnection, enabled: boolean): void {
    if (conn.id === undefined || this.working.length > 0) {
      return;
    }
    const connectionId: number = conn.id;
    this.working = `${connectionId}-state`;
    AdminPluginsApi.setConnectionEnabled(connectionId, enabled).then((rsp) => {
      this.working = '';
      if (rsp.err === undefined || rsp.err === 'ok') {
        this.toast(enabled ? '连接已启用' : '连接已停用');
        void this.loadConnections();
      } else {
        this.toast(this.messageOf(rsp.err, rsp.msg, '操作失败'));
      }
    }).catch((e: Object) => {
      this.working = '';
      this.toast(`操作失败：${e}`);
    });
  }

  // ---- 运行记录 ----

  private runTitle(run: AdminPluginRun): string {
    const action: string = run.action !== undefined ? run.action : '-';
    const status: string = run.status !== undefined ? run.status : '-';
    const duration: number = run.duration_ms !== undefined ? run.duration_ms : 0;
    return `#${run.id ?? 0} ${action} · ${status} · ${duration} ms`;
  }

  private runSubtitle(run: AdminPluginRun): string {
    const created: string = run.created_at !== undefined ? run.created_at : '';
    const error: string = run.error_message !== undefined ? run.error_message : '';
    const counts: Record<string, Object> | undefined = run.counts;
    const countText: string = counts !== undefined ? JSON.stringify(counts) : '';
    return `${created}${error.length > 0 ? ` · ${error}` : ''}${countText.length > 0 ? ` · ${countText}` : ''}`;
  }

  private async openRun(run: AdminPluginRun): Promise<void> {
    if (run.id === undefined) {
      return;
    }
    if (this.openRunId === run.id) {
      this.openRunId = 0;
      this.openRunItems = [];
      return;
    }
    const rsp = await AdminPluginsApi.getRunDetail(run.id);
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      this.toast(this.messageOf(rsp.err, rsp.msg, '详情加载失败'));
      return;
    }
    this.openRunId = run.id;
    this.openRunItems = rsp.items ?? [];
  }

  private runItemLine(item: AdminPluginRunItem): string {
    const externalId: string = item.external_id !== undefined ? item.external_id : '';
    const entity: string = item.entity_type !== undefined ? item.entity_type : '';
    const status: string = item.status !== undefined ? item.status : '';
    const error: string = item.error_message !== undefined ? item.error_message : '';
    return `${entity} ${externalId} · ${status}${error.length > 0 ? ` · ${error}` : ''}`;
  }

  // ---- 工具 ----

  private async searchToolBooks(): Promise<void> {
    if (this.toolBusy) {
      return;
    }
    this.toolBusy = true;
    this.toolBooks = [];
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await AdminPluginsApi.listToolBooks(this.toolKeyword);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toolResult = this.messageOf(rsp.err, rsp.msg, '查询失败');
        return;
      }
      this.toolBooks = rsp.books ?? [];
      this.toolResult = this.toolBooks.length === 0 ? '没有可用 EPUB/TXT 的书籍' : '';
    } catch (e) {
      this.toolResult = `查询失败：${e}`;
    } finally {
      this.toolBusy = false;
    }
  }

  private selectToolBook(book: AdminToolBookOption): void {
    this.toolBookId = book.id !== undefined ? book.id : 0;
    this.previewSamples = [];
    this.toolResult = `已选择书 #${this.toolBookId}`;
  }

  private toolBookTitle(book: AdminToolBookOption): string {
    const title: string = book.title !== undefined ? book.title : '未命名';
    const formats: string[] = book.formats ?? [];
    return `${title} · ${formats.join('/')}`;
  }

  private async previewTextReplace(): Promise<void> {
    if (this.toolBookId <= 0 || this.toolBusy) {
      return;
    }
    const payload: AdminTextReplacePayload = {
      book_id: this.toolBookId,
      pattern: this.pattern,
      replacement: this.replacement,
      use_regex: this.useRegex,
    };
    this.toolBusy = true;
    try {
      const rsp = await AdminPluginsApi.textReplacePreview(payload);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toolResult = this.messageOf(rsp.err, rsp.msg, '预览失败');
        this.previewSamples = [];
        return;
      }
      this.previewSamples = rsp.samples ?? [];
      const regexError: string = rsp.regex_error !== undefined ? rsp.regex_error : '';
      this.toolResult = regexError.length > 0
        ? `正则错误：${regexError}`
        : `格式 ${rsp.format ?? '-'} · 命中 ${rsp.matches ?? 0} 处`
          + `${rsp.truncated === true ? '（仅统计前缀）' : ''}`;
    } catch (e) {
      this.toolResult = `预览失败：${e}`;
    } finally {
      this.toolBusy = false;
    }
  }

  private async analyzeTxtFixer(): Promise<void> {
    if (this.toolBookId <= 0 || this.toolBusy) {
      return;
    }
    this.toolBusy = true;
    this.previewSamples = [];
    try {
      const rsp: AdminTxtFixerAnalyzeResponse = await AdminPluginsApi.txtFixerAnalyze(this.toolBookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toolResult = this.messageOf(rsp.err, rsp.msg, '检测失败');
        return;
      }
      const reasons: string[] = rsp.reasons ?? [];
      this.toolResult = `编码 ${rsp.encoding ?? '-'} · 乱码 ${rsp.mojibake === true ? '是' : '否'}`
        + ` · 损坏 ${rsp.garbage === true ? '是' : '否'}`
        + `\n检测依据：${reasons.join('、')}`
        + `\n修复预览：${rsp.preview ?? ''}`;
    } catch (e) {
      this.toolResult = `检测失败：${e}`;
    } finally {
      this.toolBusy = false;
    }
  }

  private confirmReplaceRun(): void {
    this.getUIContext().showAlertDialog({
      title: '执行正文替换',
      message: this.overwriteMode
        ? '将以替换结果覆盖原书文件（服务端会先备份原文件），继续？'
        : '将生成一本新的替换版书籍，继续？',
      primaryButton: {
        value: '执行',
        action: () => {
          void this.runTextReplace();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async runTextReplace(): Promise<void> {
    const payload: AdminTextReplaceRunPayload = {
      book_id: this.toolBookId,
      pattern: this.pattern,
      replacement: this.replacement,
      use_regex: this.useRegex,
      output_mode: this.overwriteMode ? TOOL_OUTPUT_MODE_OVERWRITE : TOOL_OUTPUT_MODE_NEW,
    };
    this.toolBusy = true;
    try {
      const rsp: AdminToolRunResponse = await AdminPluginsApi.textReplaceRun(payload);
      this.toolResult = this.toolRunSummary(rsp, '替换完成');
      await this.loadRuns();
    } catch (e) {
      this.toolResult = `替换失败：${e}`;
    } finally {
      this.toolBusy = false;
    }
  }

  private confirmTxtFixerRun(): void {
    this.getUIContext().showAlertDialog({
      title: '执行 TXT 编码修复',
      message: this.overwriteMode
        ? '将以修复结果覆盖原书文件（服务端会先备份原文件），继续？'
        : '将生成一本编码修复版书籍，继续？',
      primaryButton: {
        value: '执行',
        action: () => {
          void this.runTxtFixer();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async runTxtFixer(): Promise<void> {
    const payload: AdminTxtFixerRunPayload = {
      book_id: this.toolBookId,
      output_mode: this.overwriteMode ? TOOL_OUTPUT_MODE_OVERWRITE : TOOL_OUTPUT_MODE_NEW,
    };
    this.toolBusy = true;
    try {
      const rsp: AdminToolRunResponse = await AdminPluginsApi.txtFixerRun(payload);
      this.toolResult = this.toolRunSummary(rsp, '修复完成');
      await this.loadRuns();
    } catch (e) {
      this.toolResult = `修复失败：${e}`;
    } finally {
      this.toolBusy = false;
    }
  }

  private confirmZhRun(): void {
    this.getUIContext().showAlertDialog({
      title: '执行繁简转换',
      message: this.zhReplace
        ? '将以转换结果替换原书并同步书名/作者/语言（服务端会先备份原文件），继续？'
        : '将另存为一本转换后的新书，继续？',
      primaryButton: {
        value: '执行',
        action: () => {
          void this.runZhConverter();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async runZhConverter(): Promise<void> {
    const payload: AdminZhConverterRunPayload = {
      book_id: this.toolBookId,
      direction: this.zhDirection,
      use_a5: this.zhUseA5,
      convert_title: this.zhConvertTitle,
      backup: this.zhReplace,
      output_mode: this.zhReplace ? 'replace' : 'new',
    };
    this.toolBusy = true;
    try {
      const rsp: AdminToolRunResponse = await AdminPluginsApi.zhConverterRun(payload);
      this.toolResult = this.toolRunSummary(rsp, '转换完成');
      await this.loadRuns();
    } catch (e) {
      this.toolResult = `转换失败：${e}`;
    } finally {
      this.toolBusy = false;
    }
  }

  private toolRunSummary(rsp: AdminToolRunResponse, fallback: string): string {
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return this.messageOf(rsp.err, rsp.msg, fallback);
    }
    const parts: string[] = [];
    parts.push(this.messageOf(rsp.err, rsp.msg, fallback));
    if (rsp.book_id !== undefined) {
      parts.push(`book #${rsp.book_id}`);
    }
    if (rsp.matches !== undefined) {
      parts.push(`命中 ${rsp.matches}`);
    }
    if (rsp.encoding !== undefined && rsp.encoding.length > 0) {
      parts.push(`编码 ${rsp.encoding}`);
    }
    if (rsp.language !== undefined && rsp.language.length > 0) {
      parts.push(`语言 ${rsp.language}`);
    }
    if (rsp.backup_path !== undefined && rsp.backup_path.length > 0) {
      parts.push(`备份 ${rsp.backup_path}`);
    }
    return parts.join(' · ');
  }

  private sampleText(sample: AdminTextReplaceSample): string {
    const pre: string = sample.pre !== undefined ? sample.pre : '';
    const match: string = sample.match !== undefined ? sample.match : '';
    const post: string = sample.post !== undefined ? sample.post : '';
    return `${pre}[${match}]${post}`;
  }

  private toolBookSubtitle(book: AdminToolBookOption): string {
    const authors: string[] = book.authors ?? [];
    const timestamp: string = book.timestamp !== undefined ? book.timestamp : '';
    return `${authors.join('、')}${timestamp.length > 0 ? ` · ${timestamp}` : ''}`;
  }

  private onTabChange(value: number): void {
    this.tab = value;
    if (value === 1) {
      void this.loadConnections();
    } else if (value === 2) {
      void this.loadRuns();
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '插件中心',
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
      EmptyState({ message: '当前服务端不支持插件中心（需要 Talebook）' });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError, actionLabel: '重试', onAction: () => { void this.load(); } });
    } else {
      Column() {
        FilterChips({
          items: [
            { label: '插件', value: 0 },
            { label: '连接', value: 1 },
            { label: '运行记录', value: 2 },
            { label: '正文工具', value: 3 },
          ] as FilterChipItem[],
          selected: $tab,
          onChange: (value: number) => this.onTabChange(value),
        });
        Scroll() {
          Column({ space: 8 }) {
            if (this.tab === 0) {
              this.pluginTab();
            } else if (this.tab === 1) {
              this.connectionTab();
            } else if (this.tab === 2) {
              this.runTab();
            } else {
              this.toolTab();
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 24 });
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top);
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  pluginTab() {
    SectionTitle({ title: '全局元数据行为' });
    Column() {
      SettingCell({
        title: '自动补全元数据',
        subtitle: '导入/入库后自动向插件查询元数据',
        showToggle: true,
        toggleOn: this.autoFillMeta,
        onToggle: (value: boolean) => {
          this.autoFillMeta = value;
          this.savePreferences();
        },
      });
      Divider().color($r('app.color.divider')).strokeWidth(0.5);
      SettingCell({
        title: '补全时保留现有封面',
        showToggle: true,
        toggleOn: this.autoFillKeepCover,
        onToggle: (value: boolean) => {
          this.autoFillKeepCover = value;
          this.savePreferences();
        },
      });
    }
    .width('100%')
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));

    if (this.opdsServiceKey.length > 0) {
      SectionTitle({ title: '服务开关' });
      Column() {
        SettingCell({
          title: 'OPDS 服务',
          subtitle: this.opdsServiceEnabled ? '已开启（点击关闭）' : '已关闭（点击开启）',
          valueText: '切换',
          showChevron: true,
          onTap: () => this.toggleOpdsService(),
        });
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }

    SectionTitle({ title: `插件（${this.definitions.length}）` });
    Column() {
      ForEach(this.definitions, (def: AdminPluginDefinition) => {
        this.pluginRow(def);
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
      }, (def: AdminPluginDefinition) => `plugin-${def.plugin_key ?? ''}`);
    }
    .width('100%')
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  pluginRow(def: AdminPluginDefinition) {
    Column({ space: 4 }) {
      Text(this.definitionTitle(def))
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      Text(this.definitionSubtitle(def))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Text(def.description !== undefined && def.description.length > 0 ? def.description : '（无描述）')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Row({ space: 12 }) {
        Text(this.installationSubtitle(this.installationFor(def.plugin_key ?? '')))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1);
        if (this.installationFor(def.plugin_key ?? '') !== undefined) {
          Toggle({ type: ToggleType.Switch, isOn: this.installationToggle(def.plugin_key ?? '') })
            .onChange((value: boolean) => {
              this.setInstallationEnabled(def.plugin_key ?? '', value);
            });
        } else {
          TextButton({
            label: '安装',
            onTap: () => {
              this.installPlugin(def.plugin_key ?? '');
            },
          });
        }
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'));
  }

  @Builder
  connectionTab() {
    SectionTitle({ title: `实例连接（${this.connections.length}）` });
    if (this.connections.length === 0) {
      EmptyState({ message: '暂无实例级连接；请先在插件页完成安装并配置连接。' });
    } else {
      Column() {
        ForEach(this.connections, (conn: AdminPluginConnection) => {
          this.connectionRow(conn);
          Divider().color($r('app.color.divider')).strokeWidth(0.5);
        }, (conn: AdminPluginConnection) => `conn-${conn.id ?? 0}`);
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
    SecondaryButton({
      label: '刷新连接',
      fullWidth: false,
      onTap: () => {
        void this.loadConnections();
      },
    });
  }

  @Builder
  connectionRow(conn: AdminPluginConnection) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.connectionTitle(conn))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: conn.enabled === true })
          .onChange((value: boolean) => {
            this.setConnectionEnabled(conn, value);
          });
      }
      .width('100%');
      Text(this.connectionSubtitle(conn))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Row({ space: 8 }) {
        TextButton({
          label: 'test',
          onTap: () => {
            this.runConnectionAction(conn, PLUGIN_ACTION_TEST);
          },
        });
        TextButton({
          label: 'preview',
          onTap: () => {
            this.runConnectionAction(conn, PLUGIN_ACTION_PREVIEW);
          },
        });
        TextButton({
          label: 'run',
          onTap: () => {
            this.runConnectionAction(conn, PLUGIN_ACTION_RUN);
          },
        });
        TextButton({
          label: 'retry',
          onTap: () => {
            this.runConnectionAction(conn, PLUGIN_ACTION_RETRY);
          },
        });
        TextButton({
          label: 'rollback',
          tone: 'danger',
          onTap: () => {
            this.confirmRollback(conn);
          },
        });
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'));
  }

  @Builder
  runTab() {
    SectionTitle({ title: `运行记录（最近 ${this.runs.length} 条）`, actionLabel: '刷新',
      onAction: () => { void this.loadRuns(); } });
    if (this.runs.length === 0) {
      EmptyState({ message: '暂无运行记录' });
    } else {
      Column() {
        ForEach(this.runs, (run: AdminPluginRun) => {
          this.runRow(run);
          Divider().color($r('app.color.divider')).strokeWidth(0.5);
        }, (run: AdminPluginRun) => `run-${run.id ?? 0}`);
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
  }

  @Builder
  runRow(run: AdminPluginRun) {
    Column({ space: 4 }) {
      Text(this.runTitle(run))
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      Text(this.runSubtitle(run))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      if (this.openRunId === run.id) {
        if (this.openRunItems.length === 0) {
          Text('没有明细项')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%');
        } else {
          ForEach(this.openRunItems, (item: AdminPluginRunItem) => {
            Text(this.runItemLine(item))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%');
          }, (item: AdminPluginRunItem) => `item-${item.id ?? 0}`);
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => {
      void this.openRun(run);
    });
  }

  @Builder
  toolTab() {
    Text('正文工具依赖“正文查找替换 / TXT 编码修复 / 繁简转换”三个内置插件处于启用状态。')
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%');
    SearchBar({
      placeholder: '按书名/作者搜索（留空列出最近 100 本）',
      keyword: $toolKeyword,
      onSearch: () => {
        void this.searchToolBooks();
      },
    });
    if (this.toolBooks.length > 0) {
      Column() {
        ForEach(this.toolBooks, (book: AdminToolBookOption) => {
          this.toolBookRow(book);
          Divider().color($r('app.color.divider')).strokeWidth(0.5);
        }, (book: AdminToolBookOption) => `tool-book-${book.id ?? 0}`);
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
    this.toolForm();
    if (this.toolResult.length > 0) {
      Text(this.toolResult)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
    }
    if (this.previewSamples.length > 0) {
      SectionTitle({ title: '替换预览样本' });
      Column({ space: 6 }) {
        ForEach(this.previewSamples, (sample: AdminTextReplaceSample) => {
          Text(this.sampleText(sample))
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .width('100%');
        }, (sample: AdminTextReplaceSample) => `sample-${sample.index ?? 0}`);
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
  }

  @Builder
  toolBookRow(book: AdminToolBookOption) {
    Column({ space: 2 }) {
      Text(this.toolBookTitle(book))
        .fontSize(14)
        .fontColor(this.toolBookId === book.id ? $r('app.color.brand_primary') : $r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Text(this.toolBookSubtitle(book))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.selectToolBook(book));
  }

  @Builder
  toolForm() {
    if (this.toolBookId <= 0) {
      Text('先在上方选择一本书籍。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    } else {
      Column({ space: 8 }) {
        Text(`当前书籍：#${this.toolBookId}`)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        TextInput({ placeholder: '查找内容（必填）', text: this.pattern })
          .height($r('app.float.button_height_compact'))
          .onChange((value: string) => {
            this.pattern = value;
          });
        TextInput({ placeholder: '替换为', text: this.replacement })
          .height($r('app.float.button_height_compact'))
          .onChange((value: string) => {
            this.replacement = value;
          });
        Row({ space: 8 }) {
          Text('正则匹配').fontSize(13).fontColor($r('app.color.text_primary')).layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.useRegex })
            .onChange((value: boolean) => {
              this.useRegex = value;
            });
        }
        .width('100%');
        Row({ space: 8 }) {
          Text('覆盖原书').fontSize(13).fontColor($r('app.color.text_primary')).layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.overwriteMode })
            .onChange((value: boolean) => {
              this.overwriteMode = value;
            });
        }
        .width('100%');
        Row({ space: 12 }) {
          SecondaryButton({
            label: '替换预览',
            buttonEnabled: !this.toolBusy,
            fullWidth: false,
            compact: true,
            onTap: () => {
              void this.previewTextReplace();
            },
          }).layoutWeight(1);
          PrimaryButton({
            label: '执行替换',
            buttonEnabled: !this.toolBusy,
            fullWidth: false,
            onTap: () => this.confirmReplaceRun(),
          }).layoutWeight(1);
        }
        .width('100%');
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        Row({ space: 12 }) {
          SecondaryButton({
            label: '检测 TXT 编码',
            buttonEnabled: !this.toolBusy,
            fullWidth: false,
            compact: true,
            onTap: () => {
              void this.analyzeTxtFixer();
            },
          }).layoutWeight(1);
          PrimaryButton({
            label: '执行编码修复',
            buttonEnabled: !this.toolBusy,
            fullWidth: false,
            onTap: () => this.confirmTxtFixerRun(),
          }).layoutWeight(1);
        }
        .width('100%');
        Divider().color($r('app.color.divider')).strokeWidth(0.5);
        Text('繁简转换方向')
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Row({ space: 8 }) {
          ForEach(ZH_DIRECTIONS, (direction: string, index: number) => {
            TextButton({
              label: ZH_DIRECTION_LABELS[index],
              onTap: () => {
                this.zhDirection = direction;
              },
            });
          }, (direction: string) => `zh-${direction}`);
        }
        .width('100%');
        Text(`当前方向：${this.zhDirection}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        Row({ space: 8 }) {
          Text('增强词表(A5)').fontSize(13).fontColor($r('app.color.text_primary')).layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.zhUseA5 })
            .onChange((value: boolean) => {
              this.zhUseA5 = value;
            });
        }
        .width('100%');
        Row({ space: 8 }) {
          Text('同时转换标题/作者').fontSize(13).fontColor($r('app.color.text_primary')).layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.zhConvertTitle })
            .onChange((value: boolean) => {
              this.zhConvertTitle = value;
            });
        }
        .width('100%');
        Row({ space: 8 }) {
          Text('替换原书（关闭则另存新书）').fontSize(13).fontColor($r('app.color.text_primary')).layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.zhReplace })
            .onChange((value: boolean) => {
              this.zhReplace = value;
            });
        }
        .width('100%');
        Text('提示：上游未提供繁简转换的 HTTP 预览接口，故此处只有执行入口。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
        PrimaryButton({
          label: '执行繁简转换',
          buttonEnabled: !this.toolBusy,
          onTap: () => this.confirmZhRun(),
        });
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding($r('app.float.page_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
  }
}
