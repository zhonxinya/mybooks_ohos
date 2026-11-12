import { OpenAI } from '@iuroc/openai';
import { util } from '@kit.ArkTS';
import { ChatCompletionChunk } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { ChatCompletionMessageParam } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { ChatCompletionCreateParamsBase } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { TalebookService } from './TalebookService';

/**
 * 本地大模型接入：**传输层用开源 SDK `@iuroc/openai`**，业务侧仍走本项目自己的门面。
 *
 * 设计要点：
 * - **纯客户端配置**：API 地址 / 模型 / Key 全部由用户在本机填写，不经过本项目服务端，
 *   也不依赖服务端的 `AI_*` 配置项（那些只影响服务端自己的 AI 助手）。
 * - **Key 存 Asset Store**：复用 `PasswordStore`（鸿蒙关键资产存储 / Android AES-GCM），
 *   不进明文 preferences。
 * - **一套协议覆盖主流服务商**：OpenAI、DeepSeek、通义、Kimi、智谱、Ollama、LM Studio、
 *   OneAPI 等均提供 `/v1/chat/completions`，因此只实现这一种请求格式。
 * - **流式优先**：SDK 的 `onData` 逐块回调，长文本（书评/摘要）不必等整段生成完才显示。
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
  { id: 'custom', name: '自定义', baseUrl: '', model: '', vision: false },
];

/** 一条对话消息（OpenAI 协议）。 */
export interface AiMessage {
  role: string;
  content: string;
}

/** 运行时配置。 */
export interface AiConfig {
  providerId: string;
  baseUrl: string;
  model: string;
  /** 是否已保存 Key（不回传明文，只用于 UI 显示状态）。 */
  hasKey: boolean;
  temperature: number;
}

const KEY_PROVIDER: string = 'ai_provider';
const KEY_BASE_URL: string = 'ai_base_url';
const KEY_MODEL: string = 'ai_model';
const KEY_API_KEY: string = 'ai_api_key';
const KEY_TEMPERATURE: string = 'ai_temperature';

const DEFAULT_TEMPERATURE: number = 0.7;
const TIMEOUT_MS: number = 180000;

/** 流式回调：`delta` 为本次增量文本，`done` 表示结束。 */
export interface AiStreamHandlers {
  onDelta: (delta: string) => void;
  onDone: (fullText: string) => void;
  onError: (message: string) => void;
}

export class AiService {
  /** 读取当前配置（Key 只回传是否存在）。 */
  static loadConfig(): AiConfig {
    const providerId: string = TalebookService.prefGet(KEY_PROVIDER, 'deepseek');
    const preset: AiProviderPreset = AiService.presetOf(providerId);
    const baseUrl: string = TalebookService.secureGet(KEY_BASE_URL);
    const model: string = TalebookService.prefGet(KEY_MODEL);
    const temperatureText: string = TalebookService.prefGet(KEY_TEMPERATURE);
    const temperature: number = temperatureText.length > 0 ? Number(temperatureText) : DEFAULT_TEMPERATURE;
    return {
      providerId: providerId,
      baseUrl: baseUrl.length > 0 ? baseUrl : preset.baseUrl,
      model: model.length > 0 ? model : preset.model,
      hasKey: TalebookService.secureGet(KEY_API_KEY).length > 0,
      temperature: Number.isFinite(temperature) ? temperature : DEFAULT_TEMPERATURE,
    };
  }

  static presetOf(providerId: string): AiProviderPreset {
    for (let i = 0; i < AI_PROVIDERS.length; i++) {
      if (AI_PROVIDERS[i].id === providerId) {
        return AI_PROVIDERS[i];
      }
    }
    return AI_PROVIDERS[AI_PROVIDERS.length - 1];
  }

  /** 保存配置。`apiKey` 传空串表示保持原值不变。 */
  static saveConfig(providerId: string, baseUrl: string, model: string, apiKey: string,
    temperature: number): void {
    TalebookService.prefSet(KEY_PROVIDER, providerId);
    TalebookService.secureSet(KEY_BASE_URL, AiService.normalizeBaseUrl(baseUrl));
    TalebookService.prefSet(KEY_MODEL, model.trim());
    TalebookService.prefSet(KEY_TEMPERATURE, `${temperature}`);
    if (apiKey.length > 0) {
      TalebookService.secureSet(KEY_API_KEY, apiKey.trim());
    }
  }

  static clearKey(): void {
    TalebookService.secureSet(KEY_API_KEY, '');
  }

  /** 是否已配置到可用状态（地址、模型、Key 都有）。 */
  static isReady(): boolean {
    const config: AiConfig = AiService.loadConfig();
    return config.baseUrl.length > 0 && config.model.length > 0 && config.hasKey;
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
    const apiKey: string = TalebookService.secureGet(KEY_API_KEY);

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
          for (let i = 0; i < chunks.length; i++) {
            const choices = chunks[i].choices;
            if (choices !== undefined && choices.length > 0) {
              const delta = choices[0].delta.content;
              if (delta !== undefined && delta !== null) {
                piece += delta;
              }
            }
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
  static async complete(messages: AiMessage[], maxTokens: number = 2048): Promise<string> {
    const config: AiConfig = AiService.loadConfig();
    const apiKey: string = TalebookService.secureGet(KEY_API_KEY);
    if (config.baseUrl.length === 0 || config.model.length === 0) {
      throw new Error('请先配置 AI 接口地址与模型');
    }
    if (apiKey.length === 0) {
      throw new Error('请先配置 AI API Key');
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
        out.push({ role: 'user', content: m.content });
      }
    }
    return out;
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

/** SDK 会话只用到 cancel()；单独声明避免依赖 rcp 的完整类型。 */
interface AiSessionHolder {
  cancel: () => void;
}
