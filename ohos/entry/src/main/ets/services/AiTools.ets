import { ReferBook, ReferSearchOpts, ReferSearchResponse, TalebookApi } from './TalebookApi';
import { AnnotationApi, annotationTypeLabel, ANNOTATION_SCOPE_MINE } from './AnnotationApi';
import { SoNovelBookPayload, DownloadTask, TalebookService } from './TalebookService';
import { SoNovelService } from './SoNovelService';
import { SoNovelMerge, SoNovelSearchItem } from '../utils/SoNovelMerge';
import { DownloadTaskService } from './DownloadTaskService';
import { BookListAddResponse, BookListApi, BookListMutationResponse } from './BookListApi';
import { AiPersona } from './AiPersona';
import { DoubanDetail, DoubanHit, MetaSearchService } from './MetaSearchService';
import { NovelMeta, NovelMetaService } from './NovelMetaService';
import { EncyclopediaHit, EncyclopediaService } from './EncyclopediaService';

/** 工具结果里的一本书（供对话页做结构化列表渲染）。 */
export interface ToolBookLine {
  title: string;
  subtitle: string;
  /** 封面相对路径（服务端书库有图时填充；文本解析路径为空串）。 */
  cover: string;
}

/**
 * 把列表类工具输出（`- [前缀] 《书名》 附加信息` 行模板）解析成结构化条目。
 * 约定即格式：search_books / search_sonovel / list_download_tasks 的行模板改了要同步这里。
 */
export function parseToolBookLines(text: string): ToolBookLine[] {
  const lines: string[] = text.split('\n');
  const books: ToolBookLine[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (!line.startsWith('- ')) {
      continue;
    }
    const body: string = line.substring(2);
    const open: number = body.indexOf('《');
    const close: number = body.indexOf('》');
    if (open < 0 || close <= open) {
      continue;
    }
    const prefix: string = body.substring(0, open).trim();
    const suffix: string = body.substring(close + 1).trim();
    books.push({
      title: body.substring(open, close + 1),
      subtitle: prefix.length > 0 ? `${prefix} ${suffix}` : suffix,
      cover: '',
    });
  }
  return books;
}

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

/** 工具参数的单个属性 schema（OpenAI JSON Schema 子集）。 */
interface AiToolProperty {
  type: string;
  description: string;
}

interface AiToolParameters {
  type: string;
  properties: Record<string, AiToolProperty>;
  required?: string[];
}

interface AiToolFunctionBody {
  name: string;
  description: string;
  parameters: AiToolParameters;
}

/** 请求体 `tools` 数组的一项。 */
export interface AiToolDefinition {
  type: string;
  function: AiToolFunctionBody;
}

const SEARCH_LIMIT: number = 8;
const NOTE_LIMIT: number = 20;
const HISTORY_LIMIT: number = 10;
const INTRO_MAX: number = 500;

/** ArkTS 不接受嵌套匿名对象字面量：每层显式声明类型，逐件构造。 */
function prop(type: string, desc: string): AiToolProperty {
  const p: AiToolProperty = { type: type, description: desc };
  return p;
}

function defineTool(name: string, desc: string, props: Record<string, AiToolProperty>,
  required: string[]): AiToolDefinition {
  const params: AiToolParameters = { type: 'object', properties: props, required: required };
  const body: AiToolFunctionBody = { name: name, description: desc, parameters: params };
  const def: AiToolDefinition = { type: 'function', function: body };
  return def;
}

const EMPTY_PROPS: Record<string, AiToolProperty> = {};
const NO_REQUIRED: string[] = [];
const BOOK_ID_PROP: AiToolProperty = prop('number', '书籍 id（整数）');

const QUERY_PROPS: Record<string, AiToolProperty> = { 'query': prop('string', '书名或关键词') };
const BOOK_ID_PROPS: Record<string, AiToolProperty> = { 'book_id': BOOK_ID_PROP };

const TOOL_SEARCH_BOOKS: AiToolDefinition = defineTool('search_books',
  '在用户的在线书架（MyBooks/Talebook 服务器）中按关键词搜书，返回最多 8 条 {id, 书名, 作者}。' +
    '用户问“书架上有没有/想找某本书”时使用。', QUERY_PROPS, ['query']);
const TOOL_BOOK_DETAIL: AiToolDefinition = defineTool('book_detail',
  '按书籍 id（先由 search_books 得到）返回该书的作者、评分、标签、出版社/ISBN/丛书、可下载格式与截断后的简介。',
  BOOK_ID_PROPS, ['book_id']);
const TOOL_BOOK_NOTES: AiToolDefinition = defineTool('book_notes',
  '按书籍 id 返回当前用户在该书下的私有标注（高亮/笔记/书签），最多 20 条。', BOOK_ID_PROPS, ['book_id']);
const TOOL_READING_HISTORY: AiToolDefinition = defineTool('reading_history',
  '返回用户本机最近的阅读记录（最多 10 条）：书名、当前章节、进度百分比、最近阅读时间。无需参数。',
  EMPTY_PROPS, NO_REQUIRED);

const SONOVEL_LIMIT: number = 8;
const TASK_LIST_LIMIT: number = 10;
const BOOKLIST_DEFAULT_COLOR: string = '#1890ff';

