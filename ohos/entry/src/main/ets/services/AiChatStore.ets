import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { AiTools, AiPermissionMode } from './AiTools';
import { AiToolDefinition, parseToolBookLines, ToolBookLine } from './AiToolsDefs';
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

/** ask_user 反问卡片的待答状态：对话页渲染选项按钮，点选/跳过经 answerAsk 归还回路。 */
export interface AskRequest {
  question: string;
  options: string[];
}

/** 存档会话（不含当前会话）：切换/新建时当前会话整条归档到这里。 */
export interface ChatSession {
  id: string;
  title: string;
  updatedAt: number;
  messages: ChatBubble[];
}

/**
 * 系统提示词只留**行为规则与跨工具流程**：单个工具的名称/用途/参数由请求体
 * tools 数组自带（AiTools 描述是权威来源，此处复述既烧 token 又会与代码漂移）。
 * 权限模式说明由 permissionPromptNote 按当前档位追加，三档都有明确表述。
 * 工具指引段（SYSTEM_PROMPT_TOOLS）只在通道挂 tools 时拼入，见 buildContext。
 */
const SYSTEM_PROMPT: string =
  '你是一个电子书阅读应用的助手。回答与思考过程一律使用中文（书名、参数值等原文引用除外），简洁、准确。' +
  '问题涉及用户的书籍、阅读情况或其他可查证的信息，而你没有可靠依据时，如实说明不确定，绝不编造。' +
  '系统提示中若已有「用户记忆」列表，回答时自然参考、不必复述。';

/** 工具通道的行为规则与跨工具流程（仅 OpenCode 网关挂 tools 时可用）。 */
const SYSTEM_PROMPT_TOOLS: string =
  '问题涉及用户的书籍、阅读情况或其他可查证的信息时，先调用相应工具拿到真实数据再回答，绝不编造；' +
  '工具数据不足时直接说明不确定。' +
  '工具返回「暂时失败」时可稍后原样重试一次；返回「执行失败」时按错误提示修正参数或方案再试，勿原样重试；仍失败如实告知，不反复重试。' +
  '写操作（建书单、加书、下载任务、改元数据、换封面、删记忆）一律按后文的权限模式说明处理。' +
  '需要用户在多个候选间拍板、或缺少无法安全臆断的关键信息时，用 ask_user 提出一个问题并给 2-6 个简短选项，' +
    '得到答复前不要执行有后果的操作；用户跳过时基于现状谨慎收敛，不要反复追问。' +
  '换封面流程：先 search_cover 列出候选给用户看，用户选定后再 set_cover。' +
  '网文下载流程：search_sonovel 拿 url → add_sonovel_task 入队 → list_download_tasks 报进度，成品完成后自动进本地书架可读。';

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
/** 会话存档键：不含当前会话（当前仍走 ai_chat_history，退出页面重进照常恢复）。 */
const CHAT_SESSIONS_KEY: string = 'ai_chat_sessions';
/** 存档会话数上限：超出按 updatedAt 从旧到新丢弃。 */
const CHAT_SESSIONS_MAX: number = 12;
/** 历史摘要键：按会话 id 存「被窗口截断的旧轮」的压缩摘要。 */
const CHAT_SUMMARIES_KEY: string = 'ai_chat_summaries';
/** 未摘数量达到该阈值才触发一次摘要请求：压缩自身也要省 token。 */
const COMPRESS_MIN_DROPPED: number = 8;
/** 摘要生成请求的系统提示词：面向「续聊携带」，只留事实不复议论。 */
const SUMMARY_SYSTEM_PROMPT: string =
  '把对话片段压缩成供后续对话使用的交接摘要：保留书名/id、用户偏好、已完成与未完成事项等关键事实，' +
    '要点式短句，总量不超过 200 字。只输出摘要正文。';

/** 单会话的历史摘要：text=摘要正文，count=已折叠进摘要的筛后气泡前缀条数。 */
export interface HistorySummary {
  text: string;
  count: number;
}

