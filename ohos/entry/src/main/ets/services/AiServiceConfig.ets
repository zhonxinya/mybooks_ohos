/**
 * AiService 配置持久化（拆分自 AiService.ets）：preferences 读写、按服务商 API Key、
 * 自定义服务商清单、语音/权限/上下文等设置项。接口契约仍在 AiService.ets。
 */
import { OpenAI } from '@iuroc/openai';
import { rcp } from '@kit.RemoteCommunicationKit';
import { TalebookService } from './TalebookService';
import type { AiPermissionMode } from './AiTools';
import { McpService } from './McpService';
import type { AiProviderPreset, AiConfig, AiModelEntry } from './AiService';
import { AiServiceHttp } from './AiServiceHttp';

/** 模型库持久化键：值为 JSON 数组 `[{id,name,providerId,model}]`。 */
const MODEL_ENTRY_KEY: string = 'ai_model_entries';

export class AiServiceConfig {
  /** 读取当前配置（Key 只回传是否存在）。 */
  static loadConfig(): AiConfig {
    AiServiceConfig.migrateLegacyKey();
    const providerId: string = TalebookService.prefGet(KEY_PROVIDER, 'deepseek');
    const temperatureText: string = TalebookService.prefGet(KEY_TEMPERATURE);
    const temperature: number = temperatureText.length > 0 ? Number(temperatureText) : DEFAULT_TEMPERATURE;
    const finalModel: string = AiServiceConfig.modelFor(providerId);
    const visionOverride: string = TalebookService.prefGet(KEY_VISION);
    const contextText: string = TalebookService.prefGet(KEY_CONTEXT);
    const contextK: number = contextText.length > 0 ? Number(contextText) : DEFAULT_CONTEXT_K;
    return {
      providerId: providerId,
      baseUrl: AiServiceConfig.baseUrlFor(providerId),
      model: finalModel,
      hasKey: TalebookService.secureGet(AiServiceConfig.apiKeyKey(providerId)).length > 0,
      temperature: Number.isFinite(temperature) ? temperature : DEFAULT_TEMPERATURE,
      vision: visionOverride === 'on' ? true :
        visionOverride === 'off' ? false : AiServiceConfig.detectVision(finalModel),
      visionOverride: visionOverride,
      contextLength: Number.isFinite(contextK) && contextK > 0 ? contextK : DEFAULT_CONTEXT_K,
    };
  }

  /** 按模型名猜是否支持图片：各家视觉模型命名都带特征词，猜错时用户可在设置里手动覆盖。 */
  static detectVision(model: string): boolean {
    return /vl|vision|4o|omni|gemini|claude|llava|qvq/i.test(model);
  }

  /** 上下文窗口（K tokens）→ 对话页携带的历史轮数（一轮=一问一答，另留 tools/图片开销）。 */
  static contextRounds(contextK: number): number {
    if (contextK <= 4) {
      return 4;
    }
    if (contextK <= 8) {
      return 8;
    }
    if (contextK <= 32) {
      return 16;
    }
    if (contextK <= 128) {
      return 30;
    }
    return 50;
  }

  /** 读权限模式（非法/未设置值一律回落为逐笔确认）。 */
  static loadPermission(): AiPermissionMode {
    const raw: string = TalebookService.prefGet(KEY_PERMISSION, 'confirm');
    if (raw === 'readonly' || raw === 'auto') {
      return raw;
    }
    return 'confirm';
  }

  static savePermission(mode: AiPermissionMode): void {
    TalebookService.prefSet(KEY_PERMISSION, mode);
  }

  static loadAutoSpeak(): boolean {
    return TalebookService.prefGet(KEY_AUTO_SPEAK, '0') === '1';
  }

  static saveAutoSpeak(on: boolean): void {
    TalebookService.prefSet(KEY_AUTO_SPEAK, on ? '1' : '0');
  }

  // ———— 功能专属模型槽：每个 AI 功能可绑「服务商+模型」，留空走回退链 ————
  /** 功能槽目录（功能模型页数据源）。voice=旧语音档（通话轮转对话模型 + 音频网关兜底）。 */
  static readonly FEATURES: string[] = ['vision', 'summary', 'voice', 'tts', 'asr', 'realtime'];

  /** 回退父档：音频三件未绑时退语音档，语音档再退全局；其余直接退全局。 */
  private static featureParent(feature: string): string {
    return feature === 'tts' || feature === 'asr' || feature === 'realtime' ? 'voice' : '';
  }

