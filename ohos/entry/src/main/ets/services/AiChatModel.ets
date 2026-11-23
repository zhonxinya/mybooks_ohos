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

/** 一次工具调用的完整痕迹（#1623）：结果落会话，历史回放时模型才看得到「已经做过」。 */
export interface ToolTraceCall {
  id: string;
  name: string;
  args: string;
  result: string;
}

/** 一轮工具调用（assistant 发起 + N 个结果回填）；text=该轮随调用产出的正文（通常为空）。 */
export interface ToolTraceRound {
  text: string;
  calls: ToolTraceCall[];
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
  /** 创建时刻（毫秒）；旧存档无此字段=undefined，时间分隔条自动跳过不显示。 */
  ts?: number;
  /** 本轮 token 用量（#1514）；旧存档/服务商不回传=undefined 不显示。 */
  usage?: AiTokenUsage;
  /** 工具调用痕迹（#1623）：assistant 气泡专有，随历史持久化；
   * buildContext 回放成 assistant.tool_calls + tool 消息，防跨轮重复执行。 */
  toolTrace?: ToolTraceRound[];
  /** 思考耗时毫秒（#1515）：由页面在 thinking 边沿打点；旧存档=undefined 不显示。 */
  thinkMs?: number;
}

/** 思考耗时展示文案（#1515）：无效值返回空串不占位；60s 内一位小数，更长按分秒。 */
export function formatThinkMs(ms: number | undefined): string {
  if (ms === undefined || ms < 300) {
    return '';
  }
  if (ms < 60000) {
    return `${(Math.round(ms / 100) / 10).toFixed(1)}s`;
  }
  const s: number = Math.round(ms / 1000);
  return `${Math.floor(s / 60)}m${s % 60}s`;
}

/** 时间分隔条阈值：与上一条间隔 ≥5 分钟才值得打断阅读节奏插一行时间。 */
const DIVIDER_GAP_MS: number = 5 * 60 * 1000;

/**
 * 是否在该气泡上方插时间分隔条：自身无 ts 不显示；首条（prevTs≤0）显示；
 * 其余按与上一条的间隔 ≥5min。纯函数供页面渲染与离线回归共用。
 */
export function shouldShowTimeDivider(prevTs: number, ts: number): boolean {
  if (ts <= 0) {
    return false;
  }
  if (prevTs <= 0) {
    return true;
  }
  return ts - prevTs >= DIVIDER_GAP_MS;
}

/** 分隔条文案：当天只到时分，跨天补月日（跨年同理，一年前翻旧会话可见）。 */
export function formatDividerTime(ts: number): string {
  const d: Date = new Date(ts);
  const now: Date = new Date();
  const hh: string = d.getHours().toString().padStart(2, '0');
  const mm: string = d.getMinutes().toString().padStart(2, '0');
  if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()) {
    return `${hh}:${mm}`;
  }
  const Mo: string = (d.getMonth() + 1).toString().padStart(2, '0');
  const dd: string = d.getDate().toString().padStart(2, '0');
  if (d.getFullYear() === now.getFullYear()) {
    return `${Mo}-${dd} ${hh}:${mm}`;
  }
  return `${d.getFullYear()}-${Mo}-${dd} ${hh}:${mm}`;
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
    const bubble: ChatBubble = {
      role: m['role'],
      content: m['content'],
      streaming: false,
      error: m['error'] === true,
      activities: activities,
      images: images,
      reasoning: typeof reasoningRaw === 'string' ? reasoningRaw : '',
      voice: m['voice'] === true,
      ts: typeof m['ts'] === 'number' ? m['ts'] : 0,
    };
    // usage 为可选键（#1514）：旧存档无此字段保持 undefined，不造零值假数据
    const usage: AiTokenUsage | null = parseUsage(m['usage']);
    if (usage !== null) {
      bubble.usage = usage;
    }
    if (typeof m['thinkMs'] === 'number') {
      bubble.thinkMs = m['thinkMs'];
    }
    // 工具痕迹（#1623）：可选键，旧存档无=undefined（回放退化为纯文本，行为同修复前）
    const traceRaw: Object = m['toolTrace'];
    if (Array.isArray(traceRaw)) {
      const rounds: ToolTraceRound[] = [];
      for (const r of traceRaw as Object[]) {
        if (r === null || typeof r !== 'object') {
          continue;
        }
        const rr: Record<string, Object> = r as Record<string, Object>;
        const callsRaw: Object = rr['calls'];
        const calls: ToolTraceCall[] = [];
        if (Array.isArray(callsRaw)) {
          for (const c of callsRaw as Object[]) {
            if (c === null || typeof c !== 'object') {
              continue;
            }
            const cr: Record<string, Object> = c as Record<string, Object>;
            if (typeof cr['id'] !== 'string' || typeof cr['name'] !== 'string') {
              continue;
            }
            calls.push({
              id: cr['id'], name: cr['name'],
              args: typeof cr['args'] === 'string' ? cr['args'] : '',
              result: typeof cr['result'] === 'string' ? cr['result'] : '',
            });
          }
        }
        if (calls.length > 0) {
          rounds.push({ text: typeof rr['text'] === 'string' ? rr['text'] : '', calls: calls });
        }
      }
      if (rounds.length > 0) {
        bubble.toolTrace = rounds;
      }
    }
    bubbles.push(bubble);
  }
  return bubbles;
}