/** 摘要落盘条目：HistorySummary 加会话 id，仅用于 JSON 持久化。 */
interface SummaryRecord {
  id: string;
  text: string;
  count: number;
}

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
  /** ask_user 在途反问卡片；null=无。回路 await 在 answerAsk 上，退出页面按跳过收敛。 */
  pendingAsk: AskRequest | null = null;
  private askResolve: ((answer: string) => void) | null = null;
  /** 存档会话列表（时间戳 id 去重、updatedAt 排序截顶）；当前会话不在其中。 */
  sessions: ChatSession[] = [];
  /** 各会话历史摘要（键=会话 id）：窗口外旧轮压缩后随会话携带，不再静默丢弃。 */
  private summaries: Map<string, HistorySummary> = new Map();
  private compressing: boolean = false;
  private static idSeq: number = 0;

  /** 会话 id：毫秒+进程内递增，杜绝同毫秒新建/切换撞 id。 */
  private nextId(): string {
    AiChatStore.idSeq++;
    return `${Date.now()}-${AiChatStore.idSeq}`;
  }
  /** 当前会话 id：仅会话面板显示「当前」用，重启无需恢复（内容就在 ai_chat_history）。 */
  currentId: string = '';

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
      // 卡片随视图消失：在途反问按跳过收敛，回路照常收尾落盘
      this.answerAsk('');
    }
  }

  /** 卡片点选（跳过传空串）：把答复归还等待中的回路并清卡片。无在途反问则忽略。 */
  answerAsk(option: string): void {
    const resolve: ((answer: string) => void) | null = this.askResolve;
    this.askResolve = null;
    this.pendingAsk = null;
    if (resolve !== null) {
      resolve(option);
    }
    this.notify();
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
      this.currentId = this.nextId();
      this.loadHistory();
      this.loadSessions();
      this.loadSummaries();
    }
  }

  stopStreaming(): void {
    this.requestId++;
    // 停止键：在途反问卡片一并收起（跳过语义），等待中的回路随即在 isAborted 处收尾
    this.answerAsk('');
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
      this.messages = this.parseBubbles(JSON.parse(raw)).slice(-CHAT_HISTORY_MAX);
    } catch (_error) {
      // 历史损坏：保持空会话，下一次保存会覆盖
    }
    this.notify();
  }

  /** 解析气泡数组（当前会话与存档会话共用）；坏条目（缺字段/类型不符）逐条丢弃。 */
  private parseBubbles(parsed: Object): ChatBubble[] {
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
        });
      }
    return bubbles;
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
    // 无 tools 的通道（非 OpenCode 网关）不提工具与权限模式：模型看不见工具定义，
    // 指引只会诱导它伪造伪工具调用文本当正文输出（还会被后续上下文模仿强化）
    const toolsOn: boolean = AiService.supportsTools();
    let systemText: string = persona.length > 0 ? `${SYSTEM_PROMPT}\n\n${persona}` : SYSTEM_PROMPT;
    if (toolsOn) {
      systemText = `${systemText}${SYSTEM_PROMPT_TOOLS}`;
      // 权限模式说明追加在最后，覆盖 SYSTEM_PROMPT 里「逐笔确认」的默认描述
      const modeNote: string = permissionPromptNote(AiService.loadPermission());
      if (modeNote.length > 0) {
        systemText = `${systemText}\n\n${modeNote}`;
      }
    }
    const context: AiMessage[] = [{ role: 'system', content: systemText }];
    const bubbles: ChatBubble[] = this.messages.filter((m: ChatBubble) =>
      !m.error && (m.content.length > 0 || (m.images ?? []).length > 0));
    const start: number = Math.max(0, bubbles.length - AiService.contextRounds(this.contextK) * 2);
    // 窗口外旧轮的历史摘要随会话携带：count 超过当前截断点说明消息被重排
    // （重新生成/清空过），摘要脱节，宁缺毋滥地不注入
    const summary: HistorySummary | undefined = this.summaries.get(this.currentId);
    if (summary !== undefined && summary.text.length > 0 && summary.count <= start) {
      context.push({ role: 'system', content: `早前对话摘要（已压缩 ${summary.count} 条）：\n${summary.text}` });
    }
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

  /** 参与携带统计的气泡（排除错误与在途）；与 buildContext 过滤口径一致处仅在排除 streaming。 */
  private filteredBubbles(): ChatBubble[] {
    return this.messages.filter((m: ChatBubble) =>
      !m.error && !m.streaming && (m.content.length > 0 || (m.images ?? []).length > 0));
  }

  /**
   * 估算下次请求随附的历史 token（k）：窗口内正文 + 在用的历史摘要。
   * 粗算中文约 1 字 = 1 token、英文约 4 字 = 1 token，取折中 100 字/k 只用于指示不用于计费。
   * system 提示与图片 base64 开销不计（与档位设置对照的意义在于历史增长趋势）。
   */
  contextUsageK(): number {
    const bubbles: ChatBubble[] = this.filteredBubbles();
    const start: number = Math.max(0, bubbles.length - AiService.contextRounds(this.contextK) * 2);
    const summary: HistorySummary | undefined = this.summaries.get(this.currentId);
    let chars: number = summary !== undefined && summary.text.length > 0 && summary.count <= start
      ? summary.text.length : 0;
    for (let i = start; i < bubbles.length; i++) {
      chars += bubbles[i].content.length;
    }
    return Math.ceil(chars / 100);
  }

  /** 会话面板/指示器的摘要状态；''=无在用摘要。 */
  summaryNote(): string {
    const bubbles: ChatBubble[] = this.filteredBubbles();
    const start: number = Math.max(0, bubbles.length - AiService.contextRounds(this.contextK) * 2);
    const summary: HistorySummary | undefined = this.summaries.get(this.currentId);
    if (summary === undefined || summary.text.length === 0 || summary.count > start) {
      return '';
    }
    return `已摘要 ${summary.count} 条`;
  }

  /**
   * 增量历史压缩：窗口截断掉的消息比已有摘要多覆盖出 COMPRESS_MIN_DROPPED 条时，
   * 把旧摘要 + 新增被截断片段一次交给 complete() 重写（≤200 字）。
   * fire-and-forget：失败静默（旧摘要继续用），compressing 守卫防叠火；
   * 摘要是唯一「窗口外信息」的去处，触发偏保守比频繁多一次小请求更划算。
   */
  private async compressHistory(): Promise<void> {
    if (this.compressing) {
      return;
    }
    const sessionId: string = this.currentId;
    const bubbles: ChatBubble[] = this.filteredBubbles();
    const start: number = Math.max(0, bubbles.length - AiService.contextRounds(this.contextK) * 2);
    const old: HistorySummary | undefined = this.summaries.get(sessionId);
    const covered: number = old === undefined || old.text.length === 0 ? 0 : old.count;
    if (start - covered < COMPRESS_MIN_DROPPED) {
      return;
    }
    const parts: string[] = [];
    for (let i = covered; i < start; i++) {
      parts.push(`${bubbles[i].role === 'user' ? '用户' : 'AI'}: ${bubbles[i].content}`);
    }
    const prompt: string = old !== undefined && old.text.length > 0
      ? `已有摘要：\n${old.text}\n\n新增片段：\n${parts.join('\n')}`
      : parts.join('\n');
    this.compressing = true;
    try {
      const text: string = (await AiService.complete([
        { role: 'system', content: SUMMARY_SYSTEM_PROMPT },
        { role: 'user', content: prompt },
      ], 512)).trim();
      if (text.length > 0) {
        // 期间用户可能已切会话：摘要归属发起时的 sessionId，不跟随 currentId 漂移
        this.summaries.set(sessionId, { text: text, count: start });
        this.saveSummaries();
        this.notify();
      }
    } catch (_error) {
      // 摘要失败不打扰用户：下轮超过阈值自然重试
    } finally {
      this.compressing = false;
    }
  }

  private saveSummaries(): void {
    const arr: SummaryRecord[] = [];
    this.summaries.forEach((v: HistorySummary, k: string): void => {
      arr.push({ id: k, text: v.text, count: v.count });
    });
    TalebookService.prefSet(CHAT_SUMMARIES_KEY, JSON.stringify(arr));
  }

  private loadSummaries(): void {
    const raw: string = TalebookService.prefGet(CHAT_SUMMARIES_KEY, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const arr: Object = JSON.parse(raw);
      if (!Array.isArray(arr)) {
        return;
      }
      for (const entry of arr as Object[]) {
        if (entry === null || typeof entry !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = entry as Record<string, Object>;
        if (typeof rec['id'] !== 'string' || typeof rec['text'] !== 'string'
          || typeof rec['count'] !== 'number') {
          continue;
        }
        this.summaries.set(rec['id'], { text: rec['text'], count: rec['count'] });
      }
    } catch (_error) {
      // 摘要档损坏：视为无摘要
    }
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
      onToolResult: (name: string, label: string, text: string, callId: string) => {
        if (requestId === this.requestId && this.thinking) {
          this.endActivity(name, label, text, callId);
        }
      },
      onConfirm: (label: string, args: string): Promise<boolean> => {
        // 写操作闸门：弹窗让用户逐笔批准；页面已退出（无视图）与停止/回退键一样按拒绝处理
        if (requestId !== this.requestId || !this.thinking || this.confirmUi === null) {
          return Promise.resolve(false);
        }
        return this.confirmUi(label, args);
      },
      onAsk: (question: string, options: string[]): Promise<string> => {
        // 反问卡片：视图不在场/轮次已换代时直接按跳过收敛，绝不让回路无限等待
        if (requestId !== this.requestId || !this.thinking || this.viewSync === null) {
          return Promise.resolve('');
        }
        return new Promise<string>((resolve: (answer: string) => void): void => {
          this.askResolve = resolve;
          this.pendingAsk = { question: question, options: options };
          this.notify();
        });
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
    // MCP 预热：Token Plan 下拿百炼 MCP 工具清单（其余服务商零请求；
    // 握手失败静默空集，聊天照常走内置工具）。放在中断检查之后，退页不浪费连接。
    const mcpTools: AiToolDefinition[] = await AiService.mcpToolset();
    if (requestId !== this.requestId || !this.thinking) {
      return;
    }
    const handle: AiAbortHandle = AiService.chatStream(context, handlers, 2048,
      mcpTools.length > 0 ? mcpTools : null);
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
    // 轮次收尾顺带压缩窗口外旧轮（内部阈值+compressing 守卫，不阻塞界面）
    if (!isError) {
      void this.compressHistory();
    }
  }

  // ————— 语音（realtime 全双工）轮次：直接写进消息流 —————
  // 语音会话激活期间文字输入停用，与文字轮（requestId/thinking）天然不并发。

  private lastBubble(): ChatBubble | null {
    return this.messages.length > 0 ? this.messages[this.messages.length - 1] : null;
  }

  /**
   * ASR 结果进流（语音轮）：final=false 为中间结果——「进行中」用户气泡整段替换，
   * 空文本清占位（VAD 误触发）；final=true 固化，空 final 丢弃占位。
   */
  voiceUser(text: string, final: boolean): void {
    const last: ChatBubble | null = this.lastBubble();
    if (last !== null && last.role === 'user' && last.streaming) {
      this.messages.pop();
    }
    if (text.length > 0) {
      this.messages.push({ role: 'user', content: text, streaming: !final, error: false, activities: [] });
    }
    this.messages = this.messages.slice();
    if (final) {
      this.saveHistory();
    }
    this.notify();
  }

  /**
   * AI 字幕进流：delta 在既有流式气泡上累计（打断后重新开口即新气泡）；
   * final 固化（done 全文优先，空则保留已累计文本）。
   */
  voiceAi(text: string, final: boolean): void {
    const last: ChatBubble | null = this.lastBubble();
    let content: string = text;
    if (last !== null && last.role === 'assistant' && last.streaming) {
      this.messages.pop();
      if (!final) {
        content = last.content + text;
      } else if (text.length === 0) {
        content = last.content;
      }
    }
    if (content.length > 0) {
      this.messages.push({ role: 'assistant', content: content, streaming: !final, error: false, activities: [] });
    }
    this.messages = this.messages.slice();
    if (final) {
      this.saveHistory();
    }
    this.notify();
  }

  /** 打断/断线收尾：固化尾部流式气泡（AI 已播出的文字保留，光标熄灭）。 */
  voiceSealStreaming(): void {
    let changed: boolean = false;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const bubble: ChatBubble = this.messages[i];
      if (!bubble.streaming) {
        break;
      }
      bubble.streaming = false;
      changed = true;
    }
    if (changed) {
      this.messages = this.messages.slice();
      this.saveHistory();
      this.notify();
    }
  }

  /** 工具开始执行：活动区加一条 doing。整组换数组赋值，保证视图刷新。 */
  beginActivity(name: string, label: string): void {
    const act: ChatActivity = { name: name, label: label, state: 'doing', books: [], summary: '' };
    this.liveActivities = this.liveActivities.concat([act]);
    this.notify();
  }

  /** 工具执行完：把最早的同名 doing 翻成 done/rejected，书目结果转结构化条目。 */
  endActivity(name: string, label: string, text: string, callId: string = ''): void {
    // 结构化缓存带封面（search_books），文本解析仅兜底（书源/任务等无图工具）；
    // 同轮并行执行时按 callId 配对取，避免静态槽被后完成者覆盖而串台
    const cached: ToolBookLine[] = AiTools.takeLastBooksFor(callId);
    const books: ToolBookLine[] = cached.length > 0 ? cached : parseToolBookLines(text);
    const firstLine: string = text.length > 0 ? text.split('\n')[0] : '';
    const summary: string = books.length > 0 || firstLine.length === 0 ? '' :
      (firstLine.length > 48 ? `${firstLine.substring(0, 48)}…` : firstLine);
    const acts: ChatActivity[] = this.liveActivities.slice();
    let flipped: boolean = false;
    // 网关回路带 callId：正序翻最早同名 doing（并行轮结果按调用原序回填）；
    // 页面直调（无 callId）保留旧语义「只翻最后一条」
    const flipFrom: number = callId.length === 0 ? acts.length - 1 : 0;
    const flipTo: number = callId.length === 0 ? -1 : acts.length;
    const flipStep: number = callId.length === 0 ? -1 : 1;
    for (let i = flipFrom; i !== flipTo; i += flipStep) {
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

  // —— 多会话：当前会话始终走 ai_chat_history，切换/新建时整条归档进 ai_chat_sessions ——

  /** 会话标题：取首条用户消息前 20 字；没有则空串（调用侧兜底「新对话」）。 */
  private sessionTitle(bubbles: ChatBubble[]): string {
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

  /** 面板显示的当前会话标题。 */
  currentTitle(): string {
    const t: string = this.sessionTitle(this.messages);
    return t.length > 0 ? t : '新对话';
  }

  private saveSessions(): void {
    TalebookService.prefSet(CHAT_SESSIONS_KEY, JSON.stringify(this.sessions));
  }

  private loadSessions(): void {
    const raw: string = TalebookService.prefGet(CHAT_SESSIONS_KEY, '');
    if (raw.length === 0) {
      return;
    }
    try {
      const arr: Object = JSON.parse(raw);
      if (!Array.isArray(arr)) {
        return;
      }
      const list: ChatSession[] = [];
      for (const entry of arr as Object[]) {
        if (entry === null || typeof entry !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = entry as Record<string, Object>;
        if (typeof rec['id'] !== 'string' || typeof rec['title'] !== 'string'
          || typeof rec['updatedAt'] !== 'number') {
          continue;
        }
        list.push({ id: rec['id'], title: rec['title'], updatedAt: rec['updatedAt'],
          messages: this.parseBubbles(rec['messages']) });
      }
      list.sort((a: ChatSession, b: ChatSession): number => b.updatedAt - a.updatedAt);
      this.sessions = list.slice(0, CHAT_SESSIONS_MAX);
    } catch (_error) {
      // 存档损坏：视为无存档，下一次保存覆盖
    }
  }

  /** 当前会话归档（空会话与在途 streaming 气泡不入档）；超上限按 updatedAt 丢最旧。 */
  private stashCurrent(): void {
    const items: ChatBubble[] = this.messages.filter((m: ChatBubble) => !m.streaming);
    if (items.length === 0) {
      return;
    }
    const title: string = this.sessionTitle(items);
    this.sessions.push({ id: this.currentId,
      title: title.length > 0 ? title : '新对话', updatedAt: Date.now(),
      messages: items.slice(-CHAT_HISTORY_MAX) });
    if (this.sessions.length > CHAT_SESSIONS_MAX) {
      this.sessions.sort((a: ChatSession, b: ChatSession): number => a.updatedAt - b.updatedAt);
      this.sessions.shift();
    }
    this.saveSessions();
  }

  /** 开新会话：当前先归档再切空。生成中禁止（与切换/删除统一，不制造双头流）。 */
  newSession(): boolean {
    if (this.thinking) {
      return false;
    }
    if (this.messages.length === 0) {
      return true;
    }
    this.stashCurrent();
    this.messages = [];
    this.currentId = this.nextId();
    this.errorTip = '';
    this.saveHistory();
    this.notify();
    return true;
  }

  /** 切会话：当前与目标整条互换（当前进存档、目标出档）。生成中禁止。 */
  switchSession(id: string): boolean {
    if (this.thinking || id === this.currentId) {
      return false;
    }
    const index: number = this.sessions.findIndex((s: ChatSession): boolean => s.id === id);
    if (index < 0) {
      return false;
    }
    this.stashCurrent();
    const target: ChatSession = this.sessions[index];
    this.sessions.splice(index, 1);
    this.saveSessions();
    this.messages = target.messages.slice();
    this.currentId = target.id;
    this.errorTip = '';
    this.saveHistory();
    this.notify();
    return true;
  }

  /** 删除一个存档会话（当前会话不可删——丢弃当前请用「清空」，语义单一）。 */
  deleteSession(id: string): void {
    const index: number = this.sessions.findIndex((s: ChatSession): boolean => s.id === id);
    if (index < 0) {
      return;
    }
    this.sessions.splice(index, 1);
    this.saveSessions();
    // 摘要跟随会话生命周期：档删了摘要就是孤儿，一并清
    if (this.summaries.delete(id)) {
      this.saveSummaries();
    }
    this.notify();
  }

  /** 重新生成：抹掉最后一条用户消息及其后全部，原样重发该问题（原位替换答案）。 */
  regenerate(): boolean {
    if (this.thinking) {
      return false;
    }
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === 'user') {
        const question: ChatBubble = this.messages[i];
        this.messages = this.messages.slice(0, i);
        // 截断重排后摘要的「前 count 条」坐标系失效且无法回退，宁可丢掉待重建
        if (this.summaries.delete(this.currentId)) {
          this.saveSummaries();
        }
        this.saveHistory();
        void this.send(question.content, question.images ?? []);
        return true;
      }
    }
    return false;
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
    this.sessions = [];
    this.currentId = this.nextId();
    this.summaries.clear();
    this.compressing = false;
    TalebookService.prefSet(CHAT_HISTORY_KEY, '[]');
    TalebookService.prefSet(CHAT_SESSIONS_KEY, '[]');
    TalebookService.prefSet(CHAT_SUMMARIES_KEY, '[]');
  }
}
