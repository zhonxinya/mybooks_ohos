import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { AiTools, AiPermissionMode, parseToolBookLines, ToolBookLine } from './AiTools';
import { AiService, AiConfig, AiMessage, AiStreamHandlers, AiAbortHandle } from './AiService';
import { AiPersona } from './AiPersona';
import { TalebookService } from './TalebookService';

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
}

/** 写操作闸门确认弹窗；需要 UIContext，只有页面在场时可用。 */
export type ConfirmUi = (label: string, args: string) => Promise<boolean>;

/**
 * 系统提示词只留**行为规则与跨工具流程**：单个工具的名称/用途/参数由请求体
 * tools 数组自带（AiTools 描述是权威来源，此处复述既烧 token 又会与代码漂移）。
 * 权限模式说明由 permissionPromptNote 按当前档位追加，三档都有明确表述。
 */
const SYSTEM_PROMPT: string =
  '你是一个电子书阅读应用的助手。回答与思考过程一律使用中文（书名、参数值等原文引用除外），简洁、准确。' +
  '问题涉及用户的书籍、阅读情况或其他可查证的信息时，先调用相应工具拿到真实数据再回答，绝不编造；' +
  '工具数据不足时直接说明不确定。' +
  '工具返回「暂时失败」时可稍后原样重试一次；返回「执行失败」时按错误提示修正参数或方案再试，勿原样重试；仍失败如实告知，不反复重试。' +
  '写操作（建书单、加书、下载任务、改元数据、换封面、删记忆）一律按后文的权限模式说明处理。' +
  '换封面流程：先 search_cover 列出候选给用户看，用户选定后再 set_cover。' +
  '网文下载流程：search_sonovel 拿 url → add_sonovel_task 入队 → list_download_tasks 报进度，成品完成后自动进本地书架可读。' +
  '系统提示中若已有「用户记忆」列表，回答时自然参考、不必复述。';

/** 权限模式补注：追加在系统提示末尾，用顶栏徽标的准确档位名（模型曾瞎编「可写/编辑模式」）。 */
function permissionPromptNote(mode: AiPermissionMode): string {
  if (mode === 'readonly') {
    return '当前为「只读」权限模式：写操作工具不可用，调用会被系统拒绝。' +
      '用户要求改动数据时，请其点击对话页顶栏「权限」徽标切换到「逐笔确认」或「自动放行」。';
  }
  if (mode === 'auto') {
    return '当前为「自动放行」权限模式：写操作工具不逐笔确认、直接执行；执行后如实汇报改了什么。';
  }
  return '当前为「逐笔确认」权限模式：每个写操作工具执行前会请用户批准，用户拒绝时不要坚持重试，问明原因即可。';
}

/** 附图发送前的压缩长边（像素）：够模型看清，又不至于撑爆请求体。 */
const IMAGE_MAX_EDGE: number = 1024;
const IMAGE_JPEG_QUALITY: number = 80;

/** 对话历史持久化（preferences 明文 KV，与账号列表同层）：只存已固化的气泡。 */
const CHAT_HISTORY_KEY: string = 'ai_chat_history';
/** 历史上限：超出丢弃最旧条目，避免 preferences.json 无限膨胀。 */
const CHAT_HISTORY_MAX: number = 60;

/**
 * AI 对话全局会话仓库（单例）：流式状态机与历史都挂在这里，脱离页面实例存活。
 * 退出对话页只解绑视图、不打断流——后台回复照常完成并落盘，重新进入即见完整结果。
 * 页面对它而言只是一组可选的视图回调：在场则同步渲染、可弹确认；不在场则跳过刷新、
 * 写操作确认一律按拒绝处理（与切页/停止键的既有语义一致）。
 */
export class AiChatStore {
  // —— 会话状态（页面侧的 @State 镜像从这里同步）——
  messages: ChatBubble[] = [];
  /** 流式输出用：整段重建列表的代价高，只改最后一条气泡的内容。 */
  streamingText: string = '';
  /** 工具回路实时活动时间线；finishBubble 时快照进气泡成为历史。 */
  liveActivities: ChatActivity[] = [];
  /** 流式中的思考过程增量；finishBubble/stopStreaming 时固化进气泡。 */
  streamingReasoning: string = '';
  thinking: boolean = false;
  errorTip: string = '';
  configured: boolean = false;
  visionEnabled: boolean = false;
  contextK: number = 8;

