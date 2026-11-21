/**
 * AiService 传输辅助（拆分自 AiService.ets）：SDK 客户端构造、消息转换、OpenCode 会话头、
 * 模型清单 fetch、通义联网问答、响应体解码与错误文案。
 */
import { OpenAI } from '@iuroc/openai';
import { util } from '@kit.ArkTS';
import { rcp } from '@kit.RemoteCommunicationKit';
import type { ChatCompletionMessageParam } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import type { ChatCompletionContentPart } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import type { ChatCompletionContentPartText } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import type { ChatCompletionContentPartImage } from '@iuroc/openai/src/main/ets/openai@4.73.1/resources/chat/completions';
import { TalebookService } from './TalebookService';
import { AiTools } from './AiTools';
import type { AiPermissionMode } from './AiTools';
import type { AiToolDefinition } from './AiToolsDefs';
import { McpService } from './McpService';
import type { AiMessage, AiConfig, LlmSearchResult } from './AiService';
import { KEY_SESSION_ID, TIMEOUT_MS, MAX_TOOL_ROUNDS } from './AiServiceConfig';
import { AiServiceConfig } from './AiServiceConfig';

export class AiServiceHttp {
  static async fetchModels(providerId: string, baseUrl: string, apiKeyInput: string): Promise<string[]> {
    const key: string = apiKeyInput.trim().length > 0 ? apiKeyInput.trim() : AiServiceConfig.apiKeyFor(providerId);
    const base: string = AiServiceHttp.normalizeBaseUrl(baseUrl);
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
    if (AiServiceHttp.isOpenCodeGateway(base)) {
      headers['x-opencode-session'] = AiServiceHttp.opencodeSessionId();
    }
    const session: rcp.Session = rcp.createSession();
    let statusCode: number = 0;
    let text: string = '';
    try {
      const request: rcp.Request = new rcp.Request(`${base}/models`, 'GET', headers);
      const response: rcp.Response = await session.fetch(request);
      statusCode = response.statusCode;
      text = AiServiceHttp.responseBodyText(response.body);
    } catch (error) {
      throw new Error(AiServiceHttp.friendlyMessage(error instanceof Error ? error.message : String(error)));
    } finally {
      session.close();
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw new Error(AiServiceHttp.httpErrorText(statusCode, text));
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

  /**
   * 是否支持服务端内置联网搜索（enable_search 为通义 DashScope 兼容模式私有参数）。
   * 按域名判定：dashscope / maas / token-plan 均落在 aliyuncs.com，自建 OpenAI 兼容服务不会误判。
   */
  static supportsNativeOnlineSearch(baseUrl: string): boolean {
    return baseUrl.indexOf('aliyuncs.com') >= 0;
  }

  /**
   * AI 联网问答：用当前模型开 enable_search + forced_search（强制联网、不让模型凭记忆作答），
   * rcp 直连绕开 SDK 类型限制（同 fetchModels 通道形态）。
   * 返回正文与 search_info.search_results 引用列表（≤6 条）；失败全部转 ok=false+error，不抛错。
   */
  static async aiSearchOnline(query: string): Promise<LlmSearchResult> {
    const res: LlmSearchResult = { ok: false, answer: '', sources: [], error: '' };
    const cfg: AiConfig = AiServiceConfig.loadConfig();
    const key: string = AiServiceConfig.apiKeyFor(cfg.providerId);
    if (key.length === 0) {
      res.error = '请先在设置页填写该服务商的 API Key';
      return res;
    }
    const base: string = AiServiceHttp.normalizeBaseUrl(cfg.baseUrl);
    try {
      const messages: AiMessage[] = [
        { role: 'system', content: '根据实时网页检索结果回答用户问题：先给关键事实，涉及时间请标注日期；检索结果互相矛盾时如实说明。' },
        { role: 'user', content: query },
      ];
      const searchOpts: Record<string, Object> = { 'forced_search': true };
      const payload: Record<string, Object> = {
        'model': cfg.model,
        'messages': messages,
        'stream': false,
        'max_tokens': 900,
        'enable_search': true,
        'search_options': searchOpts,
      };
      const headers: rcp.RequestHeaders = {
        'Authorization': `Bearer ${key}`,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };
      const session: rcp.Session = rcp.createSession();
      let statusCode: number = 0;
      let text: string = '';
      try {
        const request: rcp.Request = new rcp.Request(`${base}/chat/completions`, 'POST', headers, JSON.stringify(payload));
        const response: rcp.Response = await session.fetch(request);
        statusCode = response.statusCode;
        text = AiServiceHttp.responseBodyText(response.body);
      } finally {
        session.close();
      }
      if (statusCode < 200 || statusCode >= 300) {
        res.error = AiServiceHttp.httpErrorText(statusCode, text);
        return res;
      }
      const root = JSON.parse(text) as Record<string, Object>;
      const choices = root['choices'] as Object[] | undefined;
      if (choices !== undefined && choices.length > 0) {
        const msg = (choices[0] as Record<string, Object>)['message'] as Record<string, Object> | undefined;
        if (msg !== undefined) {
          const content: Object | undefined = msg['content'];
          res.answer = content === undefined ? '' : String(content);
        }
      }
      const info = root['search_info'] as Record<string, Object> | undefined;
      if (info !== undefined) {
        const hits = info['search_results'] as Object[] | undefined;
        if (hits !== undefined) {
          for (let i = 0; i < hits.length && res.sources.length < 6; i++) {
            const h = hits[i] as Record<string, string>;
            const title: string = h['title'] === undefined ? '' : h['title'];
            const url: string = h['url'] === undefined ? '' : h['url'];
            if (title.length > 0 && url.length > 0) {
              res.sources.push({ title: title, url: url });
            }
          }
        }
      }
      if (res.answer.trim().length === 0) {
        res.error = '联网搜索返回了空答案';
        return res;
      }
      res.ok = true;
      return res;
    } catch (error) {
      res.error = error instanceof Error ? error.message : `${error}`;
      return res;
    }
  }

  /** rcp 的 body 可能是 string / ArrayBuffer / 已解析对象，统一转文本。 */
  static responseBodyText(body: string | Object | ArrayBuffer | undefined): string {
    if (body === undefined || body === null) {
      return '';
    }
    if (typeof body === 'string') {
      return body as string;
    }
    if (body instanceof ArrayBuffer) {
      return AiServiceHttp.responseText(body);
    }
    return JSON.stringify(body);
  }

  /**
   * 流式对话。返回可中断句柄：调用 `abort()` 停止请求。
   *
   * SDK 的 `onData` 已经是逐 chunk 回调（内部完成 SSE 拆行与 UTF-8 解码），
   * 这里只把 chunk 拼成文本转发给 UI。
   */
  /** 内置工具 + MCP 动态工具合并（MCP 全只读，任何权限档都保留）。 */
  static toolset(mode: AiPermissionMode, mcpTools: AiToolDefinition[] | null): AiToolDefinition[] {
    const base: AiToolDefinition[] = AiTools.definitions(mode);
    if (mcpTools === null || mcpTools.length === 0) {
      return base;
    }
    return base.concat(mcpTools);
  }

  /**
   * MCP 工具集门面（聊天页发送前 await）：仅当前服务商=Token Plan 且已配 Key
   * 才连接百炼三家 MCP；其余情形/任何失败都回空集，聊天走内置工具。
   */
  static async mcpToolset(): Promise<AiToolDefinition[]> {
    const config: AiConfig = AiServiceConfig.loadConfig();
    const key: string = AiServiceConfig.apiKeyFor(config.providerId);
    if (!McpService.enabledFor(config.providerId, key)) {
      return [];
    }
    try {
      return await McpService.ensureToolset(key);
    } catch (_error) {
      return [];
    }
  }

  /** 活动标签：MCP 工具显 server 中文名，内置工具走 AiTools 映射。 */
  static toolLabelFor(name: string): string {
    return McpService.isMcpTool(name) ? McpService.labelOf(name) : AiTools.toolLabel(name);
  }

  /** 执行路由：mcp_ 前缀走 MCP（自带容错），其余走内置执行器。 */
  static toolRunFor(name: string, args: string, callId: string): Promise<string> {
    if (McpService.isMcpTool(name)) {
      const config: AiConfig = AiServiceConfig.loadConfig();
      return McpService.callTool(name, args, AiServiceConfig.apiKeyFor(config.providerId));
    }
    return AiTools.execute(name, args, callId);
  }
  /**
   * mcpTools：MCP 动态工具集（发送前经 AiServiceHttp.mcpToolset() 预热取得），
   * 与内置工具合并挂载；null/空 = 只挂内置工具（非 Token Plan 或握手失败）。
   */

  static client(baseUrl: string, apiKey: string): OpenAI {
    return new OpenAI({
      apiKey: apiKey,
      baseURL: AiServiceHttp.normalizeBaseUrl(baseUrl),
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
  static toSdkMessages(messages: AiMessage[]): ChatCompletionMessageParam[] {
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
  static gatewayContent(m: AiMessage): Object {
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
  static opencodeSessionId(): string {
    let id: string = TalebookService.prefGet(KEY_SESSION_ID);
    if (id.length === 0) {
      id = util.generateRandomUUID(true);
      TalebookService.prefSet(KEY_SESSION_ID, id);
    }
    return id;
  }

  /** 是否走 OpenCode 网关（opencode.ai）。 */
  static isOpenCodeGateway(baseUrl: string): boolean {
    return baseUrl.indexOf('opencode.ai') >= 0;
  }

  /**
   * 当前配置通道是否具备工具能力：所有 OpenAI 兼容通道都走 rcp 整包工具回路
   * （挂 tools + function calling），仅自定义/非标准接口例外。
   * 系统提示词据此决定是否写工具指引——无 tools 还让模型「先调用工具」，
   * 模型会伪造伪工具调用文本当正文输出（实测 Token Plan 通道 [tools] xxx [/tools]）。
   */
  static supportsTools(): boolean {
    // 回路已泛化：网关整包回路 + SDK 流式回路（运行时累积 tool_calls）都挂 tools，
    // 项目内所有服务商均为 OpenAI 兼容。若未来接入非兼容服务商，在此按 providerId 排除。
    return true;
  }

  /** 退避等待（网关重试间隔用）。 */
  static sleep(ms: number): Promise<void> {
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

  static normalizeBaseUrl(baseUrl: string): string {
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
  static responseText(body: ArrayBuffer | undefined): string {
    if (body === undefined || body.byteLength === 0) {
      return '';
    }
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(body));
  }

  static parseContent(raw: string): string {
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
  static friendlyMessage(message: string): string {
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

  static httpErrorText(status: number, body: string): string {
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
    const detail: string = AiServiceHttp.extractErrorDetail(body);
    if (detail.length > 0) {
      return `AI 服务返回 ${status}：${detail}`;
    }
    return `AI 服务返回 HTTP ${status}`;
  }

  static extractErrorDetail(body: string): string {
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

/** SDK 会话只用到 cancel()；单独声明避免依赖 rcp 的完整类型。 */
export interface AiSessionHolder {
  cancel: () => void;
}


