import { OpenAI } from '@iuroc/openai';
import { util } from '@kit.ArkTS';
import { rcp } from '@kit.RemoteCommunicationKit';
import { ChatCompletionChunk } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { ChatCompletionMessageParam } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { ChatCompletionCreateParamsBase } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { ChatCompletionContentPart } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { ChatCompletionContentPartText } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { ChatCompletionContentPartImage } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { TalebookService } from './TalebookService';
import { AiTools, AiPermissionMode, AiToolDefinition } from './AiTools';

/**
 * AI 能力统一走 **OpenAI 兼容 API 调用**（架构约束：不在应用内集成端侧小模型）；
 * **传输层用开源 SDK `@iuroc/openai`**，业务侧仍走本项目自己的门面。
 *
 * 设计要点：
 * - **纯客户端配置**：API 地址 / 模型 / Key 全部由用户在本机填写，不经过本项目服务端，
 *   也不依赖服务端的 `AI_*` 配置项（那些只影响服务端自己的 AI 助手）。
 * - **多服务商**：预设之外可在本机添加自定义 OpenAI 兼容服务商（持久化在 preferences），
 *   API Key 按服务商分开存（`ai_api_key_<providerId>`），互不覆盖。
 * - **Key 存 Asset Store**：复用 `PasswordStore`（鸿蒙关键资产存储 / Android AES-GCM），
 *   不进明文 preferences。
 * - **一套协议覆盖主流服务商**：OpenAI、DeepSeek、通义、Kimi、智谱、Ollama、LM Studio、
 *   OneAPI 等均提供 `/v1/chat/completions`，因此只实现这一种请求格式。
 * - **流式优先**：SDK 的 `onData` 逐块回调，长文本（书评/摘要）不必等整段生成完才显示。
 * - **工具（function calling）**：只读本地工具见 `services/AiTools.ets`；仅 OpenCode 网关
 *   通道挂载并走 tool_calls 多轮回路（SDK v1.0.10 无法在流式里累积 tool_calls，其他服务商不附加）。
 * - **不重复造轮子**：HTTP、SSE 拼包、`[DONE]` 终止、鉴权头、错误体解析都由 SDK 负责，
 *   本文件只做「配置读写 + 提示词消息转换 + 面向 UI 的回调适配」。
 */

/** 预设服务商：仅填默认地址与模型，用户仍可改。 */
export interface AiProviderPreset {
  id: string;
  name: string;
  baseUrl: string;
  model: string;
  /** 是否支持多模态（可发图片）。当前仅用于提示语，不影响请求体。 */
  vision: boolean;
}

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
export interface AiMessage {
  role: string;
  content: string;
  /** 随消息附带的图片（data URL 列表）；非空且服务商 vision 开启时按多模态 content 数组发送。 */
  images?: string[];
}

/** 运行时配置。 */
export interface AiConfig {
  providerId: string;
  baseUrl: string;
  model: string;
  /** 是否已保存 Key（不回传明文，只用于 UI 显示状态）。 */
  hasKey: boolean;
  temperature: number;
  /** 是否可发图片：手动覆盖优先，未覆盖时按模型名自动检测。 */
  vision: boolean;
  /** vision 原始覆盖值：''=自动、'on'、'off'（设置页显示状态用）。 */
  visionOverride: string;
  /** 模型上下文窗口长度（K tokens），决定对话页携带历史轮数。 */
  contextLength: number;
}

const KEY_PROVIDER: string = 'ai_provider';
const KEY_BASE_URL: string = 'ai_base_url';
const KEY_MODEL: string = 'ai_model';
/** 对话页：AI 回复完成后自动用 Token Plan TTS 朗读（默认关）。 */
const KEY_AUTO_SPEAK: string = 'ai_auto_speak';
/** 语音通话的对话模型：独立服务商/模型；provider 键为空 = 跟随全局配置。 */
const KEY_VOICE_PROVIDER: string = 'ai_voice_provider';
const KEY_VOICE_MODEL: string = 'ai_voice_model';
/** AI 回复播报引擎：'system'（默认）/'cloud'（Token Plan TTS）。 */
const KEY_SPEAK_ENGINE: string = 'ai_speak_engine';
/** 旧版单 Key；首次读取时迁移到当前服务商后清空。 */
const KEY_API_KEY: string = 'ai_api_key';
const KEY_API_KEY_PREFIX: string = 'ai_api_key_';
const KEY_CUSTOM_PROVIDERS: string = 'ai_custom_providers';
const KEY_TEMPERATURE: string = 'ai_temperature';
/** OpenCode 网关要求的稳定会话 id（首次使用时生成并持久化）。 */
const KEY_SESSION_ID: string = 'ai_opencode_session';
/** vision 手动覆盖：'on'/'off'；空串=按模型名自动检测。 */
const KEY_VISION: string = 'ai_vision';
const KEY_CONTEXT: string = 'ai_context_length';
/** 权限模式：'readonly'/'confirm'/'auto'；未设置时按逐笔确认。 */
const KEY_PERMISSION: string = 'ai_permission_mode';

/** 上下文长度档位（K tokens），设置页下拉与轮数映射共用。 */
export const CONTEXT_LENGTH_OPTIONS: number[] = [4, 8, 32, 128, 200];
const DEFAULT_CONTEXT_K: number = 8;