/** 收集 from 起所有气泡的工具痕迹并拼接（#1624：retryFrom 截掉错误泡时带走已执行痕迹）。 */
export function collectTraces(bubbles: ChatBubble[], from: number): ToolTraceRound[] {
  const out: ToolTraceRound[] = [];
  for (let i = Math.max(0, from); i < bubbles.length; i++) {
    const t: ToolTraceRound[] | undefined = bubbles[i].toolTrace;
    if (t !== undefined) {
      for (let k = 0; k < t.length; k++) {
        out.push(t[k]);
      }
    }
  }
  return out;
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

/**
 * 会话搜索匹配（#1513）：空查询恒真；匹配标题或任一消息正文，忽略大小写。
 * 纯函数供 store.searchSessions 过滤存档与会话共用。
 */
export function sessionMatches(title: string, bubbles: ChatBubble[], kw: string): boolean {
  const q: string = kw.trim().toLowerCase();
  if (q.length === 0) {
    return true;
  }
  if (title.toLowerCase().indexOf(q) >= 0) {
    return true;
  }
  for (const b of bubbles) {
    if (b.content.toLowerCase().indexOf(q) >= 0) {
      return true;
    }
  }
  return false;
}

/** 会话导出为 Markdown 文本（#1513）：跳过流式/错误/空消息；now 由调用侧传入保证可回归。 */
export function buildSessionMd(title: string, bubbles: ChatBubble[], now: number): string {
  const d: Date = new Date(now);
  const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  const parts: string[] = [`# ${title}`, '',
    `> 导出于 MyBooks AI 助手 · ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}`];
  for (const b of bubbles) {
    if (b.streaming || b.error === true || b.content.trim().length === 0) {
      continue;
    }
    parts.push('', `## ${b.role === 'user' ? '用户' : '助手'}`, '', b.content.trim());
  }
  return `${parts.join('\n')}\n`;
}

/** 按住说话（#1516）把识别文本并入现有输入：两端去空白、空格相接；空识别保留原文。 */
export function appendHeardText(current: string, heard: string): string {
  const c: string = current.trim();
  const h: string = heard.trim();
  if (h.length === 0) { return c; }
  if (c.length === 0) { return h; }
  return `${c} ${h}`;
}

/** ask_user 反问卡片的待答状态：对话页渲染选项按钮，点选/跳过经 answerAsk 归还回路。 */
export interface AskRequest {
  question: string;
  options: string[];
}

/** 存档会话（不含当前会话）：切换/新建时当前会话整条归档到这里。 */
export interface ChatSession {
  id: string;
  title: string;
  /** 用户手动改名（#1513）：空串=未改名，标题跟随自动生成；跨归档持久。 */
  named: string;
  updatedAt: number;
  messages: ChatBubble[];
}

/** 单会话的历史摘要：text=摘要正文，count=已折叠进摘要的筛后气泡前缀条数。 */
export interface HistorySummary {
  text: string;
  count: number;
}

/** 一轮请求的 token 用量（OpenAI usage 字段，#1514）；多工具轮在传输层累加。 */
export interface AiTokenUsage {
  prompt: number;
  completion: number;
  total: number;
}

/** 用量累加（就地改 dst）：供传输层跨工具轮汇总。 */
export function mergeUsage(dst: AiTokenUsage, src: AiTokenUsage): void {
  dst.prompt += src.prompt;
  dst.completion += src.completion;
  dst.total += src.total;
}

/**
 * 解析 usage 对象（#1514）：同时认服务商 wire 键（prompt_tokens/total_tokens）
 * 与本地落盘键（prompt/total）；非对象或无 total 数字返回 null（缺字段静默降级）。
 */
export function parseUsage(raw: Object | undefined): AiTokenUsage | null {
  if (raw === undefined || raw === null || typeof raw !== 'object') {
    return null;
  }
  const rec: Record<string, Object> = raw as Record<string, Object>;
  const total: Object | undefined = rec['total_tokens'] !== undefined ? rec['total_tokens'] : rec['total'];
  if (typeof total !== 'number') {
    return null;
  }
  const prompt: Object | undefined = rec['prompt_tokens'] !== undefined ? rec['prompt_tokens'] : rec['prompt'];
  const completion: Object | undefined =
    rec['completion_tokens'] !== undefined ? rec['completion_tokens'] : rec['completion'];
  return {
    prompt: typeof prompt === 'number' ? prompt : 0,
    completion: typeof completion === 'number' ? completion : 0,
    total: total,
  };
}

// —— 对话持久化常量（preferences 明文 KV，与账号列表同层；存读逻辑在 AiChatStore）——

/** 对话历史键：只存已固化的气泡。 */
export const CHAT_HISTORY_KEY: string = 'ai_chat_history';
/** 历史上限：超出丢弃最旧条目，避免 preferences.json 无限膨胀。 */
export const CHAT_HISTORY_MAX: number = 60;
/** 会话存档键：不含当前会话（当前仍走 ai_chat_history，退出页面重进照常恢复）。 */
export const CHAT_SESSIONS_KEY: string = 'ai_chat_sessions';
/** 存档会话数上限：超出按 updatedAt 从旧到新丢弃。 */
export const CHAT_SESSIONS_MAX: number = 12;
/** 历史摘要键：按会话 id 存「被窗口截断的旧轮」的压缩摘要。 */
export const CHAT_SUMMARIES_KEY: string = 'ai_chat_summaries';
/** 未摘数量达到该阈值才触发一次摘要请求：压缩自身也要省 token。 */
export const COMPRESS_MIN_DROPPED: number = 8;
