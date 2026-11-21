import { pasteboard } from '@kit.BasicServicesKit';
import { LengthMetrics, promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { PageScaffold, SecondaryButton, TextButton } from '../components';
import { MarkdownText } from '../components/MarkdownText';
import { AI_SKILLS, AiSkill } from '../services/AiSkills';
import { ToolResultList } from '../components/ToolResultList';
import { AiChatStore, AskRequest, ChatActivity, ChatBubble, ChatSession } from '../services/AiChatStore';
import { ActivityGroup, groupActivities } from '../services/AiChatModel';
import { AiConfig, AiMessage, AiService } from '../services/AiService';
import { SpeakService } from '../services/SpeakService';
import { AiPermissionMode, AiTools } from '../services/AiTools';
import { RealtimeCallService, RealtimeCallCallbacks } from '../services/RealtimeCallService';
import { AiVoiceKit, VOICE_SYSTEM_PROMPT, VOICE_TOOL_NOTE } from '../services/AiVoiceKit';
import { AppRouter } from '../utils/AppRouter';
import { webview } from '@kit.ArkWeb';
import { BrowserRenderService } from '../services/BrowserRenderService';

/** 技能卡片/芯片点击：把现成提示词填入输入框，用户可先补书名再发送。 */

@Entry
@Component
struct AiAssistantPage {
  // fetch_url 降级通道的隐藏 ArkWeb 控制器（就绪后移交 BrowserRenderService）
  private renderCtrl: webview.WebviewController = new webview.WebviewController();
  // —— 以下都是 store 状态的页面镜像：store 每次变化经 onStoreChange 拉齐 ——
  @State messages: ChatBubble[] = [];
  @State input: string = '';
  @State thinking: boolean = false;
  @State configured: boolean = false;
  @State errorTip: string = '';
  /** 待发送图片（沙箱路径，属输入草稿），输入框上方预览、可删。 */
  @State pendingImages: string[] = [];
  @State visionEnabled: boolean = false;
  @State contextK: number = 8;
  /** 权限模式镜像（顶栏徽标显示 + bindMenu 勾选当前项）。 */
  @State permission: AiPermissionMode = 'confirm';
  /** 流式输出用：整段重建列表的代价高，这里只改最后一条气泡的内容。 */
  @State streamingText: string = '';
  /** Token Plan TTS 可用性与自动播报（进页/回页刷新，避免渲染中读磁盘）。 */
  @State ttsAvailable: boolean = false;
  @State autoSpeak: boolean = false;
  /** 正在播报的消息下标；-1 无。 */
  @State speakingIndex: number = -1;
  /** 工具回路实时活动时间线；finishBubble 时快照进气泡成为历史。 */
  @State liveActivities: ChatActivity[] = [];
  /** ask_user 在途反问卡片（store.pendingAsk 镜像）；null=无。 */
  @State pendingAsk: AskRequest | null = null;
  /** 存档会话列表与当前会话 id（store 镜像），供「对话」面板渲染。 */
  @State sessions: ChatSession[] = [];
  @State currentId: string = '';
  /** 对话管理半模态面板开关（页面局部态）。 */
  @State sessionsSheet: boolean = false;
  /** 顶栏模型快切（只改全局配置的 model 字段）：当前模型 id + 服务商模型列表。 */
  @State currentModel: string = '';
  @State modelChoices: string[] = [];
  /** 流式中的思考过程（store.streamingReasoning 镜像）。 */
  @State streamingReasoning: string = '';
  /** realtime 全双工语音会话（内嵌本页）：活跃标记 / 状态文案 / 静音。 */
  @State voiceActive: boolean = false;
  @State voiceStatus: string = '';
  @State voiceMuted: boolean = false;
  /** 语音会话代际：挂断/重开后，旧 connect 异步链的失败回调凭序号作废。 */
  private voiceGen: number = 0;
  /** 会话状态机在全局单例里：退出页面不中断流式回复，后台照常完成并落盘。 */
  private store: AiChatStore = AiChatStore.instance();
  /** attachView 凭据：disappear 只解绑自己这一份视图。 */
  private viewToken: number = -1;
  private scroller: Scroller = new Scroller();
  /** scrollToEnd 合并标记：在途未执行的滚动延后一个窗口，防流式期逐 token 抢滚。 */
  private scrollPending: boolean = false;
  /** 智能跟滚（#1506）：用户上滑读历史时置 false，流式增量不再抢滚；回底/发新消息恢复。 */
  @State followBottom: boolean = true;
  private touchLastY: number = 0;
  /** 「讨论本书」横幅文案（#1508）：阅读器跳转注入，空=无书籍上下文。 */
  @State bookTag: string = '';

  aboutToAppear(): void {
    this.store.refreshSettings();
    this.store.ensureLoaded();
    this.acceptBookParams();
    this.viewToken = this.store.attachView(
      (): void => this.syncFromStore(),
      (label: string, args: string): Promise<boolean> => this.requestConfirm(label, args));
    this.syncFromStore();
    this.loadModelState();
  }

  onPageShow(): void {
    this.store.refreshSettings();
    this.loadVoiceState();
    this.loadModelState();
    this.syncFromStore();
  }

  /**
   * 模型快切态：currentModel 始终跟随全局配置（设置页改完返回即同步）；
   * 本地常用模型清单（设置页维护）优先，未维护时静默拉一次服务商列表，
   * 失败不打扰——菜单里给「重新获取」出口。
   */
  private loadModelState(): void {
    const cfg: AiConfig = AiService.loadConfig();
    this.currentModel = cfg.model;
    if (cfg.baseUrl.length === 0) {
      return;
    }
    const local: string[] = AiService.loadProviderModels(cfg.providerId);
    if (local.length > 0) {
      this.modelChoices = local;
      return;
    }
    if (this.modelChoices.length > 0) {
      return;
    }
    this.refreshModels();
  }

  /** 绕过本地清单直接拉服务端全量列表（菜单「重新获取」出口）。 */
  private refreshModels(): void {
    const cfg: AiConfig = AiService.loadConfig();
    if (cfg.baseUrl.length === 0) {
      return;
    }
    AiService.fetchModels(cfg.providerId, cfg.baseUrl, '').then((ids: string[]): void => {
      this.modelChoices = ids.length > 40 ? ids.slice(0, 40) : ids;
    }).catch((): void => {
      // 服务商无 models 端点/限流等：菜单退化为重试项
    });
  }

  /** 徽标短标签：模型名截 14 字符，未配置回「模型」。 */
  private modelChipLabel(): string {
    const m: string = this.currentModel;
    if (m.length === 0) {
      return '模型';
    }
    return m.length > 14 ? `${m.substring(0, 14)}…` : m;
  }

  private modelMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const id of this.modelChoices) {
      const item: MenuElement = {
        value: id,
        action: () => this.pickModel(id),
      };
      if (id === this.currentModel) {
        item.symbolIcon = new SymbolGlyphModifier($r('sys.symbol.checkmark'))
          .fontColor([$r('app.color.brand_primary')]);
      }
      items.push(item);
    }
    if (items.length === 0) {
      items.push({
        value: '获取模型列表（可重试）',
        action: (): void => {
          this.loadModelState();
        },
      });
    } else {
      items.push({
        value: '重新获取模型列表',
        action: (): void => {
          this.refreshModels();
        },
      });
    }
    return items;
  }

  /** 部分保存：只换 model（apiKey 传空不覆盖已存 Key），下一条消息起生效。 */
  private pickModel(id: string): void {
    if (id === this.currentModel) {
      return;
    }
    const cfg: AiConfig = AiService.loadConfig();
    AiService.saveConfig(cfg.providerId, cfg.baseUrl, id, '', cfg.temperature,
      cfg.visionOverride, cfg.contextLength);
    this.currentModel = id;
    this.toast(`已切换模型 ${id}，下一条消息生效`);
  }

  /** 播报可用性：系统引擎档始终可用（失败时按钮里报错）；云端档仅语音档位为 Token Plan 服务商。 */
  private loadVoiceState(): void {
    this.autoSpeak = AiService.loadAutoSpeak();
    this.ttsAvailable = AiService.loadSpeakEngine() === 'system' ||
      AiService.loadVoiceConfig().providerId === 'qwen-tokenplan';
  }

  aboutToDisappear(): void {
    // 只解绑视图。曾经的 bug：在这里调 stopStreaming，退出对话页即掐断在途流式回复。
    // 但语音会话必须随页结束：麦克风采集/播放不应在后台页继续。
    if (this.voiceActive) {
      this.endVoiceSession();
    }
    this.store.detachView(this.viewToken);
    BrowserRenderService.detach();
  }

  /** store 状态变化回调：拉齐页面镜像（attachView 时注册）。 */
  private requestConfirm(label: string, args: string): Promise<boolean> {
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
  }

  /** 把 store 状态机拉到本页面 @State 镜像；渲染只读镜像，不直接碰单例。 */
  private syncFromStore(): void {
    this.messages = this.store.messages.slice();
    this.streamingText = this.store.streamingText;
    this.streamingReasoning = this.store.streamingReasoning;
    this.liveActivities = this.store.liveActivities.slice();
    this.pendingAsk = this.store.pendingAsk;
    this.sessions = this.store.sessions.slice();
    this.currentId = this.store.currentId;
    this.thinking = this.store.thinking;
    this.errorTip = this.store.errorTip;
    this.configured = this.store.configured;
    this.visionEnabled = this.store.visionEnabled;
    this.contextK = this.store.contextK;
    this.permission = AiService.loadPermission();
    // 智能跟滚：用户上滑脱离底部后不再抢滚（#1506），回底/发新消息恢复跟随
    if (this.followBottom) {
      this.scrollToEnd();
    }
  }

  /** 权限模式徽标短文案。 */
  private permissionLabel(): string {
    if (this.permission === 'readonly') {
      return '只读';
    }
    if (this.permission === 'auto') {
      return '自动放行';
    }
    return '逐笔确认';
  }

  private applyPermission(mode: AiPermissionMode): void {
    AiService.savePermission(mode);
    this.permission = mode;
    this.toast(`已切换为「${this.permissionLabel()}」模式`);
  }

  /** 权限模式菜单：当前项带勾（MenuElement[] 形式，理由同 BookshelfPage.sortMenuItems）。 */
  private permissionMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    const options: Array<[AiPermissionMode, string]> = [
      ['readonly', '只读（仅查询，不能改数据）'],
      ['confirm', '逐笔确认（写操作逐个批准）'],
      ['auto', '自动放行（写操作直接执行）'],
    ];
    for (const option of options) {
      const mode: AiPermissionMode = option[0];
      const item: MenuElement = {
        value: option[1],
        action: () => this.applyPermission(mode),
      };
      if (mode === this.permission) {
        item.symbolIcon = new SymbolGlyphModifier($r('sys.symbol.checkmark'))
          .fontColor([$r('app.color.brand_primary')]);
      }
      items.push(item);
    }
    return items;
  }

  /** 输入条「停止」按钮：用户主动中断，与切页无关。 */
  private stopStreaming(): void {
    this.store.stopStreaming();
  }

  // ————— realtime 全双工语音会话（内嵌对话页）：语音内容以消息流实时上屏 —————

  /** 开始语音会话：注入最近文字历史，ASR/AI 字幕直接写进消息流；再点=挂断。 */
  private async startVoiceSession(): Promise<void> {
    if (this.voiceActive) {
      this.endVoiceSession();
      return;
    }
    if (this.thinking) {
      promptAction.showToast({ message: '文字回复生成中，先停止再发起语音会话' });
      return;
    }
    if (!await AiVoiceKit.ensureMicPermission(this.getUIContext())) {
      promptAction.showToast({ message: '需要麦克风权限才能语音对话' });
      return;
    }
    // 最近 8 条定稿文字进语音上下文，AI 接得上此前的对话
    const history: AiMessage[] = [];
    const bubbles: ChatBubble[] = this.store.messages;
    for (let i = Math.max(0, bubbles.length - 8); i < bubbles.length; i++) {
      const b: ChatBubble = bubbles[i];
      if (!b.streaming && !b.error && b.content.length > 0 &&
        (b.role === 'user' || b.role === 'assistant')) {
        history.push({ role: b.role, content: b.content });
      }
    }
    const cb: RealtimeCallCallbacks = {
      onUserText: (t: string): void => {
        this.store.voiceUser(t, true);
      },
      onUserTextDelta: (t: string): void => {
        this.store.voiceUser(t, false);
      },
      onAiTextDelta: (d: string): void => {
        this.store.voiceAi(d, false);
      },
      onAiTextDone: (t: string): void => {
        this.store.voiceAi(t, true);
      },
      onSpeechStarted: (): void => {
        // 开口打断：AI 已出的字幕固化，切回聆听
        this.store.voiceSealStreaming();
        this.voiceStatus = '聆听中';
      },
      onSpeechStopped: (): void => {
        this.voiceStatus = '思考中';
      },
      onResponding: (): void => {
        this.voiceStatus = '说话中';
      },
      onResponseDone: (): void => {
        if (this.voiceActive) {
          this.voiceStatus = '聆听中';
        }
      },
      onFunctionCall: (name: string, args: string, callId: string): void => {
        void AiVoiceKit.runTool(name, args, callId, this.getUIContext());
      },
      onError: (m: string): void => {
        promptAction.showToast({ message: m });
      },
      onClosed: (): void => {
        // 网关/网络断线：会话态收敛，尾部流式气泡固化
        this.voiceActive = false;
        this.voiceStatus = '';
        this.store.voiceSealStreaming();
      },
    };
    const gen: number = ++this.voiceGen;
    this.voiceActive = true;
    this.voiceStatus = '连接中…';
    this.voiceMuted = false;
    // set_voice 生效通道：AI 换音色后存配置→挂断重开（历史从消息流重建，新音色进首包）
    AiVoiceKit.voiceSwitcher = (): void => {
      this.endVoiceSession();
      void this.startVoiceSession();
    };
    try {
      // 与文字回路同源：MCP 动态工具一并注入语音工具面（非 Token Plan/失败=空集）
      const mcpTools = await AiService.mcpToolset();
      await RealtimeCallService.connect(VOICE_SYSTEM_PROMPT + VOICE_TOOL_NOTE, cb,
        AiTools.realtimeDefinitions(AiService.loadPermission(), mcpTools), history);
      if (gen === this.voiceGen && this.voiceActive) {
        this.voiceStatus = '聆听中';
      }
    } catch (error) {
      if (gen === this.voiceGen) {
        this.voiceActive = false;
        this.voiceStatus = '';
        promptAction.showToast({ message: error instanceof Error ? error.message : '语音会话连接失败' });
      }
    }
  }

  /** 挂断：主动断开（disconnect 不再触发 onClosed），态就地复位，旧连接失败回调作废。 */
  private endVoiceSession(): void {
    this.voiceGen++;
    AiVoiceKit.voiceSwitcher = null;
    RealtimeCallService.disconnect();
    this.voiceActive = false;
    this.voiceStatus = '';
    this.voiceMuted = false;
    this.store.voiceSealStreaming();
  }

  private toggleVoiceMute(): void {
    this.voiceMuted = !this.voiceMuted;
    RealtimeCallService.setMuted(this.voiceMuted);
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

  private async send(text: string): Promise<void> {
    let images: string[] = [];
    if (this.store.canSend(text)) {
      // 确定会开流才清草稿（时序与改造前一致）；权威判定在 store，两处条件必须一致
      images = this.pendingImages;
      this.pendingImages = [];
      this.input = '';
      // 新消息发出必回「跟随最新」，即便用户此前在上滑读历史
      this.followBottom = true;
    }
    await this.store.send(text, images);
    // store.send 在流结束落盘后才返回，末条即 AI 回复；开关打开则自动播报
    if (this.autoSpeak && this.ttsAvailable) {
      void this.speakBubble(this.messages.length - 1);
    }
  }

  private scrollToEnd(): void {
    // 布局未完成时 scrollEdge 会静默失败，延后一帧即可；
    // 流式期 syncFromStore 高频调用，此处合并定时器——一帧窗口内只滚一次，避免逐 token 抽动
    if (this.scrollPending) {
      return;
    }
    this.scrollPending = true;
    setTimeout(() => {
      this.scrollPending = false;
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (_error) {
        // 列表尚未挂载时忽略
      }
    }, 60);
  }

  /**
   * 跟滚意图判定（#1506）：只认手指触控，程序 scrollEdge 不触发 onTouch。
   * 手指明确下滑（内容上移露历史）→ 脱离跟随；回底由 onListScrollStop / 浮钮恢复。
   */
  private onListTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    const y: number = event.touches[0].y;
    if (event.type === TouchType.Down) {
      this.touchLastY = y;
      return;
    }
    if (event.type === TouchType.Move && y - this.touchLastY > 24) {
      this.followBottom = false;
    }
    if (event.type === TouchType.Move) {
      this.touchLastY = y;
    }
  }

  /** 滚动停稳：视图已在底缘即恢复跟随（用户手动滑回底部的情形）。 */
  private onListScrollStop(): void {
    try {
      if (this.scroller.isAtEnd()) {
        this.followBottom = true;
      }
    } catch (_error) {
      // 列表尚未挂载时忽略
    }
  }

  /** 「回到底部」浮钮：立即恢复跟随并滚动。 */
  private backToBottom(): void {
    this.followBottom = true;
    this.scrollToEnd();
  }

  /** 讨论本书（#1508）：阅读器跳转带参时注入书籍上下文并亮横幅；普通进入无参=静默跳过。 */
  private acceptBookParams(): void {
    const params = AppRouter.getParams(this.getUIContext()) as Record<string, Object> | null;
    const title: string = String(params?.['bookTitle'] ?? '');
    if (title.length === 0) {
      return;
    }
    this.store.setBookContext(title, String(params?.['bookAuthor'] ?? ''), String(params?.['chapter'] ?? ''));
    this.bookTag = `讨论《${title}》`;
  }

  /** 横幅关闭：清除本轮书籍上下文（对话内容保留）。 */
  private leaveBookContext(): void {
    this.store.clearBookContext();
    this.bookTag = '';
  }

  private applySkill(skill: AiSkill): void {
    this.input = skill.prompt;
  }

  private removePending(index: number): void {
    const next: string[] = this.pendingImages.slice();
    next.splice(index, 1);
    this.pendingImages = next;
  }

  private clearChat(): void {
    this.store.clearChat();
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

  /** 播报/停止播报某条回复；再点当前播报项=打断。 */
  private async speakBubble(index: number): Promise<void> {
    if (index < 0 || index >= this.messages.length) {
      return;
    }
    if (this.speakingIndex === index) {
      SpeakService.stop();
      this.speakingIndex = -1;
      return;
    }
    SpeakService.stop();
    this.speakingIndex = index;
    try {
      await SpeakService.speak(this.messages[index].content);
    } catch (error) {
      this.toast(`播报失败：${error}`);
    } finally {
      if (this.speakingIndex === index) {
        this.speakingIndex = -1;
      }
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  // key 必须覆盖所有影响该气泡渲染的状态：@State 换数组后 key 不变则 ListItem 被复用、UI 不刷新。
  // 例外：文字流式气泡 key 恒定——它的内容由 StreamBubble 自订阅 store 增量更新（组件内 @State→@Prop
  // 链路不依赖 key 重建）；旧写法把长度并进 key，等于把同一段文字反复销毁重挂（重复渲染/闪烁来源）。
  private bubbleKey(bubble: ChatBubble, index: number): string {
    if (bubble.role === 'assistant' && bubble.streaming && !bubble.error && bubble.voice !== true) {
      return `bubble-${index}-assistant-s`;
    }
    return `bubble-${index}-${bubble.role}-${bubble.streaming ? 's' : 'd'}-${bubble.activities.length}-${bubble.content.length}-${(bubble.images ?? []).length}-${(bubble.reasoning ?? '').length}`;
  }

  /**
   * 长按菜单选项（纯逻辑，可离线回归）：流式气泡不提供任何操作；
   * 编辑重发只对用户气泡且非生成中；重新生成与底部按钮同规则（仅最新一条回答）。
   */
  private bubbleMenuKinds(bubble: ChatBubble, index: number): string[] {
    if (bubble.streaming) {
      return [];
    }
    const kinds: string[] = ['copy'];
    if (bubble.role === 'user' && !this.thinking) {
      kinds.push('edit');
    }
    kinds.push('delete');
    if (bubble.role === 'assistant' && !bubble.error && bubble.voice !== true
      && index === this.messages.length - 1 && !this.thinking) {
      kinds.push('regen');
    }
    return kinds;
  }

  private menuLabel(kind: string): string {
    if (kind === 'edit') {
      return '编辑重发';
    }
    if (kind === 'delete') {
      return '删除';
    }
    if (kind === 'regen') {
      return '重新生成';
    }
    return '复制';
  }

  /** 权威拦截在 store（生成中/流式气泡守卫），这里只管回填与提示。 */
  private runMenuAction(kind: string, index: number): void {
    if (kind === 'copy') {
      void this.copyBubble(index);
      return;
    }
    if (kind === 'delete') {
      this.store.deleteBubble(index);
      return;
    }
    if (kind === 'edit') {
      const text = this.store.editResend(index);
      if (text.length > 0) {
        this.input = text;
      }
      return;
    }
    if (kind === 'regen' && !this.store.regenerate()) {
      this.toast('生成中，请稍候');
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
      // 隐藏渲染器（类浏览器）：fetch_url 遇 JS 空壳/反爬页时的降级提取通道。
      // 1vp 全透明但保持渲染（Visibility.None 会停 JS），controller 经 onControllerAttached 交给服务。
      Web({ src: 'about:blank', controller: this.renderCtrl })
        .width(1)
        .height(1)
        .opacity(0)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(false)
        .onControllerAttached((): void => {
          BrowserRenderService.attach(this.renderCtrl);
        })
        .onPageEnd((): void => {
          BrowserRenderService.onPageEnd();
        })
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.sessionsSheet, this.sessionsSheetView(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: '对话管理' },
    });
  }

  @Builder
  headerAction() {
    Row({ space: 4 }) {
      TextButton({
        label: '语音',
        onTap: () => {
          // 互斥：进全屏通话页前先挂断本页内嵌会话（realtime 单会话）
          if (this.voiceActive) {
            this.endVoiceSession();
          }
          AppRouter.pushUrl(this.getUIContext(), { url: 'pages/AiVoiceCallPage' });
        },
      });
      // 权限模式徽标：点击弹三档菜单，当前项带勾
      Text(`权限·${this.permissionLabel()}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius($r('app.float.chip_radius'))
        .border({ width: 1, color: $r('app.color.divider') })
        .bindMenu(this.permissionMenuItems())
      // 模型快切徽标：点击弹当前服务商模型列表，选中即改全局配置（与设置页同源）
      Text(this.modelChipLabel())
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius($r('app.float.chip_radius'))
        .border({ width: 1, color: $r('app.color.divider') })
        .bindMenu(this.modelMenuItems())
      TextButton({
        label: '设置',
        onTap: () => AppRouter.pushUrl(this.getUIContext(), { url: 'pages/AiSettingsPage' }),
      });
      // 对话管理入口：半模态面板列出存档会话（切换/删除/新建）
      Text('对话')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius($r('app.float.chip_radius'))
        .border({ width: 1, color: $r('app.color.divider') })
        .onClick(() => this.sessionsSheet = true);
      if (this.messages.length > 0) {
        TextButton({ label: '清空', onTap: () => this.clearChat() });
      }
    }
  }

  /** 会话行的相对时间短标（今天显时分，否则显月日）。 */
  private sessionTime(ts: number): string {
    const d: Date = new Date(ts);
    const now: Date = new Date();
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth()
      && d.getDate() === now.getDate()) {
      const hh: string = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
      const mm: string = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
      return `${hh}:${mm}`;
    }
    return `${d.getMonth() + 1}/${d.getDate()}`;
  }

  /**
   * 对话管理面板：当前会话置顶带勾（不可点对比），存档会话点击切换、X 删除。
   * 生成中一律拒绝切换/新建/删除当前内容相关操作（store 返回 false 转提示）。
   */
  @Builder
  sessionsSheetView() {
    Column() {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(14)
            .fontColor([$r('app.color.brand_primary')]);
          Text(this.store.currentTitle())
            .fontSize(14)
            .fontColor($r('app.color.brand_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
          Text('当前')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'));
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 10, bottom: 10 });

        if (this.sessions.length === 0) {
          Text('没有其它对话：切换话题时点「新建对话」，当前对话会完整存档')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .padding(10)
            .width('100%');
        }
        ForEach(this.sessions, (s: ChatSession) => {
          Row({ space: 8 }) {
            Text(s.title)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
            Text(this.sessionTime(s.updatedAt))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'));
            Stack() {
              SymbolGlyph($r('sys.symbol.trash'))
                .fontSize(14)
                .fontColor([$r('app.color.text_secondary')]);
            }
            .width(28)
            .height(28)
            .borderRadius(14)
            .backgroundColor($r('app.color.page_background'))
            .onClick(() => this.store.deleteSession(s.id));
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 10, bottom: 10 })
          .onClick(() => {
            if (!this.store.switchSession(s.id)) {
              this.toast('生成中，请稍候再切换');
            } else {
              this.sessionsSheet = false;
            }
          });
        }, (s: ChatSession) => s.id);
      }
      .width('100%');

      TextButton({
        label: '＋ 新建对话',
        onTap: () => {
          if (!this.store.newSession()) {
            this.toast('生成中，请稍候再新建');
          } else {
            this.sessionsSheet = false;
          }
        },
      });
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 16 });
  }

  @Builder
  pageContent() {
    Column() {
      if (this.bookTag.length > 0) {
        this.bookBannerBar();
      }
      if (!this.configured) {
        this.notConfigured();
      } else if (this.messages.length === 0) {
        this.emptyState();
      } else {
        Stack({ alignContent: Alignment.Bottom }) {
          this.chatList();
          if (!this.followBottom) {
            this.bottomPill();
          }
        }
        .layoutWeight(1)
        .width('100%');
        this.skillBar();
      }
      if (this.pendingAsk !== null) {
        this.askCard();
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
      }, (bubble: ChatBubble, index: number): string => this.bubbleKey(bubble, index));
    }
    .height('100%')
    .width('100%')
    .padding({ left: 12, right: 12, top: 8 })
    .scrollBar(BarState.Off)
    .onTouch((event: TouchEvent): void => {
      this.onListTouch(event);
    })
    .onScrollStop((): void => {
      this.onListScrollStop();
    });
  }

  /** 流式期用户上滑离底时的「回到底部」胶囊（#1506）。 */
  @Builder
  bottomPill() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(14)
        .fontColor([$r('app.color.brand_primary')]);
      Text('回到底部')
        .fontSize(13)
        .fontColor($r('app.color.text_primary'));
    }
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .borderRadius(18)
    .backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 8, type: ShadowType.COLOR, color: $r('app.color.button_shadow'), offsetX: 0, offsetY: 2 })
    .margin({ bottom: 12 })
    .onClick((): void => {
      this.backToBottom();
    });
  }

  /** 「讨论本书」横幅（#1508）：提示 AI 已带书籍上下文，X 清除。 */
  @Builder
  bookBannerBar() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.wand_and_stars'))
        .fontSize(14)
        .fontColor([$r('app.color.brand_primary')]);
      Text(this.bookTag)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1);
      SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
        .fontSize(16)
        .fontColor([$r('app.color.text_tertiary')])
        .onClick((): void => {
          this.leaveBookContext();
        });
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 6, bottom: 6 })
    .backgroundColor($r('app.color.brand_primary_light'))
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
        // 语音轮次角标：mic=用户口述，waveform=AI 语音字幕（与文字轮区分）
        if (bubble.voice === true) {
          SymbolGlyph(bubble.role === 'user' ? $r('sys.symbol.mic') : $r('sys.symbol.waveform'))
            .fontSize(11)
            .fontColor([$r('app.color.brand_primary')]);
        }
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

      if (bubble.role === 'assistant' && !bubble.error && bubble.voice === true) {
        // 语音 AI 气泡：字幕增量直接累计在 bubble.content，不走文字轮镜像/思考/活动时间线
        MarkdownText({ content: bubble.content });
      } else if (bubble.role === 'assistant' && !bubble.error) {
        if (bubble.streaming) {
          // 流式气泡：自订阅 store 增量的独立组件，key 恒定整轮零重建（见 StreamBubble）
          StreamBubble();
        } else {
          if ((bubble.reasoning ?? '').length > 0) {
            ReasoningBlock({ reasoning: bubble.reasoning ?? '', live: false });
          }
          ActivityTimeline({ acts: bubble.activities, live: false });
          MarkdownText({ content: bubble.content });
        }
      } else {
        // 语音用户气泡的 ASR 中间结果也在 bubble.content，不能走文字轮 streamingText 镜像
        Text(bubble.streaming && bubble.voice !== true ? (this.streamingText.length > 0 ? this.streamingText : '思考中…') : bubble.content)
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
          if (index === this.messages.length - 1 && !this.thinking && bubble.voice !== true) {
            // 重新生成只挂在最新一条回答上：重发最后一条用户消息、原位替换答案（语音轮不走文字重生成）
            TextButton({
              label: '重新生成',
              onTap: () => {
                if (!this.store.regenerate()) {
                  this.toast('生成中，请稍候');
                }
              },
            });
          }
          if (this.ttsAvailable) {
            TextButton({
              label: this.speakingIndex === index ? '停止播报' : '播报',
              onTap: () => {
                void this.speakBubble(index);
              },
            });
          }
        }
        .width('100%');
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor(bubble.role === 'user' ? $r('app.color.brand_primary_light') : $r('app.color.card_background'))
    .shadow({ radius: 10, type: ShadowType.COLOR, color: $r('app.color.button_shadow'), offsetX: 0, offsetY: 2 })
    .bindContextMenu(this.bubbleMenu(bubble, index), ResponseType.LongPress);
  }

  /** 气泡长按菜单（#1507）：选项由 bubbleMenuKinds 按气泡状态生成，流式期空数组=不响应。 */
  @Builder
  bubbleMenu(bubble: ChatBubble, index: number) {
    Menu() {
      ForEach(this.bubbleMenuKinds(bubble, index), (kind: string) => {
        MenuItem({ content: this.menuLabel(kind) })
          .onClick(() => {
            this.runMenuAction(kind, index);
          });
      }, (kind: string): string => kind);
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

  /** 反问问题文案（pendingAsk 镜像解引用，@Builder 内不做局部变量）。 */
  private askQuestion(): string {
    const ask: AskRequest | null = this.pendingAsk;
    return ask === null ? '' : ask.question;
  }

  private askOptions(): string[] {
    const ask: AskRequest | null = this.pendingAsk;
    return ask === null ? [] : ask.options;
  }

  /**
   * ask_user 反问卡片：AI 需要用户拍板时挂在输入条上方，点选项即把答复归还回路续跑。
   * 视图解绑/停止键都会在 store 侧按跳过收敛，卡片不会残留成死按钮。
   */
  @Builder
  askCard() {
    Column({ space: 10 }) {
      Text(this.askQuestion())
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        ForEach(this.askOptions(), (opt: string) => {
          Text(opt)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(14)
            .backgroundColor($r('app.color.brand_primary_light'))
            .onClick(() => this.store.answerAsk(opt));
        }, (opt: string) => opt);
        Text('跳过')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(14)
          .border({ width: 1, color: $r('app.color.divider') })
          .onClick(() => this.store.answerAsk(''));
      }
      .width('100%');
    }
    .width('100%')
    .padding(14)
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 8, type: ShadowType.COLOR, color: $r('app.color.button_shadow'), offsetX: 0, offsetY: 2 })
    .alignItems(HorizontalAlign.Start)
    .margin({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), bottom: 8 });
  }

  /** 语音状态点配色：聆听=红（收音中）、思考=黄、说话=品牌色、其余（连接中等）=灰。 */
  private voiceStatusDot(): ResourceColor {
    if (this.voiceStatus === '聆听中') {
      return $r('app.color.error');
    }
    if (this.voiceStatus === '思考中') {
      return $r('app.color.warning');
    }
    if (this.voiceStatus === '说话中') {
      return $r('app.color.brand_primary');
    }
    return $r('app.color.text_tertiary');
  }

  /** 语音会话横幅：活跃期替换输入行——状态卡（配色状态点 + 双行状态）+ 静音/挂断图标按钮。 */
  @Builder
  voiceBanner() {
    Row({ space: 10 }) {
      Circle()
        .width(10)
        .height(10)
        .fill(this.voiceStatusDot());
      Column({ space: 1 }) {
        Text('实时语音')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
        Text(this.voiceStatus.length > 0 ? this.voiceStatus : '连接中…')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
      // 44vp Stack 自建热区（Circle Button 热区失效坑）
      Stack() {
        SymbolGlyph(this.voiceMuted ? $r('sys.symbol.mic_slash') : $r('sys.symbol.mic'))
          .fontSize(20)
          .fontColor([this.voiceMuted ? $r('app.color.text_tertiary') : $r('app.color.brand_primary')]);
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .backgroundColor($r('app.color.card_background'))
      .onClick(() => {
        this.toggleVoiceMute();
      });
      Stack() {
        SymbolGlyph($r('sys.symbol.phone_down_fill'))
          .fontSize(20)
          .fontColor([Color.White]);
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .backgroundColor($r('app.color.error'))
      .onClick(() => {
        this.endVoiceSession();
      });
    }
    .width('100%')
    .padding({ left: 14, right: 8, top: 9, bottom: 9 })
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.brand_primary_light'))
    .alignItems(VerticalAlign.Center);
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
      // 上下文占用指示：下次请求实际携带的历史量对照档位；摘要生效时一并标注
      if (this.store.contextUsageK() > 0) {
        Row({ space: 6 }) {
          Text(`上下文 ≈${(this.store.contextUsageK() / 10).toFixed(1)}k / ${this.contextK}k`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'));
          if (this.store.summaryNote().length > 0) {
            Text(`· ${this.store.summaryNote()}`)
              .fontSize(11)
              .fontColor($r('app.color.brand_primary'));
          }
        }
        .width('100%')
        .padding({ left: 4, bottom: 4 });
      }
      if (this.voiceActive) {
        this.voiceBanner()
      } else {
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

        // realtime 语音会话入口：内容实时进消息流，不跳通话页
        Stack() {
          SymbolGlyph($r('sys.symbol.phone'))
            .fontSize(20)
            .fontColor([Color.Black]);
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor($r('app.color.page_background'))
        .onClick(() => {
          void this.startVoiceSession();
        });

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
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    .backgroundColor($r('app.color.card_background'));
  }
}

/** 思考过程块：流式（live）默认展开实时滚动，历史气泡默认折叠，点标题行切换。 */
@Component
struct ReasoningBlock {
  @Prop @Watch('onReasoningChange') reasoning: string = '';
  live: boolean = false;
  @State expanded: boolean = false;
  private bodyScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.expanded = this.live;
    this.scrollLiveBottom();
  }

  onReasoningChange(): void {
    this.scrollLiveBottom();
  }

  private scrollLiveBottom(): void {
    if (!this.live) {
      return;
    }
    // 流式思考走 @Prop 增量更新（气泡不重建），每次变化下一拍贴底=始终露出最新一段
    setTimeout((): void => {
      try {
        this.bodyScroller.scrollEdge(Edge.Bottom);
      } catch (_error) {
        // 组件已随气泡销毁时忽略
      }
    }, 60);
  }

  build() {
    if (this.reasoning.length > 0) {
      Column({ space: 4 }) {
        Row({ space: 4 }) {
          SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(12)
            .fontColor([$r('app.color.text_tertiary')]);
          Text(this.live ? '正在思考' : '思考过程')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'));
        }
        .onClick(() => {
          // 流式期恒展开：气泡随增量重建会把折叠态强行复位，点了也白点，直接禁用避免观感闪烁
          if (!this.live) {
            this.expanded = !this.expanded;
          }
        });
        if (this.expanded) {
          Scroll(this.bodyScroller) {
            Text(this.reasoning)
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))
              .width('100%');
          }
          .constraintSize({ maxHeight: 220 })
          .scrollBar(BarState.Auto)
          .width('100%');
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }
}

/**
 * 工具调用活动区：摘要折叠行 + 展开明细；相邻同名调用合并为一条（×N）。
 * 流式期固定展开且禁用折叠点击——气泡随增量重建，组件内折叠态必被复位（同 ReasoningBlock）。
 * 单步活动默认展开：折叠只对多步有意义。
 */
@Component
struct ActivityTimeline {
  @Prop acts: ChatActivity[] = [];
  live: boolean = false;
  @State expanded: boolean = false;

  aboutToAppear(): void {
    this.expanded = this.live || this.acts.length <= 1;
  }

  private headText(groups: ActivityGroup[]): string {
    for (const g of groups) {
      if (g.state === 'doing') {
        return `执行中：${g.label}…`;
      }
    }
    return `已执行 ${this.acts.length} 步`;
  }

  build() {
    if (this.acts.length > 0) {
      Column({ space: 8 }) {
        Row({ space: 4 }) {
          SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(12)
            .fontColor([$r('app.color.text_tertiary')]);
          Text(this.headText(groupActivities(this.acts)))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        .width('100%')
        .onClick(() => {
          if (!this.live) {
            this.expanded = !this.expanded;
          }
        });
        if (this.expanded) {
          ForEach(groupActivities(this.acts), (g: ActivityGroup, idx: number) => {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                if (g.state === 'doing') {
                  LoadingProgress().width(16).height(16).color($r('app.color.brand_primary'));
                } else {
                  Stack() {
                    SymbolGlyph(g.state === 'rejected' ? $r('sys.symbol.xmark') : $r('sys.symbol.checkmark'))
                      .fontSize(9)
                      .fontWeight(FontWeight.Bold)
                      .fontColor([$r('app.color.on_brand')]);
                  }
                  .width(16)
                  .height(16)
                  .borderRadius(8)
                  .backgroundColor(g.state === 'rejected' ?
                    $r('app.color.error') : $r('app.color.brand_primary'));
                }
                Text(g.state === 'doing' ? `正在${g.label}…` :
                  (g.state === 'rejected' ? `已拒绝：${g.label}` :
                    (g.summary.length > 0 ? `${g.label}：${g.summary}` : g.label)))
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                if (g.count > 1) {
                  Text(`×${g.count}`)
                    .fontSize(11)
                    .fontColor($r('app.color.brand_primary'))
                    .padding({ left: 6, right: 6, top: 1, bottom: 1 });
                }
              }
              .width('100%');
              if (g.books.length > 0) {
                ToolResultList({ items: g.books });
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%');
          }, (g: ActivityGroup, idx: number) => `${idx}-${g.name}-${g.state}-${g.count}-${g.books.length}`);
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(10)
      .borderRadius($r('app.float.chip_radius'))
      .backgroundColor($r('app.color.page_background'));
    }
  }
}

/**
 * 流式文字气泡：自己向 store 订阅增量，打字机期间只更新内容子树。
 * ForEach 里它的 key 恒定（bubbleView 调用处），整轮不重建——避免每次增量
 * 把 markdown 全文重挂、思考/活动区折叠态复位。子组件的流式字段必须 @Prop，
 * 否则本组件 @State 变化传不进已挂载的子组件。
 */
@Component
struct StreamBubble {
  @State text: string = '';
  @State reasoning: string = '';
  @State acts: ChatActivity[] = [];
  private viewToken: number = 0;

  private pull(): void {
    const store = AiChatStore.instance();
    this.text = store.streamingText;
    this.reasoning = store.streamingReasoning;
    this.acts = store.liveActivities.slice();
  }

  aboutToAppear(): void {
    this.viewToken = AiChatStore.instance().attachStreamView((): void => this.pull());
    this.pull();
  }

  aboutToDisappear(): void {
    AiChatStore.instance().detachStreamView(this.viewToken);
  }

  build() {
    // space 与 bubbleView 外层一致（6），避免流式→固化瞬间子项间距跳动
    Column({ space: 6 }) {
      ReasoningBlock({ reasoning: this.reasoning, live: true });
      ActivityTimeline({ acts: this.acts, live: true });
      if (this.text.length > 0) {
        MarkdownText({ content: this.text });
      } else if (this.acts.length === 0) {
        Text('思考中…')
          .fontSize(15)
          .fontColor($r('app.color.text_secondary'));
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