const DEFAULT_TEMPERATURE: number = 0.7;
const TIMEOUT_MS: number = 180000;
/** 工具回路最多执行的 tool_calls 轮数；再多一轮不带 tools 逼模型收尾。
 *  上限按「长任务」定：批量场景如 4 本书×（搜+下载）=8 轮，12 轮留余量；
 *  同时兜住模型死循环烧 token。退出对话页不打断回路（后台完成落盘），分钟级任务可行。 */
const MAX_TOOL_ROUNDS: number = 12;
/** 网关单轮请求最多尝试次数（1 次原始 + 2 次重试）：网络抖动/429/5xx 不该报废整条回复。 */
const MAX_GATEWAY_ATTEMPTS: number = 3;

/** 流式回调：`delta` 为本次增量文本，`done` 表示结束。 */
export interface AiStreamHandlers {
  onDelta: (delta: string) => void;
  onDone: (fullText: string) => void;
  onError: (message: string) => void;
  /** 可选：推理模型（qwen/deepseek 等）的思考过程增量，OpenAI 兼容字段 reasoning_content。 */
  onReasoning?: (delta: string) => void;
  /** 可选：网关工具回路每次执行工具前回调一句人话（如「搜索书架」）。 */
  onTool?: (label: string, name: string) => void;
  /** 工具执行完毕（含用户拒绝）：对话页据此把活动时间线从「进行中」翻到「完成/拒绝」。 */
  onToolResult?: (name: string, label: string, text: string, callId: string) => void;
  /** 写操作工具执行前的用户确认；返回 false 拒绝，模型收到「用户拒绝了该操作」。 */
  onConfirm?: (label: string, argsSummary: string) => Promise<boolean>;
}

