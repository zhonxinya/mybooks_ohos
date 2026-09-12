import { PageScaffold, LoadingState, EmptyState, FilterChips, FilterChipItem,
  PrimaryButton, SecondaryButton, SearchBar, SectionTitle, SettingCell, TextButton,
  ChipButton } from '../components';
import {
  AdminPluginsApi,
  AdminPluginDefinition, AdminPluginInstallation, AdminPluginConnection,
  AdminPluginRun, AdminPluginRunItem, AdminToolBookOption, AdminTextReplaceSample,
  AdminTextReplacePayload, AdminTextReplaceRunPayload, AdminTxtFixerRunPayload,
  AdminZhConverterRunPayload, AdminToolRunResponse, AdminTxtFixerAnalyzeResponse,
  AdminPluginPreferencesPayload, AdminPluginMetadataPrefs, AdminPluginServiceState,
  AdminPluginSecret, AdminPluginConnectionPayload, AdminMetadataQuery,
  AdminMetadataSummary, AdminSourceSummary, AdminReviewSummary,
  PLUGIN_ACTION_TEST, PLUGIN_ACTION_PREVIEW, PLUGIN_ACTION_RUN, PLUGIN_ACTION_RETRY,
  PLUGIN_ACTION_ROLLBACK, TOOL_OUTPUT_MODE_NEW, TOOL_OUTPUT_MODE_OVERWRITE,
} from '../services/AdminPluginsApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

/** 繁简转换方向（上游 zh_converter 支持 8 种，这里列常用 4 种）。 */
const ZH_DIRECTIONS: string[] = ['t2s', 'tw2s', 's2t', 's2tw'];
const ZH_DIRECTION_LABELS: string[] = ['简↔简(A5)', '台繁→简', '简→繁', '简→台繁'];

// ---- 状态筛选（对齐上游 statusOptions） ----
const FILTER_ALL: number = 0;
const FILTER_ATTENTION: number = 1;
const FILTER_ENABLED: number = 2;
const FILTER_DISABLED: number = 3;

// ---- 插件状态键（对齐上游 statusInfo） ----
const STATUS_UNINSTALLED: string = 'uninstalled';
const STATUS_DISABLED: string = 'disabled';
const STATUS_UNCONFIGURED: string = 'unconfigured';
const STATUS_UNHEALTHY: string = 'unhealthy';
const STATUS_ENABLED: string = 'enabled';

/** 分组顺序（对齐上游 groupDefinitions 的 order 与分类键）。 */
const PLUGIN_GROUP_ORDER: string[] = ['combo', 'meta', 'annotation', 'review', 'source', 'tool', 'push'];

// ---- 底部面板模式（同一节点只能生效一个 bindSheet，故用单面板 + 模式分发） ----
const SHEET_DETAIL: string = 'detail';
const SHEET_AUTOFILL: string = 'autofill';
const SHEET_DEVICE: string = 'device';

// ---- 能力联调（对齐上游 PluginCapabilityTester 支持的三种协议） ----
const CAPABILITY_METADATA: string = 'metadata.lookup';
const CAPABILITY_SOURCES: string = 'sources.search';
const CAPABILITY_REVIEWS: string = 'reviews.lookup';

/** 插件分组。 */
interface PluginGroup {
  type: string;
  label: string;
  description: string;
  plugins: AdminPluginDefinition[];
}

/** 配置/凭据表单字段（由 config_schema / auth_schema 的 properties 展开）。 */
interface PluginConfigField {
  key: string;
  title: string;
  type: string;
  format: string;
  required: boolean;
  isArray: boolean;
}

/** 可添加到全局设备列表的推送类型（来自已启用且有 device_type 的推送插件）。 */
interface PluginPushType {
  name: string;
  value: string;
  defaultPort: number;
}

