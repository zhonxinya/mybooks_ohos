/**
 * AI 工具共享状态（拆分自 AiTools.ets）：书目卡片配对槽与封面候选缓存、
 * 参数 JSON 解析小工具。单点持有避免门面与执行器模块互相 import 成环。
 */
import { ReferBook } from './TalebookApi';
import { ToolBookLine } from './AiToolsDefs';

export class AiToolsCore {
  /**
   * 最近一次书目型工具的结构化结果（含封面），供对话页渲染卡片。
   * 串行回路读后即清即可；同轮并行执行时本槽会被后完成者覆盖，
   * 配对走 booksByCall（见 takeLastBooksFor）。
   */
  static lastBooks: ToolBookLine[] = [];

  /**
   * 并行回路专用配对槽：同轮多个 search_books 并发时静态槽会被后完成者覆盖，
   * 结果按 tool_call_id 登记于此，UI 回填时逐条取回（写入与工具产出同在同步段，无竞态）。
   */
  static booksByCall: Map<string, ToolBookLine[]> = new Map();

  /**
   * search_cover 的候选缓存：set_cover 在同一次对话回路里跨 execute 调用读取，
   * 故不在 execute 入口清空，改由 lastCoverBookId 与 book_id 匹配来防串台。
   */
  static lastCoverCandidates: ReferBook[] = [];
  static lastCoverBookId: number = 0;

  static parseArgs(json: string): Record<string, Object> {
    if (json.length === 0) {
      return {};
    }
    try {
      return JSON.parse(json) as Record<string, Object>;
    } catch (_error) {
      return {};
    }
  }

  static argString(args: Record<string, Object>, key: string): string {
    const value = args[key];
    if (value === undefined || value === null) {
      return '';
    }
    return String(value);
  }

  static argNumber(args: Record<string, Object>, key: string): number {
    const value = args[key];
    if (value === undefined || value === null) {
      return 0;
    }
    const num: number = Number(value);
    return Number.isFinite(num) ? Math.floor(num) : 0;
  }

  static clip(text: string, max: number): string {
    const trimmed: string = text.trim();
    return trimmed.length <= max ? trimmed : `${trimmed.substring(0, max)}…`;
  }

  static formatDate(ts: number): string {
    if (ts <= 0) {
      return '未知';
    }
    const d = new Date(ts);
    return `${d.getFullYear()}-${AiToolsCore.pad2(d.getMonth() + 1)}-${AiToolsCore.pad2(d.getDate())} ` +
      `${AiToolsCore.pad2(d.getHours())}:${AiToolsCore.pad2(d.getMinutes())}`;
  }

  static pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }
}

