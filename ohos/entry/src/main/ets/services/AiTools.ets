/**
 * AI 助手的本地工具门面（OpenAI function calling 协议）。
 *
 * 设计约束：
 * - 读工具只查用户已有数据（书架/详情/标注/历史/书源/任务）；**写工具
 *   （建书单/加书/加下载任务）必须登记进 WRITE_TOOLS**，由回路层的确认闸门
 *   （AiStreamHandlers.onConfirm）逐笔问过用户才执行。
 * - **返回精简文本**而非原始 JSON：省上下文 token，模型也更好引用；
 *   执行失败返回说明文本（不抛异常），协议回路（AiService.chatViaGateway）不因单个工具中断。
 * - 当前仅 OpenCode 网关通道挂载这些工具；其他服务商走 SDK 流式，不附加。
 *
 * 文件分工（800 行门禁拆分）：定义表在 AiToolsDefs.ets，共享缓存/参数工具在
 * AiToolsCore.ets，工具执行按域拆 AiToolsExecMeta/ExecShelf.ets；本文件只留
 * 权限过滤、确认闸门、分发路由与 UI 文案。
 */
import { AiPersona } from './AiPersona';
import { AiToolsCore } from './AiToolsCore';
import { AiToolsExecMeta } from './AiToolsExecMeta';
import { AiToolsExecShelf } from './AiToolsExecShelf';
import { TOOL_DEFS, TOOL_SET_VOICE, ToolBookLine, AiToolDefinition, AiToolGroup, AiToolItem,
  formatPlanList } from './AiToolsDefs';
import { McpService, McpServer } from './McpService';

/**
 * AI 助手的本地工具集（OpenAI function calling 协议）。
 *
 * 设计约束：
 * - 读工具只查用户已有数据（书架/详情/标注/历史/书源/任务）；**写工具
 *   （建书单/加书/加下载任务）必须登记进 WRITE_TOOLS**，由回路层的确认闸门
 *   （AiStreamHandlers.onConfirm）逐笔问过用户才执行。
 * - **返回精简文本**而非原始 JSON：省上下文 token，模型也更好引用；
 *   执行失败返回说明文本（不抛异常），协议回路（AiService.chatViaGateway）不因单个工具中断。
 * - 当前仅 OpenCode 网关通道挂载这些工具；其他服务商走 SDK 流式，不附加。
 */
/**
 * AI 权限模式（对话页顶栏切换，持久化在偏好 ai_permission_mode）：
 * - readonly：请求体只带读工具（模型看不见写工具），幻觉出的写调用也会被回路挡下；
 * - confirm：写工具执行前逐个过 onConfirm 确认闸门（默认）；
 * - auto：写工具不弹确认直接执行，活动时间线标注「自动执行」。
 */
export type AiPermissionMode = 'readonly' | 'confirm' | 'auto';

export class AiTools {
  /** 随请求体附带的工具定义；readonly 模式过滤掉写工具。 */
  static definitions(mode: AiPermissionMode = 'confirm'): AiToolDefinition[] {
    if (mode === 'readonly') {
      return TOOL_DEFS.filter((d: AiToolDefinition): boolean =>
      AiTools.WRITE_TOOLS.indexOf(d.function.name) < 0);
    }
    return TOOL_DEFS;
  }

  /**
   * realtime 语音通话工具面 = 文字全集（去 ask_user）+ set_voice + MCP 动态工具。
   * 与文字 toolset 对齐：mcpTools 由调用方 connect 前 await mcpToolset() 取得（空=非 Token Plan）。
   * ask_user 排除：语音无选项卡片交互，回路会引导模型正文提问，暴露出去只会白耗一轮调用。
   * set_voice 只在通话有意义，不进 TOOL_DEFS；插末前保留 OpenCode 丢末项护栏（mcp 项在其后）。
   */
  static realtimeDefinitions(mode: AiPermissionMode = 'confirm',
    mcpTools: AiToolDefinition[] | null = null): AiToolDefinition[] {
    const defs: AiToolDefinition[] = AiTools.definitions(mode).filter((d: AiToolDefinition): boolean =>
      d.function.name !== 'ask_user');
    defs.splice(defs.length - 1, 0, TOOL_SET_VOICE);
    if (mcpTools !== null && mcpTools.length > 0) {
      return defs.concat(mcpTools);
    }
    return defs;
  }