  private static inst: AiChatStore | null = null;
  private requestId: number = 0;
  private abort: AiAbortHandle | null = null;
  private loaded: boolean = false;
  /** 当前前台视图的回调（页面 struct 不能 implements 接口，用 token+闭包绑定）。 */
  private viewSync: (() => void) | null = null;
  private confirmUi: ConfirmUi | null = null;
  private viewToken: number = 0;

  static instance(): AiChatStore {
    if (AiChatStore.inst === null) {
      AiChatStore.inst = new AiChatStore();
    }
    return AiChatStore.inst;
  }

  /** 注册前台视图，返回凭据 token；detach 仅认最新 token，防旧页迟到的 disappear 误清新页。 */
  attachView(sync: () => void, confirmUi: ConfirmUi): number {
    this.viewSync = sync;
    this.confirmUi = confirmUi;
    this.viewToken++;
    return this.viewToken;
  }

  detachView(token: number): void {
    if (this.viewToken === token) {
      this.viewSync = null;
      this.confirmUi = null;
    }
  }

  private notify(): void {
    if (this.viewSync !== null) {
      this.viewSync();
    }
  }

  /** 设置页可能刚改过 vision/上下文档位，回页即刷新。 */
  refreshSettings(): void {
    this.configured = AiService.isReady();
    const config: AiConfig = AiService.loadConfig();
    this.visionEnabled = config.vision;
    this.contextK = config.contextLength;
  }

  /** 首次进页读一次历史即可：流式途中重进页面不能把在途气泡冲掉。 */
  ensureLoaded(): void {
    if (!this.loaded) {
      this.loaded = true;
      this.loadHistory();
    }
  }

  stopStreaming(): void {
    this.requestId++;
    const handle: AiAbortHandle | null = this.abort;
    this.abort = null;
    if (handle !== null) {
      handle.aborted = true;
      handle.destroy?.();
    }
    if (this.thinking && this.messages.length > 0) {
      const last: ChatBubble = this.messages[this.messages.length - 1];
      last.streaming = false;
      last.content = this.streamingText.length > 0 ? this.streamingText : '已停止生成';
      last.error = this.streamingText.length === 0;
      last.activities = this.liveActivities;
      last.reasoning = this.streamingReasoning;
      this.messages = this.messages.slice();
      this.saveHistory();
    }
    this.streamingText = '';
    this.streamingReasoning = '';
    this.liveActivities = [];
    this.thinking = false;
    this.notify();
  }

  /** 固化消息落盘（streaming 气泡除外）；在每轮完成/停止/清空时调用。 */
  private saveHistory(): void {
    const items: ChatBubble[] = this.messages.filter((m: ChatBubble) => !m.streaming);
    TalebookService.prefSet(CHAT_HISTORY_KEY, JSON.stringify(items.slice(-CHAT_HISTORY_MAX)));
  }

