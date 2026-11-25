import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { AiToolDefinition, AiToolFunctionBody, AiToolParameters } from './AiToolsDefs';
import { TalebookService } from './TalebookService';
import { ErrorFormat } from '../utils/ErrorFormat';

/**
 * MCP 客户端（Streamable HTTP / JSON-RPC 2.0）。
 *
 * 内置家分两类：百炼四家挂 Token Plan 网关域，需各家单独配 Key；
 * 开源两家（DeepWiki/Context7）为公共端点，免 Key 即可挂载（public 标记）。
 * 一家都不可用（未配 Key 且开源家全禁用）时工具集为空（零请求、静默降级）。
 * 每家可在设置页「MCP」档单独禁用（ai_mcp_on_<tag>，未设置=启用）。
 * 协议流程：initialize → notifications/initialized → tools/list → tools/call，
 * 会话 id 走 `mcp-session-id` 响应头；响应体兼容纯 JSON 与 SSE `data:` 两种形态。
 */

/** MCP server 登记：tag 用于工具名前缀 `mcp_<tag>_<工具名>`（各家工具名可能重名）。 */
export interface McpServer {
  tag: string;
  label: string;
  url: string;
  /** 是否内置家（内置家不可改删；百炼四家需单独填 Key，开源两家免 Key）。 */
  builtin?: boolean;
  /** 开源免 Key 家：无需 API Key 即可握手挂载；填了 Key 则带上（缓解限流）。 */
  public?: boolean;
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
  { tag: 'es', label: '百炼增强搜索', url: 'https://cn-beijing.maas.qianwenaiapi.com/api/v1/mcps/EnhancedSearch/mcp', builtin: true },
  { tag: 'ws', label: '百炼联网搜索', url: 'https://cn-beijing.maas.qianwenaiapi.com/api/v1/mcps/WebSearch/mcp', builtin: true },
  { tag: 'wf', label: '百炼网页解析', url: 'https://cn-beijing.maas.qianwenaiapi.com/api/v1/mcps/WebFetch/mcp', builtin: true },
  { tag: 'sg', label: '百炼语音转写', url: 'https://cn-beijing.maas.qianwenaiapi.com/api/v1/mcps/SpeechGenerateText/mcp', builtin: true },
  // 开源社区托管的公共 MCP（免 Key 可用；实测 initialize/tools/list/tools/call 均匿名通）：
  // DeepWiki=任意 GitHub 仓库文档问答，Context7=最新库/API 文档。填 Key 可选（缓解限流）。
  { tag: 'dwiki', label: '开源DeepWiki仓库问答', url: 'https://mcp.deepwiki.com/mcp', builtin: true, public: true },
  { tag: 'ctx7', label: '开源Context7库文档', url: 'https://mcp.context7.com/mcp', builtin: true, public: true },
];

/** 自定义 MCP server 的持久化键：值为 JSON 数组 `[{tag,label,url}]`。 */
const MCP_CUSTOM_KEY: string = 'ai_mcp_servers';
/** 单个 MCP server 的 Key 槽前缀（+tag）：自定义家各用各的，内置家回落 Token Plan。 */
const MCP_KEY_PREFIX: string = 'ai_mcp_key_';

/** MCP 鉴权即 Token Plan 服务商的 Key（用户明确：复用已填写的）。 */
const MCP_PROVIDER_ID: string = 'qwen-tokenplan';
/** 工具集缓存时效：过期重新握手（服务端工具/会话可能失效）。 */
const MCP_CACHE_TTL_MS: number = 600000;
/** 工具名前缀段长度：`mcp_es_` 这类固定头部，剥掉后即服务端原名。 */
const MCP_PREFIX: string = 'mcp_';
/** 每家启用开关的 preference 键前缀（+tag），未设置=启用；直接读存储避免与 AiServiceConfig 互引。 */
const MCP_ENABLED_KEY: string = 'ai_mcp_on_';

