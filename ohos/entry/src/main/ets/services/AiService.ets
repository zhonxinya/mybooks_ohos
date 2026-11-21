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
import { AiTools, AiPermissionMode } from './AiTools';
import { AiToolDefinition } from './AiToolsDefs';
import { McpService } from './McpService';
import { AiServiceConfig } from './AiServiceConfig';
import { AiServiceHttp } from './AiServiceHttp';
import { AiServiceGateway } from './AiServiceGateway';
import { KEY_PROVIDER, KEY_BASE_URL, KEY_MODEL, KEY_AUTO_SPEAK, KEY_VOICE_PROVIDER, KEY_VOICE_MODEL, KEY_SPEAK_ENGINE, KEY_CALL_MODE, KEY_API_KEY, KEY_API_KEY_PREFIX, KEY_CUSTOM_PROVIDERS, KEY_TEMPERATURE, KEY_SESSION_ID, KEY_VISION, KEY_CONTEXT, KEY_PERMISSION, KEY_PROVIDER_MODELS_PREFIX, CONTEXT_LENGTH_OPTIONS, DEFAULT_CONTEXT_K, DEFAULT_TEMPERATURE, TIMEOUT_MS, MAX_TOOL_ROUNDS, MAX_GATEWAY_ATTEMPTS, MAX_TOOL_SLOTS } from './AiServiceConfig';
import type { GatewayMessage, GatewayToolCall, GatewayReply, AskPayload } from './AiServiceGateway';
import type { AiSessionHolder } from './AiServiceHttp';
export { CONTEXT_LENGTH_OPTIONS } from './AiServiceConfig';

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
export interface AiMessage {
  role: string;
  content: string;
  /** 随消息附带的图片（data URL 列表）；非空且服务商 vision 开启时按多模态 content 数组发送。 */
  images?: string[];
}

/** AI 联网搜索引用的单条网页。 */
export interface LlmSearchSource {
  title: string;
  url: string;
}

/** AI 联网问答结果：整合答案 + 检索引用；ok=false 时 error 说明原因。 */
export interface LlmSearchResult {
  ok: boolean;
  answer: string;
  sources: LlmSearchSource[];
  error: string;
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
  /** ask_user 反问工具：把问题与选项抛给界面等待点选；返回空串表示用户跳过。 */
  onAsk?: (question: string, options: string[]) => Promise<string>;
}


/**
 * 门面（800 行门禁拆分）：配置持久化见 AiServiceConfig.ets，SDK 客户端与传输辅助见
 * AiServiceHttp.ets，网关多轮工具回路见 AiServiceGateway.ets。本文件保留类型契约、
 * AI_PROVIDERS 常量、chatStream/complete 入口，其余公开方法均为薄委托。
 */