  /** 读回历史；坏条目（缺字段/类型不符）逐条丢弃，整体损坏则视为无历史。 */
  loadHistory(): void {
    const raw: string = TalebookService.prefGet(CHAT_HISTORY_KEY, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const arr: Object = JSON.parse(raw);
      if (!Array.isArray(arr)) {
        return;
      }
      const bubbles: ChatBubble[] = [];
      for (const entry of arr as Object[]) {
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
        });
      }
      this.messages = bubbles.slice(-CHAT_HISTORY_MAX);
    } catch (_error) {
      // 历史损坏：保持空会话，下一次保存会覆盖
    }
    this.notify();
  }

  /** 沙箱图片压缩成长边 1024 的 jpeg data URL；失败返回空串（该图不发送）。 */
  private async encodeImage(path: string): Promise<string> {
    try {
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(Number(stat.size));
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(file.fd, buf);
      } finally {
        fs.closeSync(file);
      }
      const source = image.createImageSource(buf);
      let pixelMap: image.PixelMap;
      try {
        const info = await source.getImageInfo();
        const scale = Math.min(1, IMAGE_MAX_EDGE / Math.max(info.size.width, info.size.height));
        const size: image.Size = {
          width: Math.max(1, Math.round(info.size.width * scale)),
          height: Math.max(1, Math.round(info.size.height * scale)),
        };
        const opts: image.DecodingOptions = { desiredSize: size };
        pixelMap = await source.createPixelMap(opts);
      } finally {
        source.release();
      }
      const packer = image.createImagePacker();
      let packed: ArrayBuffer;
      try {
        packed = await packer.packing(pixelMap, { format: 'image/jpeg', quality: IMAGE_JPEG_QUALITY });
      } finally {
        packer.release();
        pixelMap.release();
      }
      const b64: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(packed));
      return `data:image/jpeg;base64,${b64}`;
    } catch (_error) {
      return '';
    }
  }

  /** 把界面气泡转成协议消息，只带最近 N 轮（档位来自设置），避免上下文无限增长。 */
  async buildContext(): Promise<AiMessage[]> {
    const persona: string = AiPersona.buildPersonaPrompt();
    let systemText: string = persona.length > 0 ? `${SYSTEM_PROMPT}\n\n${persona}` : SYSTEM_PROMPT;
    // 权限模式说明追加在最后，覆盖 SYSTEM_PROMPT 里「逐笔确认」的默认描述
    const modeNote: string = permissionPromptNote(AiService.loadPermission());
    if (modeNote.length > 0) {
      systemText = `${systemText}\n\n${modeNote}`;
    }
    const context: AiMessage[] = [{ role: 'system', content: systemText }];
    const bubbles: ChatBubble[] = this.messages.filter((m: ChatBubble) =>
      !m.error && (m.content.length > 0 || (m.images ?? []).length > 0));
    const start: number = Math.max(0, bubbles.length - AiService.contextRounds(this.contextK) * 2);
    for (let i = start; i < bubbles.length; i++) {
      const msg: AiMessage = { role: bubbles[i].role, content: bubbles[i].content };
      const imgs: string[] = this.visionEnabled ? (bubbles[i].images ?? []) : [];
      if (imgs.length > 0) {
        const urls: string[] = [];
        for (let j = 0; j < imgs.length; j++) {
          const dataUrl: string = await this.encodeImage(imgs[j]);
          if (dataUrl.length > 0) {
            urls.push(dataUrl);
          }
        }
        if (urls.length > 0) {
          msg.images = urls;
        }
      }
      context.push(msg);
    }
    return context;
  }

  /** 页面清草稿用的同步预检；权威判定仍在 send 内（两处条件必须一致）。 */
  canSend(text: string): boolean {
    return text.trim().length > 0 && !this.thinking && AiService.isReady();
  }

  async send(text: string, images: string[]): Promise<void> {
    const question: string = text.trim();
    if (question.length === 0 || this.thinking) {
      return;
    }
    if (!AiService.isReady()) {
      this.configured = false;
      this.errorTip = '尚未配置模型，请先填写接口地址、模型与 API Key';
      this.notify();
      return;
    }
    this.configured = true;
    this.errorTip = '';
    const requestId: number = ++this.requestId;

    const bubbleImages: string[] = this.visionEnabled ? images : [];
    this.messages.push({ role: 'user', content: question, streaming: false, error: false,
      activities: [], images: bubbleImages });
    this.messages.push({ role: 'assistant', content: '', streaming: true, error: false, activities: [] });
    this.saveHistory();
    this.streamingText = '';
    this.streamingReasoning = '';
    this.liveActivities = [];
    this.thinking = true;
    this.notify();

    const handlers: AiStreamHandlers = {
      onDelta: (delta: string) => {
        if (requestId !== this.requestId || !this.thinking) {
          return;
        }
        this.streamingText += delta;
        this.notify();
      },
      onReasoning: (delta: string) => {
        if (requestId !== this.requestId || !this.thinking) {
          return;
        }
        this.streamingReasoning += delta;
        this.notify();
      },
      onTool: (label: string, name: string) => {
        if (requestId === this.requestId && this.thinking) {
          this.beginActivity(name, label);
        }
      },
      onToolResult: (name: string, label: string, text: string) => {
        if (requestId === this.requestId && this.thinking) {
          this.endActivity(name, label, text);
        }
      },
      onConfirm: (label: string, args: string): Promise<boolean> => {
        // 写操作闸门：弹窗让用户逐笔批准；页面已退出（无视图）与停止/回退键一样按拒绝处理
        if (requestId !== this.requestId || !this.thinking || this.confirmUi === null) {
          return Promise.resolve(false);
        }
        return this.confirmUi(label, args);
      },
      onDone: (full: string) => {
        if (requestId === this.requestId && this.thinking) {
          this.finishBubble(full, false);
        }
      },
      onError: (message: string) => {
        if (requestId === this.requestId && this.thinking) {
          this.finishBubble(message, true);
        }
      },
    };

    const context: AiMessage[] = await this.buildContext();
    if (requestId !== this.requestId || !this.thinking) {
      return;
    }
    const handle: AiAbortHandle = AiService.chatStream(context, handlers, 2048);
    if (requestId === this.requestId && this.thinking) {
      this.abort = handle;
    }
  }

  finishBubble(text: string, isError: boolean): void {
    const last: ChatBubble = this.messages[this.messages.length - 1];
    last.streaming = false;
    last.error = isError;
    last.content = isError ? (text.length > 0 ? text : '请求失败') : text;
    last.activities = this.liveActivities;
    last.reasoning = this.streamingReasoning;
    this.messages = this.messages.slice();
    this.thinking = false;
    this.streamingText = '';
    this.streamingReasoning = '';
    this.liveActivities = [];
    this.abort = null;
    // 上次是错误气泡时，把这次失败的消息踢出上下文（buildContext 已过滤 error）
    if (isError) {
      this.errorTip = text;
    }
    this.saveHistory();
    this.notify();
  }

  /** 工具开始执行：活动区加一条 doing。整组换数组赋值，保证视图刷新。 */
  beginActivity(name: string, label: string): void {
    const act: ChatActivity = { name: name, label: label, state: 'doing', books: [], summary: '' };
    this.liveActivities = this.liveActivities.concat([act]);
    this.notify();
  }

  /** 工具执行完：把最后一条同名 doing 翻成 done/rejected，书目结果转结构化条目。 */
  endActivity(name: string, label: string, text: string): void {
    // 结构化缓存带封面（search_books），文本解析仅兜底（书源/任务等无图工具）
    const cached: ToolBookLine[] = AiTools.takeLastBooks();
    const books: ToolBookLine[] = cached.length > 0 ? cached : parseToolBookLines(text);
    const firstLine: string = text.length > 0 ? text.split('\n')[0] : '';
    const summary: string = books.length > 0 || firstLine.length === 0 ? '' :
      (firstLine.length > 48 ? `${firstLine.substring(0, 48)}…` : firstLine);
    const acts: ChatActivity[] = this.liveActivities.slice();
    let flipped: boolean = false;
    for (let i = acts.length - 1; i >= 0; i--) {
      if (acts[i].name === name && acts[i].state === 'doing') {
        acts[i] = {
          name: name,
          label: label,
          state: text === '用户拒绝了该操作' ? 'rejected' : 'done',
          books: books,
          summary: summary,
        };
        flipped = true;
        break;
      }
    }
    if (!flipped) {
      // 闸门拒绝的工具不会走 onTool（没有 doing 条目可翻），这里补记 ✕ 行，保证拒绝可见
      acts.push({
        name: name,
        label: label,
        state: text === '用户拒绝了该操作' ? 'rejected' : 'done',
        books: books,
        summary: summary,
      });
    }
    this.liveActivities = acts;
    this.notify();
  }

  /** 清空会话：用户主动操作，需要中断在途流。 */
  clearChat(): void {
    this.stopStreaming();
    this.messages = [];
    this.errorTip = '';
    this.saveHistory();
    this.notify();
  }

  /** 仅离线回归用：隔离单例状态，避免用例串台。 */
  resetForTest(): void {
    this.requestId++;
    this.abort = null;
    this.viewToken++;
    this.viewSync = null;
    this.confirmUi = null;
    this.messages = [];
    this.streamingText = '';
    this.streamingReasoning = '';
    this.liveActivities = [];
    this.thinking = false;
    this.errorTip = '';
    this.loaded = true;
    TalebookService.prefSet(CHAT_HISTORY_KEY, '[]');
  }
}