export class AiService {
  /** 读取当前配置（Key 只回传是否存在）。 */
  static loadConfig(): AiConfig {
    AiService.migrateLegacyKey();
    const providerId: string = TalebookService.prefGet(KEY_PROVIDER, 'deepseek');
    const preset: AiProviderPreset = AiService.presetOf(providerId);
    const baseUrl: string = TalebookService.secureGet(KEY_BASE_URL);
    const model: string = TalebookService.prefGet(KEY_MODEL);
    const temperatureText: string = TalebookService.prefGet(KEY_TEMPERATURE);
    const temperature: number = temperatureText.length > 0 ? Number(temperatureText) : DEFAULT_TEMPERATURE;
    const finalModel: string = model.length > 0 ? model : preset.model;
    const visionOverride: string = TalebookService.prefGet(KEY_VISION);
    const contextText: string = TalebookService.prefGet(KEY_CONTEXT);
    const contextK: number = contextText.length > 0 ? Number(contextText) : DEFAULT_CONTEXT_K;
    return {
      providerId: providerId,
      baseUrl: baseUrl.length > 0 ? baseUrl : preset.baseUrl,
      model: finalModel,
      hasKey: TalebookService.secureGet(AiService.apiKeyKey(providerId)).length > 0,
      temperature: Number.isFinite(temperature) ? temperature : DEFAULT_TEMPERATURE,
      vision: visionOverride === 'on' ? true :
        visionOverride === 'off' ? false : AiService.detectVision(finalModel),
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

  /**
   * 语音通话页用的对话模型配置。未单独配置（或配置的服务商已被删除）时跟随全局；
   * TTS/ASR 载体仍走 Token Plan 网关（QwenAudioService 按全局配置派生），这里只换「思考的大脑」。
   */
  static loadVoiceConfig(): AiConfig {
    const config: AiConfig = AiService.loadConfig();
    const providerId: string = TalebookService.prefGet(KEY_VOICE_PROVIDER);
    if (providerId.length === 0 || providerId === config.providerId) {
      return config;
    }
    const preset: AiProviderPreset = AiService.presetOf(providerId);
    const model: string = TalebookService.prefGet(KEY_VOICE_MODEL);
    const finalModel: string = model.length > 0 ? model : preset.model;
    return {
      providerId: providerId,
      // 自定义服务商的地址就存在预设里；预设服务商被改过全局地址时无法区分，按预设走
      baseUrl: preset.baseUrl,
      model: finalModel,
      hasKey: TalebookService.secureGet(AiService.apiKeyKey(providerId)).length > 0,
      temperature: config.temperature,
      vision: AiService.detectVision(finalModel),
      visionOverride: '',
      contextLength: config.contextLength,
    };
  }

  /** 语音通话是否已独立配置了服务商。 */
  static hasVoiceProvider(): boolean {
    return TalebookService.prefGet(KEY_VOICE_PROVIDER).length > 0;
  }

  /** `providerId` 传空串 = 恢复跟随全局。`model` 空 = 用该服务商默认模型。 */
  static saveVoiceConfig(providerId: string, model: string): void {
    if (providerId.length === 0) {
      TalebookService.prefSet(KEY_VOICE_PROVIDER, '');
      TalebookService.prefSet(KEY_VOICE_MODEL, '');
      return;
    }
    TalebookService.prefSet(KEY_VOICE_PROVIDER, providerId);
    TalebookService.prefSet(KEY_VOICE_MODEL, model.trim());
  }

  /** 已保存的语音通话服务商 id（''=跟随全局）。 */
  static loadVoiceProviderId(): string {
    return TalebookService.prefGet(KEY_VOICE_PROVIDER);
  }

  /** 已保存的语音通话模型名（''=用服务商默认）。 */
  static loadVoiceModel(): string {
    return TalebookService.prefGet(KEY_VOICE_MODEL);
  }

  /** 播报引擎：'system'=系统语音（CoreSpeechKit，默认）、'cloud'=Token Plan 云端 TTS。 */
  static loadSpeakEngine(): string {
    return TalebookService.prefGet(KEY_SPEAK_ENGINE, 'system') === 'cloud' ? 'cloud' : 'system';
  }

  static saveSpeakEngine(engine: string): void {
    TalebookService.prefSet(KEY_SPEAK_ENGINE, engine === 'cloud' ? 'cloud' : 'system');
  }

  /** 各服务商 Key 的存储键；自定义服务商 id 带时间戳，不与前缀冲突。 */
  private static apiKeyKey(providerId: string): string {
    return KEY_API_KEY_PREFIX + providerId;
  }

  /** 读取指定服务商的 API Key（未配置返回空串）。 */
  static apiKeyFor(providerId: string): string {
    AiService.migrateLegacyKey();
    return TalebookService.secureGet(AiService.apiKeyKey(providerId));
  }

  static hasKeyFor(providerId: string): boolean {
    return AiService.apiKeyFor(providerId).length > 0;
  }

  /** 旧版单 Key 一次性迁移：挪进当前所选服务商的槽位后清空。 */
  private static migrateLegacyKey(): void {
    const legacy: string = TalebookService.secureGet(KEY_API_KEY);
    if (legacy.length === 0) {
      return;
    }
    const providerId: string = TalebookService.prefGet(KEY_PROVIDER, 'deepseek');
    TalebookService.secureSet(AiService.apiKeyKey(providerId), legacy);
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

  /** 全部可选服务商：预设 + 本机关加的自定义。 */
  static listProviders(): AiProviderPreset[] {
    const out: AiProviderPreset[] = [];
    for (let i = 0; i < AI_PROVIDERS.length; i++) {
      out.push(AI_PROVIDERS[i]);
    }
    const custom: AiProviderPreset[] = AiService.listCustomProviders();
    for (let i = 0; i < custom.length; i++) {
      out.push(custom[i]);
    }
    return out;
  }

  /** 添加一个本地自定义服务商并返回其预设。 */
  static addCustomProvider(name: string, baseUrl: string, model: string): AiProviderPreset {
    const trimmedName: string = name.trim();
    const base: string = AiService.normalizeBaseUrl(baseUrl);
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
    const list: AiProviderPreset[] = AiService.listCustomProviders();
    list.push(preset);
    AiService.saveCustomProviders(list);
    return preset;
  }

  /** 删除自定义服务商，连带清掉它保存的 Key。 */
  static removeCustomProvider(id: string): void {
    const list: AiProviderPreset[] = AiService.listCustomProviders();
    const kept: AiProviderPreset[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        TalebookService.secureSet(AiService.apiKeyKey(id), '');
      } else {
        kept.push(list[i]);
      }
    }
    AiService.saveCustomProviders(kept);
  }

  private static saveCustomProviders(list: AiProviderPreset[]): void {
    TalebookService.prefSet(KEY_CUSTOM_PROVIDERS, JSON.stringify(list));
  }

  static presetOf(providerId: string): AiProviderPreset {
    const providers: AiProviderPreset[] = AiService.listProviders();
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
    TalebookService.secureSet(KEY_BASE_URL, AiService.normalizeBaseUrl(baseUrl));
    TalebookService.prefSet(KEY_MODEL, model.trim());
    TalebookService.prefSet(KEY_TEMPERATURE, `${temperature}`);
    TalebookService.prefSet(KEY_VISION, visionOverride);
    TalebookService.prefSet(KEY_CONTEXT, `${contextLength}`);
    if (apiKey.length > 0) {
      TalebookService.secureSet(AiService.apiKeyKey(providerId), apiKey.trim());
    }
  }

  static clearKey(): void {
    const providerId: string = TalebookService.prefGet(KEY_PROVIDER, 'deepseek');
    TalebookService.secureSet(AiService.apiKeyKey(providerId), '');
    TalebookService.secureSet(KEY_API_KEY, '');
  }

  /** 是否已配置到可用状态（地址、模型、Key 都有）。 */
  static isReady(): boolean {
    const config: AiConfig = AiService.loadConfig();
    return config.baseUrl.length > 0 && config.model.length > 0 && config.hasKey;
  }

  /**
   * 拉取服务商的模型 id 列表（`GET {base}/models`，OpenAI 协议通用）。
   * `apiKeyInput` 传空串表示用该服务商已保存的 Key——设置页可先填 Key 再拉，也可拉已存的。
   *
   * 不用 SDK 的 `models.list()`：其 .d.ets 声明返回 `Model[]`，运行时实际 resolve 了
   * undefined（2026-11-17 上板实测），这里直接用 rcp 发一个带鉴权头的 GET。
   */
  static async fetchModels(providerId: string, baseUrl: string, apiKeyInput: string): Promise<string[]> {
    const key: string = apiKeyInput.trim().length > 0 ? apiKeyInput.trim() : AiService.apiKeyFor(providerId);
    const base: string = AiService.normalizeBaseUrl(baseUrl);
    if (base.length === 0) {
      throw new Error('请先填写接口地址');
    }
    if (key.length === 0) {
      throw new Error('请先填写 API Key');
    }
    const headers: rcp.RequestHeaders = {
      'Authorization': `Bearer ${key}`,
      'Accept': 'application/json',
    };
    // models 端点不校验该头，但保持与 chat 通道一致（见 chatViaGateway）
    if (AiService.isOpenCodeGateway(base)) {
      headers['x-opencode-session'] = AiService.opencodeSessionId();
    }
    const session: rcp.Session = rcp.createSession();
    let statusCode: number = 0;
    let text: string = '';
    try {
      const request: rcp.Request = new rcp.Request(`${base}/models`, 'GET', headers);
      const response: rcp.Response = await session.fetch(request);
      statusCode = response.statusCode;
      text = AiService.responseBodyText(response.body);
    } catch (error) {
      throw new Error(AiService.friendlyMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      session.close();
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw new Error(AiService.httpErrorText(statusCode, text));
    }
    const ids: string[] = [];
    try {
      const root = JSON.parse(text) as Record<string, Object>;
      const items = root['data'] as Object[] | undefined;
      if (items !== undefined) {
        for (let i = 0; i < items.length; i++) {
          const it = items[i] as Record<string, string>;
          const id: string | undefined = it['id'];
          if (id !== undefined && id.length > 0 && ids.indexOf(id) < 0) {
            ids.push(id);
          }
        }
      }
    } catch (_error) {
      throw new Error('模型列表解析失败，该服务可能不兼容 OpenAI 协议');
    }
    return ids;
  }

  /** rcp 的 body 可能是 string / ArrayBuffer / 已解析对象，统一转文本。 */
  private static responseBodyText(body: string | Object | ArrayBuffer | undefined): string {
    if (body === undefined || body === null) {
      return '';
    }
    if (typeof body === 'string') {
      return body as string;
    }
    if (body instanceof ArrayBuffer) {
      return AiService.responseText(body);
    }
    return JSON.stringify(body);
  }

  /**
   * 流式对话。返回可中断句柄：调用 `abort()` 停止请求。
   *
   * SDK 的 `onData` 已经是逐 chunk 回调（内部完成 SSE 拆行与 UTF-8 解码），
   * 这里只把 chunk 拼成文本转发给 UI。
   */
  static chatStream(messages: AiMessage[], handlers: AiStreamHandlers, maxTokens: number = 2048): AiAbortHandle {
    const handle: AiAbortHandle = { aborted: false };
    const config: AiConfig = AiService.loadConfig();
    const apiKey: string = AiService.apiKeyFor(config.providerId);

    if (config.baseUrl.length === 0 || config.model.length === 0) {
      handlers.onError('请先在「AI 助手 → 模型设置」里填写接口地址与模型');
      return handle;
    }
    if (apiKey.length === 0) {
      handlers.onError('请先在「AI 助手 → 模型设置」里填写 API Key');
      return handle;
    }

    let full: string = '';
    let settled: boolean = false;
    const finish = (errorText: string): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (errorText.length > 0) {
        handlers.onError(errorText);
      } else {
        handlers.onDone(full);
      }
    };

    if (AiService.isOpenCodeGateway(config.baseUrl)) {
      const gatewaySession: rcp.Session = rcp.createSession();
      handle.destroy = (): void => {
        handle.aborted = true;
        try {
          gatewaySession.cancel();
        } catch (_error) {
          // 已结束的会话再 cancel 会抛，忽略
        }
      };
      const notice: ((label: string, name: string) => void) | undefined = handlers.onTool;
      const ask: ((label: string, args: string) => Promise<boolean>) | undefined = handlers.onConfirm;
      const done: ((name: string, label: string, text: string, callId: string) => void) | undefined = handlers.onToolResult;
      const think: ((text: string) => void) | undefined = handlers.onReasoning;
      const permission: AiPermissionMode = AiService.loadPermission();
      AiService.chatViaGateway(config, apiKey, messages, maxTokens, gatewaySession,
        AiTools.definitions(permission), permission, (): boolean => handle.aborted,
        notice === undefined ? null : notice,
        ask === undefined ? null : ask,
        done === undefined ? null : done,
        think === undefined ? null : think).then((content: string): void => {
        if (handle.aborted) {
          return;
        }
        full = content;
        handlers.onDelta(content);
        finish('');
      }).catch((error: Error): void => {
        if (!handle.aborted) {
          finish(error.message);
        }
      });
      return handle;
    }

    let session: AiSessionHolder | null = null;
    try {
      const client: OpenAI = AiService.client(config.baseUrl, apiKey);
      const params: ChatCompletionCreateParamsBase = {
        model: config.model,
        messages: AiService.toSdkMessages(messages),
        stream: true,
        temperature: config.temperature,
        max_tokens: maxTokens,
      };
      const result = client.chat.completions.create(params, {
        onData: (chunks: ChatCompletionChunk[]): void => {
          if (handle.aborted) {
            return;
          }
          let piece: string = '';
          let think: string = '';
          for (let i = 0; i < chunks.length; i++) {
            const choices = chunks[i].choices;
            if (choices !== undefined && choices.length > 0) {
              const delta = choices[0].delta.content;
              if (delta !== undefined && delta !== null) {
                piece += delta;
              }
              // SDK 类型没声明 reasoning_content，但运行时是 JSON 透传，按 Record 取
              const deltaObj: Record<string, Object> = choices[0].delta as Object as Record<string, Object>;
              const reasoning = deltaObj['reasoning_content'];
              if (typeof reasoning === 'string') {
                think += reasoning;
              }
            }
          }
          if (think.length > 0 && handlers.onReasoning !== undefined) {
            handlers.onReasoning(think);
          }
          if (piece.length > 0) {
            full += piece;
            handlers.onDelta(piece);
          }
        },
        onError: (error: Error): void => {
          if (!handle.aborted) {
            finish(AiService.friendlyMessage(error.message));
          }
        },
      });
      session = result.session as AiSessionHolder;
      result.response.then((response): void => {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          finish(AiService.httpErrorText(response.statusCode, AiService.responseText(response.body)));
          return;
        }
        finish('');
      }).catch((error: Error): void => {
        finish(AiService.friendlyMessage(error.message));
      });
    } catch (error) {
      finish(AiService.friendlyMessage(error instanceof Error ? error.message : String(error)));
      return handle;
    }

    handle.destroy = (): void => {
      handle.aborted = true;
      try {
        // rcp.Session.cancel()：中断在途请求，否则流式响应会一直占着连接
        session?.cancel();
      } catch (_error) {
        // 已结束的会话再 cancel 会抛，忽略
      }
    };
    return handle;
  }

  /** 非流式的单轮问答，用于结构化结果（如推荐书单 JSON）。 */
  /**
   * 一次性补全（非流式）。`config` 缺省用全局配置；语音通话页传
   * `loadVoiceConfig()` 以走独立选择的对话模型。
   */
  static async complete(messages: AiMessage[], maxTokens: number = 2048, override?: AiConfig): Promise<string> {
    const config: AiConfig = override !== undefined ? override : AiService.loadConfig();
    const apiKey: string = AiService.apiKeyFor(config.providerId);
    if (config.baseUrl.length === 0 || config.model.length === 0) {
      throw new Error('请先配置 AI 接口地址与模型');
    }
    if (apiKey.length === 0) {
      throw new Error('请先配置 AI API Key');
    }
    if (AiService.isOpenCodeGateway(config.baseUrl)) {
      // 结构化输出（书单 JSON 等）不需要工具，避免模型中途改去查数据
      return AiService.chatViaGateway(config, apiKey, messages, maxTokens, rcp.createSession(),
        null, AiService.loadPermission(), null, null, null, null, null);
    }
    const client: OpenAI = AiService.client(config.baseUrl, apiKey);
    const params: ChatCompletionCreateParamsBase = {
      model: config.model,
      messages: AiService.toSdkMessages(messages),
      stream: false,
      temperature: config.temperature,
      max_tokens: maxTokens,
    };
    const result = client.chat.completions.create(params);
    let statusCode: number = 0;
    let text: string = '';
    try {
      const response = await result.response;
      statusCode = response.statusCode;
      text = AiService.responseText(response.body);
    } catch (error) {
      throw new Error(AiService.friendlyMessage(error instanceof Error ? error.message : String(error)));
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw new Error(AiService.httpErrorText(statusCode, text));
    }
    const content: string = AiService.parseContent(text);
    if (content.length === 0) {
      throw new Error('AI 返回内容为空，请检查模型是否可用');
    }
    return content;
  }

  /** 建 SDK 客户端。地址按 SDK 约定只给到 `/v1`，它自己拼 `/chat/completions`。 */
  private static client(baseUrl: string, apiKey: string): OpenAI {
    return new OpenAI({
      apiKey: apiKey,
      baseURL: AiService.normalizeBaseUrl(baseUrl),
      timeout: TIMEOUT_MS,
    });
  }

  /**
   * 把本项目的 `AiMessage[]` 转成 SDK 的严格联合类型。
   *
   * SDK 用的是 `role: 'user'` 这类字面量联合；ArkTS 既不能把宽 string 直接赋过去，
   * 也不支持索引访问类型（`X['messages']`），所以这里显式声明成
   * `ChatCompletionMessageParam[]` 再交给 `messages` 字段。
   */
  private static toSdkMessages(messages: AiMessage[]): ChatCompletionMessageParam[] {
    const out: ChatCompletionMessageParam[] = [];
    for (let i = 0; i < messages.length; i++) {
      const m: AiMessage = messages[i];
      if (m.role === 'assistant') {
        out.push({ role: 'assistant', content: m.content });
      } else if (m.role === 'system') {
        out.push({ role: 'system', content: m.content });
      } else {
        const images: string[] = m.images ?? [];
        if (images.length === 0) {
          out.push({ role: 'user', content: m.content });
        } else {
          const parts: ChatCompletionContentPart[] = [];
          const textPart: ChatCompletionContentPartText = { type: 'text', text: m.content };
          parts.push(textPart);
          for (let j = 0; j < images.length; j++) {
            const imageUrl: ChatCompletionContentPartImage.ImageURL = { url: images[j] };
            const part: ChatCompletionContentPartImage = { type: 'image_url', image_url: imageUrl };
            parts.push(part);
          }
          out.push({ role: 'user', content: parts });
        }
      }
    }
    return out;
  }

  /** 网关请求体的消息正文：带图时拼 OpenAI 多模态数组，否则纯文本。 */
  private static gatewayContent(m: AiMessage): Object {
    const images: string[] = m.images ?? [];
    if (images.length === 0) {
      return m.content;
    }
    const parts: Record<string, Object>[] = [];
    const textPart: Record<string, Object> = { 'type': 'text', 'text': m.content };
    parts.push(textPart);
    for (let j = 0; j < images.length; j++) {
      const urlRec: Record<string, Object> = { 'url': images[j] };
      const imgPart: Record<string, Object> = { 'type': 'image_url', 'image_url': urlRec };
      parts.push(imgPart);
    }
    return parts;
  }

  /** 稳定会话 id：首次生成后持久化（OpenCode 网关要求同一会话一致路由、复用 prompt 缓存）。 */
  private static opencodeSessionId(): string {
    let id: string = TalebookService.prefGet(KEY_SESSION_ID);
    if (id.length === 0) {
      id = util.generateRandomUUID(true);
      TalebookService.prefSet(KEY_SESSION_ID, id);
    }
    return id;
  }

  /** 是否走 OpenCode 网关（opencode.ai）。 */
  private static isOpenCodeGateway(baseUrl: string): boolean {
    return baseUrl.indexOf('opencode.ai') >= 0;
  }

  /** 退避等待（网关重试间隔用）。 */
  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * OpenCode 网关对话通道：**绕过 @iuroc SDK 直连 rcp**。
   *
   * 原因：网关对 /chat/completions 强制 `x-opencode-session`（缺失 400
   * MissingSessionID，2026-11-17 上板实测），而 SDK v1.0.10 没有任何自定义
   * 请求头注入能力——声明里的 requestConfiguration 实为 rcp.Configuration
   * （无 headers 字段），实测透传也不会附加到请求；且当前 SDK 的 rcp 声明
   * （4.1.0(11) 精简版）没有流式事件，无法自解析 SSE。故整包返回
   * （stream:false），OpenCode 对话暂无打字机效果，其他服务商不受影响。
   *
   * `tools` 非空时走 **function calling 回路**：模型返回 tool_calls → （写工具按
   * `permission` 三档处理：只读挡下 / 逐笔过 onConfirm / 自动放行）本地执行（AiTools）
   * → 以 assistant+tool 消息回填上下文 → 再次请求，
   * 直到模型给出文本回答或达到 MAX_TOOL_ROUNDS 轮上限。
   */
  private static async chatViaGateway(config: AiConfig, apiKey: string, messages: AiMessage[],
    maxTokens: number, session: rcp.Session, tools: AiToolDefinition[] | null,
    permission: AiPermissionMode,
    isAborted: (() => boolean) | null,
    onTool: ((label: string, name: string) => void) | null,
    onConfirm: ((label: string, argsSummary: string) => Promise<boolean>) | null,
    onResult: ((name: string, label: string, text: string, callId: string) => void) | null,
    onReasoning: ((text: string) => void) | null): Promise<string> {
    const headers: rcp.RequestHeaders = {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'x-opencode-session': AiService.opencodeSessionId(),
    };
    const gwMessages: GatewayMessage[] = [];
    for (let i = 0; i < messages.length; i++) {
      gwMessages.push({ role: messages[i].role, content: AiService.gatewayContent(messages[i]) });
    }
    const url: string = `${AiService.normalizeBaseUrl(config.baseUrl)}/chat/completions`;
    try {
      for (let round = 0; round <= MAX_TOOL_ROUNDS; round++) {
        if (isAborted !== null && isAborted()) {
          return '';
        }
        // 剩 3 轮时提醒模型收敛：多数截断本可避免（软着陆只是兜底，别靠它）
        if (round === MAX_TOOL_ROUNDS - 3) {
          gwMessages.push({
            role: 'user',
            content: '（内部提示）工具调用仅剩 3 轮。请尽快汇总已获得的结果准备最终回答，不要再发起非必要的工具调用。',
          });
        }
        // 最后一轮不带 tools，逼模型给最终回答而不是继续调工具
        const attach: AiToolDefinition[] | null = round < MAX_TOOL_ROUNDS ? tools : null;
        const payload: Record<string, Object> = {
          'model': config.model,
          'messages': gwMessages,
          'stream': false,
          'temperature': config.temperature,
          'max_tokens': maxTokens,
        };
        if (attach !== null && attach.length > 0) {
          payload['tools'] = attach;
        }
        const request: rcp.Request = new rcp.Request(url, 'POST', headers, JSON.stringify(payload));
        // 单轮请求失败（网络抖动 / 429 / 5xx）直接 throw 会让整条多轮回复报废——
        // 用户侧表现为「工具调用失败不重试、会话中断」。退避重试，其余 4xx 无意义不重试。
        let statusCode: number = 0;
        let text: string = '';
        let lastError: string = '';
        for (let attempt = 0; attempt < MAX_GATEWAY_ATTEMPTS; attempt++) {
          if (attempt > 0) {
            if (isAborted !== null && isAborted()) {
              return '';
            }
            await AiService.sleep(attempt * 1000);
          }
          try {
            const response: rcp.Response = await session.fetch(request);
            statusCode = response.statusCode;
            text = AiService.responseBodyText(response.body);
          } catch (error) {
            lastError = AiService.friendlyMessage(error instanceof Error ? error.message : String(error));
            continue;
          }
          if (statusCode >= 200 && statusCode < 300) {
            break;
          }
          if (statusCode !== 429 && statusCode < 500) {
            throw new Error(AiService.httpErrorText(statusCode, text));
          }
          lastError = AiService.httpErrorText(statusCode, text);
        }
        if (statusCode < 200 || statusCode >= 300) {
          throw new Error(lastError);
        }
        const reply: GatewayReply = AiService.parseGatewayReply(text);
        if (reply.reasoning.length > 0 && onReasoning !== null) {
          // 整包模式：本轮思考过程一次性给出（工具回路多轮则逐轮累积）
          onReasoning(reply.reasoning);
        }
        if (reply.calls !== null && reply.calls.length > 0) {
          if (round === MAX_TOOL_ROUNDS) {
            // 软着陆：模型此前已产出正文时保留部分成果，整条回复不再报废；
            // 只有纯工具调用没正文可给才报错（此时前文也无总结价值）
            if (reply.content.length > 0) {
              return `${reply.content}\n\n（本次任务工具调用达到 ${MAX_TOOL_ROUNDS} 轮上限，以上为中断时的结果；如需继续请再发一条消息。）`;
            }
            throw new Error(`模型连续调用工具达到上限（${MAX_TOOL_ROUNDS} 轮），请把问题说具体些再试`);
          }
          const calls: Record<string, Object>[] = [];
          for (let i = 0; i < reply.calls.length; i++) {
            const c: GatewayToolCall = reply.calls[i];
            const fn: Record<string, Object> = { 'name': c.name, 'arguments': c.arguments };
            const call: Record<string, Object> = { 'id': c.id, 'type': 'function', 'function': fn };
            calls.push(call);
          }
          gwMessages.push({ role: 'assistant', content: reply.content, tool_calls: calls });
          // 同轮全是免确认（只读）工具 → Promise.all 并发：网络类工具单项要几秒，
          // 串行白白叠加等待。含写工具保持串行——确认闸门与执行顺序必须和模型输出一致。
          let allAuto: boolean = true;
          for (let i = 0; i < reply.calls.length; i++) {
            if (AiTools.needsConfirm(reply.calls[i].name)) {
              allAuto = false;
              break;
            }
          }
          if (allAuto) {
            const labels: string[] = [];
            const tasks: Promise<string>[] = [];
            for (let i = 0; i < reply.calls.length; i++) {
              const c: GatewayToolCall = reply.calls[i];
              const l: string = AiTools.toolLabel(c.name);
              labels.push(l);
              if (onTool !== null) {
                onTool(l, c.name);
              }
              tasks.push(AiTools.execute(c.name, c.arguments, c.id));
            }
            const results: string[] = await Promise.all(tasks);
            for (let i = 0; i < results.length; i++) {
              gwMessages.push({ role: 'tool', content: results[i], tool_call_id: reply.calls[i].id });
              if (onResult !== null) {
                onResult(reply.calls[i].name, labels[i], results[i], reply.calls[i].id);
              }
            }
            if (isAborted !== null && isAborted()) {
              return '';
            }
            continue;
          }
          for (let i = 0; i < reply.calls.length; i++) {
            const c: GatewayToolCall = reply.calls[i];
            let label: string = AiTools.toolLabel(c.name);
            if (AiTools.needsConfirm(c.name)) {
              if (permission === 'readonly') {
                // 只读模式 tools 里本就没有写工具；走到这里说明模型幻觉调用，回路层同样挡下
                const blocked: string = '当前为只读权限模式，写操作不可执行';
                gwMessages.push({ role: 'tool', content: blocked, tool_call_id: c.id });
                if (onResult !== null) {
                  onResult(c.name, label, blocked, c.id);
                }
                continue;
              }
              if (permission === 'confirm') {
                // 写工具先过用户确认闸门；没人能确认（onConfirm 缺省）就一律拒绝
                let approved: boolean = false;
                if (onConfirm !== null) {
                  approved = await onConfirm(label, c.arguments);
                }
                if (!approved) {
                  gwMessages.push({ role: 'tool', content: '用户拒绝了该操作', tool_call_id: c.id });
                  if (onResult !== null) {
                    onResult(c.name, label, '用户拒绝了该操作', c.id);
                  }
                  continue;
                }
              } else {
                // 自动放行：不弹确认，活动时间线标注执行方式
                label = `${label}（自动执行）`;
              }
            }
            if (onTool !== null) {
              onTool(label, c.name);
            }
            const result: string = await AiTools.execute(c.name, c.arguments);
            gwMessages.push({ role: 'tool', content: result, tool_call_id: c.id });
            if (onResult !== null) {
              onResult(c.name, label, result, c.id);
            }
            if (isAborted !== null && isAborted()) {
              return '';
            }
          }
          continue;
        }
        if (reply.content.length === 0) {
          throw new Error('AI 返回内容为空，请检查模型是否可用');
        }
        return reply.content;
      }
      return '';
    } finally {
      session.close();
      // 中断/异常可能留下未取配对条目，回路收尾一律清理
      AiTools.clearPendingBooks();
    }
  }

  /** 解析网关整包响应：正文 + tool_calls（不依赖 SDK 的 ChatCompletionMessage 类型）。 */
  private static parseGatewayReply(raw: string): GatewayReply {
    const reply: GatewayReply = { content: '', calls: null, reasoning: '' };
    if (raw.length === 0) {
      return reply;
    }
    let root: Record<string, Object>;
    try {
      root = JSON.parse(raw) as Record<string, Object>;
    } catch (_error) {
      throw new Error('AI 响应解析失败');
    }
    const errorObj = root['error'] as Record<string, Object> | undefined;
    if (errorObj !== undefined) {
      const message = errorObj['message'];
      if (typeof message === 'string') {
        throw new Error(message as string);
      }
    }
    const choices = root['choices'] as Object[] | undefined;
    if (choices === undefined || choices.length === 0) {
      return reply;
    }
    const first = choices[0] as Record<string, Object>;
    const message = first['message'] as Record<string, Object> | undefined;
    if (message === undefined) {
      return reply;
    }
    const content = message['content'];
    reply.content = typeof content === 'string' ? content as string : '';
    const reasoning = message['reasoning_content'];
    reply.reasoning = typeof reasoning === 'string' ? reasoning as string : '';
    const rawCalls = message['tool_calls'] as Object[] | undefined;
    if (rawCalls === undefined || rawCalls.length === 0) {
      return reply;
    }
    const calls: GatewayToolCall[] = [];
    for (let i = 0; i < rawCalls.length; i++) {
      const c = rawCalls[i] as Record<string, Object>;
      const fn = c['function'] as Record<string, Object> | undefined;
      if (fn === undefined) {
        continue;
      }
      const id = c['id'];
      const name = fn['name'];
      const args = fn['arguments'];
      calls.push({
        id: typeof id === 'string' ? id as string : '',
        name: typeof name === 'string' ? name as string : '',
        arguments: typeof args === 'string' ? args as string : '{}',
      });
    }
    reply.calls = calls.length > 0 ? calls : null;
    return reply;
  }

  /** 容错用户输入：去掉末尾 `/chat/completions` 与多余斜杠，SDK 只接受 base URL。 */
  private static normalizeBaseUrl(baseUrl: string): string {
    let base: string = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    const suffix: string = '/chat/completions';
    if (base.endsWith(suffix)) {
      base = base.substring(0, base.length - suffix.length);
    }
    return base;
  }

  /** `rcp.Response.body` 是 ArrayBuffer，按 UTF-8 解文本。 */
  private static responseText(body: ArrayBuffer | undefined): string {
    if (body === undefined || body.byteLength === 0) {
      return '';
    }
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(body));
  }

