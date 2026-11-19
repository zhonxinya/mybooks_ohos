import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { PageScaffold, SecondaryButton, TextButton } from '../components';
import { MarkdownText } from '../components/MarkdownText';
import { AI_SKILLS, AiSkill } from '../services/AiSkills';
import { AiTools, parseToolBookLines, ToolBookLine } from '../services/AiTools';
import { ToolResultList } from '../components/ToolResultList';
import { AiService, AiConfig, AiMessage, AiStreamHandlers, AiAbortHandle } from '../services/AiService';
import { AiPersona } from '../services/AiPersona';
import { TalebookService } from '../services/TalebookService';
import { AppRouter } from '../utils/AppRouter';

/** 工具调用活动：回路里每次工具执行产生一条，流式期间实时翻转状态。 */
interface ChatActivity {
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
interface ChatBubble {
  role: string;
  content: string;
  /** 是否正在流式输出（末尾光标用）。 */
  streaming: boolean;
  error: boolean;
  /** 完成后固化的活动快照（流式期间由 liveActivities 渲染）。 */
  activities: ChatActivity[];
  /** 用户消息附带的图片（沙箱绝对路径；发送时压缩编码为 data URL）。 */
  images?: string[];
}

/** 技能卡片/芯片点击：把现成提示词填入输入框，用户可先补书名再发送。 */

const SYSTEM_PROMPT: string =
  '你是一个电子书阅读应用的助手，回答简洁、准确、中文优先。' +
  '只读工具查询真实数据：search_books（搜书架）、book_detail（书籍详情，需 id）、' +
  'book_notes（该书标注，需 id）、reading_history（最近阅读记录）、' +
  'search_sonovel（搜网络小说书源）、list_download_tasks（查下载任务）、' +
  'search_cover（按 ISBN/书名检索封面候选，需 id）、' +
  'search_meta（多站元数据：豆瓣直连检索与评分/出版社/ISBN 详情、传 book_id 拿服务端多源候选、网文源更新状态）。' +
  '写操作工具：create_booklist（建书单）、add_books_to_booklist（书单加书，id 来自 search_books）、' +
  'add_sonovel_task（加入下载队列，参数来自 search_sonovel）、' +
  'update_book_meta（改书籍元数据：书名/作者/标签/出版社/ISBN/丛书/简介/评分，只传要改的字段）、' +
  'set_cover（换封面，index 来自对同一本书的 search_cover）；' +
  '这些操作执行前都会请用户逐笔确认，被拒绝时不要坚持重试，问明原因即可。' +
  '改元数据前先用 book_detail 核对现值，把「从什么改成什么」讲清楚再调用工具。' +
  '换封面流程：先 search_cover 列出候选给用户看，选定后再 set_cover。' +
  '下载工作流：先 search_sonovel 拿 url，再 add_sonovel_task 入队，用 list_download_tasks 报进度，' +
  '成品完成后自动进本地书架可读。' +
  '记忆工具：save_memory 记录值得跨对话保留的用户事实（偏好、正在读的书、约定），' +
  'forget_memory 按序号删除；系统提示中若已有「用户记忆」列表，回答时自然参考、不必复述。' +
  '问题涉及用户的书籍或阅读情况时，先调用工具拿到真实数据再回答，绝不编造；' +
  '工具数据不足时直接说明不确定。';

/** 附图发送前的压缩长边（像素）：够模型看清，又不至于撑爆请求体。 */
const IMAGE_MAX_EDGE: number = 1024;
const IMAGE_JPEG_QUALITY: number = 80;

/** 对话历史持久化（preferences 明文 KV，与账号列表同层）：只存已固化的气泡。 */
const CHAT_HISTORY_KEY: string = 'ai_chat_history';
/** 历史上限：超出丢弃最旧条目，避免 preferences.json 无限膨胀。 */
const CHAT_HISTORY_MAX: number = 60;

@Entry
@Component
struct AiAssistantPage {
  @State messages: ChatBubble[] = [];
  @State input: string = '';
  @State thinking: boolean = false;
  @State configured: boolean = false;
  @State errorTip: string = '';
  /** 待发送图片（沙箱路径），输入框上方预览、可删。 */
  @State pendingImages: string[] = [];
  @State visionEnabled: boolean = false;
  @State contextK: number = 8;
  /** 流式输出用：整段重建列表的代价高，这里只改最后一条气泡的内容。 */
  @State streamingText: string = '';
  /** 工具回路实时活动时间线；finishBubble 时快照进气泡成为历史。 */
  @State liveActivities: ChatActivity[] = [];
  private requestId: number = 0;
  private abort: AiAbortHandle | null = null;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.configured = AiService.isReady();
    this.refreshSettings();
    this.loadHistory();
  }

