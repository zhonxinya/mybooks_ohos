// AI 对话纯模型层：气泡/活动形状与持久化解析。自 AiChatStore 拆出（800 行门禁），
// 类型经 AiChatStore 再导出，页面与语音 kit 的既有 import 路径不变。
import { ToolBookLine } from './AiToolsDefs';

/** 工具调用活动：回路里每次工具执行产生一条，流式期间实时翻转状态。 */
export interface ChatActivity {
  name: string;
  label: string;
  /** doing 执行中 / done 完成 / rejected 用户拒绝 */
  state: string;
  /** 书目型结果的结构化条目（书架/小说源/下载任务） */
  books: ToolBookLine[];
  /** 非书目型结果的一行摘要 */
  summary: string;
}

/** 界面上的消息：与协议层 AiMessage 分开，因为要额外带状态。 */
export interface ChatBubble {
  role: string;
  content: string;
  /** 是否正在流式输出（末尾光标用）。 */
  streaming: boolean;
  error: boolean;
  /** 完成后固化的活动快照（流式期间由 liveActivities 渲染）。 */
  activities: ChatActivity[];
  /** 用户消息附带的图片（沙箱绝对路径；发送时压缩编码为 data URL）。 */
  images?: string[];
  /** 推理模型的思考过程（reasoning_content）；完成固化后随历史持久化。 */
  reasoning?: string;
  /** 语音轮次气泡（realtime 内嵌会话产生）：渲染时带 mic/播报角标，与文字轮区分。 */
  voice?: boolean;
}

/** 解析气泡数组（当前会话与存档会话共用）；坏条目（缺字段/类型不符）逐条丢弃。 */
export function parseBubbles(parsed: Object): ChatBubble[] {
  const bubbles: ChatBubble[] = [];
  if (!Array.isArray(parsed)) {
    return bubbles;
  }
  for (const entry of parsed as Object[]) {
    if (entry === null || typeof entry !== 'object') {
      continue;
    }
    const m: Record<string, Object> = entry as Record<string, Object>;
    if (typeof m['role'] !== 'string' || typeof m['content'] !== 'string') {
      continue;
    }
    const actsRaw: Object = m['activities'];
    const activities: ChatActivity[] = [];
    if (Array.isArray(actsRaw)) {
      for (const a of actsRaw as Object[]) {
        if (a === null || typeof a !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = a as Record<string, Object>;
        if (typeof rec['name'] !== 'string' || typeof rec['label'] !== 'string') {
          continue;
        }
        const booksRaw: Object = rec['books'];
        const books: ToolBookLine[] = [];
        if (Array.isArray(booksRaw)) {
          for (const b of booksRaw as Object[]) {
            if (b === null || typeof b !== 'object') {
              continue;
            }
            const br: Record<string, Object> = b as Record<string, Object>;
            if (typeof br['title'] !== 'string') {
              continue;
            }
            books.push({
              title: br['title'],
              subtitle: typeof br['subtitle'] === 'string' ? br['subtitle'] : '',
              cover: typeof br['cover'] === 'string' ? br['cover'] : '',
            });
          }
        }
        activities.push({
          name: rec['name'],
          label: rec['label'],
          state: typeof rec['state'] === 'string' ? rec['state'] : 'done',
          books: books,
          summary: typeof rec['summary'] === 'string' ? rec['summary'] : '',
        });
      }
    }
    const imgsRaw: Object = m['images'];
    const images: string[] = [];
    if (Array.isArray(imgsRaw)) {
      for (const p of imgsRaw as Object[]) {
        if (typeof p === 'string' && p.length > 0) {
          images.push(p);
        }
      }
    }
    const reasoningRaw: Object = m['reasoning'];
    bubbles.push({
      role: m['role'],
      content: m['content'],
      streaming: false,
      error: m['error'] === true,
      activities: activities,
      images: images,
      reasoning: typeof reasoningRaw === 'string' ? reasoningRaw : '',
      voice: m['voice'] === true,
    });
  }
  return bubbles;
}

/** 会话标题：取首条用户消息前 20 字；没有则空串（调用侧兜底「新对话」）。 */
export function sessionTitle(bubbles: ChatBubble[]): string {
  for (const b of bubbles) {
    if (b.role === 'user') {
      const t: string = b.content.trim();
      if (t.length === 0) {
        continue;
      }
      return t.length > 20 ? `${t.slice(0, 20)}…` : t;
    }
  }
  return '';
}

/** 活动区合并展示组：相邻同名工具调用并一条，count>1 显示 ×N。 */
export interface ActivityGroup {
  name: string;
  label: string;
  /** 聚合态：任一 doing→doing，否则任一 rejected→rejected，否则 done */
  state: string;
  summary: string;
  books: ToolBookLine[];
  count: number;
}

/**
 * 相邻同名同标签的活动合并成组（并行只读轮/连续同类调用一眼看清「搜索 ×3」）。
 * 纯函数供 ActivityTimeline 与离线回归共用；summary/books 取组内最后一个非空，
 * 保证合并行仍有真实结果可展示，失败态的 summary 不被后续成功覆盖之前先判 doing。
 */
export function groupActivities(acts: ChatActivity[]): ActivityGroup[] {
  const groups: ActivityGroup[] = [];
  for (const a of acts) {
    const prev: ActivityGroup | null = groups.length > 0 ? groups[groups.length - 1] : null;
    if (prev !== null && prev.name === a.name && prev.label === a.label) {
      prev.count += 1;
      prev.state = a.state === 'doing' || prev.state === 'doing' ? 'doing' :
        (a.state === 'rejected' || prev.state === 'rejected' ? 'rejected' : 'done');
      if (a.summary.length > 0) {
        prev.summary = a.summary;
      }
      if (a.books.length > 0) {
        prev.books = a.books;
      }
      continue;
    }
    groups.push({ name: a.name, label: a.label, state: a.state,
      summary: a.summary, books: a.books, count: 1 });
  }
  return groups;
}