  private static featureProviderKey(feature: string): string {
    return `ai_${feature}_provider`;
  }

  private static featureModelKey(feature: string): string {
    return `ai_${feature}_model`;
  }

  /**
   * 功能档位配置：未绑服务商（provider 键空）= 跟随回退父档直至全局；
   * 绑了就**完全独立解析**——与全局同服务商时也用自己的 model 与地址。
   * 'voice' 即旧语音档，键名格式与历史常量一致，老配置零迁移。
   */
  static loadFeatureConfig(feature: string): AiConfig {
    const providerId: string = TalebookService.prefGet(AiServiceConfig.featureProviderKey(feature));
    if (providerId.length === 0) {
      const parent: string = AiServiceConfig.featureParent(feature);
      return parent.length > 0 ? AiServiceConfig.loadFeatureConfig(parent) : AiServiceConfig.loadConfig();
    }
    const config: AiConfig = AiServiceConfig.loadConfig();
    const preset: AiProviderPreset = AiServiceConfig.presetOf(providerId);
    const model: string = TalebookService.prefGet(AiServiceConfig.featureModelKey(feature));
    const finalModel: string = model.length > 0 ? model : preset.model;
    return {
      providerId: providerId,
      baseUrl: AiServiceConfig.baseUrlFor(providerId),
      model: finalModel,
      hasKey: TalebookService.secureGet(AiServiceConfig.apiKeyKey(providerId)).length > 0,
      temperature: config.temperature,
      vision: AiServiceConfig.detectVision(finalModel),
      visionOverride: '',
      contextLength: config.contextLength,
    };
  }

  /** 功能是否已独立绑定服务商。 */
  static hasFeatureProvider(feature: string): boolean {
    return TalebookService.prefGet(AiServiceConfig.featureProviderKey(feature)).length > 0;
  }

  /** `providerId` 传空串 = 该功能恢复跟随。`model` 空 = 用该服务商默认模型。 */
  static saveFeatureConfig(feature: string, providerId: string, model: string): void {
    if (providerId.length === 0) {
      TalebookService.prefSet(AiServiceConfig.featureProviderKey(feature), '');
      TalebookService.prefSet(AiServiceConfig.featureModelKey(feature), '');
      return;
    }
    TalebookService.prefSet(AiServiceConfig.featureProviderKey(feature), providerId);
    TalebookService.prefSet(AiServiceConfig.featureModelKey(feature), model.trim());
  }

  /** 已保存的功能服务商 id（''=跟随）。 */
  static loadFeatureProviderId(feature: string): string {
    return TalebookService.prefGet(AiServiceConfig.featureProviderKey(feature));
  }

  /** 已保存的功能模型名（''=服务商默认；音频协议类功能空=协议固定模型）。 */
  static loadFeatureModel(feature: string): string {
    return TalebookService.prefGet(AiServiceConfig.featureModelKey(feature));
  }

  // ———— 模型库：模型条目 = 名称 + 服务商 + 模型 id 的自由组合 ————
  /**
   * 功能槽改存库条目 id（`ai_<feature>_entry`）：选中条目即写 provider/model 两个旧键，
   * 消费链（loadFeatureConfig）无需改动；条目被改名/删除时旧键仍可用，只是摘要会显示未命名。
   */
  private static featureEntryKey(feature: string): string {
    return `ai_${feature}_entry`;
  }

  /** 已绑定的模型库条目 id（''=未用库条目，可能仍绑着旧的服务商+模型）。 */
  static loadFeatureEntry(feature: string): string {
    return TalebookService.prefGet(AiServiceConfig.featureEntryKey(feature));
  }