const BOOKLIST_CREATE_PROPS: Record<string, AiToolProperty> = {
  'name': prop('string', '书单名称'),
  'description': prop('string', '书单简介，可留空'),
};
const BOOKLIST_ADD_PROPS: Record<string, AiToolProperty> = {
  'booklist_id': prop('number', '书单 id（create_booklist 返回）'),
  'book_ids': prop('string', '逗号分隔的书籍 id，如 "12,44"（来自 search_books 的 id）'),
};
const SONOVEL_TASK_PROPS: Record<string, AiToolProperty> = {
  'book_name': prop('string', '小说名'),
  'url': prop('string', '书源站详情页 url（来自 search_sonovel）'),
  'author': prop('string', '作者，可留空'),
  'source_id': prop('number', '书源 id（来自 search_sonovel）'),
  'source_name': prop('string', '书源名（来自 search_sonovel）'),
  'format': prop('string', '生成格式 epub 或 txt，默认 epub'),
};
const BOOKLIST_CREATE_REQUIRED: string[] = ['name'];
const BOOKLIST_ADD_REQUIRED: string[] = ['booklist_id', 'book_ids'];
const SONOVEL_TASK_REQUIRED: string[] = ['book_name', 'url'];

const TOOL_SEARCH_SONOVEL: AiToolDefinition = defineTool('search_sonovel',
  '在 so-novel 书源站聚合搜索网络小说，返回最多 8 条 {书名, 作者, 书源, 类别, 状态, 字数, url, 最新章节}。' +
    '用户想下载书架上没有的网络小说时使用；url 是后续 add_sonovel_task 的必需参数，' +
    '也是 get_novel_meta 取简介/封面的入参。',
  QUERY_PROPS, ['query']);
const TOOL_ADD_SONOVEL_TASK: AiToolDefinition = defineTool('add_sonovel_task',
  '把一本 so-novel 网络小说加入下载任务队列（参数来自 search_sonovel 的返回）。' +
    '服务器转换完成后成品会自动拉进本地书架可供阅读。',
  SONOVEL_TASK_PROPS, SONOVEL_TASK_REQUIRED);
const TOOL_LIST_DOWNLOAD_TASKS: AiToolDefinition = defineTool('list_download_tasks',
  '查看当前下载任务队列：每条任务的状态（等待/下载中/完成/失败）、进度与错误原因。无需参数。',
  EMPTY_PROPS, NO_REQUIRED);
const TOOL_CREATE_BOOKLIST: AiToolDefinition = defineTool('create_booklist',
  '在 MyBooks 服务器上创建一个新书单。返回新书单 id，可用于 add_books_to_booklist。',
  BOOKLIST_CREATE_PROPS, BOOKLIST_CREATE_REQUIRED);
const TOOL_ADD_BOOKS_TO_BOOKLIST: AiToolDefinition = defineTool('add_books_to_booklist',
  '把若干本书（书籍 id 来自 search_books）加入指定书单。',
  BOOKLIST_ADD_PROPS, BOOKLIST_ADD_REQUIRED);

const BOOK_META_PROPS: Record<string, AiToolProperty> = {
  'book_id': BOOK_ID_PROP,
  'title': prop('string', '新书名；留空不改'),
  'authors': prop('string', '作者，多个用逗号分隔；留空不改'),
  'tags': prop('string', '标签，逗号分隔；留空不改'),
  'publisher': prop('string', '出版社；留空不改'),
  'isbn': prop('string', 'ISBN；留空不改'),
  'series': prop('string', '丛书名；留空不改'),
  'comment': prop('string', '书籍简介全文；留空不改'),
  'rating': prop('number', '评分 0-10；0 表示不改'),
};
const BOOK_META_REQUIRED: string[] = ['book_id'];

const TOOL_UPDATE_BOOK_META: AiToolDefinition = defineTool('update_book_meta',
  '更新服务器上某本书的元数据（书籍 id 来自 search_books）。只传要修改的字段，未传字段保持原值。' +
    '改前先 book_detail 核对现值并向用户复述目标改动。更换封面图片用 search_cover + set_cover。',
  BOOK_META_PROPS, BOOK_META_REQUIRED);

const COVER_SEARCH_PROPS: Record<string, AiToolProperty> = {
  'book_id': BOOK_ID_PROP,
  'title': prop('string', '检索书名；留空用该书现书名'),
  'isbn': prop('string', 'ISBN；有则优先，命中更准'),
  'publisher': prop('string', '出版社，可留空'),
};
const COVER_SET_PROPS: Record<string, AiToolProperty> = {
  'book_id': BOOK_ID_PROP,
  'index': prop('number', '选第几条候选（1 起，来自 search_cover 返回）'),
};
const COVER_SEARCH_REQUIRED: string[] = ['book_id'];
const COVER_SET_REQUIRED: string[] = ['book_id', 'index'];

const TOOL_SEARCH_COVER: AiToolDefinition = defineTool('search_cover',
  '在互联网元数据源中按 ISBN/书名检索某本书的候选条目，返回每条的书名/作者/出版社/来源/封面图 url。' +
    '更换封面（set_cover）前必须先对同一本书调用本工具。',
  COVER_SEARCH_PROPS, COVER_SEARCH_REQUIRED);
const TOOL_SET_COVER: AiToolDefinition = defineTool('set_cover',
  '把某本书的封面图片换成 search_cover 返回的第 index 条候选（只改封面，其余元数据不动）。' +
    '候选须来自对同一 book_id 的最近一次 search_cover。',
  COVER_SET_PROPS, COVER_SET_REQUIRED);

const MEMORY_SAVE_PROPS: Record<string, AiToolProperty> = {
  'content': prop('string', '要记住的一句话事实，如「用户偏好刘慈欣的长篇」「用户正在读《三体》，计划两周读完」'),
};
const MEMORY_FORGET_PROPS: Record<string, AiToolProperty> = {
  'index': prop('number', '要删除的记忆序号（1 起，来自系统提示中的记忆列表编号）'),
};
const TOOL_SAVE_MEMORY: AiToolDefinition = defineTool('save_memory',
  '把关于用户的一条长期事实记进跨对话记忆：阅读偏好、正在读的书、明确说过的约定、身份/称呼等。' +
    '只记值得跨对话保留的信息，一次性提问和闲聊不要记；已有相同记忆时不要重复记。',
  MEMORY_SAVE_PROPS, ['content']);
