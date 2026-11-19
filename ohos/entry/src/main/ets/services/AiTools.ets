import { TalebookApi } from './TalebookApi';
import { AnnotationApi, annotationTypeLabel, ANNOTATION_SCOPE_MINE } from './AnnotationApi';
import { TalebookService } from './TalebookService';

/**
 * AI 助手的本地工具集（OpenAI function calling 协议）。
 *
 * 设计约束：
 * - **一律只读**：只查用户已有的书架/书籍详情/标注/阅读历史，复用现成服务，不新增写操作。
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

const TOOL_DEFS: AiToolDefinition[] = [TOOL_SEARCH_BOOKS, TOOL_BOOK_DETAIL, TOOL_BOOK_NOTES, TOOL_READING_HISTORY];

export class AiTools {
  /** 随请求体附带的工具定义。 */
  static definitions(): AiToolDefinition[] {
    return TOOL_DEFS;
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
    return name;
  }

  /** 执行一次工具调用；永不抛出，返回给模型的文本结果。 */
  static async execute(name: string, argsJson: string): Promise<string> {
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
      return `未知工具：${name}`;
    } catch (error) {
      return `工具 ${name} 执行失败：${error instanceof Error ? error.message : `${error}`}`;
    }
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
    for (const b of books) {
      lines.push(`id=${b.id} 《${b.title}》（${b.authors.join('、')}）`);
    }
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
