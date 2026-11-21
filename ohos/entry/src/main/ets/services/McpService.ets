import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { AiToolDefinition, AiToolFunctionBody, AiToolParameters } from './AiTools';

/**
 * 百炼 MCP 客户端（Streamable HTTP / JSON-RPC 2.0）。
 *
 * 三家 MCP server 挂在 Token Plan 网关域，鉴权复用设置页已填的 qwen-tokenplan Key；
 * 当前服务商非 Token Plan 或未配 Key 时整个工具集为空（零请求、静默降级）。
 * 协议流程：initialize → notifications/initialized → tools/list → tools/call，
 * 会话 id 走 `mcp-session-id` 响应头；响应体兼容纯 JSON 与 SSE `data:` 两种形态。
 */

/** MCP server 登记：tag 用于工具名前缀 `mcp_<tag>_<工具名>`（三家工具名可能重名）。 */
interface McpServer {
  tag: string;
  label: string;
  url: string;
}

/** 单个 server 的握手产物（会话 id + 工具清单）。 */
interface McpServerState {
  server: McpServer;
  sessionId: string;
  tools: AiToolDefinition[];
}

/** rpc 返回：JSON-RPC 信封拆出的 result / 会话头 / 错误文本。 */
interface McpRpcReply {
  result: Record<string, Object> | null;
  sessionId: string;
  error: string;
}

const MCP_SERVERS: McpServer[] = [
  { tag: 'es', label: '百炼增强搜索', url: 'https://cn-beijing.maas.qianwenaiapi.com/api/v1/mcps/EnhancedSearch/mcp' },
  { tag: 'wf', label: '百炼网页解析', url: 'https://cn-beijing.maas.qianwenaiapi.com/api/v1/mcps/WebFetch/mcp' },
  { tag: 'sg', label: '百炼语音转写', url: 'https://cn-beijing.maas.qianwenaiapi.com/api/v1/mcps/SpeechGenerateText/mcp' },
];

/** MCP 鉴权即 Token Plan 服务商的 Key（用户明确：复用已填写的）。 */
const MCP_PROVIDER_ID: string = 'qwen-tokenplan';
/** 工具集缓存时效：过期重新握手（服务端工具/会话可能失效）。 */
const MCP_CACHE_TTL_MS: number = 600000;
/** 工具名前缀段长度：`mcp_es_` 这类固定头部，剥掉后即服务端原名。 */
const MCP_PREFIX: string = 'mcp_';

export class McpService {
  private static cacheKey: string = '';
  private static cacheAt: number = 0;
  private static states: McpServerState[] = [];

  /** 当前服务商是否启用 MCP。 */
  static enabledFor(providerId: string, apiKey: string): boolean {
    return providerId === MCP_PROVIDER_ID && apiKey.length > 0;
  }

  /** 清空缓存（服务商/Key 变更后调用，下次发送重新握手）。 */
  static reset(): void {
    McpService.cacheKey = '';
    McpService.cacheAt = 0;
    McpService.states = [];
  }

  /**
   * 取全量 MCP 工具定义（合并三家）：命中缓存零请求；单家失败静默跳过，
   * 三家全挂返回空数组——聊天照常走内置工具。
   */
  static async ensureToolset(apiKey: string): Promise<AiToolDefinition[]> {
    if (apiKey.length === 0) {
      return [];
    }
    const now: number = Date.now();
    if (McpService.cacheKey !== apiKey || now - McpService.cacheAt >= MCP_CACHE_TTL_MS) {
      const fresh: (McpServerState | null)[] = await Promise.all(
        MCP_SERVERS.map((s: McpServer): Promise<McpServerState | null> => McpService.handshake(s, apiKey)));
      const states: McpServerState[] = [];
      for (let i = 0; i < fresh.length; i++) {
        const st: McpServerState | null = fresh[i];
        if (st !== null && st.tools.length > 0) {
          states.push(st);
        }
      }
      McpService.states = states;
      McpService.cacheKey = apiKey;
      McpService.cacheAt = now;
    }
    const out: AiToolDefinition[] = [];
    for (let i = 0; i < McpService.states.length; i++) {
      const tools: AiToolDefinition[] = McpService.states[i].tools;
      for (let j = 0; j < tools.length; j++) {
        out.push(tools[j]);
      }
    }
    return out;
  }

  /** 工具名是否属于 MCP（回路路由用）。 */
  static isMcpTool(name: string): boolean {
    return name.startsWith(MCP_PREFIX);
  }

  /** 活动标签：mcp_es_xxx → 「百炼增强搜索」；认不出回原名。 */
  static labelOf(name: string): string {
    const server: McpServer | null = McpService.serverOf(name);
    return server === null ? name : server.label;
  }