  /**
   * 写操作工具：confirm 模式下执行前必须过用户确认闸门（AiStreamHandlers.onConfirm），
   * readonly 模式下不出现在 tools 里。
   * 名字与 TOOL_DEFS 里的写工具对应；新加写工具忘记登记 = 无确认直接执行，务必同步。
   */
  private static readonly WRITE_TOOLS: string[] =
    ['create_booklist', 'add_books_to_booklist', 'update_booklist', 'delete_booklist',
      'remove_book_from_booklist', 'add_sonovel_task', 'add_to_shelf', 'push_to_device',
      'update_book_meta', 'set_cover', 'save_memory', 'forget_memory', 'add_mcp_server'];

  static needsConfirm(name: string): boolean {
    return AiTools.WRITE_TOOLS.indexOf(name) >= 0;
  }

  /** 工具目录分组：按用途归类，供 list_ai_tools 输出与设置页展示。 */
  private static readonly TOOL_GROUPS: string[][] = [
    ['书架检索', 'search_books', 'book_detail', 'shelf_list', 'book_progress', 'reading_history', 'reading_stats'],
    ['书单管理', 'list_booklists', 'create_booklist', 'add_books_to_booklist', 'update_booklist',
      'delete_booklist', 'remove_book_from_booklist'],
    ['书籍入库', 'search_sonovel', 'add_sonovel_task', 'list_download_tasks', 'add_to_shelf', 'push_to_device'],
    ['元数据与封面', 'search_meta', 'get_novel_meta', 'update_book_meta', 'list_categories',
      'search_cover', 'set_cover'],
    ['联网检索', 'search_web', 'fetch_url', 'ai_search', 'search_encyclopedia'],
    ['记忆与配置', 'save_memory', 'forget_memory', 'add_mcp_server'],
    ['交互', 'ask_user', 'plan', 'list_ai_tools'],
  ];

  /** 结构化工具目录（设置页渲染用）：分组 → 工具条目。 */
  static catalogGroups(): AiToolGroup[] {
    const byName: Map<string, AiToolDefinition> = new Map();
    for (let i = 0; i < TOOL_DEFS.length; i++) {
      byName.set(TOOL_DEFS[i].function.name, TOOL_DEFS[i]);
    }
    const groups: AiToolGroup[] = [];
    for (let g = 0; g < AiTools.TOOL_GROUPS.length; g++) {
      const group: string[] = AiTools.TOOL_GROUPS[g];
      const items: AiToolItem[] = [];
      for (let i = 1; i < group.length; i++) {
        const name: string = group[i];
        const def: AiToolDefinition | undefined = byName.get(name);
        if (def === undefined) {
          continue;
        }
        const item: AiToolItem = {
          name: name,
          summary: AiToolsCore.clip(def.function.description, 48),
          write: AiTools.needsConfirm(name),
        };
        items.push(item);
      }
      if (items.length > 0) {
        const grp: AiToolGroup = { title: group[0], items: items };
        groups.push(grp);
      }
    }
    return groups;
  }

  /** 工具总数（设置页标题用）。 */
  static toolCount(): number {
    return TOOL_DEFS.length;
  }

