import { AiService, AiMessage } from './AiService';

/**
 * 书架 / 书籍场景的 AI 能力。
 *
 * 与 `AiService` 的分工：`AiService` 只管协议与连接，本类负责「把书籍上下文组织成
 * 提示词」并解析结构化结果。所有能力都在客户端完成，不依赖服务端 AI 端点。
 */

/** 单本书的上下文（提示词素材）。 */
export interface BookContext {
  title: string;
  author: string;
  publisher: string;
  description: string;
  tags: string[];
}

/** 元数据建议：只给建议，不直接改库，交给用户在编辑页确认。 */
export interface MetaSuggestion {
  title: string;
  author: string;
  publisher: string;
  tags: string;
  summary: string;
  /** 模型自评置信度（低/中/高），用于提示用户是否值得采信。 */
  confidence: string;
}

/** 推荐结果项。 */
export interface RecommendedBook {
  title: string;
  author: string;
  reason: string;
}

/** 书架概况（用于推荐书单）。 */
export interface ShelfProfile {
  titles: string[];
  authors: string[];
  tags: string[];
}

export class AiBookService {
  private static bookPrompt(context: BookContext): string {
    const parts: string[] = [];
    parts.push(`书名：${context.title}`);
    if (context.author.length > 0) {
      parts.push(`作者：${context.author}`);
    }
    if (context.publisher.length > 0) {
      parts.push(`出版社：${context.publisher}`);
    }
    if (context.tags.length > 0) {
      parts.push(`标签：${context.tags.join('、')}`);
    }
    if (context.description.length > 0) {
      // 简介可能很长，截断以免浪费上下文（多数模型的简介前 1200 字已足够判断）
      parts.push(`简介：${context.description.substring(0, 1200)}`);
    }
    return parts.join('\n');
  }

  /** 不开流式的短请求：书评/摘要都是一次性结果，直接等完整文本更简单。 */
  static async summarize(context: BookContext, maxChars: number): Promise<string> {
    if (!AiService.isReady()) {
      throw new Error('尚未配置 AI 模型');
    }
    const messages: AiMessage[] = [
      { role: 'system', content: '你是图书编辑助手。只输出正文，不要开场白、不要 Markdown 标题。' },
      {
        role: 'user',
        content: `${AiBookService.bookPrompt(context)}\n\n请用 ${maxChars} 字以内概括这本书：核心内容、主要看点、适合谁读。`,
      },
    ];
    return AiService.complete(messages, 1024);
  }

  static async review(context: BookContext, stars: number): Promise<string> {
    if (!AiService.isReady()) {
      throw new Error('尚未配置 AI 模型');
    }
    const messages: AiMessage[] = [
      {
        role: 'system',
        content: '你是普通读者，不是营销号。写书评要具体、克制，避免「不容错过」这类空话。只输出正文。',
      },
      {
        role: 'user',
        content: `${AiBookService.bookPrompt(context)}\n\n请写一段 250 字左右的书评，整体评价 ${stars} 星（5 分制）。`,
      },
    ];
    return AiService.complete(messages, 1024);
  }

  /**
   * 基于书架概况推荐书单。
   *
   * 要求返回 JSON 是为了能直接排队进检索，而不是给一段自由文本让用户自己抄书名。
   */
  static async recommend(profile: ShelfProfile, count: number, mood: string): Promise<RecommendedBook[]> {
    if (!AiService.isReady()) {
      throw new Error('尚未配置 AI 模型');
    }
    const titles: string = profile.titles.slice(0, 60).join('、');
    const authors: string = profile.authors.slice(0, 30).join('、');
    const tags: string = profile.tags.slice(0, 30).join('、');
    const moodHint: string = mood.length > 0 ? `这次特别想要：${mood}。` : '';
    const messages: AiMessage[] = [
      {
        role: 'system',
        content: '你是图书推荐助手。只输出 JSON 数组，不要 Markdown 代码块、不要解释文字。',
      },
      {
        role: 'user',
        content: `我的书架有以下书：${titles}\n常读作者：${authors}\n偏好标签：${tags}\n${moodHint}\n` +
          `请推荐 ${count} 本我书架里没有的书。严格按此 JSON 格式输出：` +
          `[{"title":"书名","author":"作者","reason":"一句话推荐理由"}]`,
      },
    ];
    const raw: string = await AiService.complete(messages, 1500);
    return AiBookService.parseRecommendations(raw);
  }

