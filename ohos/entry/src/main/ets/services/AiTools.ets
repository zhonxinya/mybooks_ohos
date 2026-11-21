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
import { TOOL_DEFS, TOOL_SET_VOICE, ToolBookLine, AiToolDefinition } from './AiToolsDefs';

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
   * realtime 语音通话工具面 = 文字全集 + set_voice。
   * 音色切换只在通话会话有意义，不进 TOOL_DEFS（文字回路不暴露）。
   */
  static realtimeDefinitions(mode: AiPermissionMode = 'confirm'): AiToolDefinition[] {
    const defs: AiToolDefinition[] = AiTools.definitions(mode).slice();
    defs.splice(defs.length - 1, 0, TOOL_SET_VOICE);
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
      'update_book_meta', 'set_cover', 'save_memory', 'forget_memory'];

  static needsConfirm(name: string): boolean {
    return AiTools.WRITE_TOOLS.indexOf(name) >= 0;
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
   */
  static async execute(name: string, argsJson: string, callId: string = ''): Promise<string> {
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