  /** 工具目录文本：按分组列出名称+说明+是否写操作，帮助模型避免盲猜工具名。 */
  static catalog(): string {
    const byName: Map<string, AiToolDefinition> = new Map();
    for (let i = 0; i < TOOL_DEFS.length; i++) {
      byName.set(TOOL_DEFS[i].function.name, TOOL_DEFS[i]);
    }
    const lines: string[] = [];
    for (let g = 0; g < AiTools.TOOL_GROUPS.length; g++) {
      const group: string[] = AiTools.TOOL_GROUPS[g];
      const title: string = group[0];
      const rows: string[] = [];
      for (let i = 1; i < group.length; i++) {
        const name: string = group[i];
        const def: AiToolDefinition | undefined = byName.get(name);
        if (def === undefined) {
          continue;
        }
        const write: string = AiTools.needsConfirm(name) ? ' [写]' : '';
        rows.push(`· ${name}${write} — ${AiToolsCore.clip(def.function.description, 60)}`);
      }
      if (rows.length > 0) {
        lines.push(`【${title}】`, ...rows);
      }
    }
    return `当前可用工具（共 ${TOOL_DEFS.length} 个，[写] 表示执行前需用户确认）：\n${lines.join('\n')}`;
  }

  /**
   * add_mcp_server 执行：新增自定义 MCP 服务（含可选 Key）。
   * 返回文案**不回显 Key**（对话历史会落盘），只报告是否已配。
   */
  private static addMcpServer(args: Record<string, Object>): string {
    const label: string = AiToolsCore.argString(args, 'label');
    const url: string = AiToolsCore.argString(args, 'url');
    const apiKey: string = AiToolsCore.argString(args, 'api_key');
    try {
      const server: McpServer = McpService.addServer(label, url, apiKey);
      const keyNote: string = apiKey.trim().length > 0 ? '已配置 Key' : '未配置 Key（如该服务需鉴权请补填）';
      return `已新增 MCP 服务「${server.label}」（${server.url}），${keyNote}。` +
        '下一轮对话会自动挂载其工具；若未出现可在设置页 MCP 档点「立即探测挂载状态」查看原因。';
    } catch (error) {
      return `新增 MCP 服务失败：${error instanceof Error ? error.message : `${error}`}`;
    }
  }

  // ———— 只读工具结果缓存（#1517）：进程级内存，不落盘、重启即清 ————
  /**
   * 缓存白名单：贵且静态的联网/元数据类，结果纯文本、无书目 side-channel。
   * 不缓存书目侧信道类（命中会把 book 卡槽旁路掉）与进度语义类（list_download_tasks）。
   */
  private static readonly CACHEABLE_TOOLS: string[] =
    ['search_meta', 'get_novel_meta', 'search_encyclopedia', 'search_web', 'fetch_url', 'ai_search'];
  /** 条数上限：FIFO 淘汰，长会话内存有界。 */
  private static readonly TOOL_CACHE_MAX: number = 24;
  private static toolCache: Map<string, string> = new Map();
  /** 回归隔离开关：harness setup 置 true（既有用例多次同参调用是设计使然），#1517 用例内手动开回。 */
  static cacheDisabled: boolean = false;

  static isCacheable(name: string): boolean {
    return AiTools.CACHEABLE_TOOLS.indexOf(name) >= 0 || name.indexOf('mcp_') === 0;
  }

  /** 缓存键归一：参数按 key 排序序列化，同义不同序也命中；坏 JSON 原样退化精确匹配。 */
  static toolCacheKey(name: string, argsJson: string): string {
    let norm: string = argsJson.trim();
    try {
      const obj: Record<string, Object> = JSON.parse(norm) as Record<string, Object>;
      const keys: string[] = Object.keys(obj);
      keys.sort();
      const parts: string[] = [];
      for (const k of keys) {
        parts.push(`${k}=${JSON.stringify(obj[k])}`);
      }
      norm = parts.join('&');
    } catch (_error) {
      // 参数不可解析时按原文，代价只是命中率
    }
    return `${name}|${norm}`;
  }

  /** 清历史等本地数据变更时可主动调用；默认缓存随进程存活。 */
  static clearToolCache(): void {
    AiTools.toolCache.clear();
  }

  private static rememberCache(key: string, text: string): void {
    if (AiTools.toolCache.size >= AiTools.TOOL_CACHE_MAX && !AiTools.toolCache.has(key)) {
      const oldest: string = AiTools.toolCache.keys().next().value as string;
      AiTools.toolCache.delete(oldest);
    }
    AiTools.toolCache.set(key, text);
  }