  onPageShow(): void {
    this.configured = AiService.isReady();
    this.refreshSettings();
  }

  /** 设置页可能刚改过 vision/上下文档位，回页即刷新。 */
  private refreshSettings(): void {
    const config: AiConfig = AiService.loadConfig();
    this.visionEnabled = config.vision;
    this.contextK = config.contextLength;
  }

  aboutToDisappear(): void {
    this.stopStreaming();
  }

  private stopStreaming(): void {
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
      this.messages = this.messages.slice();
      this.saveHistory();
    }
    this.streamingText = '';
    this.liveActivities = [];
    this.thinking = false;
  }

  /** 固化消息落盘（streaming 气泡除外）；在每轮完成/停止/清空时调用。 */
  private saveHistory(): void {
    const items: ChatBubble[] = this.messages.filter((m: ChatBubble) => !m.streaming);
    TalebookService.prefSet(CHAT_HISTORY_KEY, JSON.stringify(items.slice(-CHAT_HISTORY_MAX)));
  }

  /** 读回历史；坏条目（缺字段/类型不符）逐条丢弃，整体损坏则视为无历史。 */
  private loadHistory(): void {
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
        bubbles.push({
          role: m['role'],
          content: m['content'],
          streaming: false,
          error: m['error'] === true,
          activities: activities,
          images: images,
        });
      }
      this.messages = bubbles.slice(-CHAT_HISTORY_MAX);
    } catch (_error) {
      // 历史损坏：保持空会话，下一次保存会覆盖
    }
  }

  /** 附图沙箱目录（历史恢复与发送都从这里读文件）。 */
  private aiImagesDir(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const dir = `${context.filesDir}/ai_images`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    return dir;
  }

  /** 相册选一张图复制进沙箱；用户取消不算错误。 */
  private async pickImage(): Promise<void> {
    if (this.thinking) {
      return;
    }
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      };
      const result = await picker.select(options);
      if (result.photoUris.length === 0) {
        return;
      }
      const dest = `${this.aiImagesDir()}/img_${Date.now()}.jpg`;
      const srcFile = fs.openSync(result.photoUris[0], fs.OpenMode.READ_ONLY);
      const dstFile = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(srcFile.fd, dstFile.fd);
      } finally {
        fs.closeSync(srcFile);
        fs.closeSync(dstFile);
      }
      this.pendingImages = this.pendingImages.concat([dest]);
    } catch (_error) {
      // 取消选择/复制失败：静默
    }
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
  private async buildContext(): Promise<AiMessage[]> {
    const persona: string = AiPersona.buildPersonaPrompt();
    const systemText: string = persona.length > 0 ? `${SYSTEM_PROMPT}\n\n${persona}` : SYSTEM_PROMPT;
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

  private async send(text: string): Promise<void> {
    const question: string = text.trim();
    if (question.length === 0 || this.thinking) {
      return;
    }
    if (!AiService.isReady()) {
      this.configured = false;
      this.errorTip = '尚未配置模型，请先填写接口地址、模型与 API Key';
      return;
    }
    this.configured = true;
    this.errorTip = '';
    const requestId: number = ++this.requestId;

    const images: string[] = this.visionEnabled ? this.pendingImages : [];
    this.pendingImages = [];
    this.messages.push({ role: 'user', content: question, streaming: false, error: false,
      activities: [], images: images });
    this.messages.push({ role: 'assistant', content: '', streaming: true, error: false, activities: [] });
    this.saveHistory();
    this.streamingText = '';
    this.liveActivities = [];
    this.input = '';
    this.thinking = true;
    this.scrollToEnd();

    const handlers: AiStreamHandlers = {
      onDelta: (delta: string) => {
        if (requestId !== this.requestId || !this.thinking) {
          return;
        }
        this.streamingText += delta;
        this.scrollToEnd();
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
        // 写操作闸门：弹窗让用户逐笔批准；切页/停止/回退键都按拒绝处理
        if (requestId !== this.requestId || !this.thinking) {
          return Promise.resolve(false);
        }
        const summary: string = args.length > 200 ? `${args.substring(0, 200)}…` : args;
        // showDialog 的 Promise 结果是按钮下标；异常路径（返回键等）统一按拒绝兜底
        return this.getUIContext().getPromptAction().showDialog({
          title: 'AI 想执行操作',
          message: `操作：${label}\n参数：${summary}`,
          buttons: [
            { text: '拒绝', color: '#E5484D' },
            { text: '允许', color: '#1890FF' },
          ],
          alignment: DialogAlignment.Center,
        }).then((res: promptAction.ShowDialogSuccessResponse): boolean => res.index === 1)
          .catch((): boolean => false);
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

  private finishBubble(text: string, isError: boolean): void {
    const last: ChatBubble = this.messages[this.messages.length - 1];
    last.streaming = false;
    last.error = isError;
    last.content = isError ? (text.length > 0 ? text : '请求失败') : text;
    last.activities = this.liveActivities;
    this.messages = this.messages.slice();
    this.thinking = false;
    this.streamingText = '';
    this.liveActivities = [];
    this.abort = null;
    // 上次是错误气泡时，把这次失败的消息踢出上下文（buildContext 已过滤 error）
    if (isError) {
      this.errorTip = text;
    }
    this.saveHistory();
    this.scrollToEnd();
  }

  private scrollToEnd(): void {
    // 布局未完成时 scrollEdge 会静默失败，延后一帧即可
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (_error) {
        // 列表尚未挂载时忽略
      }
    }, 60);
  }

  private applySkill(skill: AiSkill): void {
    this.input = skill.prompt;
  }

  private removePending(index: number): void {
    const next: string[] = this.pendingImages.slice();
    next.splice(index, 1);
    this.pendingImages = next;
  }

  /** 工具开始执行：活动区加一条 doing。整组换数组赋值，保证 @State 刷新。 */
  private beginActivity(name: string, label: string): void {
    const act: ChatActivity = { name: name, label: label, state: 'doing', books: [], summary: '' };
    this.liveActivities = this.liveActivities.concat([act]);
    this.scrollToEnd();
  }

  /** 工具执行完：把最后一条同名 doing 翻成 done/rejected，书目结果转结构化条目。 */
  private endActivity(name: string, label: string, text: string): void {
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
    this.scrollToEnd();
  }

  private clearChat(): void {
    this.stopStreaming();
    this.messages = [];
    this.errorTip = '';
    this.saveHistory();
  }

  private async copyBubble(index: number): Promise<void> {
    if (index < 0 || index >= this.messages.length) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.messages[index].content);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast('已复制');
    } catch (_error) {
      this.toast('复制失败');
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: 'AI 助手',
        showBack: true,
        action: () => {
          this.headerAction();
        },
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  headerAction() {
    Row({ space: 4 }) {
      TextButton({
        label: '设置',
        onTap: () => AppRouter.pushUrl(this.getUIContext(), { url: 'pages/AiSettingsPage' }),
      });
      if (this.messages.length > 0) {
        TextButton({ label: '清空', onTap: () => this.clearChat() });
      }
    }
  }

  @Builder
  pageContent() {
    Column() {
      if (!this.configured) {
        this.notConfigured();
      } else if (this.messages.length === 0) {
        this.emptyState();
      } else {
        this.chatList();
        this.skillBar();
      }
      this.inputBar();
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  notConfigured() {
    Column({ space: 16 }) {
      Text('尚未配置模型')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Text('配置你自己的大模型接口即可开始使用。key 只保存在本机，不经过本项目服务端。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .constraintSize({ maxWidth: '86%' });
      SecondaryButton({
        label: '去配置',
        fullWidth: false,
        onTap: () => AppRouter.pushUrl(this.getUIContext(), { url: 'pages/AiSettingsPage' }),
      });
      if (this.errorTip.length > 0) {
        Text(this.errorTip)
          .fontSize(12)
          .fontColor($r('app.color.error'))
          .textAlign(TextAlign.Center);
      }
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center);
  }

  @Builder
  emptyState() {
    Column({ space: 14 }) {
      Text('问点什么')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Text('可以直接提问，也可以用下面的技能')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'));
      Column({ space: 10 }) {
        ForEach(AI_SKILLS, (skill: AiSkill) => {
          Row({ space: 10 }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.wand_and_stars'))
                .fontSize(15)
                .fontColor([$r('app.color.brand_primary')]);
            }
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor($r('app.color.brand_primary_light'));
            Column({ space: 2 }) {
              Text(skill.label)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'));
              Text(skill.hint)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'));
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(14)
              .fontColor([$r('app.color.text_tertiary')]);
          }
          .width('100%')
          .padding({ left: 12, right: 14, top: 10, bottom: 10 })
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'))
          .shadow({ radius: 8, type: ShadowType.COLOR, color: $r('app.color.button_shadow'), offsetX: 0, offsetY: 2 })
          .onClick(() => this.applySkill(skill));
        }, (skill: AiSkill) => skill.label);
      }
      .width('100%');
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding') })
    .justifyContent(FlexAlign.Center);
  }

  @Builder
  chatList() {
    List({ space: 12, scroller: this.scroller }) {
      ForEach(this.messages, (bubble: ChatBubble, index: number) => {
        ListItem() {
          this.bubbleView(bubble, index);
        }
      }, (bubble: ChatBubble, index: number) => {
        // key 必须覆盖所有影响该气泡渲染的状态：@State 换数组后 key 不变则 ListItem 被复用、UI 不刷新
        if (bubble.role === 'assistant' && bubble.streaming) {
          let sig: string = '';
          for (let i = 0; i < this.liveActivities.length; i++) {
            sig += this.liveActivities[i].state;
          }
          return `bubble-${index}-assistant-s-${sig}-${this.streamingText.length}`;
        }
        return `bubble-${index}-${bubble.role}-${bubble.streaming ? 's' : 'd'}-${bubble.activities.length}-${bubble.content.length}-${(bubble.images ?? []).length}`;
      });
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 12, right: 12, top: 8 })
    .scrollBar(BarState.Off);
  }

  @Builder
  bubbleView(bubble: ChatBubble, index: number) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Stack() {
          SymbolGlyph(bubble.role === 'user' ? $r('sys.symbol.person') : $r('sys.symbol.wand_and_stars'))
            .fontSize(11)
            .fontColor(bubble.role === 'user' ?
              [$r('app.color.text_secondary')] : [$r('app.color.brand_primary')]);
        }
        .width(20)
        .height(20)
        .borderRadius(10)
        .backgroundColor($r('app.color.page_background'));
        Text(bubble.role === 'user' ? '你' : 'AI')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'));
        Blank();
      }
      .width('100%');

      if (bubble.role === 'user' && (bubble.images ?? []).length > 0) {
        Row({ space: 6 }) {
          ForEach(bubble.images ?? [], (p: string) => {
            Image(`file://${p}`)
              .width(72)
              .height(72)
              .borderRadius(8)
              .objectFit(ImageFit.Cover);
          }, (p: string) => p);
        }
        .width('100%');
      }

      if (bubble.role === 'assistant' && !bubble.error) {
        // 活动时间线：流式气泡挂实时 liveActivities，完成后的气泡挂固化的历史快照
        this.activityView(bubble.streaming ? this.liveActivities : bubble.activities);
        if (bubble.streaming) {
          if (this.streamingText.length > 0) {
            MarkdownText({ content: this.streamingText });
          } else if (this.liveActivities.length === 0) {
            Text('思考中…')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'));
          }
        } else {
          MarkdownText({ content: bubble.content });
        }
      } else {
        Text(bubble.streaming ? (this.streamingText.length > 0 ? this.streamingText : '思考中…') : bubble.content)
          .fontSize(15)
          .lineHeight(23)
          .fontColor(bubble.error ? $r('app.color.error') : $r('app.color.text_primary'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
          .textAlign(TextAlign.Start);
      }

      if (bubble.role === 'assistant' && !bubble.streaming && !bubble.error && bubble.content.length > 0) {
        Row({ space: 12 }) {
          TextButton({ label: '复制', onTap: () => { void this.copyBubble(index); } });
        }
        .width('100%');
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor(bubble.role === 'user' ? $r('app.color.brand_primary_light') : $r('app.color.card_background'))
    .shadow({ radius: 10, type: ShadowType.COLOR, color: $r('app.color.button_shadow'), offsetX: 0, offsetY: 2 });
  }

  /** 工具调用活动区：状态行 + 书目型结果的结构化列表。 */
  @Builder
  activityView(acts: ChatActivity[]) {
    if (acts.length > 0) {
      Column({ space: 8 }) {
        ForEach(acts, (act: ChatActivity, idx: number) => {
          Column({ space: 6 }) {
            Row({ space: 8 }) {
              if (act.state === 'doing') {
                LoadingProgress().width(16).height(16).color($r('app.color.brand_primary'));
              } else {
                Stack() {
                  SymbolGlyph(act.state === 'rejected' ? $r('sys.symbol.xmark') : $r('sys.symbol.checkmark'))
                    .fontSize(9)
                    .fontWeight(FontWeight.Bold)
                    .fontColor([$r('app.color.on_brand')]);
                }
                .width(16)
                .height(16)
                .borderRadius(8)
                .backgroundColor(act.state === 'rejected' ?
                  $r('app.color.error') : $r('app.color.brand_primary'));
              }
              Text(act.state === 'doing' ? `正在${act.label}…` :
                (act.state === 'rejected' ? `已拒绝：${act.label}` :
                  (act.summary.length > 0 ? `${act.label}：${act.summary}` : act.label)))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
            }
            .width('100%');
            if (act.books.length > 0) {
              ToolResultList({ items: act.books });
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%');
        }, (act: ChatActivity, idx: number) => `${idx}-${act.name}-${act.state}-${act.books.length}`);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(10)
      .borderRadius($r('app.float.chip_radius'))
      .backgroundColor($r('app.color.page_background'));
    }
  }

  /** 对话进行中的技能芯片：横向滚动，点击填入输入框（不自动发送）。 */
  @Builder
  skillBar() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(AI_SKILLS, (skill: AiSkill) => {
          Text(skill.label)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor($r('app.color.brand_primary_light'))
            .onClick(() => this.applySkill(skill));
        }, (skill: AiSkill) => skill.label);
      }
      .padding({ left: 12, right: 12, top: 4, bottom: 4 });
    }
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
    .align(Alignment.Start);
  }

  @Builder
  inputBar() {
    Column() {
      if (this.errorTip.length > 0 && this.messages.length > 0) {
        Text(this.errorTip)
          .fontSize(11)
          .fontColor($r('app.color.error'))
          .width('100%')
          .padding({ left: 4, bottom: 6 });
      }
      if (this.pendingImages.length > 0) {
        Row({ space: 8 }) {
          ForEach(this.pendingImages, (p: string, idx: number) => {
            Stack({ alignContent: Alignment.TopEnd }) {
              Image(`file://${p}`)
                .width(56)
                .height(56)
                .borderRadius(8)
                .objectFit(ImageFit.Cover);
              Stack() {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(10)
                  .fontColor([$r('app.color.on_brand')]);
              }
              .width(16)
              .height(16)
              .borderRadius(8)
              .backgroundColor($r('app.color.error'))
              .onClick(() => this.removePending(idx));
            }
            .width(56)
            .height(56);
          }, (p: string, idx: number) => `${idx}-${p}`);
        }
        .width('100%')
        .padding({ bottom: 8 });
      }
      Row({ space: 10 }) {
        if (this.visionEnabled) {
          Stack() {
            SymbolGlyph($r('sys.symbol.picture'))
              .fontSize(20)
              .fontColor([$r('app.color.text_secondary')]);
          }
          .width(44)
          .height(44)
          .borderRadius(22)
          .backgroundColor($r('app.color.page_background'))
          .onClick(() => {
            void this.pickImage();
          });
        }
        TextInput({ placeholder: this.thinking ? '生成中…' : '输入问题', text: this.input })
          .layoutWeight(1)
          .height(44)
          .borderRadius(22)
          .backgroundColor($r('app.color.page_background'))
          .enabled(!this.thinking)
          .onChange((value: string) => this.input = value)
          .onSubmit(() => { void this.send(this.input); });

        // Circle Button 带图标子节点时 width/height 不生效（实测渲染仅 20vp），改用 Stack 保证 44vp 热区
        Stack() {
          if (this.thinking) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(Color.White);
          } else {
            SymbolGlyph($r('sys.symbol.arrow_up'))
              .fontSize(20)
              .fontColor([Color.White]);
          }
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(this.thinking ? $r('app.color.error') :
          (this.input.trim().length > 0 ? $r('app.color.brand_primary') : $r('app.color.divider')))
        .onClick(() => {
          if (this.thinking) {
            this.stopStreaming();
          } else {
            void this.send(this.input);
          }
        });
      }
      .width('100%');
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    .backgroundColor($r('app.color.card_background'));
  }
}