  private static parseContent(raw: string): string {
    if (raw.length === 0) {
      return '';
    }
    try {
      const root = JSON.parse(raw) as Record<string, Object>;
      const choices = root['choices'] as Object[] | undefined;
      if (choices !== undefined && choices.length > 0) {
        const first = choices[0] as Record<string, Object>;
        const message = first['message'] as Record<string, Object> | undefined;
        if (message !== undefined) {
          const content = message['content'];
          if (typeof content === 'string') {
            return content as string;
          }
        }
      }
      const errorObj = root['error'] as Record<string, Object> | undefined;
      if (errorObj !== undefined) {
        const message = errorObj['message'];
        if (typeof message === 'string') {
          throw new Error(message as string);
        }
      }
      return '';
    } catch (error) {
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('AI 响应解析失败');
    }
  }

  /** 把 SDK / 网络层的原始错误翻成人话；识别不出来就原样带上。 */
  private static friendlyMessage(message: string): string {
    const text: string = message.trim();
    if (text.length === 0) {
      return 'AI 请求失败';
    }
    if (text.indexOf('2300007') >= 0 || text.indexOf('2300006') >= 0 ||
      text.toLowerCase().indexOf('unable to resolve host') >= 0) {
      return '无法连接 AI 服务，请检查接口地址与网络';
    }
    if (text.indexOf('2300028') >= 0 || text.toLowerCase().indexOf('timeout') >= 0) {
      return 'AI 请求超时，请检查网络或换用更快的模型';
    }
    return `AI 请求失败：${text}`;
  }