  static takeLastBooks(): ToolBookLine[] {
    const books: ToolBookLine[] = AiToolsCore.lastBooks;
    AiToolsCore.lastBooks = [];
    return books;
  }

  /** 按 callId 取并行执行的结构化结果；无登记则回退静态槽（串行路径）。 */
  static takeLastBooksFor(callId: string): ToolBookLine[] {
    if (callId.length > 0 && AiToolsCore.booksByCall.has(callId)) {
      const books: ToolBookLine[] = AiToolsCore.booksByCall.get(callId) ?? [];
      AiToolsCore.booksByCall.delete(callId);
      return books;
    }
    return AiTools.takeLastBooks();
  }

  /** 回路收尾清理：中断/异常路径可能残留未取的条目。 */
  static clearPendingBooks(): void {
    AiToolsCore.booksByCall.clear();
  }

  /** 给 UI 的一句人话：正在用哪个工具。 */
  static toolLabel(name: string): string {
    if (name === 'search_books') {
      return '搜索书架';
    }
    if (name === 'book_detail') {
      return '查询书籍详情';
    }
    if (name === 'book_notes') {
      return '查找你的标注';
    }
    if (name === 'reading_history') {
      return '查看阅读历史';
    }
    if (name === 'search_sonovel') {
      return '搜索网络小说书源';
    }
    if (name === 'list_download_tasks') {
      return '查看下载任务';
    }
    if (name === 'add_to_shelf') {
      return '加入书架';
    }
    if (name === 'push_to_device') {
      return '推送到阅读设备';
    }
    if (name === 'reading_stats') {
      return '查看阅读统计';
    }
    if (name === 'list_booklists') {
      return '查询我的书单';
    }
    if (name === 'update_booklist') {
      return '修改书单';
    }
    if (name === 'delete_booklist') {
      return '删除书单';
    }
    if (name === 'remove_book_from_booklist') {
      return '从书单移出书籍';
    }
    if (name === 'create_booklist') {
      return '创建书单';
    }
    if (name === 'add_books_to_booklist') {
      return '把书加进书单';
    }
    if (name === 'add_sonovel_task') {
      return '添加 so-novel 下载任务';
    }
    if (name === 'update_book_meta') {
      return '更新书籍元数据';
    }
    if (name === 'list_categories') {
      return '查询书库分类';
    }
    if (name === 'search_cover') {
      return '检索封面候选';
    }
    if (name === 'set_cover') {
      return '更换封面';
    }
    if (name === 'search_meta') {
      return '检索元数据站点';
    }
    if (name === 'get_novel_meta') {
      return '抓书源站详情页';
    }
    if (name === 'search_encyclopedia') {
      return '搜百科词条';
    }
    if (name === 'search_web') {
      return '搜索网页';
    }
    if (name === 'fetch_url') {
      return '读取网页';
    }
    if (name === 'ai_search') {
      return 'AI 联网问答';
    }
    if (name === 'save_memory') {
      return '记住用户的事';
    }
    if (name === 'forget_memory') {
      return '删除一条记忆';
    }
    if (name === 'ask_user') {
      return '向用户提问';
    }
    if (name === 'add_mcp_server') {
      return '新增 MCP 服务';
    }
    if (name === 'shelf_list') {
      return '列书架书单';
    }
    if (name === 'book_progress') {
      return '查阅读进度';
    }
    if (name === 'list_ai_tools') {
      return '查看可用工具';
    }
    if (name === 'plan') {
      return '梳理任务计划';
    }
    if (name === 'set_voice') {
      return '更换通话音色';
    }
    return name;
  }

