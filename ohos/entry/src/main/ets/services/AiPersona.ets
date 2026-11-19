import { fileIo as fs } from '@kit.CoreFileKit';
import { TalebookService } from './TalebookService';

/**
 * AI 助手的灵魂与记忆（OpenClaw 式沙箱文件）。
 *
 * - SOUL.md：人格设定，用户在「灵魂与记忆」页编辑，缺省回 DEFAULT_SOUL。
 * - MEMORY.md：跨对话长期记忆，每行一条 `- 事实`；由 save_memory/forget_memory
 *   工具或管理页维护。对话构建时把两者拼进 system prompt。
 *
 * 目录复用 TalebookService.dataDir()（= filesDir，EntryAbility 启动时注入），
 * 与 ai_images 同级，不再新增 init 步骤。
 */

/** SOUL.md 缺失/清空时的默认人格（也是「恢复默认」的目标文本）。 */
export const DEFAULT_SOUL: string =
  '# 灵魂\n' +
  '你是一位电子书阅读助手，也是用户的书友。\n\n' +
  '## 性格\n' +
  '- 温和、真诚，对书有热情；聊书像朋友，不像客服。\n' +
  '- 简洁优先：先给结论，再给理由，不堆砌套话。\n\n' +
  '## 原则\n' +
  '- 涉及用户的书籍、标注、阅读记录时，先用工具查真实数据，绝不编造。\n' +
  '- 用户让你记住的事情（偏好、正在读的书、约定），用 save_memory 记下来。\n';

const SOUL_FILE: string = 'SOUL.md';
const MEMORY_FILE: string = 'MEMORY.md';
const MEMORY_HEADER: string = '# 用户记忆';

/** 记忆条目上限：超出拒绝新增，提示用户先清理。 */
const MEMORY_MAX_ENTRIES: number = 100;
/** 注入 prompt 的记忆段字符上限：档位再小也不能被记忆撑爆。 */
const MEMORY_INJECT_MAX_CHARS: number = 4000;

export class AiPersona {
  private static dir(): string {
    const dir = `${TalebookService.dataDir()}/ai_soul`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    return dir;
  }

  private static soulPath(): string {
    return `${AiPersona.dir()}/${SOUL_FILE}`;
  }

  private static memoryPath(): string {
    return `${AiPersona.dir()}/${MEMORY_FILE}`;
  }

  private static readText(path: string): string {
    if (!fs.accessSync(path)) {
      return '';
    }
    try {
      return fs.readTextSync(path);
    } catch (_error) {
      return '';
    }
  }

  private static writeText(path: string, text: string): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  /** 灵魂文本：文件缺失或全空白时返回默认人格。 */
  static loadSoul(): string {
    const text: string = AiPersona.readText(AiPersona.soulPath());
    return text.trim().length > 0 ? text : DEFAULT_SOUL;
  }

  static saveSoul(text: string): void {
    AiPersona.writeText(AiPersona.soulPath(), text);
  }

  /** 恢复默认灵魂并返回默认文本（管理页直接回填输入框）。 */
  static resetSoul(): string {
    AiPersona.saveSoul(DEFAULT_SOUL);
    return DEFAULT_SOUL;
  }

  /** MEMORY.md 中的 `- 事实` 行解析为条目（顺序即文件顺序）。 */
  static loadMemories(): string[] {
    const lines: string[] = AiPersona.readText(AiPersona.memoryPath()).split('\n');
    const items: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.startsWith('- ') && line.length > 2) {
        items.push(line.substring(2).trim());
      }
    }
    return items;
  }

  private static saveMemories(items: string[]): void {
    if (items.length === 0) {
      AiPersona.writeText(AiPersona.memoryPath(), '');
      return;
    }
    const parts: string[] = [MEMORY_HEADER];
    for (let i = 0; i < items.length; i++) {
      parts.push(`- ${items[i]}`);
    }
    AiPersona.writeText(AiPersona.memoryPath(), `${parts.join('\n')}\n`);
  }

  /**
   * 追加一条记忆（重复条目直接跳过，返回给工具的措辞区分三种结果）。
   * 单条压成一行：换行会破坏 `- 事实` 行格式。
   */
  static appendMemory(fact: string): string {
    const oneLine: string = fact.replace(/[\r\n]+/g, ' ').trim();
    if (oneLine.length === 0) {
      return '记忆内容为空，没有保存。';
    }
    const items: string[] = AiPersona.loadMemories();
    if (items.length >= MEMORY_MAX_ENTRIES) {
      return `记忆已达上限 ${MEMORY_MAX_ENTRIES} 条，请先用 forget_memory 或管理页清理几条。`;
    }
    if (items.indexOf(oneLine) >= 0) {
      return `这条记忆已经存在，没有重复保存：${oneLine}`;
    }
    items.push(oneLine);
    AiPersona.saveMemories(items);
    return `已记住：${oneLine}`;
  }

  /** 删除第 index 条（1 起，与工具输出编号一致）；越界返回带当前列表的提示。 */
  static removeMemory(index: number): string {
    const items: string[] = AiPersona.loadMemories();
    if (items.length === 0) {
      return '当前没有任何记忆。';
    }
    if (index < 1 || index > items.length) {
      return `序号 ${index} 超出范围（当前共 ${items.length} 条）。`;
    }
    const removed: string = items.splice(index - 1, 1)[0];
    AiPersona.saveMemories(items);
    return `已忘记：${removed}`;
  }

  /**
   * 拼进 system prompt 的人格+记忆段；无任何内容时返回空串。
   * 记忆超限截断时保留新条目（尾部），旧的先被舍弃。
   */
  static buildPersonaPrompt(): string {
    const soul: string = AiPersona.loadSoul();
    const memories: string[] = AiPersona.loadMemories();
    const parts: string[] = [];
    if (soul.trim().length > 0) {
      parts.push(`以下是你的灵魂设定（来自用户的个性化配置，覆盖默认人格描述）：\n${soul.trim()}`);
    }
    if (memories.length > 0) {
      // 序号用全局条目号（1 起，即 forget_memory 的 index）：超上限截断旧条目时不错位。
      let block: string = '';
      for (let i = memories.length - 1; i >= 0; i--) {
        const line: string = `${i + 1}. ${memories[i]}\n`;
        if (block.length + line.length > MEMORY_INJECT_MAX_CHARS) {
          break;
        }
        block = line + block;
      }
      parts.push('以下是关于用户的长期记忆（跨对话有效，自然参考即可，不必逐条复述；' +
        `用户要求记住新事项时用 save_memory，纠正或删除时用 forget_memory）：\n${block.trimEnd()}`);
    }
    return parts.join('\n\n');
  }
}
