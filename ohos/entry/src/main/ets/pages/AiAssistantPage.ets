import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { PageScaffold, SecondaryButton, TextButton } from '../components';
import { MarkdownText } from '../components/MarkdownText';
import { AI_SKILLS, AiSkill } from '../services/AiSkills';
import { ActivityTimeline, AskUserCard, ReasoningBlock, SessionsSheet, StreamBubble } from '../components/AiChatBlocks';
import { AiChatStore, AskRequest, ChatActivity, ChatBubble, ChatSession } from '../services/AiChatStore';
import { appendHeardText, formatDividerTime, shouldShowTimeDivider } from '../services/AiChatModel';
import { AiConfig, AiMessage, AiService } from '../services/AiService';
import { SpeakService } from '../services/SpeakService';
import { AiPermissionMode, AiTools } from '../services/AiTools';
import { RealtimeCallService, RealtimeCallCallbacks } from '../services/RealtimeCallService';
import { AiVoiceKit, VOICE_SYSTEM_PROMPT, VOICE_TOOL_NOTE } from '../services/AiVoiceKit';
import { QwenAudioService } from '../services/QwenAudioService';
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
  /** 会话面板搜索词（#1513）：过滤走 store.searchSessions，命中含标题与消息正文。 */
  @State sessQuery: string = '';
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
  /** 按住说话（#1516）：录音中/识别中/入口可用（ASR 仅云端，语音档位须 Token Plan）。 */
  @State holdRecording: boolean = false;
  @State holdBusy: boolean = false;
  @State holdTalkReady: boolean = false;
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
    this.holdTalkReady = AiService.loadVoiceConfig().providerId === 'qwen-tokenplan';
  }

  aboutToDisappear(): void {
    // 只解绑视图。曾经的 bug：在这里调 stopStreaming，退出对话页即掐断在途流式回复。
    // 但语音会话必须随页结束：麦克风采集/播放不应在后台页继续。
    if (this.voiceActive) {
      this.endVoiceSession();
    }
    if (this.holdRecording) {
      // 退页松开不了手指：直接弃录释放麦克风（与通话页挂断路径同款）
      QwenAudioService.stopRecordingCleanup();
      this.holdRecording = false;
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
        // 工具轮的 response.done 先于结果回填到达：还欠回填（isToolBusy）时不得切回「聆听中」
        if (this.voiceActive && !RealtimeCallService.isToolBusy()) {
          this.voiceStatus = '聆听中';
        }
      },
      onFunctionCall: (name: string, args: string, callId: string): void => {
        void AiVoiceKit.runTool(name, args, callId, this.getUIContext(),
          (label: string, state: string): void => {
            if (!this.voiceActive) {
              return;
            }
            if (state === 'doing') {
              this.voiceStatus = `执行中：${label}…`;
            } else if (this.voiceStatus.indexOf('执行中：') === 0 && !RealtimeCallService.isToolBusy()) {
              // 仍有其它工具在途时保持「执行中」显示，最后一个回填后才收敛
              this.voiceStatus = state === 'rejected' ? '已拒绝' : '思考中';
            }
          });
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

  /** 按住说话·按下（#1516）：授权通过才开录；失败不进录音态（松手会被 guard 吞掉）。 */
  private async holdStart(): Promise<void> {
    if (this.holdRecording || this.holdBusy || this.thinking) {
      return;
    }
    if (!(await AiVoiceKit.ensureMicPermission(this.getUIContext()))) {
      this.toast('请在系统设置中允许麦克风权限后重试');
      return;
    }
    try {
      await QwenAudioService.startRecording();
      this.holdRecording = true;
    } catch (_error) {
      this.toast('无法开始录音，请检查麦克风占用');
    }
  }

  /** 按住说话·松手：wav→ASR→并入输入框（不自动发送，用户可先校对）。 */
  private async holdFinish(): Promise<void> {
    if (!this.holdRecording) {
      return;
    }
    this.holdRecording = false;
    this.holdBusy = true;
    try {
      const wav: string = await QwenAudioService.stopRecording();
      if (wav.length === 0) {
        this.toast('没听到声音，请再试一次');
        return;
      }
      const heard: string = await QwenAudioService.transcribe(wav);
      if (heard.length === 0) {
        this.toast('没有识别到内容');
        return;
      }
      this.input = appendHeardText(this.input, heard);
    } catch (_error) {
      this.toast('语音识别失败，稍后重试');
    } finally {
      this.holdBusy = false;
    }
  }

  /** 输入框占位：按住说话的录音/识别态优先于生成中文案。 */
  private holdPlaceholder(): string {
    if (this.holdRecording) {
      return '聆听中…松手转文字';
    }
    if (this.holdBusy) {
      return '识别中…';
    }
    return this.thinking ? '生成中…' : '输入问题';
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

  /** 本会话累计 token 用量（#1514）：无 usage 的气泡（旧存档/语音轮）按 0 计。 */
  private sessionTokens(): number {
    let n: number = 0;
    for (const b of this.messages) {
      n += b.usage?.total ?? 0;
    }
    return n;
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
    // 分隔条并入 key：上一条被删后本条的分隔状态会变，复用项必须重建才重算
    const divider: string = this.showsTimeDivider(index) ? 't' : '';
    return `bubble-${index}-${bubble.role}-${bubble.streaming ? 's' : 'd'}-${bubble.activities.length}-${bubble.content.length}-${(bubble.images ?? []).length}-${(bubble.reasoning ?? '').length}-${divider}`;
  }

  /** 该气泡上方是否需要时间分隔条（#1509）。 */
  private showsTimeDivider(index: number): boolean {
    const b = this.messages[index];
    if (b === undefined) {
      return false;
    }
    const prev = index > 0 ? this.messages[index - 1] : undefined;
    return shouldShowTimeDivider(prev?.ts ?? 0, b.ts ?? 0);
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

  /**
   * 对话管理面板：当前会话置顶带勾（不可点对比），存档会话点击切换。
   * #1513：搜索过滤、行内改名与导出；生成中拒绝切换/新建（store 返回 false 转提示）。
   */
  @Builder
  sessionsSheetView() {
    SessionsSheet({
      sessions: this.store.searchSessions(this.sessQuery),
      currentTitle: this.store.currentTitle(),
      currentId: this.currentId,
      query: this.sessQuery,
      onPick: (id: string): void => {
        if (!this.store.switchSession(id)) {
          this.toast('生成中，请稍候再切换');
        } else {
          this.sessionsSheet = false;
        }
      },
      onDelete: (id: string): void => this.store.deleteSession(id),
      onNew: (): void => {
        if (!this.store.newSession()) {
          this.toast('生成中，请稍候再新建');
        } else {
          this.sessionsSheet = false;
        }
      },
      onQuery: (kw: string): void => {
        this.sessQuery = kw;
      },
      onRename: (id: string, name: string): void => {
        if (!this.store.renameSession(id, name)) {
          this.toast('重命名失败：标题不能为空');
        }
      },
      onExport: (id: string): void => {
        void this.exportSession(id);
      },
    });
  }

  /** 导出会话为 Markdown（#1513）：系统保存面板选位置，写不进只提示失败不静默。 */
  private async exportSession(id: string): Promise<void> {
    const md: string = this.store.exportSessionMd(id);
    if (md.length === 0) {
      this.toast('这条对话还没有可导出的内容');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const options = new picker.DocumentSaveOptions();
      // SDK 实名：newFileNames 预置文件名、fileSuffixChoices 限定后缀选择
      options.newFileNames = [`${this.safeFileName(this.store.sessionTitleOf(id))}.md`];
      options.fileSuffixChoices = ['.md'];
      const viewPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await viewPicker.save(options);
      if (uris.length === 0) {
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, md);
      } finally {
        fs.closeSync(file);
      }
      this.toast('已导出 Markdown');
    } catch (e) {
      this.toast(`导出失败：${e}`);
    }
  }

  /** 导出文件名净化：文件系统非法字符换空格，限 40 字。 */
  private safeFileName(title: string): string {
    const cleaned: string = title.replace(/[\\/:*?"<>|\r\n]/g, ' ').trim();
    if (cleaned.length === 0) {
      return 'AI对话';
    }
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
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
        AskUserCard({
          question: this.askQuestion(),
          options: this.askOptions(),
          onAnswer: (opt: string): void => this.store.answerAsk(opt),
        });
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
          Column() {
            // 时间分隔条（#1509）：间隔 ≥5min 或首条时显示
            if (this.showsTimeDivider(index)) {
              Text(formatDividerTime(bubble.ts ?? 0))
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ bottom: 2 });
            }
            this.bubbleView(bubble, index);
          }
          .alignItems(HorizontalAlign.Start);
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
            ReasoningBlock({ reasoning: bubble.reasoning ?? '', live: false, thinkMs: bubble.thinkMs ?? 0 });
          }
          ActivityTimeline({ acts: bubble.activities, live: false });
          MarkdownText({ content: bubble.content });
          // token 用量脚注（#1514）：服务商回传 usage 才显示，旧存档/语音轮无感
          if (bubble.usage !== undefined && bubble.usage.total > 0) {
            Text(`已用 ${bubble.usage.total} tokens · 入 ${bubble.usage.prompt} / 出 ${bubble.usage.completion}`)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'));
          }
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

      // 失败轮只给「重试」：截掉该错误条连同其问题原样重发（#1512），不保留半截内容
      if (bubble.error && !bubble.streaming) {
        Row({ space: 12 }) {
          TextButton({
            label: '重试',
            onTap: () => {
              if (!this.store.retryFrom(index)) {
                this.toast('生成中，请稍候');
              }
            },
          });
        }
        .width('100%');
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
          if (this.sessionTokens() > 0) {
            Text(`· 共耗 ${this.sessionTokens()} tokens`)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'));
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
        // 按住说话（#1516）：44vp Stack 自建热区（Button+Circle 宽高失效坑），按下录音松手转文字
        if (this.holdTalkReady && !this.voiceActive) {
          Stack() {
            SymbolGlyph($r('sys.symbol.mic'))
              .fontSize(20)
              .fontColor([this.holdRecording ? Color.White : $r('app.color.text_secondary')]);
          }
          .width(44)
          .height(44)
          .borderRadius(22)
          .backgroundColor(this.holdRecording ? $r('app.color.brand_primary') :
            $r('app.color.page_background'))
          .onTouch((e: TouchEvent): void => {
            if (e.type === TouchType.Down) {
              void this.holdStart();
            } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
              void this.holdFinish();
            }
          });
        }
        // TextArea 随内容自动长高（#1510），44vp 单行起步、5 行封顶后内部滚动；键盘动作键=发送（板上实测语义）
        TextArea({ placeholder: this.holdPlaceholder(), text: this.input })
          .layoutWeight(1)
          .constraintSize({ minHeight: 44, maxHeight: 132 })
          .borderRadius(22)
          .backgroundColor($r('app.color.page_background'))
          .enabled(!this.thinking)
          .fontSize(15)
          .enterKeyType(EnterKeyType.Send)
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