  /** 执行一次工具调用；永不抛出，返回给模型的文本结果。 */
  /**
   * 工具执行入口（失败处理见 dispatch 外层循环）：
   * - 只读工具的**瞬时失败**（网络/限流/5xx）在代码层自动重试一次——模型层重试
   *   要整趟网关往返（秒级+token），这类失败无副作用，本地重试最快最省。
   * - **写工具永不自动重试**：部分成功可能已落在服务端，盲目重试会重复执行；
   *   只回传分类文案，由模型（和用户确认闸门）决定下一步。
   * - 白名单只读工具先查会话缓存（#1517），命中直接回文本，成功轮结果才固化。
   */
  static async execute(name: string, argsJson: string, callId: string = ''): Promise<string> {
    const cacheable: boolean = AiTools.isCacheable(name) && !AiTools.cacheDisabled;
    const key: string = cacheable ? AiTools.toolCacheKey(name, argsJson) : '';
    if (cacheable) {
      const hit: string | undefined = AiTools.toolCache.get(key);
      if (hit !== undefined) {
        // 前缀标注让模型知道这是会话内复用而非新鲜查询，避免据此断言「最新状态」
        return `[缓存复用] ${hit}`;
      }
    }
    const text: string = await AiTools.executeWithRetry(name, argsJson, callId);
    // 含「失败」一律不固化：除重试环兜底文案外，工具内部把网络/HTTP 异常消化成的
    // 失败文本（如「网页抓取失败：…」）也在 dispatch 正常返回里，钉住会放大成整会话错误。
    // 误伤正文含「失败」的正常结果只是不缓存，代价仅命中率。
    if (cacheable && text.indexOf('失败') < 0) {
      AiTools.rememberCache(key, text);
    }
    return text;
  }