const TOOL_FORGET_MEMORY: AiToolDefinition = defineTool('forget_memory',
  '按序号删除一条用户记忆（用户说「别记得/忘掉第 N 条」时用）。序号来自系统提示记忆列表的编号。',
  MEMORY_FORGET_PROPS, ['index']);

const META_SEARCH_PROPS: Record<string, AiToolProperty> = {
  'query': prop('string', '书名或「书名 作者」关键词；也用于网文源检索'),
  'isbn': prop('string', 'ISBN（10/13 位），比书名更准'),
  'subject_id': prop('string', '豆瓣条目 id（来自本工具 suggest 结果），返回评分/出版社/ISBN/页数/简介'),
  'book_id': prop('number', '本地书籍 id；给出时同时拉服务端多源候选（豆瓣/百度/亚马逊/新华，可用于 set_cover）'),
};
const TOOL_SEARCH_META: AiToolDefinition = defineTool('search_meta',
  '多站元数据搜索：豆瓣直连检索（书名/ISBN→subject_id+封面）、豆瓣条目详情（评分/出版社/ISBN/出版年/页数/简介）、' +
    '服务端 refer 多源候选（传 book_id）、网文源含类别/状态/字数（传 query）。' +
    '豆瓣查不到的网文：用网文通道的 url 再调 get_novel_meta 补简介/封面。' +
    '补元数据（update_book_meta）或核对书目信息前先用它查真实数据。',
  META_SEARCH_PROPS, []);

const NOVEL_META_PROPS: Record<string, AiToolProperty> = {
  'url': prop('string', '书源站详情页 url（来自 search_sonovel / search_meta 的网文通道）'),
};
const TOOL_GET_NOVEL_META: AiToolDefinition = defineTool('get_novel_meta',
  '抓书源站详情页补全网络小说元数据：简介、封面、类别、连载状态（url 来自 search_sonovel 结果）。' +
    '豆瓣查不到的网文就靠它；对 17K小说网详情页解析最全。失败时换另一条书源候选的 url 重试。',
  NOVEL_META_PROPS, ['url']);

const ENCYCLOPEDIA_PROPS: Record<string, AiToolProperty> = {
  'query': prop('string', '百科词条名（如「刘慈欣」「三体」），只给名词本身，不要带「是谁/什么是」等整句问话'),
};
const TOOL_SEARCH_ENCYCLOPEDIA: AiToolDefinition = defineTool('search_encyclopedia',
  '搜百科词条（百度百科+维基百科双通道）：回答「这位作者是谁/这本书什么背景/某地某概念」类问题，' +
    '返回词条标题、摘要与链接。query 传词条名而非整句问话。一个通道不可达会如实标注并仍给另一通道结果。',
  ENCYCLOPEDIA_PROPS, ['query']);