  /** 执行一个 MCP 工具。契约同 AiTools.execute：永不抛异常，失败返回说明文本。 */
  static async callTool(fullName: string, argsJson: string, apiKey: string): Promise<string> {
    const server: McpServer | null = McpService.serverOf(fullName);
    if (server === null) {
      return `未知的 MCP 工具：${fullName}`;
    }
    if (apiKey.length === 0) {
      return 'MCP 不可用：未配置 Token Plan API Key';
    }
    const orig: string = fullName.substring(MCP_PREFIX.length + server.tag.length + 1);
    // 参数以字符串形态校验+透传（ArkTS 禁裸 {}；重新序列化反而丢模型给的键序）
    const argsText: string = argsJson.length > 0 ? argsJson : '{}';
    try {
      JSON.parse(argsText) as Object;
    } catch (_error) {
      return `MCP 工具参数不是合法 JSON：${argsJson.substring(0, 80)}`;
    }
    let state: McpServerState | null = McpService.stateOf(server);
    if (state === null) {
      state = await McpService.handshake(server, apiKey);
      if (state !== null) {
        McpService.states = McpService.states.concat([state]);
      }
    }
    if (state === null) {
      return `MCP 服务「${server.label}」连接失败`;
    }
    const body: string = `{"jsonrpc":"2.0","id":3,"method":"tools/call",` +
      `"params":{"name":"${McpService.esc(orig)}","arguments":${argsText}}}`;
    let reply: McpRpcReply = await McpService.rpc(server, apiKey, state.sessionId, body, true);
    if (reply.error.length > 0 && state.sessionId.length > 0) {
      // 会话可能已被服务端回收：重新握手再试一次
      const retry: McpServerState | null = await McpService.handshake(server, apiKey);
      if (retry !== null) {
        McpService.replaceState(retry);
        reply = await McpService.rpc(server, apiKey, retry.sessionId, body, true);
      }
    }
    if (reply.error.length > 0) {
      return `MCP 调用失败：${reply.error}`;
    }
    const result: Record<string, Object> | null = reply.result;
    if (result === null) {
      return 'MCP 工具返回空结果';
    }
    const parts: string[] = [];
    const content: Object | undefined = result['content'];
    if (Array.isArray(content)) {
      const list: Object[] = content as Object[];
      for (let i = 0; i < list.length; i++) {
        const item: Object = list[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = item as Record<string, Object>;
        const text: Object | undefined = rec['text'];
        if (typeof text === 'string' && text.length > 0) {
          parts.push(text);
        }
      }
    }
    const isError: boolean = result['isError'] === true;
    if (parts.length === 0) {
      return isError ? 'MCP 工具执行报错（服务端未给出原因）' : 'MCP 工具返回空结果';
    }
    return isError ? `MCP 工具返回错误：${parts.join('\n')}` : parts.join('\n');
  }

  private static serverOf(name: string): McpServer | null {
    if (!name.startsWith(MCP_PREFIX)) {
      return null;
    }
    for (let i = 0; i < MCP_SERVERS.length; i++) {
      if (name.startsWith(`${MCP_PREFIX}${MCP_SERVERS[i].tag}_`)) {
        return MCP_SERVERS[i];
      }
    }
    return null;
  }

  private static stateOf(server: McpServer): McpServerState | null {
    for (let i = 0; i < McpService.states.length; i++) {
      if (McpService.states[i].server.url === server.url) {
        return McpService.states[i];
      }
    }
    return null;
  }

  private static replaceState(next: McpServerState): void {
    const out: McpServerState[] = [];
    for (let i = 0; i < McpService.states.length; i++) {
      if (McpService.states[i].server.url !== next.server.url) {
        out.push(McpService.states[i]);
      }
    }
    out.push(next);
    McpService.states = out;
  }

  /** initialize 握手 + tools/list；失败返回 null（单家故障不影响其余）。 */
  private static async handshake(server: McpServer, apiKey: string): Promise<McpServerState | null> {
    try {
      const init: McpRpcReply = await McpService.rpc(server, apiKey, '',
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{' +
        '"protocolVersion":"2025-03-26","capabilities":{},' +
        '"clientInfo":{"name":"mybooks-ohos","version":"1.0"}}}', true);
      if (init.error.length > 0) {
        return null;
      }
      // 已初始化通知：多数实现回 202 空体，不等待回执
      await McpService.rpc(server, apiKey, init.sessionId,
        '{"jsonrpc":"2.0","method":"notifications/initialized"}', false);
      const listed: McpRpcReply = await McpService.rpc(server, apiKey, init.sessionId,
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}', true);
      if (listed.error.length > 0 || listed.result === null) {
        return null;
      }
      const tools: AiToolDefinition[] = [];
      const raw: Object | undefined = (listed.result as Record<string, Object>)['tools'];
      if (Array.isArray(raw)) {
        const list: Object[] = raw as Object[];
        for (let i = 0; i < list.length && tools.length < 24; i++) {
          const item: Object = list[i];
          if (item === null || typeof item !== 'object') {
            continue;
          }
          const rec: Record<string, Object> = item as Record<string, Object>;
          const name: Object | undefined = rec['name'];
          const desc: Object | undefined = rec['description'];
          const schema: Object | undefined = rec['inputSchema'];
          if (typeof name !== 'string' || name.length === 0 || schema === null ||
            typeof schema !== 'object') {
            continue;
          }
          const params: AiToolParameters = schema as AiToolParameters;
          params.type = 'object';
          const body: AiToolFunctionBody = {
            name: `${MCP_PREFIX}${server.tag}_${name}`,
            description: typeof desc === 'string' ? desc : name,
            parameters: params,
          };
          const def: AiToolDefinition = { type: 'function', function: body };
          tools.push(def);
        }
      }
      const state: McpServerState = { server: server, sessionId: init.sessionId, tools: tools };
      return state;
    } catch (_error) {
      return null;
    }
  }

  /** 单次 JSON-RPC POST：兼容纯 JSON 与 SSE `data:` 响应；错误尽量带原因。 */
  private static async rpc(server: McpServer, apiKey: string, sessionId: string,
    body: string, waitReply: boolean): Promise<McpRpcReply> {
    const reply: McpRpcReply = { result: null, sessionId: '', error: '' };
    const headers: rcp.RequestHeaders = {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
    };
    if (sessionId.length > 0) {
      headers['mcp-session-id'] = sessionId;
    }
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: { transfer: { timeout: { connectMs: 10000, transferMs: 60000 } } },
    });
    try {
      const request: rcp.Request = new rcp.Request(server.url, 'POST', headers, body);
      const response: rcp.Response = await session.fetch(request);
      const hs: Object | undefined = response.headers as Object;
      const sidRaw: Object | undefined = hs === undefined || hs === null || typeof hs !== 'object' ?
        undefined : (hs as Record<string, Object>)['mcp-session-id'];
      reply.sessionId = typeof sidRaw === 'string' ? sidRaw : '';
      const buf: ArrayBuffer | undefined = response.body;
      let text: string = '';
      if (buf !== undefined) {
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        text = decoder.decodeToString(new Uint8Array(buf));
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        reply.error = McpService.errorBrief(response.statusCode, text);
        return reply;
      }
      if (!waitReply || text.length === 0) {
        return reply;
      }
      const envelope: Object = JSON.parse(McpService.extractJson(text)) as Object;
      if (envelope === null || typeof envelope !== 'object') {
        reply.error = '响应不是 JSON-RPC 信封';
        return reply;
      }
      const rec: Record<string, Object> = envelope as Record<string, Object>;
      const err: Object | undefined = rec['error'];
      if (err !== undefined && err !== null && typeof err === 'object') {
        const erec: Record<string, Object> = err as Record<string, Object>;
        const emsg: Object | undefined = erec['message'];
        reply.error = typeof emsg === 'string' ? emsg : 'MCP 服务返回未知错误';
        return reply;
      }
      const res: Object | undefined = rec['result'];
      reply.result = res !== undefined && res !== null && typeof res === 'object' ?
        res as Record<string, Object> : null;
      return reply;
    } catch (error) {
      reply.error = error instanceof Error ? error.message : `${error}`;
      return reply;
    } finally {
      session.close();
    }
  }

