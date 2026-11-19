import { TalebookApi } from './TalebookApi';
import { AnnotationApi, annotationTypeLabel, ANNOTATION_SCOPE_MINE } from './AnnotationApi';
import { SoNovelBookPayload, DownloadTask, TalebookService } from './TalebookService';
import { SoNovelService } from './SoNovelService';
import { SoNovelMerge, SoNovelSearchItem } from '../utils/SoNovelMerge';
import { DownloadTaskService } from './DownloadTaskService';
import { BookListAddResponse, BookListApi, BookListMutationResponse } from './BookListApi';

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
  '按书籍 id（先由 search_books 得到）返回该书的作者、评分、标签、可下载格式与截断后的简介。',
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
  '在 so-novel 书源站聚合搜索网络小说，返回最多 8 条 {书名, 作者, 书源, url, 最新章节}。' +
    '用户想下载书架上没有的网络小说时使用；url 是后续 add_sonovel_task 的必需参数。',
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
    '改前先 book_detail 核对现值并向用户复述目标改动。暂不支持更换封面图片。',
  BOOK_META_PROPS, BOOK_META_REQUIRED);

const TOOL_DEFS: AiToolDefinition[] = [
  TOOL_SEARCH_BOOKS, TOOL_BOOK_DETAIL, TOOL_BOOK_NOTES, TOOL_READING_HISTORY,
  TOOL_SEARCH_SONOVEL, TOOL_ADD_SONOVEL_TASK, TOOL_LIST_DOWNLOAD_TASKS,
  TOOL_CREATE_BOOKLIST, TOOL_ADD_BOOKS_TO_BOOKLIST, TOOL_UPDATE_BOOK_META,
];

export class AiTools {
  /** 随请求体附带的工具定义。 */
  static definitions(): AiToolDefinition[] {
    return TOOL_DEFS;
  }

  /**
   * 写操作工具：执行前必须过用户确认闸门（AiStreamHandlers.onConfirm）。
   * 名字与 TOOL_DEFS 里的写工具对应；新加写工具忘记登记 = 无确认直接执行，务必同步。
   */
  private static readonly WRITE_TOOLS: string[] =
    ['create_booklist', 'add_books_to_booklist', 'add_sonovel_task', 'update_book_meta'];

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
    return name;
  }

  /** 执行一次工具调用；永不抛出，返回给模型的文本结果。 */
  static async execute(name: string, argsJson: string): Promise<string> {
    AiTools.lastBooks = [];
    try {
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
      if (name === 'list_download_tasks') {
        return AiTools.listDownloadTasks();
      }
      if (name === 'create_booklist') {
        return await AiTools.createBooklist(args);
      }
      if (name === 'add_books_to_booklist') {
        return await AiTools.addBooksToBooklist(args);
      }
      return `未知工具：${name}`;
    } catch (error) {
      return `工具 ${name} 执行失败：${error instanceof Error ? error.message : `${error}`}`;
    }
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
      if (item.latestChapter.length > 0) {
        line += `，最新章节：${AiTools.clip(item.latestChapter, 30)}`;
      }
      line += `，url：${item.url}`;
      lines.push(line);
    }
    return `书源站找到 ${cap} 条，要下载需调 add_sonovel_task（带上 url 与书源信息）：\n${lines.join('\n')}`;
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