  private static async executeWithRetry(name: string, argsJson: string, callId: string): Promise<string> {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        return await AiTools.dispatch(name, argsJson, callId);
      } catch (error) {
        const msg: string = error instanceof Error ? error.message : `${error}`;
        const transient: boolean = AiTools.isTransientError(msg);
        if (transient && attempt === 0 && !AiTools.needsConfirm(name)) {
          continue;
        }
        if (transient) {
          const note: string = AiTools.needsConfirm(name) ? '' : '（已自动重试一次）';
          return `工具 ${name} 暂时失败${note}：${msg}。可稍后原样重试一次，或换个说法。`;
        }
        return `工具 ${name} 执行失败：${msg}。请按错误原因修正参数或方案，不要原样重试。`;
      }
    }
    return '';
  }

  /** 网络/限流/服务端不可用类错误判为瞬时（可重试），其余为确定性错误。 */
  private static isTransientError(message: string): boolean {
    const keys: string[] = ['超时', 'timeout', 'Timeout', '连接', 'connection', 'Connection',
      'network', 'Network', 'unavailable', 'Unavailable', 'reset', 'ECONN', 'econn',
      '429', '500', '502', '503', '504', '暂时不可用'];
    for (let i = 0; i < keys.length; i++) {
      if (message.indexOf(keys[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  private static async dispatch(name: string, argsJson: string, callId: string = ''): Promise<string> {
    AiToolsCore.lastBooks = [];
    const args: Record<string, Object> = AiToolsCore.parseArgs(argsJson);
    if (AiToolsCore.lastParseError.length > 0) {
      // 参数解析失败要如实回报（否则工具报「query 为空」会误导模型改参数而非改 JSON）
      return `工具 ${name} 的参数解析失败：${AiToolsCore.lastParseError}。请按工具 schema 重新生成 JSON。`;
    }
      if (name === 'search_books') {
        return await AiToolsExecShelf.searchBooks(AiToolsCore.argString(args, 'query'), callId);
      }
      if (name === 'book_detail') {
        return await AiToolsExecShelf.bookDetail(AiToolsCore.argNumber(args, 'book_id'));
      }
      if (name === 'book_notes') {
        return await AiToolsExecShelf.bookNotes(AiToolsCore.argNumber(args, 'book_id'));
      }
      if (name === 'reading_history') {
        return AiToolsExecShelf.readingHistory();
      }
      if (name === 'search_sonovel') {
        return await AiToolsExecShelf.searchSoNovel(AiToolsCore.argString(args, 'query'));
      }
      if (name === 'add_sonovel_task') {
        return AiToolsExecShelf.addSonovelTask(args);
      }
      if (name === 'update_book_meta') {
        return await AiToolsExecMeta.updateBookMeta(args);
      }
      if (name === 'list_categories') {
        return await AiToolsExecMeta.listCategories();
      }
      if (name === 'search_cover') {
        return await AiToolsExecMeta.searchCover(args);
      }
      if (name === 'set_cover') {
        return await AiToolsExecMeta.setCover(args);
      }
      if (name === 'list_download_tasks') {
        return AiToolsExecShelf.listDownloadTasks();
      }
      if (name === 'add_to_shelf') {
        return await AiToolsExecShelf.addToShelf(args);
      }
      if (name === 'push_to_device') {
        return await AiToolsExecShelf.pushToDevice(args);
      }
      if (name === 'reading_stats') {
        return await AiToolsExecShelf.readingStats();
      }
      if (name === 'list_booklists') {
        return await AiToolsExecShelf.listBooklists();
      }
      if (name === 'update_booklist') {
        return await AiToolsExecShelf.updateBooklist(args);
      }
      if (name === 'delete_booklist') {
        return await AiToolsExecShelf.deleteBooklist(args);
      }
      if (name === 'remove_book_from_booklist') {
        return await AiToolsExecShelf.removeBookFromBooklist(args);
      }
      if (name === 'create_booklist') {
        return await AiToolsExecShelf.createBooklist(args);
      }
      if (name === 'add_books_to_booklist') {
        return await AiToolsExecShelf.addBooksToBooklist(args);
      }
      if (name === 'search_meta') {
        return await AiToolsExecMeta.searchMeta(args);
      }
      if (name === 'get_novel_meta') {
        return await AiToolsExecMeta.getNovelMeta(args);
      }
      if (name === 'search_encyclopedia') {
        return await AiToolsExecMeta.searchEncyclopedia(AiToolsCore.argString(args, 'query'));
      }
      if (name === 'search_web') {
        return await AiToolsExecMeta.searchWeb(AiToolsCore.argString(args, 'query'));
      }
      if (name === 'fetch_url') {
        return await AiToolsExecMeta.fetchUrl(AiToolsCore.argString(args, 'url'));
      }
      if (name === 'ai_search') {
        return await AiToolsExecMeta.aiSearch(AiToolsCore.argString(args, 'query'));
      }
      if (name === 'save_memory') {
        return AiPersona.appendMemory(AiToolsCore.argString(args, 'content'));
      }
      if (name === 'forget_memory') {
        return AiPersona.removeMemory(AiToolsCore.argNumber(args, 'index'));
      }
      if (name === 'add_mcp_server') {
        return AiTools.addMcpServer(args);
      }
      if (name === 'shelf_list') {
        return await AiToolsExecShelf.shelfList(AiToolsCore.argString(args, 'kind'),
          AiToolsCore.argNumber(args, 'limit'), AiToolsCore.argString(args, 'keyword'));
      }
      if (name === 'book_progress') {
        return AiToolsExecShelf.bookProgress(AiToolsCore.argNumber(args, 'book_id'));
      }
      if (name === 'list_ai_tools') {
        return AiTools.catalog();
      }
      if (name === 'plan') {
        return formatPlanList(AiToolsCore.argString(args, 'items'));
      }
      if (name === 'ask_user') {
        // 文字对话页由回路层（AiService.runToolLoop）拦截执行反问交互；
        // 能走到这里说明是无卡片的渠道（如语音通话），引导模型改用正文直接提问
        return '当前渠道不支持交互式反问，请把问题写在正文里直接问用户，然后停下等待回复';
      }
      if (name === 'set_voice') {
        // 正常路径在 AiVoiceKit.runTool 特判执行（含会话重建）；走到这里=文字回路误调
        return 'set_voice 仅在实时语音通话中可用；文字对话无需换音色';
      }
      return `未知工具：${name}`;
  }
}