export class AiService {
  static chatStream(messages: AiMessage[], handlers: AiStreamHandlers, maxTokens: number = 2048,
    mcpTools: AiToolDefinition[] | null = null): AiAbortHandle {
    const handle: AiAbortHandle = { aborted: false };
    const config: AiConfig = AiServiceConfig.loadConfig();
    const apiKey: string = AiServiceConfig.apiKeyFor(config.providerId);

    // 配置校验先行（回路重构后 client 创建已上移，校验必须在前）
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

    if (AiServiceHttp.isOpenCodeGateway(config.baseUrl)) {
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
      const permission: AiPermissionMode = AiServiceConfig.loadPermission();
      AiServiceGateway.chatViaGateway(config, apiKey, messages, maxTokens, gatewaySession,
        AiServiceHttp.toolset(permission, mcpTools), permission, (): boolean => handle.aborted,
        notice === undefined ? null : notice,
        ask === undefined ? null : ask,
        done === undefined ? null : done,
        think === undefined ? null : think,
        handlers.onAsk === undefined ? null : handlers.onAsk).then((content: string): void => {
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

    const client: OpenAI = AiServiceHttp.client(config.baseUrl, apiKey);
    const sdkPermission: AiPermissionMode = AiServiceConfig.loadPermission();
    const sdkTools: AiToolDefinition[] = AiServiceHttp.toolset(sdkPermission, mcpTools);
    if (sdkTools.length > 0) {
      // 非网关通道同样走 function calling 回路：传输换成 SDK 流式
      // （sdkStreamRound 打字机保留 + 运行时累积 tool_calls），回路主体与网关共用。
      const gwMessages: GatewayMessage[] = [];
      for (let i = 0; i < messages.length; i++) {
        gwMessages.push({ role: messages[i].role, content: AiServiceHttp.gatewayContent(messages[i]) });
      }
      const sessionBox: AiSessionHolder[] = [];
      handle.destroy = (): void => {
        handle.aborted = true;
        try {
          // rcp.Session.cancel()：中断在途请求，否则流式响应会一直占着连接
          sessionBox[0]?.cancel();
        } catch (_error) {
          // 已结束的会话再 cancel 会抛，忽略
        }
      };
      const notice: ((label: string, name: string) => void) | undefined = handlers.onTool;
      const ask: ((label: string, args: string) => Promise<boolean>) | undefined = handlers.onConfirm;
      const done: ((name: string, label: string, text: string, callId: string) => void) | undefined = handlers.onToolResult;
      const think: ((text: string) => void) | undefined = handlers.onReasoning;
      const transport = async (attach: AiToolDefinition[] | null): Promise<GatewayReply | null> =>
        AiServiceGateway.sdkStreamRound(client, config, gwMessages, maxTokens, attach, handle,
          handlers.onDelta, think === undefined ? null : think, sessionBox);
      AiServiceGateway.runToolLoop(gwMessages, transport, sdkTools, sdkPermission,
        (): boolean => handle.aborted,
        notice === undefined ? null : notice,
        ask === undefined ? null : ask,
        done === undefined ? null : done,
        think === undefined ? null : think,
        handlers.onAsk === undefined ? null : handlers.onAsk).then((content: string): void => {
        if (handle.aborted) {
          return;
        }
        // 流式模式正文已逐块 onDelta 过，这里只定稿全文，不得重复回调
        full = content;
        finish('');
      }).catch((error: Error): void => {
        finish(error.message);
      });
      return handle;
    }

    let session: AiSessionHolder | null = null;
    try {
      const params: ChatCompletionCreateParamsBase = {
        model: config.model,
        messages: AiServiceHttp.toSdkMessages(messages),
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
          // 同 sdkStreamRound：napi 回调里未捕获异常会直接终止应用，解析必须包底
          try {
            for (let i = 0; i < chunks.length; i++) {
              const chunk: Object | undefined = chunks[i] as Object;
              if (chunk === undefined || chunk === null || typeof chunk !== 'object') {
                continue;
              }
              const choices: Object | undefined = (chunk as Record<string, Object>)['choices'];
              if (!Array.isArray(choices) || (choices as Object[]).length === 0) {
                continue;
              }
              const first: Object = (choices as Object[])[0];
              if (first === undefined || first === null || typeof first !== 'object') {
                continue;
              }
              const deltaObj: Object | undefined = (first as Record<string, Object>)['delta'];
              if (deltaObj === undefined || deltaObj === null || typeof deltaObj !== 'object') {
                // 尾包常见形态：只有 finish_reason 没有 delta
                continue;
              }
              const rec: Record<string, Object> = deltaObj as Record<string, Object>;
              const delta: Object | undefined = rec['content'];
              if (typeof delta === 'string') {
                piece += delta;
              }
              // SDK 类型没声明 reasoning_content，但运行时是 JSON 透传，按 Record 取
              const reasoning = rec['reasoning_content'];
              if (typeof reasoning === 'string') {
                think += reasoning;
              }
            }
          } catch (_error) {
            // 畸形分片静默跳过
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
            finish(AiServiceHttp.friendlyMessage(error.message));
          }
        },
      });
      session = result.session as AiSessionHolder;
      result.response.then((response): void => {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          finish(AiServiceHttp.httpErrorText(response.statusCode, AiServiceHttp.responseText(response.body)));
          return;
        }
        finish('');
      }).catch((error: Error): void => {
        finish(AiServiceHttp.friendlyMessage(error.message));
      });
    } catch (error) {
      finish(AiServiceHttp.friendlyMessage(error instanceof Error ? error.message : String(error)));
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
    const config: AiConfig = override !== undefined ? override : AiServiceConfig.loadConfig();
    const apiKey: string = AiServiceConfig.apiKeyFor(config.providerId);
    if (config.baseUrl.length === 0 || config.model.length === 0) {
      throw new Error('请先配置 AI 接口地址与模型');
    }
    if (apiKey.length === 0) {
      throw new Error('请先配置 AI API Key');
    }
    if (AiServiceHttp.isOpenCodeGateway(config.baseUrl)) {
      // 结构化输出（书单 JSON 等）不需要工具，避免模型中途改去查数据
      return AiServiceGateway.chatViaGateway(config, apiKey, messages, maxTokens, rcp.createSession(),
        null, AiServiceConfig.loadPermission(), null, null, null, null, null, null);
    }
    const client: OpenAI = AiServiceHttp.client(config.baseUrl, apiKey);
    const params: ChatCompletionCreateParamsBase = {
      model: config.model,
      messages: AiServiceHttp.toSdkMessages(messages),
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
      text = AiServiceHttp.responseText(response.body);
    } catch (error) {
      throw new Error(AiServiceHttp.friendlyMessage(error instanceof Error ? error.message : String(error)));
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw new Error(AiServiceHttp.httpErrorText(statusCode, text));
    }
    const content: string = AiServiceHttp.parseContent(text);
    if (content.length === 0) {
      throw new Error('AI 返回内容为空，请检查模型是否可用');
    }
    return content;
  }

  /** 建 SDK 客户端。地址按 SDK 约定只给到 `/v1`，它自己拼 `/chat/completions`。 */

  /** 委托 AiServiceConfig.loadConfig（拆分：见文件头说明）。 */
  static loadConfig(): AiConfig {
    return AiServiceConfig.loadConfig();
  }
  /** 委托 AiServiceConfig.detectVision（拆分：见文件头说明）。 */
  static detectVision(model: string): boolean {
    return AiServiceConfig.detectVision(model);
  }
  /** 委托 AiServiceConfig.contextRounds（拆分：见文件头说明）。 */
  static contextRounds(contextK: number): number {
    return AiServiceConfig.contextRounds(contextK);
  }
  /** 委托 AiServiceConfig.loadPermission（拆分：见文件头说明）。 */
  static loadPermission(): AiPermissionMode {
    return AiServiceConfig.loadPermission();
  }
  /** 委托 AiServiceConfig.savePermission（拆分：见文件头说明）。 */
  static savePermission(mode: AiPermissionMode): void {
    AiServiceConfig.savePermission(mode);
  }
  /** 委托 AiServiceConfig.loadAutoSpeak（拆分：见文件头说明）。 */
  static loadAutoSpeak(): boolean {
    return AiServiceConfig.loadAutoSpeak();
  }
  /** 委托 AiServiceConfig.saveAutoSpeak（拆分：见文件头说明）。 */
  static saveAutoSpeak(on: boolean): void {
    AiServiceConfig.saveAutoSpeak(on);
  }
  /** 委托 AiServiceConfig.loadVoiceConfig（拆分：见文件头说明）。 */
  static loadVoiceConfig(): AiConfig {
    return AiServiceConfig.loadVoiceConfig();
  }
  /** 委托 AiServiceConfig.hasVoiceProvider（拆分：见文件头说明）。 */
  static hasVoiceProvider(): boolean {
    return AiServiceConfig.hasVoiceProvider();
  }
  /** 委托 AiServiceConfig.saveVoiceConfig（拆分：见文件头说明）。 */
  static saveVoiceConfig(providerId: string, model: string): void {
    AiServiceConfig.saveVoiceConfig(providerId, model);
  }
  /** 委托 AiServiceConfig.loadVoiceProviderId（拆分：见文件头说明）。 */
  static loadVoiceProviderId(): string {
    return AiServiceConfig.loadVoiceProviderId();
  }
  /** 委托 AiServiceConfig.loadVoiceModel（拆分：见文件头说明）。 */
  static loadVoiceModel(): string {
    return AiServiceConfig.loadVoiceModel();
  }
  /** 委托 AiServiceConfig.loadRealtimeTimbre（拆分：见文件头说明）。 */
  static loadRealtimeTimbre(): string {
    return AiServiceConfig.loadRealtimeTimbre();
  }
  /** 委托 AiServiceConfig.saveRealtimeTimbre（拆分：见文件头说明）。 */
  static saveRealtimeTimbre(voice: string): void {
    AiServiceConfig.saveRealtimeTimbre(voice);
  }
  /** 委托 AiServiceConfig.loadTtsTimbre（拆分：见文件头说明）。 */
  static loadTtsTimbre(): string {
    return AiServiceConfig.loadTtsTimbre();
  }
  /** 委托 AiServiceConfig.saveTtsTimbre（拆分：见文件头说明）。 */
  static saveTtsTimbre(voice: string): void {
    AiServiceConfig.saveTtsTimbre(voice);
  }
  /** 委托 AiServiceConfig.loadSpeakEngine（拆分：见文件头说明）。 */
  static loadSpeakEngine(): string {
    return AiServiceConfig.loadSpeakEngine();
  }
  /** 委托 AiServiceConfig.saveSpeakEngine（拆分：见文件头说明）。 */
  static saveSpeakEngine(engine: string): void {
    AiServiceConfig.saveSpeakEngine(engine);
  }
  /** 委托 AiServiceConfig.loadCallMode（拆分：见文件头说明）。 */
  static loadCallMode(): string {
    return AiServiceConfig.loadCallMode();
  }
  /** 委托 AiServiceConfig.saveCallMode（拆分：见文件头说明）。 */
  static saveCallMode(mode: string): void {
    AiServiceConfig.saveCallMode(mode);
  }
  /** 委托 AiServiceConfig.apiKeyKey（拆分：见文件头说明）。 */
  static apiKeyKey(providerId: string): string {
    return AiServiceConfig.apiKeyKey(providerId);
  }
  /** 委托 AiServiceConfig.apiKeyFor（拆分：见文件头说明）。 */
  static apiKeyFor(providerId: string): string {
    return AiServiceConfig.apiKeyFor(providerId);
  }
  /** 委托 AiServiceConfig.baseUrlFor（指定服务商的接口地址，按服务商分槽）。 */
  static baseUrlFor(providerId: string): string {
    return AiServiceConfig.baseUrlFor(providerId);
  }
  /** 委托 AiServiceConfig.hasKeyFor（拆分：见文件头说明）。 */
  static hasKeyFor(providerId: string): boolean {
    return AiServiceConfig.hasKeyFor(providerId);
  }
  /** 委托 AiServiceConfig.migrateLegacyKey（拆分：见文件头说明）。 */
  static migrateLegacyKey(): void {
    AiServiceConfig.migrateLegacyKey();
  }
  /** 委托 AiServiceConfig.listCustomProviders（拆分：见文件头说明）。 */
  static listCustomProviders(): AiProviderPreset[] {
    return AiServiceConfig.listCustomProviders();
  }
  /** 委托 AiServiceConfig.listProviders（拆分：见文件头说明）。 */
  static listProviders(): AiProviderPreset[] {
    return AiServiceConfig.listProviders();
  }
  /** 委托 AiServiceConfig.addCustomProvider（拆分：见文件头说明）。 */
  static addCustomProvider(name: string, baseUrl: string, model: string): AiProviderPreset {
    return AiServiceConfig.addCustomProvider(name, baseUrl, model);
  }
  /** 委托 AiServiceConfig.removeCustomProvider（拆分：见文件头说明）。 */
  static removeCustomProvider(id: string): void {
    AiServiceConfig.removeCustomProvider(id);
  }
  /** 委托 AiServiceConfig.saveCustomProviders（拆分：见文件头说明）。 */
  static saveCustomProviders(list: AiProviderPreset[]): void {
    AiServiceConfig.saveCustomProviders(list);
  }
  /** 委托 AiServiceConfig.loadProviderModels（拆分：见文件头说明）。 */
  static loadProviderModels(providerId: string): string[] {
    return AiServiceConfig.loadProviderModels(providerId);
  }
  /** 委托 AiServiceConfig.saveProviderModels（拆分：见文件头说明）。 */
  static saveProviderModels(providerId: string, models: string[]): void {
    AiServiceConfig.saveProviderModels(providerId, models);
  }
  /** 委托 AiServiceConfig.presetOf（拆分：见文件头说明）。 */
  static presetOf(providerId: string): AiProviderPreset {
    return AiServiceConfig.presetOf(providerId);
  }
  /** 委托 AiServiceConfig.saveConfig（拆分：见文件头说明）。 */
  static saveConfig(providerId: string, baseUrl: string, model: string, apiKey: string, temperature: number, visionOverride: string = '', contextLength: number = DEFAULT_CONTEXT_K): void {
    AiServiceConfig.saveConfig(providerId, baseUrl, model, apiKey, temperature, visionOverride, contextLength);
  }
  /** 委托 AiServiceConfig.clearKey（拆分：见文件头说明）。 */
  static clearKey(): void {
    AiServiceConfig.clearKey();
  }
  /** 委托 AiServiceConfig.isReady（拆分：见文件头说明）。 */
  static isReady(): boolean {
    return AiServiceConfig.isReady();
  }

  /** 委托 AiServiceHttp.client（拆分：见文件头说明）。 */
  static client(baseUrl: string, apiKey: string): OpenAI {
    return AiServiceHttp.client(baseUrl, apiKey);
  }
  /** 委托 AiServiceHttp.toSdkMessages（拆分：见文件头说明）。 */
  static toSdkMessages(messages: AiMessage[]): ChatCompletionMessageParam[] {
    return AiServiceHttp.toSdkMessages(messages);
  }
  /** 委托 AiServiceHttp.gatewayContent（拆分：见文件头说明）。 */
  static gatewayContent(m: AiMessage): Object {
    return AiServiceHttp.gatewayContent(m);
  }
  /** 委托 AiServiceHttp.opencodeSessionId（拆分：见文件头说明）。 */
  static opencodeSessionId(): string {
    return AiServiceHttp.opencodeSessionId();
  }
  /** 委托 AiServiceHttp.isOpenCodeGateway（拆分：见文件头说明）。 */
  static isOpenCodeGateway(baseUrl: string): boolean {
    return AiServiceHttp.isOpenCodeGateway(baseUrl);
  }
  /** 委托 AiServiceHttp.supportsTools（拆分：见文件头说明）。 */
  static supportsTools(): boolean {
    return AiServiceHttp.supportsTools();
  }
  /** 委托 AiServiceHttp.sleep（拆分：见文件头说明）。 */
  static sleep(ms: number): Promise<void> {
    return AiServiceHttp.sleep(ms);
  }
  /** 委托 AiServiceHttp.responseBodyText（拆分：见文件头说明）。 */
  static responseBodyText(body: string | Object | ArrayBuffer | undefined): string {
    return AiServiceHttp.responseBodyText(body);
  }
  /** 委托 AiServiceHttp.toolset（拆分：见文件头说明）。 */
  static toolset(mode: AiPermissionMode, mcpTools: AiToolDefinition[] | null): AiToolDefinition[] {
    return AiServiceHttp.toolset(mode, mcpTools);
  }
  /** 委托 AiServiceHttp.mcpToolset（拆分：见文件头说明）。 */
  static async mcpToolset(): Promise<AiToolDefinition[]> {
    return AiServiceHttp.mcpToolset();
  }
  /** 委托 AiServiceHttp.toolLabelFor（拆分：见文件头说明）。 */
  static toolLabelFor(name: string): string {
    return AiServiceHttp.toolLabelFor(name);
  }
  /** 委托 AiServiceHttp.toolRunFor（拆分：见文件头说明）。 */
  static toolRunFor(name: string, args: string, callId: string): Promise<string> {
    return AiServiceHttp.toolRunFor(name, args, callId);
  }
  /** 委托 AiServiceHttp.fetchModels（拆分：见文件头说明）。 */
  static async fetchModels(providerId: string, baseUrl: string, apiKeyInput: string): Promise<string[]> {
    return AiServiceHttp.fetchModels(providerId, baseUrl, apiKeyInput);
  }
  /** 委托 AiServiceHttp.supportsNativeOnlineSearch（拆分：见文件头说明）。 */
  static supportsNativeOnlineSearch(baseUrl: string): boolean {
    return AiServiceHttp.supportsNativeOnlineSearch(baseUrl);
  }
  /** 委托 AiServiceHttp.aiSearchOnline（拆分：见文件头说明）。 */
  static async aiSearchOnline(query: string): Promise<LlmSearchResult> {
    return AiServiceHttp.aiSearchOnline(query);
  }
  /** 委托 AiServiceHttp.normalizeBaseUrl（拆分：见文件头说明）。 */
  static normalizeBaseUrl(baseUrl: string): string {
    return AiServiceHttp.normalizeBaseUrl(baseUrl);
  }
  /** 委托 AiServiceHttp.responseText（拆分：见文件头说明）。 */
  static responseText(body: ArrayBuffer | undefined): string {
    return AiServiceHttp.responseText(body);
  }
  /** 委托 AiServiceHttp.parseContent（拆分：见文件头说明）。 */
  static parseContent(raw: string): string {
    return AiServiceHttp.parseContent(raw);
  }
  /** 委托 AiServiceHttp.friendlyMessage（拆分：见文件头说明）。 */
  static friendlyMessage(message: string): string {
    return AiServiceHttp.friendlyMessage(message);
  }
  /** 委托 AiServiceHttp.httpErrorText（拆分：见文件头说明）。 */
  static httpErrorText(status: number, body: string): string {
    return AiServiceHttp.httpErrorText(status, body);
  }
  /** 委托 AiServiceHttp.extractErrorDetail（拆分：见文件头说明）。 */
  static extractErrorDetail(body: string): string {
    return AiServiceHttp.extractErrorDetail(body);
  }

  /** 委托 AiServiceGateway.chatViaGateway（拆分：见文件头说明）。 */
  static async chatViaGateway(config: AiConfig, apiKey: string, messages: AiMessage[], maxTokens: number, session: rcp.Session, tools: AiToolDefinition[] | null, permission: AiPermissionMode, isAborted: (() => boolean) | null, onTool: ((label: string, name: string) => void) | null, onConfirm: ((label: string, argsSummary: string) => Promise<boolean>) | null, onResult: ((name: string, label: string, text: string, callId: string) => void) | null, onReasoning: ((text: string) => void) | null, onAsk: ((question: string, options: string[]) => Promise<string>) | null): Promise<string> {
    return AiServiceGateway.chatViaGateway(config, apiKey, messages, maxTokens, session, tools, permission, isAborted, onTool, onConfirm, onResult, onReasoning, onAsk);
  }
  /** 委托 AiServiceGateway.runToolLoop（拆分：见文件头说明）。 */
  static async runToolLoop(gwMessages: GatewayMessage[], transport: (attach: AiToolDefinition[] | null) => Promise<GatewayReply | null>, tools: AiToolDefinition[] | null, permission: AiPermissionMode, isAborted: (() => boolean) | null, onTool: ((label: string, name: string) => void) | null, onConfirm: ((label: string, argsSummary: string) => Promise<boolean>) | null, onResult: ((name: string, label: string, text: string, callId: string) => void) | null, onReasoning: ((text: string) => void) | null, onAsk: ((question: string, options: string[]) => Promise<string>) | null): Promise<string> {
    return AiServiceGateway.runToolLoop(gwMessages, transport, tools, permission, isAborted, onTool, onConfirm, onResult, onReasoning, onAsk);
  }
  /** 委托 AiServiceGateway.parseAskArgs（拆分：见文件头说明）。 */
  static parseAskArgs(argsJson: string): AskPayload {
    return AiServiceGateway.parseAskArgs(argsJson);
  }
  /** 委托 AiServiceGateway.consumeStreamChunks（拆分：见文件头说明）。 */
  static consumeStreamChunks(chunks: ChatCompletionChunk[], slots: GatewayToolCall[], reply: GatewayReply, onDelta: (text: string) => void, onReasoning: ((text: string) => void) | null): void {
    AiServiceGateway.consumeStreamChunks(chunks, slots, reply, onDelta, onReasoning);
  }
  /** 委托 AiServiceGateway.sdkStreamRound（拆分：见文件头说明）。 */
  static sdkStreamRound(client: OpenAI, config: AiConfig, gwMessages: GatewayMessage[], maxTokens: number, attach: AiToolDefinition[] | null, handle: AiAbortHandle, onDelta: (text: string) => void, onReasoning: ((text: string) => void) | null, sessionBox: AiSessionHolder[]): Promise<GatewayReply | null> {
    return AiServiceGateway.sdkStreamRound(client, config, gwMessages, maxTokens, attach, handle, onDelta, onReasoning, sessionBox);
  }
  /** 委托 AiServiceGateway.parseGatewayReply（拆分：见文件头说明）。 */
  static parseGatewayReply(raw: string): GatewayReply {
    return AiServiceGateway.parseGatewayReply(raw);
  }
}

/** 中断句柄。 */
export interface AiAbortHandle {
  aborted: boolean;
  destroy?: () => void;
}