  /** 元数据补全建议：只输出建议字段，供用户人工复核。 */
  static async suggestMeta(context: BookContext): Promise<MetaSuggestion> {
    if (!AiService.isReady()) {
      throw new Error('尚未配置 AI 模型');
    }
    const messages: AiMessage[] = [
      {
        role: 'system',
        content: '你是图书元数据校对助手。只依据确定的信息填写，不确定的字段留空字符串，不要编造。' +
          '只输出 JSON 对象，不要 Markdown 代码块。',
      },
      {
        role: 'user',
        content: `${AiBookService.bookPrompt(context)}\n\n` +
          '请核对并补全元数据，严格输出：' +
          '{"title":"规范书名","author":"作者","publisher":"出版社","tags":"逗号分隔的标签",' +
          '"summary":"80字以内内容简介","confidence":"high|medium|low"}',
      },
    ];
    const raw: string = await AiService.complete(messages, 800);
    return AiBookService.parseMetaSuggestion(raw);
  }

  /** 从模型输出里取 JSON：容忍 ```json 包裹和前后多余说明。 */
  private static extractJson(raw: string, open: string, close: string): string {
    let text: string = raw.trim();
    const fence: number = text.indexOf('```');
    if (fence >= 0) {
      text = text.substring(fence + 3);
      if (text.startsWith('json')) {
        text = text.substring(4);
      }
      const endFence: number = text.indexOf('```');
      if (endFence >= 0) {
        text = text.substring(0, endFence);
      }
    }
    const start: number = text.indexOf(open);
    const end: number = text.lastIndexOf(close);
    if (start >= 0 && end > start) {
      return text.substring(start, end + 1);
    }
    return text.trim();
  }

  private static parseRecommendations(raw: string): RecommendedBook[] {
    const json: string = AiBookService.extractJson(raw, '[', ']');
    const result: RecommendedBook[] = [];
    try {
      const list = JSON.parse(json) as Object[];
      for (let i = 0; i < list.length; i++) {
        const item = list[i] as Record<string, Object>;
        const title: string = AiBookService.str(item, 'title');
        if (title.length === 0) {
          continue;
        }
        result.push({ title: title, author: AiBookService.str(item, 'author'), reason: AiBookService.str(item, 'reason') });
      }
    } catch (_error) {
      throw new Error('模型返回格式无法解析，请重试或换用能力更强的模型');
    }
    if (result.length === 0) {
      throw new Error('模型没有给出可解析的推荐结果');
    }
    return result;
  }

  private static parseMetaSuggestion(raw: string): MetaSuggestion {
    const json: string = AiBookService.extractJson(raw, '{', '}');
    try {
      const item = JSON.parse(json) as Record<string, Object>;
      return {
        title: AiBookService.str(item, 'title'),
        author: AiBookService.str(item, 'author'),
        publisher: AiBookService.str(item, 'publisher'),
        tags: AiBookService.str(item, 'tags'),
        summary: AiBookService.str(item, 'summary'),
        confidence: AiBookService.str(item, 'confidence'),
      };
    } catch (_error) {
      throw new Error('模型返回格式无法解析，请重试或换用能力更强的模型');
    }
  }

  private static str(obj: Record<string, Object>, key: string): string {
    const value = obj[key];
    return typeof value === 'string' ? (value as string).trim() : '';
  }
}