// 顺序有坑：OpenCode 网关实测会丢 tools 数组最后一项（2026-11-20 板上取证：模型枚举
// 恰缺末位 get_novel_meta，报「最后一个工具是 search_meta」）。末位放最低频工具，
// 新增工具一律插在中间，别放最后。
const TOOL_DEFS: AiToolDefinition[] = [
  TOOL_SEARCH_BOOKS, TOOL_BOOK_DETAIL, TOOL_BOOK_NOTES, TOOL_READING_HISTORY,
  TOOL_SEARCH_SONOVEL, TOOL_ADD_SONOVEL_TASK, TOOL_LIST_DOWNLOAD_TASKS,
  TOOL_CREATE_BOOKLIST, TOOL_ADD_BOOKS_TO_BOOKLIST, TOOL_UPDATE_BOOK_META,
  TOOL_SEARCH_COVER, TOOL_SET_COVER,
  TOOL_SAVE_MEMORY, TOOL_SEARCH_META, TOOL_GET_NOVEL_META, TOOL_SEARCH_ENCYCLOPEDIA,
  TOOL_FORGET_MEMORY,
];

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
   * 写操作工具：confirm 模式下执行前必须过用户确认闸门（AiStreamHandlers.onConfirm），
   * readonly 模式下不出现在 tools 里。
   * 名字与 TOOL_DEFS 里的写工具对应；新加写工具忘记登记 = 无确认直接执行，务必同步。
   */
  private static readonly WRITE_TOOLS: string[] =
    ['create_booklist', 'add_books_to_booklist', 'add_sonovel_task', 'update_book_meta', 'set_cover',
      'forget_memory'];

  static needsConfirm(name: string): boolean {
    return AiTools.WRITE_TOOLS.indexOf(name) >= 0;
  }

  /**
   * 最近一次书目型工具的结构化结果（含封面），供对话页渲染卡片。
   * 工具回路串行执行，读后即清即可避免与下一次结果串台。
   */
  private static lastBooks: ToolBookLine[] = [];

  static takeLastBooks(): ToolBookLine[] {
    const books: ToolBookLine[] = AiTools.lastBooks;
    AiTools.lastBooks = [];
    return books;
  }

  /**
   * search_cover 的候选缓存：set_cover 在同一次对话回路里跨 execute 调用读取，
   * 故不在 execute 入口清空，改由 lastCoverBookId 与 book_id 匹配来防串台。
   */
  private static lastCoverCandidates: ReferBook[] = [];
  private static lastCoverBookId: number = 0;

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
    if (name === 'save_memory') {
      return '记住用户的事';
    }
    if (name === 'forget_memory') {
      return '删除一条记忆';
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
  static async execute(name: string, argsJson: string): Promise<string> {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        return await AiTools.dispatch(name, argsJson);
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

  private static async dispatch(name: string, argsJson: string): Promise<string> {
    AiTools.lastBooks = [];
    const args: Record<string, Object> = AiTools.parseArgs(argsJson);
      if (name === 'search_books') {
        return await AiTools.searchBooks(AiTools.argString(args, 'query'));
      }
      if (name === 'book_detail') {
        return await AiTools.bookDetail(AiTools.argNumber(args, 'book_id'));
      }
      if (name === 'book_notes') {
        return await AiTools.bookNotes(AiTools.argNumber(args, 'book_id'));
      }
      if (name === 'reading_history') {
        return AiTools.readingHistory();
      }
      if (name === 'search_sonovel') {
        return await AiTools.searchSoNovel(AiTools.argString(args, 'query'));
      }
      if (name === 'add_sonovel_task') {
        return AiTools.addSonovelTask(args);
      }
      if (name === 'update_book_meta') {
        return await AiTools.updateBookMeta(args);
      }
      if (name === 'search_cover') {
        return await AiTools.searchCover(args);
      }
      if (name === 'set_cover') {
        return await AiTools.setCover(args);
      }
      if (name === 'list_download_tasks') {
        return AiTools.listDownloadTasks();
      }
      if (name === 'create_booklist') {
        return await AiTools.createBooklist(args);
      }
      if (name === 'add_books_to_booklist') {
        return await AiTools.addBooksToBooklist(args);
      }
      if (name === 'search_meta') {
        return await AiTools.searchMeta(args);
      }
      if (name === 'get_novel_meta') {
        return await AiTools.getNovelMeta(args);
      }
      if (name === 'search_encyclopedia') {
        return await AiTools.searchEncyclopedia(AiTools.argString(args, 'query'));
      }
      if (name === 'save_memory') {
        return AiPersona.appendMemory(AiTools.argString(args, 'content'));
      }
      if (name === 'forget_memory') {
        return AiPersona.removeMemory(AiTools.argNumber(args, 'index'));
      }
      return `未知工具：${name}`;
  }

  /**
   * 更新书籍元数据。服务端 /api/book/:id/edit 是全量表单提交（BookEditPage 同款 payload），
   * 因此先读现值、只覆盖用户点名要改的字段，再整体提交，避免未传字段被清空。
   */
  private static async updateBookMeta(args: Record<string, Object>): Promise<string> {
    const bookId: number = AiTools.argNumber(args, 'book_id');
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    const envelope = await TalebookService.getBookDetailAsync(bookId);
    const body: Record<string, Object> = envelope.body ?? {};
    const book: Record<string, Object> = (body['book'] as Record<string, Object> | undefined) ?? body;
    const oldTitle: string = String(book['title'] ?? '');
    if (oldTitle.length === 0) {
      return `没有找到 id=${bookId} 的书。`;
    }
    const oldAuthors: string[] = Array.isArray(book['authors']) ? (book['authors'] as string[]) : [];
    const oldTags: string[] = Array.isArray(book['tags']) ? (book['tags'] as string[]) : [];
    const changes: string[] = [];
    const newTitle: string = AiTools.argString(args, 'title').length > 0
      ? AiTools.argString(args, 'title').trim() : oldTitle;
    if (newTitle !== oldTitle) {
      changes.push(`书名「${oldTitle}」→「${newTitle}」`);
    }
    let authors: string[] = oldAuthors;
    if (AiTools.argString(args, 'authors').length > 0) {
      authors = AiTools.argString(args, 'authors').split(',').map((s: string) => s.trim()).filter((s: string) => s.length > 0);
      changes.push(`作者 →「${authors.join('、')}」`);
    }
    let tags: string[] = oldTags;
    if (AiTools.argString(args, 'tags').length > 0) {
      tags = AiTools.argString(args, 'tags').split(',').map((s: string) => s.trim()).filter((s: string) => s.length > 0);
      changes.push(`标签 →「${tags.join('、')}」`);
    }
    const publisher: string = AiTools.argString(args, 'publisher').length > 0
      ? AiTools.argString(args, 'publisher').trim() : String(book['publisher'] ?? '');
    if (publisher !== String(book['publisher'] ?? '')) {
      changes.push(`出版社 →「${publisher}」`);
    }
    const isbn: string = AiTools.argString(args, 'isbn').length > 0
      ? AiTools.argString(args, 'isbn').trim() : String(book['isbn'] ?? '');
    if (isbn !== String(book['isbn'] ?? '')) {
      changes.push(`ISBN →「${isbn}」`);
    }
    const series: string = AiTools.argString(args, 'series').length > 0
      ? AiTools.argString(args, 'series').trim() : String(book['series'] ?? '');
    if (series !== String(book['series'] ?? '')) {
      changes.push(`丛书 →「${series}」`);
    }
    const comments: string = AiTools.argString(args, 'comment').length > 0
      ? AiTools.argString(args, 'comment') : String(book['comments'] ?? '');
    if (comments !== String(book['comments'] ?? '')) {
      changes.push('简介已更新');
    }
    const rating: number = AiTools.argNumber(args, 'rating');
    if (changes.length === 0 && rating <= 0) {
      return '没有要修改的字段（所有参数都留空了）。';
    }
    const payload: Record<string, Object> = {
      'title': newTitle,
      'authors': authors,
      'publisher': publisher,
      'comments': comments,
      'tags': tags,
      'isbn': isbn,
      'series': series,
      'languages': Array.isArray(book['languages']) ? (book['languages'] as string[]) : [],
      'translators': Array.isArray(book['translators']) ? (book['translators'] as string[]) : [],
    };
    const oldSeriesIndex: Object = book['series_index'];
    if (oldSeriesIndex !== undefined && oldSeriesIndex !== null) {
      payload['series_index'] = Number(oldSeriesIndex);
    }
    if (rating > 0) {
      payload['rating'] = Math.min(10, Math.round(rating));
      changes.push(`评分 →${payload['rating']}`);
    }
    const rsp = await TalebookService.editBookAsync(bookId, payload);
    if (rsp.status < 200 || rsp.status >= 300) {
      return `更新失败（${rsp.error.length > 0 ? rsp.error : `HTTP ${rsp.status}`}）。`;
    }
    return `已更新《${newTitle}》：${changes.join('；')}`;
  }

  private static async searchCover(args: Record<string, Object>): Promise<string> {
    const bookId: number = AiTools.argNumber(args, 'book_id');
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    const opts: ReferSearchOpts = {};
    if (AiTools.argString(args, 'title').length > 0) {
      opts.title = AiTools.argString(args, 'title').trim();
    }
    if (AiTools.argString(args, 'isbn').length > 0) {
      opts.isbn = AiTools.argString(args, 'isbn').trim();
    }
    if (AiTools.argString(args, 'publisher').length > 0) {
      opts.publisher = AiTools.argString(args, 'publisher').trim();
    }
    const rsp: ReferSearchResponse = await TalebookApi.searchRefer(bookId, opts);
    if (rsp.books.length === 0) {
      return '互联网上没有检索到该书的元数据候选。可尝试补充更准确的 ISBN 再查。';
    }
    AiTools.lastCoverCandidates = rsp.books;
    AiTools.lastCoverBookId = bookId;
    const lines: string[] = [];
    for (let i = 0; i < rsp.books.length; i++) {
      const b: ReferBook = rsp.books[i];
      const authors: string[] = b.authors ?? [];
      lines.push(`- 候选${i + 1}：《${b.title ?? ''}》（${authors.join('、')}）` +
        `出版社：${b.publisher ?? '未知'}　来源：${b.source}　封面：${b.cover_url ?? ''}`);
    }
    return `找到 ${rsp.books.length} 条候选（换封面用 set_cover 传 index）：\n${lines.join('\n')}`;
  }

  /**
   * 多通道元数据搜索聚合：豆瓣直连（suggest/detail）、服务端 refer（book_id）、
   * 网文源（query，复用 searchSoNovel）。各通道独立降级，单站失败不影响其余。
   */
  private static async searchMeta(args: Record<string, Object>): Promise<string> {
    const query: string = AiTools.argString(args, 'query').trim();
    const isbn: string = AiTools.argString(args, 'isbn').trim();
    const subjectId: string = AiTools.argString(args, 'subject_id').trim();
    const bookId: number = AiTools.argNumber(args, 'book_id');
    // 详情模式：只要豆瓣 subject 详情，一次把评分/出版社/ISBN 给全
    if (subjectId.length > 0) {
      const d: DoubanDetail = await MetaSearchService.detail(subjectId);
      if (!d.ok) {
        return `豆瓣详情获取失败：${d.error}`;
      }
      const fields: string[] = [`《${d.title}》${d.author.length > 0 ? `（${d.author}）` : ''}`];
      if (d.rating.length > 0) {
        fields.push(`豆瓣评分：${d.rating}`);
      }
      if (d.publisher.length > 0) {
        fields.push(`出版社：${d.publisher}`);
      }
      if (d.publishYear.length > 0) {
        fields.push(`出版时间：${d.publishYear}`);
      }
      if (d.isbn.length > 0) {
        fields.push(`ISBN：${d.isbn}`);
      }
      if (d.pages.length > 0) {
        fields.push(`页数：${d.pages}`);
      }
      if (d.binding.length > 0) {
        fields.push(`装帧：${d.binding}`);
      }
      if (d.price.length > 0) {
        fields.push(`定价：${d.price}`);
      }
      let out: string = `豆瓣详情：\n${fields.join('\n')}`;
      if (d.intro.length > 0) {
        out += `\n简介：\n${d.intro}`;
      }
      return out;
    }
    const sections: string[] = [];
    if (bookId > 0) {
      const opts: ReferSearchOpts = {};
      if (query.length > 0) {
        opts.title = query;
      }
      if (isbn.length > 0) {
        opts.isbn = isbn;
      }
      const rsp: ReferSearchResponse = await TalebookApi.searchRefer(bookId, opts);
      // 候选同时缓存给 set_cover 复用（与 search_cover 同一约定）
      AiTools.lastCoverCandidates = rsp.books;
      AiTools.lastCoverBookId = bookId;
      const lines: string[] = [];
      for (let i = 0; i < rsp.books.length && i < 12; i++) {
        const b: ReferBook = rsp.books[i];
        const authors: string[] = b.authors ?? [];
        lines.push(`- 候选${i + 1}：《${b.title ?? ''}》（${authors.join('、')}）` +
          `出版社：${b.publisher ?? '未知'}　ISBN：${b.isbn ?? ''}　来源：${b.source}　封面：${b.cover_url ?? ''}`);
      }
      sections.push(lines.length > 0
        ? `服务端多源候选（id=${bookId}，换封面可直接 set_cover 传 index）：\n${lines.join('\n')}`
        : `服务端多源没有 id=${bookId} 的候选。`);
    }
    const kw: string = isbn.length > 0 ? isbn : query;
    if (kw.length > 0) {
      try {
        const hits: DoubanHit[] = await MetaSearchService.suggest(kw);
        if (hits.length > 0) {
          const lines: string[] = [];
          for (let i = 0; i < hits.length; i++) {
            const h: DoubanHit = hits[i];
            lines.push(`- 《${h.title}》（${h.author}）${h.year}　subject_id=${h.subjectId}　封面：${h.cover}`);
          }
          sections.push(`豆瓣检索「${kw}」（要评分/出版社就用 subject_id 再查）：\n${lines.join('\n')}`);
        } else {
          sections.push(`豆瓣没有「${kw}」的匹配。`);
        }
      } catch (error) {
        sections.push(`豆瓣检索失败：${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (query.length > 0) {
      sections.push(await AiTools.searchSoNovel(query));
    }
    if (sections.length === 0) {
      return '请至少提供 query（书名）/ isbn / subject_id / book_id 之一。';
    }
    return sections.join('\n\n');
  }

  /**
   * 网文元数据补全：抓书源站详情页解析简介/封面（so-novel 聚合搜索不提供这两样的补丁通道）。
   */
  private static async getNovelMeta(args: Record<string, Object>): Promise<string> {
    const url: string = AiTools.argString(args, 'url').trim();
    if (url.length === 0) {
      return '参数 url 必填（search_sonovel 结果里的书源站详情页地址）。';
    }
    const meta: NovelMeta = await NovelMetaService.fetchDetail(url);
    if (!meta.ok) {
      return `网文元数据获取失败：${meta.error}\nurl：${url}`;
    }
    const head: string[] = [];
    if (meta.title.length > 0) {
      head.push(`书名：${meta.title}`);
    }
    if (meta.author.length > 0) {
      head.push(`作者：${meta.author}`);
    }
    if (meta.category.length > 0) {
      head.push(`类别：${meta.category}`);
    }
    if (meta.status.length > 0) {
      head.push(`状态：${meta.status}`);
    }
    let out: string = `网文元数据（规则：${meta.rule}，来源 ${url}）：\n${head.join('　')}`;
    if (meta.cover.length > 0) {
      out += `\n封面：${meta.cover}`;
    }
    if (meta.intro.length > 0) {
      out += `\n简介：\n${meta.intro}`;
    }
    out += '\n要把简介写进书架用 update_book_meta 的 comment 字段。';
    return out;
  }

  /**
   * 百科双通道聚合：各通道独立容错（EncyclopediaService 已把网络失败转成 ok=false），
   * 全失败才回失败文案——不抛错，避免 execute 层对「被墙」这类确定性失败做无意义重试。
   */
  private static async searchEncyclopedia(query: string): Promise<string> {
    const trimmed: string = query.trim();
    if (trimmed.length === 0) {
      return '参数 query 为空，请提供百科词条关键词。';
    }
    const bk: EncyclopediaHit = await EncyclopediaService.searchBaike(trimmed);
    const wk: EncyclopediaHit = await EncyclopediaService.searchWikipedia(trimmed);
    if (!bk.ok && !wk.ok) {
      return `百科检索失败：百度百科（${bk.error}）；维基百科（${wk.error}）`;
    }
    const parts: string[] = [];
    if (bk.ok) {
      parts.push(`【百度百科】${bk.title}\n${bk.abstract}\n链接：${bk.url}`);
    } else {
      parts.push(`【百度百科】未获取到：${bk.error}`);
    }
    if (wk.ok) {
      parts.push(`【维基百科】${wk.title}\n${wk.abstract}\n链接：${wk.url}`);
    } else {
      parts.push(`【维基百科】未获取到：${wk.error}`);
    }
    return parts.join('\n\n');
  }

  private static async setCover(args: Record<string, Object>): Promise<string> {
    const bookId: number = AiTools.argNumber(args, 'book_id');
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    if (AiTools.lastCoverBookId !== bookId || AiTools.lastCoverCandidates.length === 0) {
      return `id=${bookId} 没有可引用的封面候选，请先对该书调用 search_cover。`;
    }
    const index: number = AiTools.argNumber(args, 'index');
    if (index < 1 || index > AiTools.lastCoverCandidates.length) {
      return `候选序号 ${index} 超出范围（当前有效 1-${AiTools.lastCoverCandidates.length}）。`;
    }
    const entry: ReferBook = AiTools.lastCoverCandidates[index - 1];
    if ((entry.cover_url ?? '').length === 0) {
      return `候选${index}没有封面图片 url，请换一条候选。`;
    }
    const rsp = await TalebookApi.applyRefer(bookId, entry, false, true);
    if (rsp.err !== undefined && rsp.err !== 'ok') {
      return `换封面失败：${(rsp.msg ?? '').length > 0 ? rsp.msg : rsp.err}`;
    }
    return `已将 id=${bookId} 的封面换成候选${index}（来源 ${entry.source}），其余元数据未动。`;
  }

  private static async searchBooks(query: string): Promise<string> {
    if (query.length === 0) {
      return '参数 query 为空，请提供书名或关键词。';
    }
    const books = await TalebookApi.search(query, 1, SEARCH_LIMIT);
    if (books.length === 0) {
      return `书架中没有找到与「${query}」相关的书。`;
    }
    const lines: string[] = [];
    const structured: ToolBookLine[] = [];
    for (const b of books) {
      lines.push(`- 《${b.title}》（${b.authors.join('、')}） id=${b.id}`);
      structured.push({
        title: `《${b.title}》`,
        subtitle: b.authors.join('、'),
        cover: b.coverUrl,
      });
    }
    AiTools.lastBooks = structured;
    return `找到 ${books.length} 本：\n${lines.join('\n')}`;
  }

  private static async bookDetail(bookId: number): Promise<string> {
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    const detail = await TalebookApi.getBookDetail(bookId);
    if (detail === null) {
      return `没有找到 id=${bookId} 的书籍。`;
    }
    const lines: string[] = [
      `《${detail.title}》（${detail.authors.join('、')}），评分 ${detail.rating}`,
    ];
    if (detail.tags.length > 0) {
      lines.push(`标签：${detail.tags.join('、')}`);
    }
    const meta: string[] = [];
    if (detail.publisher.length > 0) {
      meta.push(`出版社：${detail.publisher}`);
    }
    if (detail.isbn.length > 0) {
      meta.push(`ISBN：${detail.isbn}`);
    }
    if (detail.series.length > 0) {
      meta.push(`丛书：${detail.series}`);
    }
    if (meta.length > 0) {
      lines.push(meta.join('　'));
    }
    const formats: string[] = [];
    for (const f of detail.files) {
      formats.push(f.format);
    }
    if (formats.length > 0) {
      lines.push(`可下载格式：${formats.join('、')}`);
    }
    if (detail.comments.length > 0) {
      lines.push(`简介：${AiTools.clip(detail.comments, INTRO_MAX)}`);
    }
    return lines.join('\n');
  }

  private static async bookNotes(bookId: number): Promise<string> {
    if (bookId <= 0) {
      return '参数 book_id 需要是正整数（可先用 search_books 查到 id）。';
    }
    const items = await AnnotationApi.listBookAnnotations(bookId, ANNOTATION_SCOPE_MINE);
    if (items.length === 0) {
      return '这本书还没有你的标注记录。';
    }
    const cap: number = Math.min(items.length, NOTE_LIMIT);
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      const it = items[i];
      let line: string = `[${annotationTypeLabel(it.annotationType)}]`;
      if (it.chapter.length > 0) {
        line += ` 章节：${AiTools.clip(it.chapter, 40)}`;
      }
      if (it.quoteText.length > 0) {
        line += ` 原文「${AiTools.clip(it.quoteText, 60)}」`;
      }
      if (it.content.length > 0) {
        line += ` 备注：${AiTools.clip(it.content, 100)}`;
      }
      lines.push(line);
    }
    const more: string = items.length > cap ? `\n（共 ${items.length} 条，仅显示前 ${cap} 条）` : '';
    return `${lines.join('\n')}${more}`;
  }

  private static readingHistory(): string {
    const items = TalebookService.getReadingHistory().slice();
    items.sort((a, b): number => b.lastReadTime - a.lastReadTime);
    const cap: number = Math.min(items.length, HISTORY_LIMIT);
    if (cap === 0) {
      return '还没有阅读记录。';
    }
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      const it = items[i];
      let line: string = `《${it.title}》`;
      if (it.author !== undefined && it.author.length > 0) {
        line += `（${it.author}）`;
      }
      if (it.chapterName !== undefined && it.chapterName.length > 0) {
        line += ` 读到：${AiTools.clip(it.chapterName, 30)}`;
      }
      if (it.progressPercent !== undefined) {
        line += `，进度 ${Math.round(it.progressPercent)}%`;
      }
      line += `，最近阅读 ${AiTools.formatDate(it.lastReadTime)}`;
      lines.push(line);
    }
    return `最近阅读 ${cap} 本：\n${lines.join('\n')}`;
  }

  private static async searchSoNovel(query: string): Promise<string> {
    if (query.length === 0) {
      return '参数 query 为空，请提供小说名关键词。';
    }
    const envelope = await SoNovelService.search(query);
    if (envelope.error.length > 0) {
      return `so-novel 搜索失败：${envelope.error}`;
    }
    const body: Record<string, Object> | null = envelope.body as Record<string, Object> | null;
    const data: Object | undefined = body !== null ? body['data'] : undefined;
    if (data === undefined || !Array.isArray(data) || data.length === 0) {
      return `各书源没有找到与「${query}」相关的小说。`;
    }
    const cap: number = Math.min(data.length, SONOVEL_LIMIT);
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      const item: SoNovelSearchItem = SoNovelMerge.fromRecord(data[i] as Record<string, Object>);
      let line: string = `- 《${item.bookName}》（${item.author.length > 0 ? item.author : '佚名'}）` +
        ` 书源：${item.sourceName}(id=${item.sourceId})`;
      if (item.category.length > 0) {
        line += `，类别：${item.category}`;
      }
      if (item.status.length > 0) {
        line += `，${item.status}`;
      }
      if (item.wordCount.length > 0) {
        line += `，字数：${item.wordCount}`;
      }
      if (item.latestChapter.length > 0) {
        line += `，最新章节：${AiTools.clip(item.latestChapter, 30)}`;
      }
      line += `，url：${item.url}`;
      lines.push(line);
    }
    return `书源站找到 ${cap} 条，要下载需调 add_sonovel_task（带上 url 与书源信息）；` +
      `要简介/封面拿该 url 调 get_novel_meta：\n${lines.join('\n')}`;
  }

  private static addSonovelTask(args: Record<string, Object>): string {
    const bookName: string = AiTools.argString(args, 'book_name');
    const url: string = AiTools.argString(args, 'url');
    if (bookName.length === 0 || url.length === 0) {
      return '参数 book_name 与 url 必填（都来自 search_sonovel 的结果）。';
    }
    const formatRaw: string = AiTools.argString(args, 'format').toLowerCase();
    const format: string = formatRaw === 'txt' ? 'txt' : 'epub';
    const payload: SoNovelBookPayload = {
      sourceId: AiTools.argNumber(args, 'source_id'),
      sourceName: AiTools.argString(args, 'source_name'),
      url: url,
      bookName: bookName,
      author: AiTools.argString(args, 'author'),
      format: format,
      language: 'zh-CN',
    };
    const dup: DownloadTask | undefined = DownloadTaskService.getTasks().find((t: DownloadTask) =>
      t.kind === 'sonovel' && t.payload !== undefined && t.payload.url === url &&
        (t.status === 'pending' || t.status === 'downloading'));
    if (dup !== undefined) {
      return `《${bookName}》已在下载队列中（状态：${DownloadTaskService.statusLabel(dup.status)}），无需重复添加。`;
    }
    DownloadTaskService.enqueue(payload);
    DownloadTaskService.processQueue();
    return `已加入下载任务：《${bookName}》（书源：${payload.sourceName.length > 0 ? payload.sourceName : '未知'}，` +
      `格式 ${format}）。服务器转换完成后成品会自动拉进本地书架；进度可随时让我用 list_download_tasks 查。`;
  }

  private static listDownloadTasks(): string {
    const tasks: DownloadTask[] = DownloadTaskService.getTasks();
    if (tasks.length === 0) {
      return '还没有下载任务。';
    }
    const cap: number = Math.min(tasks.length, TASK_LIST_LIMIT);
    const lines: string[] = [];
    for (let i = 0; i < cap; i++) {
      const t: DownloadTask = tasks[i];
      let line: string = `- [${DownloadTaskService.statusLabel(t.status)}] 《${t.title}》` +
        `（${t.author.length > 0 ? t.author : '佚名'}）`;
      if (t.status === 'downloading') {
        line += ` 进度 ${t.progress}% ${AiTools.clip(t.message, 30)}`;
      }
      if (t.status === 'failed' && t.error.length > 0) {
        line += ` 错误：${AiTools.clip(t.error, 40)}`;
      }
      if (t.status === 'completed' && t.filePath.length > 0) {
        line += '，已存入本地书架';
      }
      lines.push(line);
    }
    const more: string = tasks.length > cap ? `\n（共 ${tasks.length} 条，仅列最近 ${cap} 条）` : '';
    return `下载任务：\n${lines.join('\n')}${more}`;
  }

  private static async createBooklist(args: Record<string, Object>): Promise<string> {
    const name: string = AiTools.argString(args, 'name');
    if (name.length === 0) {
      return '参数 name 为空，请给书单起个名字。';
    }
    const description: string = AiTools.argString(args, 'description');
    const res: BookListMutationResponse =
      await BookListApi.createBooklist(name, description, BOOKLIST_DEFAULT_COLOR, true);
    if (res.err !== undefined && res.err !== 'ok') {
      return `创建书单失败：${res.msg !== undefined && res.msg.length > 0 ? res.msg : res.err}`;
    }
    const booklist: Record<string, Object> | undefined = res.booklist as Record<string, Object> | undefined;
    const id: number = booklist !== undefined ? Number(booklist['id'] ?? 0) : 0;
    return `已创建书单「${name}」${id > 0 ? `（id=${id}）` : ''}。` +
      '接下来可用 add_books_to_booklist 把 search_books 查到的书 id 加进来。';
  }

  private static async addBooksToBooklist(args: Record<string, Object>): Promise<string> {
    const booklistId: number = AiTools.argNumber(args, 'booklist_id');
    const raw: string = AiTools.argString(args, 'book_ids');
    if (booklistId <= 0 || raw.length === 0) {
      return '参数 booklist_id 与 book_ids（逗号分隔的书籍 id）必填。';
    }
    const ids: number[] = [];
    for (const part of raw.split(',')) {
      const num: number = Number(part.trim());
      if (Number.isFinite(num) && num > 0) {
        ids.push(num);
      }
    }
    if (ids.length === 0) {
      return 'book_ids 没解析出任何有效 id。';
    }
    const res: BookListAddResponse = await BookListApi.addBooks(booklistId, ids);
    if (res.err !== undefined && res.err !== 'ok') {
      return `书单加书失败：${res.msg !== undefined && res.msg.length > 0 ? res.msg : res.err}`;
    }
    return `已把 ${res.added !== undefined ? res.added : ids.length} 本书加入书单` +
      `${res.book_count !== undefined ? `，书单现有 ${res.book_count} 本` : ''}。`;
  }

  private static parseArgs(json: string): Record<string, Object> {
    if (json.length === 0) {
      return {};
    }
    try {
      return JSON.parse(json) as Record<string, Object>;
    } catch (_error) {
      return {};
    }
  }

  private static argString(args: Record<string, Object>, key: string): string {
    const value = args[key];
    if (value === undefined || value === null) {
      return '';
    }
    return String(value);
  }

  private static argNumber(args: Record<string, Object>, key: string): number {
    const value = args[key];
    if (value === undefined || value === null) {
      return 0;
    }
    const num: number = Number(value);
    return Number.isFinite(num) ? Math.floor(num) : 0;
  }

  private static clip(text: string, max: number): string {
    const trimmed: string = text.trim();
    return trimmed.length <= max ? trimmed : `${trimmed.substring(0, max)}…`;
  }

  private static formatDate(ts: number): string {
    if (ts <= 0) {
      return '未知';
    }
    const d = new Date(ts);
    return `${d.getFullYear()}-${AiTools.pad2(d.getMonth() + 1)}-${AiTools.pad2(d.getDate())} ` +
      `${AiTools.pad2(d.getHours())}:${AiTools.pad2(d.getMinutes())}`;
  }

  private static pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }
}