  /** 全部模型条目（模型库页与功能模型页共用）。 */
  static listModelEntries(): AiModelEntry[] {
    const raw: string = TalebookService.prefGet(MODEL_ENTRY_KEY);
    if (raw.length === 0) {
      return [];
    }
    const out: AiModelEntry[] = [];
    try {
      const list: Object[] = JSON.parse(raw) as Object[];
      for (let i = 0; i < list.length; i++) {
        const item: Object = list[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = item as Record<string, Object>;
        const id: Object | undefined = rec['id'];
        const name: Object | undefined = rec['name'];
        const providerId: Object | undefined = rec['providerId'];
        const model: Object | undefined = rec['model'];
        if (typeof id !== 'string' || id.length === 0 || typeof providerId !== 'string' ||
          providerId.length === 0) {
          continue;
        }
        out.push({
          id: id,
          name: typeof name === 'string' && name.length > 0 ? name : providerId,
          providerId: providerId,
          model: typeof model === 'string' ? model : '',
        });
      }
    } catch (_error) {
      // 存储损坏：当作空库
    }
    return out;
  }

  /** 新增条目；同名允许（用 id 区分），名称空则用「服务商·模型」兜底。 */
  static addModelEntry(name: string, providerId: string, model: string): AiModelEntry {
    if (providerId.trim().length === 0) {
      throw new Error('请选择服务商');
    }
    const modelText: string = model.trim();
    const preset: AiProviderPreset = AiServiceConfig.presetOf(providerId);
    const entry: AiModelEntry = {
      id: `m${Date.now()}${Math.floor(Math.random() * 1000)}`,
      name: name.trim().length > 0 ? name.trim() :
        `${preset.name}${modelText.length > 0 ? ' · ' + modelText : ''}`,
      providerId: providerId,
      model: modelText,
    };
    const all: AiModelEntry[] = AiServiceConfig.listModelEntries();
    all.push(entry);
    AiServiceConfig.writeModelEntries(all);
    return entry;
  }

  /** 改条目（服务商/模型/名称都可改）；返回是否找到。 */
  static updateModelEntry(id: string, name: string, providerId: string, model: string): boolean {
    const all: AiModelEntry[] = AiServiceConfig.listModelEntries();
    let hit: boolean = false;
    for (let i = 0; i < all.length; i++) {
      if (all[i].id === id) {
        all[i].name = name.trim().length > 0 ? name.trim() : all[i].name;
        if (providerId.trim().length > 0) {
          all[i].providerId = providerId.trim();
        }
        all[i].model = model.trim();
        hit = true;
      }
    }
    if (hit) {
      AiServiceConfig.writeModelEntries(all);
    }
    return hit;
  }

  /** 删条目：引用它的功能槽退回「跟随」语义（清 provider/model/entry 三键）。 */
  static removeModelEntry(id: string): boolean {
    const all: AiModelEntry[] = AiServiceConfig.listModelEntries();
    const kept: AiModelEntry[] = [];
    let hit: boolean = false;
    for (let i = 0; i < all.length; i++) {
      if (all[i].id === id) {
        hit = true;
      } else {
        kept.push(all[i]);
      }
    }
    if (!hit) {
      return false;
    }
    AiServiceConfig.writeModelEntries(kept);
    for (let i = 0; i < AiServiceConfig.FEATURES.length; i++) {
      const feature: string = AiServiceConfig.FEATURES[i];
      if (AiServiceConfig.loadFeatureEntry(feature) === id) {
        AiServiceConfig.saveFeatureConfig(feature, '', '');
      }
    }
    return true;
  }

  /** 按 id 取条目（功能页回显用）；不存在返回 null。 */
  static modelEntryOf(id: string): AiModelEntry | null {
    const all: AiModelEntry[] = AiServiceConfig.listModelEntries();
    for (let i = 0; i < all.length; i++) {
      if (all[i].id === id) {
        return all[i];
      }
    }
    return null;
  }

  /** 功能绑定模型库条目：写 entry 键 + 同步 provider/model 旧键；id 空 = 恢复跟随。 */
  static bindFeatureEntry(feature: string, entryId: string): void {
    if (entryId.length === 0) {
      AiServiceConfig.saveFeatureConfig(feature, '', '');
      TalebookService.prefSet(AiServiceConfig.featureEntryKey(feature), '');
      return;
    }
    const entry: AiModelEntry | null = AiServiceConfig.modelEntryOf(entryId);
    if (entry === null) {
      return;
    }
    TalebookService.prefSet(AiServiceConfig.featureEntryKey(feature), entryId);
    TalebookService.prefSet(AiServiceConfig.featureProviderKey(feature), entry.providerId);
    TalebookService.prefSet(AiServiceConfig.featureModelKey(feature), entry.model);
  }

  private static writeModelEntries(entries: AiModelEntry[]): void {
    const items: Record<string, Object>[] = [];
    for (let i = 0; i < entries.length; i++) {
      const rec: Record<string, Object> = {
        'id': entries[i].id, 'name': entries[i].name,
        'providerId': entries[i].providerId, 'model': entries[i].model,
      };
      items.push(rec);
    }
    TalebookService.prefSet(MODEL_ENTRY_KEY, JSON.stringify(items));
  }

  // ———— 语音档兼容层（历史 API，转委托功能槽） ————

  /** 语音档位配置：同 loadFeatureConfig('voice')。 */
  static loadVoiceConfig(): AiConfig {
    return AiServiceConfig.loadFeatureConfig('voice');
  }

  /** 语音通话是否已独立配置了服务商。 */
  static hasVoiceProvider(): boolean {
    return AiServiceConfig.hasFeatureProvider('voice');
  }

  /** `providerId` 传空串 = 恢复跟随全局。`model` 空 = 用该服务商默认模型。 */
  static saveVoiceConfig(providerId: string, model: string): void {
    AiServiceConfig.saveFeatureConfig('voice', providerId, model);
  }

  /** 已保存的语音通话服务商 id（''=跟随全局）。 */
  static loadVoiceProviderId(): string {
    return AiServiceConfig.loadFeatureProviderId('voice');
  }

  /** 已保存的语音通话模型名（''=用服务商默认）。 */
  static loadVoiceModel(): string {
    return AiServiceConfig.loadFeatureModel('voice');
  }

  /** realtime 通话音色（池与校验在 AiVoiceKit；此处只管存取，空=默认 longanqian）。 */
  static loadRealtimeTimbre(): string {
    const v: string = TalebookService.prefGet(KEY_REALTIME_TIMBRE);
    return v.length > 0 ? v : 'longanqian';
  }

  static saveRealtimeTimbre(voice: string): void {
    TalebookService.prefSet(KEY_REALTIME_TIMBRE, voice);
  }

  /** 思考强度档位：'default'（跟随模型默认，请求体不发字段）/'low'/'medium'/'high'。 */
  static loadReasoningEffort(): string {
    const v: string = TalebookService.prefGet(KEY_REASONING_EFFORT);
    return v.length > 0 ? v : 'default';
  }

  static saveReasoningEffort(effort: string): void {
    TalebookService.prefSet(KEY_REASONING_EFFORT, effort);
  }

  /** 播报 TTS 音色（空=默认 longanhuan_v3.6，实测可用音色）。 */
  static loadTtsTimbre(): string {
    const v: string = TalebookService.prefGet(KEY_TTS_TIMBRE);
    return v.length > 0 ? v : 'longanhuan_v3.6';
  }

  static saveTtsTimbre(voice: string): void {
    TalebookService.prefSet(KEY_TTS_TIMBRE, voice);
  }

  /** 播报引擎：'system'=系统语音（CoreSpeechKit，默认）、'cloud'=Token Plan 云端 TTS。 */
  static loadSpeakEngine(): string {
    return TalebookService.prefGet(KEY_SPEAK_ENGINE, 'system') === 'cloud' ? 'cloud' : 'system';
  }

  static saveSpeakEngine(engine: string): void {
    TalebookService.prefSet(KEY_SPEAK_ENGINE, engine === 'cloud' ? 'cloud' : 'system');
  }

  /** 通话模式：'realtime'=WS 全双工（默认，打断式）、'turn'=轮转（可用自选对话模型）。 */
  static loadCallMode(): string {
    return TalebookService.prefGet(KEY_CALL_MODE, 'realtime') === 'turn' ? 'turn' : 'realtime';
  }

  static saveCallMode(mode: string): void {
    TalebookService.prefSet(KEY_CALL_MODE, mode === 'turn' ? 'turn' : 'realtime');
  }

  /** 各服务商 Key 的存储键；自定义服务商 id 带时间戳，不与前缀冲突。 */
  static apiKeyKey(providerId: string): string {
    return KEY_API_KEY_PREFIX + providerId;
  }

  /** 各服务商接口地址的存储键（与 Key 同样按服务商分槽，互不覆盖）。 */
  static baseUrlKey(providerId: string): string {
    return KEY_BASE_URL_PREFIX + providerId;
  }

  /** 各服务商「上次使用模型」槽位：并行工作时每家记住自己的模型，切回不丢。 */
  static modelKey(providerId: string): string {
    return 'ai_model_' + providerId;
  }

  /** 指定服务商的模型：本槽存过用本槽，否则回落预设默认。 */
  static modelFor(providerId: string): string {
    AiServiceConfig.migrateLegacyModel();
    const saved: string = TalebookService.prefGet(AiServiceConfig.modelKey(providerId));
    return saved.length > 0 ? saved : AiServiceConfig.presetOf(providerId).model;
  }

  /** 旧版全局单槽模型一次性迁移：挪进当前服务商槽后清空。 */
  static migrateLegacyModel(): void {
    const legacy: string = TalebookService.prefGet(KEY_MODEL);
    if (legacy.length === 0) {
      return;
    }
    const providerId: string = TalebookService.prefGet(KEY_PROVIDER, 'deepseek');
    if (TalebookService.prefGet(AiServiceConfig.modelKey(providerId)).length === 0) {
      TalebookService.prefSet(AiServiceConfig.modelKey(providerId), legacy);
    }
    TalebookService.prefSet(KEY_MODEL, '');
  }

  /** 指定服务商的接口地址：本槽存过用本槽，否则回落预设（自定义商预设即注册地址）。 */
  static baseUrlFor(providerId: string): string {
    AiServiceConfig.migrateLegacyBaseUrl();
    const saved: string = TalebookService.secureGet(AiServiceConfig.baseUrlKey(providerId));
    return saved.length > 0 ? saved : AiServiceConfig.presetOf(providerId).baseUrl;
  }

  /** 旧版全局单槽地址一次性迁移：挪进当前所选服务商的槽位后清空。 */
  static migrateLegacyBaseUrl(): void {
    const legacy: string = TalebookService.secureGet(KEY_BASE_URL);
    if (legacy.length === 0) {
      return;
    }
    const providerId: string = TalebookService.prefGet(KEY_PROVIDER, 'deepseek');
    TalebookService.secureSet(AiServiceConfig.baseUrlKey(providerId), legacy);
    TalebookService.secureSet(KEY_BASE_URL, '');
  }

  /** 读取指定服务商的 API Key（未配置返回空串）。 */
  static apiKeyFor(providerId: string): string {
    AiServiceConfig.migrateLegacyKey();
    return TalebookService.secureGet(AiServiceConfig.apiKeyKey(providerId));
  }

  static hasKeyFor(providerId: string): boolean {
    return AiServiceConfig.apiKeyFor(providerId).length > 0;
  }

  /** 旧版单 Key 一次性迁移：挪进当前所选服务商的槽位后清空。 */
  static migrateLegacyKey(): void {
    const legacy: string = TalebookService.secureGet(KEY_API_KEY);
    if (legacy.length === 0) {
      return;
    }
    const providerId: string = TalebookService.prefGet(KEY_PROVIDER, 'deepseek');
    TalebookService.secureSet(AiServiceConfig.apiKeyKey(providerId), legacy);
    TalebookService.secureSet(KEY_API_KEY, '');
  }

  /** 本机添加的自定义服务商列表（JSON 落 preferences，坏条目丢弃）。 */
  static listCustomProviders(): AiProviderPreset[] {
    const out: AiProviderPreset[] = [];
    const raw: string = TalebookService.prefGet(KEY_CUSTOM_PROVIDERS);
    if (raw.length === 0) {
      return out;
    }
    let items: Object[];
    try {
      items = JSON.parse(raw) as Object[];
    } catch (_error) {
      return out;
    }
    for (let i = 0; i < items.length; i++) {
      const it = items[i] as Record<string, string>;
      const id: string | undefined = it['id'];
      const name: string | undefined = it['name'];
      const baseUrl: string | undefined = it['baseUrl'];
      const model: string | undefined = it['model'];
      if (id === undefined || name === undefined || id.length === 0 || name.length === 0) {
        continue;
      }
      out.push({
        id: id,
        name: name,
        baseUrl: baseUrl === undefined ? '' : baseUrl,
        model: model === undefined ? '' : model,
        vision: false,
      });
    }
    return out;
  }

  /** 全部可选服务商：预设 + 本机关加的自定义（含已停用，管理页数据源）。 */
  static listProviders(): AiProviderPreset[] {
    const out: AiProviderPreset[] = [];
    for (let i = 0; i < AI_PROVIDERS.length; i++) {
      out.push(AI_PROVIDERS[i]);
    }
    const custom: AiProviderPreset[] = AiServiceConfig.listCustomProviders();
    for (let i = 0; i < custom.length; i++) {
      out.push(custom[i]);
    }
    return out;
  }

  // ———— 每家服务商启停（并行管理页；默认=启用，老配置零变化） ————

  /** 停用标记键 `ai_provider_disabled_<id>`='1'。 */
  static disabledKey(providerId: string): string {
    return 'ai_provider_disabled_' + providerId;
  }

  static isProviderEnabled(providerId: string): boolean {
    return TalebookService.prefGet(AiServiceConfig.disabledKey(providerId)) !== '1';
  }

  /** 启停改动让 MCP 工具集缓存作废（网关按服务商现取配置，无需额外失效）。 */
  static setProviderEnabled(providerId: string, on: boolean): void {
    TalebookService.prefSet(AiServiceConfig.disabledKey(providerId), on ? '' : '1');
    McpService.reset();
  }

  /** 启用的服务商清单：chips / 功能模型页下拉 / 快切菜单数据源——停用的家不出现。 */
  static listEnabledProviders(): AiProviderPreset[] {
    const out: AiProviderPreset[] = [];
    const all: AiProviderPreset[] = AiServiceConfig.listProviders();
    for (let i = 0; i < all.length; i++) {
      if (AiServiceConfig.isProviderEnabled(all[i].id)) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /**
   * 编辑服务商自身资产（地址/模型/Key），**不动当前默认选择**——管理页用。
   * `apiKey` 传空串=保持已存值不变（占位「已保存，留空不修改」语义）。
   */
  static updateProviderProfile(providerId: string, baseUrl: string, model: string, apiKey: string): void {
    TalebookService.secureSet(AiServiceConfig.baseUrlKey(providerId), AiServiceHttp.normalizeBaseUrl(baseUrl));
    TalebookService.prefSet(AiServiceConfig.modelKey(providerId), model.trim());
    if (apiKey.length > 0) {
      TalebookService.secureSet(AiServiceConfig.apiKeyKey(providerId), apiKey.trim());
    }
    McpService.reset();
  }

  /** 设为对话默认服务商：只切选择；地址/模型/Key 各家分槽，切回即恢复。 */
  static setDefaultProvider(providerId: string): void {
    TalebookService.prefSet(KEY_PROVIDER, providerId);
    McpService.reset();
  }

  /** 添加一个本地自定义服务商并返回其预设。 */
  static addCustomProvider(name: string, baseUrl: string, model: string): AiProviderPreset {
    const trimmedName: string = name.trim();
    const base: string = AiServiceHttp.normalizeBaseUrl(baseUrl);
    if (trimmedName.length === 0 || base.length === 0) {
      throw new Error('服务商名称与接口地址不能为空');
    }
    const preset: AiProviderPreset = {
      id: `custom-${Date.now()}`,
      name: trimmedName,
      baseUrl: base,
      model: model.trim(),
      vision: false,
    };
    const list: AiProviderPreset[] = AiServiceConfig.listCustomProviders();
    list.push(preset);
    AiServiceConfig.saveCustomProviders(list);
    return preset;
  }

  /** 删除自定义服务商，连带清掉它保存的 Key。 */
  static removeCustomProvider(id: string): void {
    const list: AiProviderPreset[] = AiServiceConfig.listCustomProviders();
    const kept: AiProviderPreset[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        TalebookService.secureSet(AiServiceConfig.apiKeyKey(id), '');
        TalebookService.secureSet(AiServiceConfig.baseUrlKey(id), '');
      } else {
        kept.push(list[i]);
      }
    }
    AiServiceConfig.saveCustomProviders(kept);
  }

  static saveCustomProviders(list: AiProviderPreset[]): void {
    TalebookService.prefSet(KEY_CUSTOM_PROVIDERS, JSON.stringify(list));
  }

  /**
   * 本地常用模型清单（按服务商分开存）：设置页手动添加/拉取勾选写入，
   * 对话页顶栏快切菜单优先用它——免去每次现拉全量列表。
   */
  static loadProviderModels(providerId: string): string[] {
    const raw: string = TalebookService.prefGet(`${KEY_PROVIDER_MODELS_PREFIX}${providerId}`, '');
    if (raw.length === 0) {
      return [];
    }
    try {
      const arr: Object[] = JSON.parse(raw) as Object[];
      const out: string[] = [];
      for (let i = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string') {
          out.push(arr[i] as string);
        }
      }
      return out;
    } catch (_error) {
      return [];
    }
  }

  /** 覆盖保存某服务商的模型清单；空数组即清除该键。 */
  static saveProviderModels(providerId: string, models: string[]): void {
    TalebookService.prefSet(`${KEY_PROVIDER_MODELS_PREFIX}${providerId}`,
      models.length === 0 ? '' : JSON.stringify(models));
  }

  static presetOf(providerId: string): AiProviderPreset {
    const providers: AiProviderPreset[] = AiServiceConfig.listProviders();
    for (let i = 0; i < providers.length; i++) {
      if (providers[i].id === providerId) {
        return providers[i];
      }
    }
    return AI_PROVIDERS[AI_PROVIDERS.length - 1];
  }

  /** 保存配置。`apiKey` 传空串表示保持原值不变。 */
  static saveConfig(providerId: string, baseUrl: string, model: string, apiKey: string,
    temperature: number, visionOverride: string = '', contextLength: number = DEFAULT_CONTEXT_K): void {
    TalebookService.prefSet(KEY_PROVIDER, providerId);
    TalebookService.secureSet(AiServiceConfig.baseUrlKey(providerId), AiServiceHttp.normalizeBaseUrl(baseUrl));
    TalebookService.prefSet(AiServiceConfig.modelKey(providerId), model.trim());
    TalebookService.prefSet(KEY_TEMPERATURE, `${temperature}`);
    TalebookService.prefSet(KEY_VISION, visionOverride);
    TalebookService.prefSet(KEY_CONTEXT, `${contextLength}`);
    if (apiKey.length > 0) {
      TalebookService.secureSet(AiServiceConfig.apiKeyKey(providerId), apiKey.trim());
    }
    // 服务商/Key 变了：MCP 工具集与会话缓存作废，下次发送前重新握手
    McpService.reset();
  }

  static clearKey(): void {
    const providerId: string = TalebookService.prefGet(KEY_PROVIDER, 'deepseek');
    TalebookService.secureSet(AiServiceConfig.apiKeyKey(providerId), '');
    TalebookService.secureSet(KEY_API_KEY, '');
  }

  /** 是否已配置到可用状态（地址、模型、Key 都有）。 */
  static isReady(): boolean {
    const config: AiConfig = AiServiceConfig.loadConfig();
    return config.baseUrl.length > 0 && config.model.length > 0 && config.hasKey;
  }

  /**
   * 拉取服务商的模型 id 列表（`GET {base}/models`，OpenAI 协议通用）。
   * `apiKeyInput` 传空串表示用该服务商已保存的 Key——设置页可先填 Key 再拉，也可拉已存的。
   *
   * 不用 SDK 的 `models.list()`：其 .d.ets 声明返回 `Model[]`，运行时实际 resolve 了
   * undefined（2026-11-17 上板实测），这里直接用 rcp 发一个带鉴权头的 GET。
   */
}

// —— 配置区常量（原 AiService 顶层，拆分后由本文件持有）——

export const AI_PROVIDERS: AiProviderPreset[] = [
  { id: 'openai', name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', model: 'gpt-4o-mini', vision: true },
  { id: 'deepseek', name: 'DeepSeek', baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat', vision: false },
  { id: 'moonshot', name: 'Kimi (Moonshot)', baseUrl: 'https://api.moonshot.cn/v1', model: 'moonshot-v1-8k', vision: false },
  { id: 'zhipu', name: '智谱 GLM', baseUrl: 'https://open.bigmodel.cn/api/paas/v4', model: 'glm-4-flash', vision: false },
  { id: 'qwen', name: '通义千问', baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1', model: 'qwen-plus', vision: false },
  { id: 'siliconflow', name: '硅基流动', baseUrl: 'https://api.siliconflow.cn/v1', model: 'Qwen/Qwen2.5-7B-Instruct', vision: false },
  { id: 'ollama', name: 'Ollama (本地)', baseUrl: 'http://127.0.0.1:11434/v1', model: 'qwen2.5:7b', vision: false },
  // OpenCode Go 订阅专用网关（Console 按量走 opencode.ai/inference/openai/v1），
  // Key 在 opencode.ai/console 创建；网关强制 x-opencode-session 请求头（见 gatewayConfiguration）
  { id: 'opencode', name: 'OpenCode (Go)', baseUrl: 'https://opencode.ai/zen/go/v1', model: 'big-pickle',
    vision: false },
  // Token Plan 订阅网关：除文字模型外，音频三端点（ASR/TTS/realtime）见 docs/token-plan-audio-protocol-2026-11-20.md
  { id: 'qwen-tokenplan', name: 'Token Plan (千问)', baseUrl: 'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1',
    model: 'qwen3.6-flash', vision: false },
  { id: 'custom', name: '自定义', baseUrl: '', model: '', vision: false },
];

/** 一条对话消息（OpenAI 协议）。 */
export const KEY_PROVIDER: string = 'ai_provider';
/** 旧版全局单槽接口地址；首次读取时迁移到所属服务商槽后清空。 */
export const KEY_BASE_URL: string = 'ai_base_url';
/** 各服务商接口地址前缀：`ai_base_url_<providerId>`，与 Key 同样分槽互不覆盖。 */
export const KEY_BASE_URL_PREFIX: string = 'ai_base_url_';
export const KEY_MODEL: string = 'ai_model';
/** 对话页：AI 回复完成后自动用 Token Plan TTS 朗读（默认关）。 */
export const KEY_AUTO_SPEAK: string = 'ai_auto_speak';
/** 语音通话的对话模型：独立服务商/模型；provider 键为空 = 跟随全局配置。 */
export const KEY_VOICE_PROVIDER: string = 'ai_voice_provider';
export const KEY_VOICE_MODEL: string = 'ai_voice_model';
export const KEY_REALTIME_TIMBRE: string = 'ai_voice_timbre_realtime';
export const KEY_TTS_TIMBRE: string = 'ai_voice_timbre_tts';
/** 推理模型的思考强度（OpenAI 兼容 reasoning_effort）。 */
export const KEY_REASONING_EFFORT: string = 'ai_reasoning_effort';
/** AI 回复播报引擎：'system'（默认）/'cloud'（Token Plan TTS）。 */
export const KEY_SPEAK_ENGINE: string = 'ai_speak_engine';
/** 语音通话模式：'realtime'（默认，WS 全双工）/'turn'（轮转）。 */
export const KEY_CALL_MODE: string = 'ai_call_mode';
/** 旧版单 Key；首次读取时迁移到当前服务商后清空。 */
export const KEY_API_KEY: string = 'ai_api_key';
export const KEY_API_KEY_PREFIX: string = 'ai_api_key_';
export const KEY_CUSTOM_PROVIDERS: string = 'ai_custom_providers';
export const KEY_TEMPERATURE: string = 'ai_temperature';
/** OpenCode 网关要求的稳定会话 id（首次使用时生成并持久化）。 */
export const KEY_SESSION_ID: string = 'ai_opencode_session';
/** vision 手动覆盖：'on'/'off'；空串=按模型名自动检测。 */
export const KEY_VISION: string = 'ai_vision';
export const KEY_CONTEXT: string = 'ai_context_length';
/** 权限模式：'readonly'/'confirm'/'auto'；未设置时按逐笔确认。 */
export const KEY_PERMISSION: string = 'ai_permission_mode';
/** 本地常用模型清单（按服务商分开存）：`ai_provider_models_<id>` = JSON 字符串数组。 */
export const KEY_PROVIDER_MODELS_PREFIX: string = 'ai_provider_models_';

/** 上下文长度档位（K tokens），设置页下拉与轮数映射共用。 */
export const CONTEXT_LENGTH_OPTIONS: number[] = [4, 8, 32, 128, 200];
export const DEFAULT_CONTEXT_K: number = 8;

export const DEFAULT_TEMPERATURE: number = 0.7;
export const TIMEOUT_MS: number = 180000;
/** 工具回路最多执行的 tool_calls 轮数；再多一轮不带 tools 逼模型收尾。
 *  上限按「长任务」定：批量场景如 4 本书×（搜+下载）=8 轮，12 轮留余量；
 *  同时兜住模型死循环烧 token。退出对话页不打断回路（后台完成落盘），分钟级任务可行。 */
export const MAX_TOOL_ROUNDS: number = 12;
/** 网关单轮请求最多尝试次数（1 次原始 + 2 次重试）：网络抖动/429/5xx 不该报废整条回复。 */
export const MAX_GATEWAY_ATTEMPTS: number = 3;
/** 单轮流式 tool_calls 槽位上限（OpenAI 标准 index 从 0 连续）：异常 index 钳制于此，防无界扩容。 */
export const MAX_TOOL_SLOTS: number = 64;