/** 全局共享设备（对应上游 `settings.DEVICES` 条目）。 */
interface PluginDevice {
  name: string;
  type: string;
  mailbox: string;
  ip: string;
  port: string;
  schema: string;
}

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
  // 内置插件自报状态（builtin_state 原样保留，供 OPDS 服务开关与"待配置"判定使用）
  @State private builtinState: Record<string, AdminPluginServiceState> = {};
  // 目录：搜索与状态筛选
  @State private search: string = '';
  @State private statusFilter: number = FILTER_ALL;
  // 插件详情
  @State private selectedKey: string = '';
  @State private sheetMode: string = '';
  @State private showSheet: boolean = false;
  @State private connFormOpen: boolean = false;
  @State private connBool: Record<string, boolean> = {};
  @State private connBusy: boolean = false;
  // 表单文本值不参与渲染，用普通字段避免逐字符重渲染
  private connText: Record<string, string> = {};
  private connName: string = '';
  // 能力测试
  @State private capKind: string = '';
  @State private capItems: string[] = [];
  @State private capSubmitted: boolean = false;
  @State private capError: string = '';
  @State private capBusy: boolean = false;
  private capTitle: string = '';
  private capIsbn: string = '';
  private capAuthors: string = '';
  private capPublisher: string = '';
  private capKeyword: string = '';
  // 自动补全设置 / 全局设备
  @State private devices: PluginDevice[] = [];
  @State private deviceError: string = '';
  @State private deviceBusy: boolean = false;

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
    this.builtinState = state;
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

  // -------------------------------------------------------------------------
  // 目录 / 状态 / 分组（对齐上游 catalog、statusInfo、filteredPlugins、groupedPlugins）
  // -------------------------------------------------------------------------

  private pluginKeyOf(def: AdminPluginDefinition): string {
    return def.plugin_key !== undefined ? def.plugin_key : '';
  }

  private uiFlag(def: AdminPluginDefinition, key: string): boolean {
    const ui: Record<string, Object> | undefined = def.ui;
    return ui !== undefined && ui[key] === true;
  }

  private uiText(def: AdminPluginDefinition, key: string): string {
    const ui: Record<string, Object> | undefined = def.ui;
    if (ui === undefined) {
      return '';
    }
    const value: Object | undefined = ui[key];
    return value !== undefined ? String(value) : '';
  }

  private uiNumber(def: AdminPluginDefinition, key: string): number {
    const parsed: number = Number(this.uiText(def, key));
    return parsed > 0 ? parsed : 0;
  }

  /** 目录：剔除声明 `ui.hidden` 的插件（与上游 catalog 一致）。 */
  private catalog(): AdminPluginDefinition[] {
    const result: AdminPluginDefinition[] = [];
    for (let i = 0; i < this.definitions.length; i++) {
      if (!this.uiFlag(this.definitions[i], 'hidden')) {
        result.push(this.definitions[i]);
      }
    }
    return result;
  }

  /** 分类键取自 `plugin_key` 的第二段（如 talebook.meta.douban → meta）。 */
  private pluginType(def: AdminPluginDefinition): string {
    const parts: string[] = this.pluginKeyOf(def).split('.');
    if (parts.length > 1 && parts[0] === 'talebook') {
      return parts[1];
    }
    return 'other';
  }

  private groupLabel(type: string): string {
    if (type === 'combo') { return '综合服务'; }
    if (type === 'meta') { return '元数据'; }
    if (type === 'annotation') { return '划线笔记'; }
    if (type === 'review') { return '评价'; }
    if (type === 'source') { return '书源'; }
    if (type === 'tool') { return '书籍工具'; }
    if (type === 'push') { return '发送到设备'; }
    return type.length > 0 && type !== 'other' ? type : '其他';
  }

  private groupDescription(type: string): string {
    if (type === 'combo') {
      return '综合服务插件同时提供多种关联能力；启用后可在对应的全局配置或个人设置中使用。';
    }
    if (type === 'meta') {
      return '元数据插件提供书籍信息的搜索能力。同步书籍信息时会自动调用已启用的插件查询；'
        + '「自动补全设置」用于控制新书是否自动补全信息。';
    }
    if (type === 'annotation') {
      return 'Talebook 负责保存本地划线与笔记；此类插件用于从外部阅读服务导入内容，'
        + '或将公开内容同步到已连接的服务。';
    }
    if (type === 'review') {
      return '评价插件用于查询书籍评分、评价摘要与样本数量，并在书籍详情中提供参考信息。';
    }
    if (type === 'source') {
      return '书源插件用于浏览、搜索和获取在线书籍；启用后可在网络书库或插件的全局配置中使用对应来源。';
    }
    if (type === 'tool') {
      return '书籍工具用于修复或转换书籍文件；启用后处理入口会出现在书籍详情页的「处理」菜单中。';
    }
    if (type === 'push') {
      return '发送到设备插件决定用户可添加的阅读设备类型；启用后用户可在个人设备设置中配置目标并发送书籍。';
    }
    return '服务端声明的其它分类。';
  }

  private groupGlyph(type: string): Resource {
    if (type === 'meta') { return $r('sys.symbol.magnifyingglass'); }
    if (type === 'annotation') { return $r('sys.symbol.bookmark'); }
    if (type === 'review') { return $r('sys.symbol.star'); }
    if (type === 'source') { return $r('sys.symbol.list_bullet'); }
    if (type === 'tool') { return $r('sys.symbol.wand_and_stars'); }
    if (type === 'push') { return $r('sys.symbol.paperplane'); }
    return $r('sys.symbol.square_grid_2x2');
  }

  private groupCount(type: string): number {
    const list: AdminPluginDefinition[] = this.catalog();
    let count: number = 0;
    for (let i = 0; i < list.length; i++) {
      if (this.pluginType(list[i]) === type) {
        count++;
      }
    }
    return count;
  }

  private matchesSearch(def: AdminPluginDefinition): boolean {
    const needle: string = this.search.trim().toLowerCase();
    if (needle.length === 0) {
      return true;
    }
    const capabilities: string[] = def.capabilities ?? [];
    const haystack: string = `${this.definitionTitle(def)} ${def.description ?? ''} ${capabilities.join(' ')}`
      .toLowerCase();
    return haystack.includes(needle);
  }

  private connectionFor(def: AdminPluginDefinition): AdminPluginConnection | undefined {
    const inst: AdminPluginInstallation | undefined = this.installationFor(this.pluginKeyOf(def));
    if (inst === undefined || inst.id === undefined) {
      return undefined;
    }
    for (let i = 0; i < this.connections.length; i++) {
      if (this.connections[i].installation_id === inst.id) {
        return this.connections[i];
      }
    }
    return undefined;
  }

  private supportsInstanceConnection(def: AdminPluginDefinition): boolean {
    const owners: string[] = def.connection_owners ?? [];
    return owners.indexOf('instance') >= 0;
  }

  private pluginNeedsConfiguration(def: AdminPluginDefinition): boolean {
    return this.supportsInstanceConnection(def) && this.uiText(def, 'configuration_mode') === 'form';
  }

  /**
   * 详情页「设置」区：只在有可执行入口时展示。
   * `manage_dialog` 类插件（如 OPDS）的入口已由上方服务开关承接，不再重复标题。
   */
  private hasConfigurationUi(def: AdminPluginDefinition): boolean {
    return this.uiText(def, 'manage_route').length > 0 || this.pluginNeedsConfiguration(def);
  }

  private schemaRequired(schema: Record<string, Object> | undefined): string[] {
    if (schema === undefined) {
      return [];
    }
    const value: Object | undefined = schema['required'];
    return value !== undefined ? value as string[] : [];
  }

  /** 展开 config_schema / auth_schema 的 properties 为表单字段。 */
  private schemaFields(schema: Record<string, Object> | undefined): PluginConfigField[] {
    const fields: PluginConfigField[] = [];
    if (schema === undefined) {
      return fields;
    }
    const properties: Record<string, Object> | undefined = schema['properties'] as Record<string, Object>;
    if (properties === undefined) {
      return fields;
    }
    const required: string[] = this.schemaRequired(schema);
    const keys: string[] = Object.keys(properties);
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      const spec: Record<string, Object> = properties[key] as Record<string, Object>;
      const title: Object | undefined = spec['title'];
      const typeValue: Object | undefined = spec['type'];
      const type: string = typeValue !== undefined ? String(typeValue) : 'string';
      const formatValue: Object | undefined = spec['format'];
      fields.push({
        key: key,
        title: title !== undefined && String(title).length > 0 ? String(title) : key,
        type: type,
        format: formatValue !== undefined ? String(formatValue) : '',
        required: required.indexOf(key) >= 0,
        isArray: type === 'array',
      });
    }
    return fields;
  }

  private connectionConfigured(def: AdminPluginDefinition, conn: AdminPluginConnection | undefined): boolean {
    if (conn === undefined) {
      return false;
    }
    const config: Record<string, Object> | undefined = conn.config;
    const requiredConfig: string[] = this.schemaRequired(def.config_schema);
    for (let i = 0; i < requiredConfig.length; i++) {
      const value: Object | undefined = config !== undefined ? config[requiredConfig[i]] : undefined;
      if (value === undefined || String(value).length === 0) {
        return false;
      }
    }
    if (this.schemaRequired(def.auth_schema).length > 0) {
      const secret: AdminPluginSecret | undefined = conn.secret;
      if (secret === undefined || secret.configured !== true) {
        return false;
      }
    }
    return true;
  }

  /** 状态键（对齐上游 statusInfo 的五种取值）。 */
  private statusKey(def: AdminPluginDefinition): string {
    const inst: AdminPluginInstallation | undefined = this.installationFor(this.pluginKeyOf(def));
    if (inst === undefined) {
      return STATUS_UNINSTALLED;
    }
    if (inst.enabled !== true) {
      return STATUS_DISABLED;
    }
    const conn: AdminPluginConnection | undefined = this.connectionFor(def);
    const state: AdminPluginServiceState | undefined = this.builtinState[this.pluginKeyOf(def)];
    if (this.pluginNeedsConfiguration(def) && state === undefined && !this.connectionConfigured(def, conn)) {
      return STATUS_UNCONFIGURED;
    }
    if (conn !== undefined && (conn.health === 'unauthorized' || conn.health === 'degraded')) {
      return STATUS_UNHEALTHY;
    }
    return STATUS_ENABLED;
  }

  private statusLabel(def: AdminPluginDefinition): string {
    const key: string = this.statusKey(def);
    if (key === STATUS_UNINSTALLED) { return '未安装'; }
    if (key === STATUS_DISABLED) { return '未启用'; }
    if (key === STATUS_UNCONFIGURED) { return '待配置'; }
    if (key === STATUS_UNHEALTHY) {
      const conn: AdminPluginConnection | undefined = this.connectionFor(def);
      return conn !== undefined && conn.health === 'unauthorized' ? '认证失效' : '异常';
    }
    return '正常';
  }

  private statusColor(def: AdminPluginDefinition): Resource {
    const key: string = this.statusKey(def);
    if (key === STATUS_ENABLED) { return $r('app.color.success'); }
    if (key === STATUS_UNCONFIGURED || key === STATUS_UNHEALTHY) { return $r('app.color.warning'); }
    return $r('app.color.text_tertiary');
  }

  private statusBackground(def: AdminPluginDefinition): Resource {
    const key: string = this.statusKey(def);
    if (key === STATUS_ENABLED) { return $r('app.color.success_light'); }
    if (key === STATUS_UNCONFIGURED) { return $r('app.color.warning_light'); }
    if (key === STATUS_UNHEALTHY) { return $r('app.color.error_light'); }
    return $r('app.color.page_background');
  }

  private matchesStatus(def: AdminPluginDefinition): boolean {
    const key: string = this.statusKey(def);
    if (this.statusFilter === FILTER_ALL) { return true; }
    if (this.statusFilter === FILTER_ATTENTION) { return key !== STATUS_ENABLED; }
    if (this.statusFilter === FILTER_ENABLED) { return key === STATUS_ENABLED; }
    return key === STATUS_DISABLED;
  }

  private filteredPlugins(): AdminPluginDefinition[] {
    const list: AdminPluginDefinition[] = this.catalog();
    const result: AdminPluginDefinition[] = [];
    for (let i = 0; i < list.length; i++) {
      if (this.matchesSearch(list[i]) && this.matchesStatus(list[i])) {
        result.push(list[i]);
      }
    }
    return result;
  }

  /** 按分类分组，已知分类按上游顺序排列，服务端新增分类追加在后。 */
  private groupedPlugins(): PluginGroup[] {
    const list: AdminPluginDefinition[] = this.filteredPlugins();
    const types: string[] = [];
    const buckets: AdminPluginDefinition[][] = [];
    for (let i = 0; i < list.length; i++) {
      const type: string = this.pluginType(list[i]);
      let index: number = types.indexOf(type);
      if (index < 0) {
        types.push(type);
        buckets.push([]);
        index = types.length - 1;
      }
      buckets[index].push(list[i]);
    }
    const groups: PluginGroup[] = [];
    for (let i = 0; i < PLUGIN_GROUP_ORDER.length; i++) {
      const type: string = PLUGIN_GROUP_ORDER[i];
      const index: number = types.indexOf(type);
      if (index >= 0) {
        groups.push(this.buildGroup(type, buckets[index]));
      }
    }
    for (let i = 0; i < types.length; i++) {
      if (PLUGIN_GROUP_ORDER.indexOf(types[i]) < 0) {
        groups.push(this.buildGroup(types[i], buckets[i]));
      }
    }
    return groups;
  }

  private buildGroup(type: string, plugins: AdminPluginDefinition[]): PluginGroup {
    const group: PluginGroup = {
      type: type,
      label: this.groupLabel(type),
      description: this.groupDescription(type),
      plugins: plugins,
    };
    return group;
  }

  private enabledCount(): number {
    const list: AdminPluginDefinition[] = this.catalog();
    let count: number = 0;
    for (let i = 0; i < list.length; i++) {
      const inst: AdminPluginInstallation | undefined = this.installationFor(this.pluginKeyOf(list[i]));
      if (inst !== undefined && inst.enabled === true) {
        count++;
      }
    }
    return count;
  }

  private attentionCount(): number {
    const list: AdminPluginDefinition[] = this.catalog();
    let count: number = 0;
    for (let i = 0; i < list.length; i++) {
      if (this.statusKey(list[i]) !== STATUS_ENABLED) {
        count++;
      }
    }
    return count;
  }

  // ---- 插件详情 ----

  private emptyDefinition(): AdminPluginDefinition {
    const empty: AdminPluginDefinition = {
      plugin_key: '',
      name: '',
      version: '',
      description: '',
      capabilities: [],
      permissions: [],
      connection_owners: [],
      ui: {},
      config_schema: {},
      auth_schema: {},
    };
    return empty;
  }

  private detailDef(): AdminPluginDefinition {
    for (let i = 0; i < this.definitions.length; i++) {
      if (this.definitions[i].plugin_key === this.selectedKey) {
        return this.definitions[i];
      }
    }
    return this.emptyDefinition();
  }

  private detailTitle(): string {
    return this.definitionTitle(this.detailDef());
  }

  private detailSubtitle(): string {
    const def: AdminPluginDefinition = this.detailDef();
    const version: string = def.version !== undefined && def.version.length > 0 ? def.version : '-';
    return `${this.pluginKeyOf(def)} · v${version} · ${this.statusLabel(def)}`;
  }

  private detailDescription(): string {
    const def: AdminPluginDefinition = this.detailDef();
    return def.description !== undefined && def.description.length > 0 ? def.description : '（无描述）';
  }

  private detailInstallationId(): number {
    const inst: AdminPluginInstallation | undefined = this.installationFor(this.selectedKey);
    return inst !== undefined && inst.id !== undefined ? inst.id : 0;
  }

  private detailEnabled(): boolean {
    const inst: AdminPluginInstallation | undefined = this.installationFor(this.selectedKey);
    return inst !== undefined && inst.enabled === true;
  }

  private detailCatalogNotice(): string {
    if (this.uiText(this.detailDef(), 'catalog_access') === 'public_free') {
      return '这是无需账号的公开免费书目，可直接体验。下载前请确认作品在你所在地区的版权状态。';
    }
    return '此目录同时包含开放、借阅和受限条目；Talebook 只会取得明确开放下载的文件。';
  }

  private detailHasServiceToggle(): boolean {
    return this.uiText(this.detailDef(), 'service_toggle') === 'opds';
  }

  private detailHealth(): string {
    const conn: AdminPluginConnection | undefined = this.connectionFor(this.detailDef());
    return conn !== undefined && conn.health !== undefined ? conn.health : '';
  }

  private detailHealthMessage(): string {
    const conn: AdminPluginConnection | undefined = this.connectionFor(this.detailDef());
    return conn !== undefined && conn.health_message !== undefined ? conn.health_message : '';
  }

  private detailHealthLabel(): string {
    const health: string = this.detailHealth();
    if (health === 'unauthorized') { return '认证失效'; }
    if (health === 'degraded') { return '连接异常'; }
    return health;
  }

  private detailHasConnectionProblem(): boolean {
    const health: string = this.detailHealth();
    return health === 'unauthorized' || health === 'degraded';
  }

  private detailCapabilityKinds(): string[] {
    const def: AdminPluginDefinition = this.detailDef();
    const kinds: string[] = [];
    if (!this.supportsInstanceConnection(def)) {
      return kinds;
    }
    const caps: string[] = def.capabilities ?? [];
    if (caps.indexOf(CAPABILITY_METADATA) >= 0) { kinds.push('metadata'); }
    if (caps.indexOf(CAPABILITY_SOURCES) >= 0) { kinds.push('source'); }
    if (caps.indexOf(CAPABILITY_REVIEWS) >= 0) { kinds.push('review'); }
    return kinds;
  }

  private detailPermissions(): string[] {
    return this.detailDef().permissions ?? [];
  }

  /** 该插件所属连接的最近执行记录（最多 5 条）。 */
  private detailRuns(): AdminPluginRun[] {
    const result: AdminPluginRun[] = [];
    const conn: AdminPluginConnection | undefined = this.connectionFor(this.detailDef());
    if (conn === undefined || conn.id === undefined) {
      return result;
    }
    for (let i = 0; i < this.runs.length && result.length < 5; i++) {
      if (this.runs[i].connection_id === conn.id) {
        result.push(this.runs[i]);
      }
    }
    return result;
  }

  private textValue(value: Object | undefined, fallback: string): string {
    if (value === undefined || value === null) {
      return fallback;
    }
    const text: string = String(value);
    return text.length > 0 ? text : fallback;
  }

  private openDetails(def: AdminPluginDefinition): void {
    this.selectedKey = this.pluginKeyOf(def);
    this.connFormOpen = false;
    this.connText = {};
    this.connBool = {};
    const kinds: string[] = this.detailCapabilityKinds();
    this.capKind = kinds.length > 0 ? kinds[0] : '';
    this.capTitle = '';
    this.capIsbn = '';
    this.capAuthors = '';
    this.capPublisher = '';
    this.capKeyword = '';
    this.capItems = [];
    this.capSubmitted = false;
    this.capError = '';
    this.sheetMode = SHEET_DETAIL;
    this.showSheet = true;
  }

  private onSheetClosed(): void {
    this.connFormOpen = false;
    this.sheetMode = '';
  }

  private sheetTitle(): string {
    if (this.sheetMode === SHEET_AUTOFILL) { return '自动补全设置'; }
    if (this.sheetMode === SHEET_DEVICE) { return '全局设备'; }
    return '插件详情';
  }

  /** 详情与设备表单内容较多，使用大尺寸；自动补全设置内容少，使用中尺寸。 */
  private sheetHeight(): SheetSize {
    return this.sheetMode === SHEET_AUTOFILL ? SheetSize.MEDIUM : SheetSize.LARGE;
  }

  private toggleDetailInstallation(): void {
    const installationId: number = this.detailInstallationId();
    if (installationId <= 0 || this.working.length > 0) {
      return;
    }
    const next: boolean = !this.detailEnabled();
    const name: string = this.detailTitle();
    if (!next) {
      this.getUIContext().showAlertDialog({
        title: '停用插件',
        message: `确定停用「${name}」吗？停用后其能力与入口会立即失效。`,
        primaryButton: { value: '停用', action: () => { this.setInstallationEnabledById(installationId, false); } },
        secondaryButton: { value: '取消', action: () => {} },
      });
      return;
    }
    this.setInstallationEnabledById(installationId, true);
  }

  private setInstallationEnabledById(installationId: number, enabled: boolean): void {
    this.working = `plugin-${installationId}`;
    AdminPluginsApi.setInstallationEnabled(installationId, enabled).then((rsp) => {
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

  // ---- 详情页的能力测试 ----

  private runCapabilityTest(): void {
    if (this.capBusy || this.capKind.length === 0) {
      return;
    }
    if (this.capKind === 'source' && this.capKeyword.trim().length === 0) {
      this.capError = '请填写搜索关键词。';
      return;
    }
    if (this.capKind !== 'source' && this.capTitle.trim().length === 0 && this.capIsbn.trim().length === 0) {
      this.capError = '请填写书名或 ISBN。';
      return;
    }
    this.capBusy = true;
    this.capError = '';
    this.capItems = [];
    this.capSubmitted = false;
    const pluginKey: string = this.selectedKey;
    if (this.capKind === 'source') {
      AdminPluginsApi.searchSources(pluginKey, this.capKeyword.trim()).then((rsp) => {
        this.capBusy = false;
        if (rsp.err !== undefined && rsp.err !== 'ok') {
          this.capError = this.messageOf(rsp.err, rsp.msg, '能力测试失败，请检查插件设置或稍后重试。');
          return;
        }
        const items: AdminSourceSummary[] = rsp.items ?? [];
        const lines: string[] = [];
        for (let i = 0; i < items.length; i++) {
          lines.push(this.sourceLine(items[i]));
        }
        this.capItems = lines;
        this.capSubmitted = true;
        if (items.length === 0) {
          this.capError = '协议调用成功，但没有返回匹配结果。';
        }
      }).catch((e: Object) => {
        this.capBusy = false;
        this.capError = `能力测试失败：${e}`;
      });
      return;
    }
    const query: AdminMetadataQuery = {
      title: this.capTitle.trim(),
      isbn: this.capIsbn.trim(),
      authors: this.splitAuthors(),
      publisher: this.capPublisher.trim(),
    };
    if (this.capKind === 'metadata') {
      AdminPluginsApi.searchMetadata(pluginKey, query).then((rsp) => {
        this.capBusy = false;
        if (rsp.err !== undefined && rsp.err !== 'ok') {
          this.capError = this.messageOf(rsp.err, rsp.msg, '能力测试失败，请检查插件设置或稍后重试。');
          return;
        }
        const items: AdminMetadataSummary[] = rsp.items ?? [];
        const lines: string[] = [];
        for (let i = 0; i < items.length; i++) {
          lines.push(this.metadataLine(items[i]));
        }
        this.capItems = lines;
        this.capSubmitted = true;
        if (items.length === 0) {
          this.capError = '协议调用成功，但没有返回匹配结果。';
        }
      }).catch((e: Object) => {
        this.capBusy = false;
        this.capError = `能力测试失败：${e}`;
      });
      return;
    }
    AdminPluginsApi.lookupReviews(pluginKey, query).then((rsp) => {
      this.capBusy = false;
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.capError = this.messageOf(rsp.err, rsp.msg, '能力测试失败，请检查插件设置或稍后重试。');
        return;
      }
      const items: AdminReviewSummary[] = rsp.items ?? [];
      const lines: string[] = [];
      for (let i = 0; i < items.length; i++) {
        lines.push(this.reviewLine(items[i]));
      }
      this.capItems = lines;
      this.capSubmitted = true;
      if (items.length === 0) {
        this.capError = '协议调用成功，但没有返回匹配结果。';
      }
    }).catch((e: Object) => {
      this.capBusy = false;
      this.capError = `能力测试失败：${e}`;
    });
  }

  private splitAuthors(): string[] {
    const result: string[] = [];
    const parts: string[] = this.capAuthors.split(',');
    for (let i = 0; i < parts.length; i++) {
      const name: string = parts[i].trim();
      if (name.length > 0) {
        result.push(name);
      }
    }
    return result;
  }

  private metadataLine(item: AdminMetadataSummary): string {
    const parts: string[] = [this.textValue(item.title, '—')];
    const authors: string[] = item.authors ?? [];
    if (authors.length > 0) {
      parts.push(authors.join('、'));
    }
    if (item.publisher !== undefined && item.publisher.length > 0) {
      parts.push(item.publisher);
    }
    if (item.isbn !== undefined && item.isbn.length > 0) {
      parts.push(item.isbn);
    }
    return parts.join(' · ');
  }

  private sourceLine(item: AdminSourceSummary): string {
    const parts: string[] = [this.textValue(item.title, '—')];
    const authors: string = this.textValue(item.authors, '');
    if (authors.length > 0) {
      parts.push(authors);
    }
    const format: string = this.textValue(item.format, '');
    if (format.length > 0) {
      parts.push(format);
    }
    const access: string = this.textValue(item.access, '');
    if (access.length > 0) {
      parts.push(access);
    }
    const license: string = this.textValue(item.license, '');
    if (license.length > 0) {
      parts.push(license);
    }
    return parts.join(' · ');
  }

  private reviewLine(item: AdminReviewSummary): string {
    const parts: string[] = [this.textValue(item.source, '—')];
    const rating: Record<string, Object> | undefined = item.rating as Record<string, Object>;
    if (rating !== undefined) {
      const value: Object | undefined = rating['value'];
      if (value !== undefined) {
        parts.push(`评分 ${String(value)} / ${this.textValue(rating['scale'], '—')}`
          + `（${this.textValue(rating['sample_count'], '0')} 人）`);
      }
    }
    const summary: string = this.textValue(item.summary, '');
    if (summary.length > 0) {
      parts.push(summary);
    }
    return parts.join(' · ');
  }

  // ---- 详情页的连接配置表单 ----

  private configFields(): PluginConfigField[] {
    return this.schemaFields(this.detailDef().config_schema);
  }

  private credentialFields(): PluginConfigField[] {
    return this.schemaFields(this.detailDef().auth_schema);
  }

  private connTextValue(key: string): string {
    const value: string | undefined = this.connText[key];
    return value !== undefined ? value : '';
  }

  private connTextOf(record: Record<string, Object> | undefined, key: string): string {
    if (record === undefined) {
      return '';
    }
    const value: Object | undefined = record[key];
    if (value === undefined || value === null) {
      return '';
    }
    if (Array.isArray(value)) {
      const list: string[] = value as string[];
      return list.join(', ');
    }
    return String(value);
  }

  private setConnBool(key: string, value: boolean): void {
    const next: Record<string, boolean> = {};
    const keys: string[] = Object.keys(this.connBool);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.connBool[keys[i]];
    }
    next[key] = value;
    this.connBool = next;
  }

  private setConnText(key: string, value: string): void {
    this.connText[key] = value;
  }

  private openConnForm(): void {
    const def: AdminPluginDefinition = this.detailDef();
    const conn: AdminPluginConnection | undefined = this.connectionFor(def);
    const text: Record<string, string> = {};
    const bool: Record<string, boolean> = {};
    const fields: PluginConfigField[] = this.configFields();
    for (let i = 0; i < fields.length; i++) {
      const field: PluginConfigField = fields[i];
      const existing: Object | undefined = conn !== undefined && conn.config !== undefined
        ? conn.config[field.key] : undefined;
      if (field.type === 'boolean') {
        bool[field.key] = existing === true;
      } else if (field.isArray) {
        text[field.key] = this.connTextOf(conn !== undefined ? conn.config : undefined, field.key);
      } else {
        text[field.key] = this.connTextOf(conn !== undefined ? conn.config : undefined, field.key);
      }
    }
    const credentials: PluginConfigField[] = this.credentialFields();
    for (let i = 0; i < credentials.length; i++) {
      text[credentials[i].key] = '';
    }
    this.connText = text;
    this.connBool = bool;
    const connName: string = conn !== undefined && conn.name !== undefined && conn.name.length > 0
      ? conn.name : this.definitionTitle(def);
    this.connName = connName;
    this.connFormOpen = true;
  }

  private saveConnection(): void {
    const installationId: number = this.detailInstallationId();
    if (installationId <= 0) {
      this.toast('插件尚未安装，无法保存连接');
      return;
    }
    if (this.connBusy) {
      return;
    }
    const def: AdminPluginDefinition = this.detailDef();
    const config: Record<string, Object> = {};
    const fields: PluginConfigField[] = this.configFields();
    for (let i = 0; i < fields.length; i++) {
      const field: PluginConfigField = fields[i];
      if (field.type === 'boolean') {
        config[field.key] = this.connBool[field.key] === true;
        continue;
      }
      const raw: string = this.connTextValue(field.key);
      if (field.isArray) {
        const list: string[] = [];
        const parts: string[] = raw.split(',');
        for (let j = 0; j < parts.length; j++) {
          const item: string = parts[j].trim();
          if (item.length > 0) {
            list.push(item);
          }
        }
        config[field.key] = list;
        continue;
      }
      const value: string = raw.trim();
      if (field.required && value.length === 0) {
        this.toast(`请填写：${field.title}`);
        return;
      }
      config[field.key] = value;
    }
    const credentials: Record<string, Object> = {};
    const conn: AdminPluginConnection | undefined = this.connectionFor(def);
    const credentialFields: PluginConfigField[] = this.credentialFields();
    for (let i = 0; i < credentialFields.length; i++) {
      const field: PluginConfigField = credentialFields[i];
      const value: string = this.connTextValue(field.key).trim();
      if (value.length > 0) {
        credentials[field.key] = value;
        continue;
      }
      const secret: AdminPluginSecret | undefined = conn !== undefined ? conn.secret : undefined;
      if (field.required && (secret === undefined || secret.configured !== true)) {
        this.toast(`请填写：${field.title}`);
        return;
      }
    }
    const role: string = conn !== undefined && conn.role !== undefined && conn.role.length > 0
      ? conn.role : 'default';
    const payload: AdminPluginConnectionPayload = {
      installation_id: installationId,
      name: this.connName,
      role: role,
      config: config,
    };
    if (Object.keys(credentials).length > 0) {
      payload.credentials = credentials;
    }
    this.connBusy = true;
    AdminPluginsApi.saveConnection(payload).then((rsp) => {
      this.connBusy = false;
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(this.messageOf(rsp.err, rsp.msg, '连接保存失败'));
        return;
      }
      this.toast('连接已保存。');
      this.connFormOpen = false;
      void this.loadConnections();
    }).catch((e: Object) => {
      this.connBusy = false;
      this.toast(`连接保存失败：${e}`);
    });
  }

  private detailConfigActionLabel(): string {
    return this.supportsInstanceConnection(this.detailDef()) ? '全局配置' : '个人设置';
  }

  private detailSecretConfigured(): boolean {
    const conn: AdminPluginConnection | undefined = this.connectionFor(this.detailDef());
    return conn !== undefined && conn.secret !== undefined && conn.secret.configured === true;
  }

  private configPlaceholder(field: PluginConfigField): string {
    const suffix: string = field.required ? '（必填）' : '';
    if (field.isArray) {
      return `${field.title}${suffix} · 多个值用逗号分隔`;
    }
    if (field.format === 'uri') {
      return `${field.title}${suffix} · URL`;
    }
    return `${field.title}${suffix}`;
  }

  private credentialPlaceholder(field: PluginConfigField): string {
    const suffix: string = field.required ? '（必填）' : '';
    return this.detailSecretConfigured()
      ? `${field.title}${suffix} · 已保存，留空不变`
      : `${field.title}${suffix}`;
  }

  private credentialInputType(key: string): InputType {
    return key === 'username' ? InputType.Normal : InputType.Password;
  }

  private capabilityLabel(kind: string): string {
    if (kind === 'metadata') { return '检索元数据'; }
    if (kind === 'source') { return '搜索书源'; }
    if (kind === 'review') { return '查询评价'; }
    return '能力测试';
  }

  // ---- 全局元数据行为 / 全局设备（取值与保存） ----

  private openAutofillSheet(): void {
    this.sheetMode = SHEET_AUTOFILL;
    this.showSheet = true;
  }

  private availablePushTypes(): PluginPushType[] {
    const result: PluginPushType[] = [];
    const list: AdminPluginDefinition[] = this.catalog();
    for (let i = 0; i < list.length; i++) {
      const def: AdminPluginDefinition = list[i];
      if (this.pluginType(def) !== 'push') {
        continue;
      }
      const inst: AdminPluginInstallation | undefined = this.installationFor(this.pluginKeyOf(def));
      if (inst === undefined || inst.enabled !== true) {
        continue;
      }
      const deviceType: string = this.uiText(def, 'device_type');
      if (deviceType.length === 0) {
        continue;
      }
      result.push({
        name: def.name !== undefined && def.name.length > 0 ? def.name : this.pluginKeyOf(def),
        value: deviceType,
        defaultPort: this.uiNumber(def, 'default_port'),
      });
    }
    return result;
  }

  private openDeviceSheet(): void {
    const types: PluginPushType[] = this.availablePushTypes();
    this.devices = [];
    this.deviceError = types.length === 0 ? '请先启用至少一个「发送到设备」插件，再添加全局设备。' : '';
    this.sheetMode = SHEET_DEVICE;
    this.showSheet = true;
    AdminPluginsApi.getPreferences().then((rsp) => {
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.deviceError = this.messageOf(rsp.err, rsp.msg, '设备列表加载失败');
        return;
      }
      const raw: Array<Record<string, Object>> = rsp.devices ?? [];
      const list: PluginDevice[] = [];
      for (let i = 0; i < raw.length; i++) {
        const item: Record<string, Object> = raw[i];
        list.push({
          name: this.textValue(item['name'], ''),
          type: this.textValue(item['type'], ''),
          mailbox: this.textValue(item['mailbox'], ''),
          ip: this.textValue(item['ip'], ''),
          port: this.textValue(item['port'], ''),
          schema: this.textValue(item['schema'], 'http'),
        });
      }
      this.devices = list;
    }).catch((e: Object) => {
      this.deviceError = `设备列表加载失败：${e}`;
    });
  }

  private addDevice(): void {
    const types: PluginPushType[] = this.availablePushTypes();
    if (types.length === 0) {
      this.deviceError = '请先启用至少一个「发送到设备」插件，再添加全局设备。';
      return;
    }
    const first: PluginPushType = types[0];
    const device: PluginDevice = {
      name: first.name,
      type: first.value,
      mailbox: '',
      ip: '',
      port: `${first.defaultPort > 0 ? first.defaultPort : 12121}`,
      schema: 'http',
    };
    this.devices.push(device);
    this.devices = this.devices.slice();
    this.deviceError = '';
  }

  private removeDevice(index: number): void {
    const next: PluginDevice[] = [];
    for (let i = 0; i < this.devices.length; i++) {
      if (i !== index) {
        next.push(this.devices[i]);
      }
    }
    this.devices = next;
  }

  private setDeviceName(index: number, value: string): void {
    this.devices[index].name = value;
  }

  private setDeviceType(index: number, value: string): void {
    this.devices[index].type = value;
    const types: PluginPushType[] = this.availablePushTypes();
    for (let i = 0; i < types.length; i++) {
      if (types[i].value === value && types[i].defaultPort > 0) {
        this.devices[index].port = `${types[i].defaultPort}`;
      }
    }
  }

  private setDeviceField(index: number, field: string, value: string): void {
    if (field === 'mailbox') { this.devices[index].mailbox = value; }
    else if (field === 'ip') { this.devices[index].ip = value; }
    else if (field === 'port') { this.devices[index].port = value; }
    else if (field === 'schema') { this.devices[index].schema = value; }
  }

  private saveDevices(): void {
    if (this.deviceBusy) {
      return;
    }
    const payloadDevices: Array<Record<string, Object>> = [];
    for (let i = 0; i < this.devices.length; i++) {
      const device: PluginDevice = this.devices[i];
      const name: string = device.name.trim();
      if (name.length === 0 || name.length > 64) {
        this.deviceError = '设备名称必填且不超过 64 个字符。';
        return;
      }
      if (device.type.length === 0) {
        this.deviceError = '请选择设备类型。';
        return;
      }
      if (device.type === 'kindle') {
        payloadDevices.push({ 'name': name, 'type': device.type, 'mailbox': device.mailbox.trim() });
        continue;
      }
      const port: number = Number(device.port.trim());
      if (!(port > 0 && port <= 65535)) {
        this.deviceError = '端口需在 1-65535 之间。';
        return;
      }
      payloadDevices.push({
        'name': name,
        'type': device.type,
        'ip': device.ip.trim(),
        'port': port,
        'schema': device.schema === 'https' ? 'https' : 'http',
      });
    }
    const payload: AdminPluginPreferencesPayload = { devices: payloadDevices };
    this.deviceBusy = true;
    this.deviceError = '';
    AdminPluginsApi.savePreferences(payload).then((rsp) => {
      this.deviceBusy = false;
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.deviceError = this.messageOf(rsp.err, rsp.msg, '保存失败，请重试。');
        return;
      }
      this.toast('插件中心设置已保存。');
      this.showSheet = false;
    }).catch((e: Object) => {
      this.deviceBusy = false;
      this.deviceError = `保存失败：${e}`;
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
      height: this.sheetHeight(),
      dragBar: true,
      showClose: true,
      title: { title: this.sheetTitle() },
      onDisappear: () => {
        this.onSheetClosed();
      },
    });
  }

  @Builder
  sheetContent() {
    if (this.sheetMode === SHEET_AUTOFILL) {
      this.autofillSheet();
    } else if (this.sheetMode === SHEET_DEVICE) {
      this.deviceSheet();
    } else {
      this.detailSheet();
    }
  }

  @Builder
  headerAction() {
    Text('执行记录')
      .fontSize(14)
      .fontColor($r('app.color.brand_primary'))
      .padding({ left: 8, right: 8 })
      .onClick(() => this.onTabChange(2));
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
            { label: '执行记录', value: 2 },
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
  sectionHeader(title: string) {
    Row({ space: 8 }) {
      Column()
        .width(4)
        .height(16)
        .borderRadius(2)
        .backgroundColor($r('app.color.brand_primary'));
      Text(title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1);
    }
    .width('100%')
    .padding({ top: 12, bottom: 8 });
  }

  @Builder
  hintText(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding(12)
      .borderRadius(8)
      .backgroundColor($r('app.color.page_background'));
  }

  @Builder
  pluginTab() {
    // 状态摘要（对齐上游 summary 三个计数）
    Row({ space: 16 }) {
      Text(`内置插件 ${this.catalog().length}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
      Text(`可用 ${this.enabledCount()}`)
        .fontSize(12)
        .fontColor($r('app.color.success'));
      Text(`需处理 ${this.attentionCount()}`)
        .fontSize(12)
        .fontColor($r('app.color.warning'));
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 4 });

    Text('内置插件无需安装，启用后即可使用；账号与密钥由各用户自行配置。')
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: 4, right: 4 });

    SearchBar({
      placeholder: '搜索名称、说明或能力',
      keyword: $search,
      onSearch: () => {},
    });

    FilterChips({
      items: [
        { label: '全部', value: FILTER_ALL },
        { label: '需处理', value: FILTER_ATTENTION },
        { label: '已启用', value: FILTER_ENABLED },
        { label: '未启用', value: FILTER_DISABLED },
      ] as FilterChipItem[],
      selected: $statusFilter,
      onChange: () => {},
    });

    if (this.filteredPlugins().length === 0) {
      Text('没有符合条件的插件')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ top: 24, bottom: 8 });
      TextButton({
        label: '清除筛选',
        onTap: () => {
          this.search = '';
          this.statusFilter = FILTER_ALL;
        },
      });
    } else {
      ForEach(this.groupedPlugins(), (group: PluginGroup) => {
        this.pluginGroupSection(group);
      }, (group: PluginGroup) => `group-${group.type}`);
    }
  }

  @Builder
  pluginGroupSection(group: PluginGroup) {
    Row({ space: 8 }) {
      SymbolGlyph(this.groupGlyph(group.type))
        .fontSize(16)
        .fontColor([$r('app.color.brand_primary')]);
      Text(group.label)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1);
      Text(`${group.plugins.length}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
      if (group.type === 'meta') {
        Text('自动补全设置')
          .fontSize(13)
          .fontColor($r('app.color.brand_primary'))
          .padding({ left: 4, right: 4 })
          .onClick(() => this.openAutofillSheet());
      }
      if (group.type === 'push') {
        Text('全局设备')
          .fontSize(13)
          .fontColor($r('app.color.brand_primary'))
          .padding({ left: 4, right: 4 })
          .onClick(() => this.openDeviceSheet());
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 4 });

    Text(group.description)
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ bottom: 8 });

    Column() {
      ForEach(group.plugins, (def: AdminPluginDefinition) => {
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
    Row({ space: 12 }) {
      // 分类色底 + 分类系统符号（上游用品牌图标，这里按分类取符号以免额外的图片依赖）
      Stack() {
        Circle()
          .width(36)
          .height(36)
          .fill($r('app.color.brand_primary_light'));
        SymbolGlyph(this.groupGlyph(this.pluginType(def)))
          .fontSize(18)
          .fontColor([$r('app.color.brand_primary')]);
      }

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(this.definitionTitle(def))
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
          Text(this.statusLabel(def))
            .fontSize(11)
            .fontColor(this.statusColor(def))
            .backgroundColor(this.statusBackground(def))
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        }
        .width('100%');

        Text(this.definitionSubtitle(def))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        Text(def.description !== undefined && def.description.length > 0 ? def.description : '（无描述）')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');

        Row({ space: 12 }) {
          Text(this.installationSubtitle(this.installationFor(this.pluginKeyOf(def))))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1);
          if (this.installationFor(this.pluginKeyOf(def)) !== undefined) {
            Toggle({ type: ToggleType.Switch, isOn: this.installationToggle(this.pluginKeyOf(def)) })
              .onChange((value: boolean) => {
                this.setInstallationEnabled(this.pluginKeyOf(def), value);
              });
          } else {
            TextButton({
              label: '安装',
              onTap: () => {
                this.installPlugin(this.pluginKeyOf(def));
              },
            });
          }
          TextButton({
            label: '详情',
            onTap: () => {
              this.openDetails(def);
            },
          });
        }
        .width('100%');
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding($r('app.float.page_padding'))
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.openDetails(def));
  }

  // ---- 插件详情 ----

  @Builder
  detailSheet() {
    Scroll() {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text(this.detailTitle())
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%');
            Text(this.detailSubtitle())
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%');
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);

          if (this.detailInstallationId() > 0) {
            TextButton({
              label: this.detailEnabled() ? '停用' : '启用',
              onTap: () => this.toggleDetailInstallation(),
            });
          }
        }
        .width('100%');

        Text(this.detailDescription())
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        if (this.uiText(this.detailDef(), 'catalog_access').length > 0) {
          this.hintText(this.detailCatalogNotice());
        }
        if (this.uiFlag(this.detailDef(), 'deprecated')) {
          this.hintText('该插件已被上游标记为废弃，建议改用替代插件。');
        }

        if (this.detailHasServiceToggle()) {
          this.sectionHeader('Talebook OPDS 服务');
          Text('向 OPDS 客户端发布当前书库；只影响 Talebook 的 OPDS 访问，不影响从外部 OPDS 书源导入。')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%');
          Column() {
            SettingCell({
              title: '启用 OPDS 服务',
              subtitle: this.opdsServiceEnabled ? '已开启' : '已关闭',
              showToggle: true,
              toggleOn: this.opdsServiceEnabled,
              onToggle: () => this.toggleOpdsService(),
            });
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));
        }

        if (this.detailHasConnectionProblem()) {
          this.hintText(`${this.detailHealthLabel()}${this.detailHealthMessage().length > 0
            ? `：${this.detailHealthMessage()}` : ''}`);
        } else if (this.pluginNeedsConfiguration(this.detailDef())
          && !this.connectionConfigured(this.detailDef(), this.connectionFor(this.detailDef()))) {
          this.hintText('完成所需设置后才能使用此插件。');
        }

        if (this.hasConfigurationUi(this.detailDef())) {
          this.sectionHeader('设置');
          this.configurationSection();
        }

        if (this.detailCapabilityKinds().length > 0) {
          this.capabilitySection();
        }

        if (this.detailPermissions().length > 0) {
          this.sectionHeader(`权限与数据范围（${this.detailPermissions().length}）`);
          Column() {
            ForEach(this.detailPermissions(), (permission: string) => {
              Text(permission)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding($r('app.float.page_padding'));
            }, (permission: string) => `perm-${permission}`);
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));
        }

        this.sectionHeader('最近执行');
        if (this.detailRuns().length === 0) {
          Text('还没有执行记录')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%');
        } else {
          Column() {
            ForEach(this.detailRuns(), (run: AdminPluginRun) => {
              Text(this.runTitle(run))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding($r('app.float.page_padding'));
            }, (run: AdminPluginRun) => `detail-run-${run.id ?? 0}`);
          }
          .width('100%')
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, bottom: 24 });
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top);
  }

  @Builder
  configurationSection() {
    // 插件声明了服务端自己的管理入口时，App 内只能提示入口位置
    if (this.uiText(this.detailDef(), 'manage_route').length > 0) {
      this.hintText(`该插件在服务端页面 ${this.uiText(this.detailDef(), 'manage_route')} 中配置。`);
    }

    if (this.pluginNeedsConfiguration(this.detailDef())) {
      if (this.connFormOpen) {
        this.connectionForm();
      } else {
        SecondaryButton({
          label: this.detailConfigActionLabel(),
          buttonEnabled: !this.connBusy,
          onTap: () => this.openConnForm(),
        });
      }
    }
  }

  @Builder
  connectionForm() {
    Column({ space: 8 }) {
      Text('连接名称')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      TextInput({ placeholder: '连接名称', text: this.connName })
        .height($r('app.float.button_height_compact'))
        .onChange((value: string) => {
          this.connName = value;
        });

      ForEach(this.configFields(), (field: PluginConfigField) => {
        this.configFieldRow(field);
      }, (field: PluginConfigField) => `cfg-${field.key}`);

      ForEach(this.credentialFields(), (field: PluginConfigField) => {
        TextInput({ placeholder: this.credentialPlaceholder(field), text: this.connTextValue(field.key) })
          .type(this.credentialInputType(field.key))
          .height($r('app.float.button_height_compact'))
          .onChange((value: string) => {
            this.setConnText(field.key, value);
          });
      }, (field: PluginConfigField) => `cred-${field.key}`);

      Row({ space: 12 }) {
        SecondaryButton({
          label: '取消',
          fullWidth: false,
          compact: true,
          onTap: () => {
            this.connFormOpen = false;
          },
        }).layoutWeight(1);
        PrimaryButton({
          label: '保存连接',
          buttonEnabled: !this.connBusy,
          fullWidth: false,
          onTap: () => this.saveConnection(),
        }).layoutWeight(1);
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  configFieldRow(field: PluginConfigField) {
    if (field.type === 'boolean') {
      Row({ space: 8 }) {
        Text(field.title)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Toggle({ type: ToggleType.Switch, isOn: this.connBool[field.key] === true })
          .onChange((value: boolean) => {
            this.setConnBool(field.key, value);
          });
      }
      .width('100%');
    } else {
      TextInput({ placeholder: this.configPlaceholder(field), text: this.connTextValue(field.key) })
        .height($r('app.float.button_height_compact'))
        .onChange((value: string) => {
          this.setConnText(field.key, value);
        });
    }
  }

  @Builder
  capabilitySection() {
    this.sectionHeader('能力测试');
    Text('使用插件声明的协议直接验证实际查询结果。')
      .fontSize(12)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%');

    Row({ space: 8 }) {
      ForEach(this.detailCapabilityKinds(), (kind: string) => {
        ChipButton({
          label: this.capabilityLabel(kind),
          selected: this.capKind === kind,
          onTap: () => {
            this.capKind = kind;
            this.capItems = [];
            this.capError = '';
            this.capSubmitted = false;
          },
        });
      }, (kind: string) => `cap-${kind}`);
      Blank().layoutWeight(1);
    }
    .width('100%');

    if (this.capKind === 'source') {
      TextInput({ placeholder: '搜索关键词', text: this.capKeyword })
        .height($r('app.float.button_height_compact'))
        .onChange((value: string) => {
          this.capKeyword = value;
        });
    } else {
      Row({ space: 8 }) {
        TextInput({ placeholder: '书名', text: this.capTitle })
          .height($r('app.float.button_height_compact'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.capTitle = value;
          });
        TextInput({ placeholder: 'ISBN', text: this.capIsbn })
          .height($r('app.float.button_height_compact'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.capIsbn = value;
          });
      }
      .width('100%');

      Row({ space: 8 }) {
        TextInput({ placeholder: '作者（逗号分隔）', text: this.capAuthors })
          .height($r('app.float.button_height_compact'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.capAuthors = value;
          });
        TextInput({ placeholder: '出版社', text: this.capPublisher })
          .height($r('app.float.button_height_compact'))
          .layoutWeight(1)
          .onChange((value: string) => {
            this.capPublisher = value;
          });
      }
      .width('100%');
    }

    PrimaryButton({
      label: this.capabilityLabel(this.capKind),
      buttonEnabled: !this.capBusy,
      fullWidth: false,
      onTap: () => this.runCapabilityTest(),
    });

    if (this.capError.length > 0) {
      this.hintText(this.capError);
    }
    if (this.capSubmitted) {
      Text(`返回 ${this.capItems.length} 条结果`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
      Column() {
        ForEach(this.capItems, (line: string) => {
          Text(line)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding($r('app.float.page_padding'));
        }, (line: string, index: number) => `cap-item-${index}`);
      }
      .width('100%')
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));
    }
  }

  // ---- 全局元数据行为 / 全局设备 ----

  @Builder
  autofillSheet() {
    Scroll() {
      Column({ space: 8 }) {
        Text('启用哪些元数据来源由「元数据」分组中各插件的状态决定；'
          + '这里只控制新书是否自动补全以及是否保留原封面。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
        Column() {
          SettingCell({
            title: '自动补全元数据',
            subtitle: '导入/入库后自动向已启用的元数据插件查询',
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
            subtitle: this.autoFillMeta ? '' : '需先开启自动补全',
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
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, bottom: 24 });
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top);
  }

  @Builder
  deviceSheet() {
    Scroll() {
      Column({ space: 8 }) {
        Text('这些共享设备对所有用户可见。可添加的设备类型只取自当前已启用的「发送到设备」插件。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');

        if (this.devices.length === 0) {
          Text('还没有全局设备')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ top: 12, bottom: 12 });
        } else {
          ForEach(this.devices, (device: PluginDevice, index: number) => {
            this.deviceCard(device, index);
          }, (device: PluginDevice, index: number) => `device-${index}`);
        }

        SecondaryButton({
          label: '添加全局设备',
          fullWidth: false,
          compact: true,
          onTap: () => this.addDevice(),
        });

        if (this.deviceError.length > 0) {
          this.hintText(this.deviceError);
        }

        Row({ space: 12 }) {
          SecondaryButton({
            label: '关闭',
            fullWidth: false,
            compact: true,
            onTap: () => {
              this.showSheet = false;
            },
          }).layoutWeight(1);
          PrimaryButton({
            label: '保存设备',
            buttonEnabled: !this.deviceBusy,
            fullWidth: false,
            onTap: () => this.saveDevices(),
          }).layoutWeight(1);
        }
        .width('100%');
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, bottom: 24 });
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top);
  }

  @Builder
  deviceCard(device: PluginDevice, index: number) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(device.type.length > 0 ? device.type : '未选择类型')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        TextButton({
          label: '删除',
          tone: 'danger',
          onTap: () => this.removeDevice(index),
        });
      }
      .width('100%');

      TextInput({ placeholder: '设备名称', text: device.name })
        .height($r('app.float.button_height_compact'))
        .onChange((value: string) => this.setDeviceName(index, value));

      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.availablePushTypes(), (pushType: PluginPushType) => {
            ChipButton({
              label: pushType.name,
              selected: device.type === pushType.value,
              onTap: () => this.setDeviceType(index, pushType.value),
            });
          }, (pushType: PluginPushType) => `dt-${index}-${pushType.value}`);
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%');

      if (device.type === 'kindle') {
        TextInput({ placeholder: '接收邮箱', text: device.mailbox })
          .height($r('app.float.button_height_compact'))
          .onChange((value: string) => this.setDeviceField(index, 'mailbox', value));
      } else {
        Row({ space: 8 }) {
          TextInput({ placeholder: 'IP / 主机', text: device.ip })
            .height($r('app.float.button_height_compact'))
            .layoutWeight(2)
            .onChange((value: string) => this.setDeviceField(index, 'ip', value));
          TextInput({ placeholder: '端口', text: device.port })
            .type(InputType.Number)
            .height($r('app.float.button_height_compact'))
            .layoutWeight(1)
            .onChange((value: string) => this.setDeviceField(index, 'port', value));
        }
        .width('100%');

        Row({ space: 8 }) {
          ChipButton({
            label: 'http',
            selected: device.schema !== 'https',
            onTap: () => this.setDeviceField(index, 'schema', 'http'),
          });
          ChipButton({
            label: 'https',
            selected: device.schema === 'https',
            onTap: () => this.setDeviceField(index, 'schema', 'https'),
          });
          Blank().layoutWeight(1);
        }
        .width('100%');
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
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
    SectionTitle({ title: `执行记录（最近 ${this.runs.length} 条）`, actionLabel: '刷新',
      onAction: () => { void this.loadRuns(); } });
    if (this.runs.length === 0) {
      EmptyState({ message: '暂无执行记录' });
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