  private static httpErrorText(status: number, body: string): string {
    if (status === 401) {
      return 'API Key 无效或已过期（HTTP 401）';
    }
    if (status === 402) {
      return '账户余额不足（HTTP 402）';
    }
    if (status === 404) {
      return '接口地址不正确，需以 /v1 结尾（HTTP 404）';
    }
    if (status === 429) {
      return '请求过于频繁或超出配额，请稍后再试（HTTP 429）';
    }
    const detail: string = AiService.extractErrorDetail(body);
    if (detail.length > 0) {
      return `AI 服务返回 ${status}：${detail}`;
    }
    return `AI 服务返回 HTTP ${status}`;
  }

  private static extractErrorDetail(body: string): string {
    if (body.length === 0) {
      return '';
    }
    try {
      const root = JSON.parse(body) as Record<string, Object>;
      const errorObj = root['error'] as Record<string, Object> | undefined;
      if (errorObj !== undefined) {
        const message = errorObj['message'];
        if (typeof message === 'string') {
          return (message as string).substring(0, 120);
        }
      }
    } catch (_error) {
      return body.substring(0, 120);
    }
    return '';
  }
}

/** 中断句柄。 */
export interface AiAbortHandle {
  aborted: boolean;
  destroy?: () => void;
}

/**
 * 网关通道专用消息：只有 chatViaGateway 直连时会用到 tool_calls / tool_call_id，
 * 字段名对齐 OpenAI 协议（回填给服务端时必须一致）。
 */
interface GatewayMessage {
  role: string;
  /** 纯文本或 OpenAI 多模态 content 数组（带图时）。 */
  content?: Object;
  tool_calls?: Record<string, Object>[];
  tool_call_id?: string;
}

/** 响应里的一条工具调用（已拍平 function 嵌套）。 */
interface GatewayToolCall {
  id: string;
  name: string;
  arguments: string;
}

/** 整包响应的解析结果。 */
interface GatewayReply {
  content: string;
  calls: GatewayToolCall[] | null;
  /** 推理模型的思考过程（OpenAI 兼容字段 reasoning_content，整包模式一次给全）。 */
  reasoning: string;
}

/** SDK 会话只用到 cancel()；单独声明避免依赖 rcp 的完整类型。 */
interface AiSessionHolder {
  cancel: () => void;
}