export class McpService {
  private static cacheKey: string = '';
  private static cacheAt: number = 0;
  private static states: McpServerState[] = [];

  /** 当前是否至少有一家「启用且可用」：配了 Key，或开源免 Key 家（MCP 门控）。 */
  static enabledFor(): boolean {
    const all: McpServer[] = McpService.servers();
    for (let i = 0; i < all.length; i++) {
      if (McpService.isServerEnabled(all[i].tag) && McpService.usableFor(all[i])) {
        return true;
      }
    }
    return false;
  }

  /** 单家当前是否可用：填了 Key，或开源免 Key 家无需 Key。 */
  static usableFor(server: McpServer): boolean {
    return server.public === true || McpService.apiKeyFor(server).length > 0;
  }

  /** 当前全部 MCP server：内置家（百炼四 + 开源免 Key 二）+ 用户新增的自定义家。 */
  static servers(): McpServer[] {
    const out: McpServer[] = MCP_SERVERS.slice();
    const raw: string = TalebookService.prefGet(MCP_CUSTOM_KEY);
    if (raw.length === 0) {
      return out;
    }
    try {
      const list: Object[] = JSON.parse(raw) as Object[];
      for (let i = 0; i < list.length; i++) {
        const item: Object = list[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = item as Record<string, Object>;
        const tag: Object | undefined = rec['tag'];
        const label: Object | undefined = rec['label'];
        const url: Object | undefined = rec['url'];
        if (typeof tag !== 'string' || tag.length === 0 || typeof url !== 'string' ||
          url.length === 0) {
          continue;
        }
        out.push({
          tag: tag,
          label: typeof label === 'string' && label.length > 0 ? label : tag,
          url: url,
        });
      }
    } catch (_error) {
      // 存储损坏：只用内置家
    }
    return out;
  }

  /**
   * 单家鉴权 Key：一律用该家自己的槽位（百炼家需单独填写，不复用服务商 Key；开源家可留空）。
   * 不反向 import AiServiceConfig（Config 已 import McpService，会成环）。
   */
  static apiKeyFor(server: McpServer): string {
    return TalebookService.secureGet(MCP_KEY_PREFIX + server.tag);
  }

  /** 设置某家 Key（内置与自定义家一视同仁）。 */
  static setApiKey(tag: string, apiKey: string): void {
    TalebookService.secureSet(MCP_KEY_PREFIX + tag, apiKey.trim());
    McpService.reset();
  }

  /** 该家是否已有 Key（UI 展示「已配置/未配置」）。 */
  static hasApiKey(server: McpServer): boolean {
    return McpService.apiKeyFor(server).length > 0;
  }

  /** 新增自定义 MCP server：tag 由 label 归一化（去重加序号），返回落库后的条目。 */
  static addServer(label: string, url: string, apiKey: string): McpServer {
    const name: string = label.trim();
    const endpoint: string = url.trim();
    if (name.length === 0 || endpoint.length === 0) {
      throw new Error('名称和 URL 都不能为空');
    }
    const all: McpServer[] = McpService.servers();
    let tag: string = McpService.normalizeTag(name);
    let seq: number = 2;
    while (McpService.tagTaken(all, tag)) {
      tag = `${McpService.normalizeTag(name)}${seq}`;
      seq++;
    }
    const server: McpServer = { tag: tag, label: name, url: endpoint };
    McpService.saveCustom(all, server);
    if (apiKey.trim().length > 0) {
      McpService.setApiKey(tag, apiKey);
    }
    McpService.reset();
    return server;
  }

  /** 改自定义家的名称/URL/Key（内置家不可改，返回 false）。 */
  static updateServer(tag: string, label: string, url: string, apiKey: string): boolean {
    const all: McpServer[] = McpService.servers();
    const target: McpServer | null = McpService.findByTag(all, tag);
    if (target === null || target.builtin === true) {
      return false;
    }
    const next: McpServer = {
      tag: tag,
      label: label.trim().length > 0 ? label.trim() : target.label,
      url: url.trim().length > 0 ? url.trim() : target.url,
    };
    McpService.saveCustom(all, next);
    if (apiKey.trim().length > 0) {
      McpService.setApiKey(tag, apiKey);
    }
    McpService.reset();
    return true;
  }

  /** 删自定义家（内置家不可删，返回 false）；连带清 Key 与启用开关。 */
  static removeServer(tag: string): boolean {
    const all: McpServer[] = McpService.servers();
    const target: McpServer | null = McpService.findByTag(all, tag);
    if (target === null || target.builtin === true) {
      return false;
    }
    const kept: McpServer[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].tag !== tag) {
        kept.push(all[i]);
      }
    }
    McpService.writeCustom(kept);
    TalebookService.secureSet(MCP_KEY_PREFIX + tag, '');
    TalebookService.prefSet(MCP_ENABLED_KEY + tag, '');
    McpService.reset();
    return true;
  }

  /** 清空缓存（服务商/Key 变更后调用，下次发送重新握手）。 */
  static reset(): void {
    McpService.cacheKey = '';
    McpService.cacheAt = 0;
    McpService.states = [];
  }

  /** 单家启用开关（设置页「MCP」档）：未设置=启用。 */
  static isServerEnabled(tag: string): boolean {
    return TalebookService.prefGet(MCP_ENABLED_KEY + tag, '1') !== '0';
  }

  /** 改开关即失效工具集缓存，下一轮按新开关重新握手。 */
  static setServerEnabled(tag: string, on: boolean): void {
    TalebookService.prefSet(MCP_ENABLED_KEY + tag, on ? '1' : '0');
    McpService.reset();
  }

  /**
   * 取全量 MCP 工具定义（合并各家）：命中缓存零请求；设置页禁用的家与未配 Key 的家不握手，
   * 单家失败静默跳过，全挂返回空数组——聊天照常走内置工具。
   * Key 由各家自取（百炼家需单独填写，开源免 Key 家空 Key 也握手），参数仅用于缓存归属（服务商切换后重新握手）。
   */
  static async ensureToolset(cacheOwner: string): Promise<AiToolDefinition[]> {
    const all: McpServer[] = McpService.servers();
    const now: number = Date.now();
    if (McpService.cacheKey !== cacheOwner || now - McpService.cacheAt >= MCP_CACHE_TTL_MS) {
      const fresh: (McpServerState | null)[] = await Promise.all(
        all.map((s: McpServer): Promise<McpServerState | null> => {
          const key: string = McpService.apiKeyFor(s);
          return McpService.isServerEnabled(s.tag) && McpService.usableFor(s) ?
            McpService.handshake(s, key) : Promise.resolve(null);
        }));
      const states: McpServerState[] = [];
      for (let i = 0; i < fresh.length; i++) {
        const st: McpServerState | null = fresh[i];
        if (st !== null && st.tools.length > 0) {
          states.push(st);
        }
      }
      McpService.states = states;
      McpService.cacheKey = cacheOwner;
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

  /** 登记清单（设置页「MCP」档数据源）：内置 + 自定义。 */
  static serverList(): McpServer[] {
    return McpService.servers();
  }

  /** 探测摘要：每家一行——已禁用 / 已挂载 N 工具 / 未挂载（握手失败或还没试）。 */
  static summaryBrief(): string {
    const all: McpServer[] = McpService.servers();
    const parts: string[] = [];
    for (let i = 0; i < all.length; i++) {
      const s: McpServer = all[i];
      if (!McpService.isServerEnabled(s.tag)) {
        parts.push(`${s.label}：已禁用`);
        continue;
      }
      const st: McpServerState | null = McpService.stateOf(s);
      parts.push(`${s.label}：${st === null ? '未挂载' : `${st.tools.length} 工具`}`);
    }
    return parts.join('　');
  }

  /** 执行一个 MCP 工具。契约同 AiTools.execute：永不抛异常，失败返回说明文本。 */
  static async callTool(fullName: string, argsJson: string): Promise<string> {
    const server: McpServer | null = McpService.serverOf(fullName);
    if (server === null) {
      return `未知的 MCP 工具：${fullName}`;
    }
    if (!McpService.isServerEnabled(server.tag)) {
      return `${server.label}已在设置页的 MCP 档中禁用`;
    }
    const key: string = McpService.apiKeyFor(server);
    if (key.length === 0 && server.public !== true) {
      return `${server.label} 不可用：未配置 API Key`;
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
      state = await McpService.handshake(server, key);
      if (state !== null) {
        McpService.states = McpService.states.concat([state]);
      }
    }
    if (state === null) {
      return `MCP 服务「${server.label}」连接失败`;
    }
    const body: string = `{"jsonrpc":"2.0","id":3,"method":"tools/call",` +
      `"params":{"name":"${McpService.esc(orig)}","arguments":${argsText}}}`;
    let reply: McpRpcReply = await McpService.rpc(server, key, state.sessionId, body, true);
    if (reply.error.length > 0 && state.sessionId.length > 0) {
      // 会话可能已被服务端回收：重新握手再试一次
      const retry: McpServerState | null = await McpService.handshake(server, key);
      if (retry !== null) {
        McpService.replaceState(retry);
        reply = await McpService.rpc(server, key, retry.sessionId, body, true);
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
    const all: McpServer[] = McpService.servers();
    for (let i = 0; i < all.length; i++) {
      if (name.startsWith(`${MCP_PREFIX}${all[i].tag}_`)) {
        return all[i];
      }
    }
    return null;
  }

  private static findByTag(all: McpServer[], tag: string): McpServer | null {
    for (let i = 0; i < all.length; i++) {
      if (all[i].tag === tag) {
        return all[i];
      }
    }
    return null;
  }

  private static tagTaken(all: McpServer[], tag: string): boolean {
    return McpService.findByTag(all, tag) !== null;
  }

  /** 名称归一化成 tag：非字母数字转下划线、小写、限长 12（工具名前缀要短）。 */
  private static normalizeTag(label: string): string {
    const lowered: string = label.toLowerCase();
    let out: string = '';
    for (let i = 0; i < lowered.length && out.length < 12; i++) {
      const c: string = lowered.charAt(i);
      out += (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ? c : '_';
    }
    while (out.length > 0 && out.charAt(0) === '_') {
      out = out.substring(1);
    }
    return out.length > 0 ? out : 'srv';
  }

  /** 增/改：把 next 合并进自定义清单（同 tag 覆盖，其余保持）并落库。 */
  private static saveCustom(all: McpServer[], next: McpServer): void {
    const merged: McpServer[] = [];
    let replaced: boolean = false;
    for (let i = 0; i < all.length; i++) {
      if (all[i].builtin === true) {
        continue;
      }
      if (all[i].tag === next.tag) {
        merged.push(next);
        replaced = true;
      } else {
        merged.push(all[i]);
      }
    }
    if (!replaced) {
      merged.push(next);
    }
    McpService.writeCustom(merged);
  }

  /** 落库自定义清单（只存 tag/label/url，Key 走 secure 槽）。 */
  private static writeCustom(custom: McpServer[]): void {
    const items: Record<string, Object>[] = [];
    for (let i = 0; i < custom.length; i++) {
      const rec: Record<string, Object> = {
        'tag': custom[i].tag, 'label': custom[i].label, 'url': custom[i].url,
      };
      items.push(rec);
    }
    TalebookService.prefSet(MCP_CUSTOM_KEY, JSON.stringify(items));
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
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
    };
    // 开源免 Key 家用空 Key：不发 Authorization（匿名端点会忽略甚至拒绝 Bearer 空串）
    if (apiKey.length > 0) {
      headers['Authorization'] = `Bearer ${apiKey}`;
    }
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
      reply.error = ErrorFormat.message(error);
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