  /** SSE 兼容：取最后一个 `data:` 行；纯 JSON 直接返回原文。 */
  private static extractJson(text: string): string {
    if (text.indexOf('data:') < 0) {
      return text;
    }
    let last: string = '';
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.startsWith('data:')) {
        const payload: string = line.substring(5).trim();
        if (payload.length > 0 && payload !== '[DONE]') {
          last = payload;
        }
      }
    }
    return last;
  }

  /** 非 2xx 摘要：优先 DashScope 错误信封 {code,message}。 */
  private static errorBrief(statusCode: number, text: string): string {
    try {
      const rec: Record<string, Object> =
        JSON.parse(McpService.extractJson(text)) as Record<string, Object>;
      const code: Object | undefined = rec['code'];
      const msg: Object | undefined = rec['message'];
      if (typeof msg === 'string' && msg.length > 0) {
        return `${statusCode} ${typeof code === 'string' ? `${code}: ` : ''}${msg.substring(0, 120)}`;
      }
    } catch (_error) {
      // 非 JSON 错误体：回落状态码
    }
    return `HTTP ${statusCode}`;
  }

  /** 工具名只含标识符；防御性剥引号/反斜杠。 */
  private static esc(name: string): string {
    return name.split('\\').join('').split('"').join('');
  }
}
