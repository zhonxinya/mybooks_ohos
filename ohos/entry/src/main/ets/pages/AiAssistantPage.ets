import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { PageScaffold, SecondaryButton, TextButton } from '../components';
import { MarkdownText } from '../components/MarkdownText';
import { AI_SKILLS, AiSkill } from '../services/AiSkills';
import { parseToolBookLines, ToolBookLine } from '../services/AiTools';
import { ToolResultList } from '../components/ToolResultList';
import { AiService, AiMessage, AiStreamHandlers, AiAbortHandle } from '../services/AiService';
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
}

/** 技能卡片/芯片点击：把现成提示词填入输入框，用户可先补书名再发送。 */

const SYSTEM_PROMPT: string =
  '你是一个电子书阅读应用的助手，回答简洁、准确、中文优先。' +
  '只读工具查询真实数据：search_books（搜书架）、book_detail（书籍详情，需 id）、' +
  'book_notes（该书标注，需 id）、reading_history（最近阅读记录）、' +
  'search_sonovel（搜网络小说书源）、list_download_tasks（查下载任务）。' +
  '写操作工具：create_booklist（建书单）、add_books_to_booklist（书单加书，id 来自 search_books）、' +
  'add_sonovel_task（加入下载队列，参数来自 search_sonovel）；' +
  '这些操作执行前都会请用户逐笔确认，被拒绝时不要坚持重试，问明原因即可。' +
  '下载工作流：先 search_sonovel 拿 url，再 add_sonovel_task 入队，用 list_download_tasks 报进度，' +
  '成品完成后自动进本地书架可读。' +
  '问题涉及用户的书籍或阅读情况时，先调用工具拿到真实数据再回答，绝不编造；' +
  '工具数据不足时直接说明不确定。';

const MAX_HISTORY_ROUNDS: number = 10;

@Entry
@Component
struct AiAssistantPage {
  @State messages: ChatBubble[] = [];
  @State input: string = '';
  @State thinking: boolean = false;
  @State configured: boolean = false;
  @State errorTip: string = '';
  /** 流式输出用：整段重建列表的代价高，这里只改最后一条气泡的内容。 */
  @State streamingText: string = '';
  /** 工具回路实时活动时间线；finishBubble 时快照进气泡成为历史。 */
  @State liveActivities: ChatActivity[] = [];
  private requestId: number = 0;
  private abort: AiAbortHandle | null = null;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.configured = AiService.isReady();
  }

  onPageShow(): void {
    this.configured = AiService.isReady();
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
    }
    this.streamingText = '';
    this.liveActivities = [];
    this.thinking = false;
  }

  /** 把界面气泡转成协议消息，只带最近 N 轮，避免上下文无限增长。 */
  private buildContext(): AiMessage[] {
    const context: AiMessage[] = [{ role: 'system', content: SYSTEM_PROMPT }];
    const bubbles: ChatBubble[] = this.messages.filter((m: ChatBubble) => !m.error && m.content.length > 0);
    const start: number = Math.max(0, bubbles.length - MAX_HISTORY_ROUNDS * 2);
    for (let i = start; i < bubbles.length; i++) {
      context.push({ role: bubbles[i].role, content: bubbles[i].content });
    }
    return context;
  }

  private send(text: string): void {
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

    this.messages.push({ role: 'user', content: question, streaming: false, error: false, activities: [] });
    this.messages.push({ role: 'assistant', content: '', streaming: true, error: false, activities: [] });
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

    const handle: AiAbortHandle = AiService.chatStream(this.buildContext(), handlers, 2048);
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

  /** 工具开始执行：活动区加一条 doing。整组换数组赋值，保证 @State 刷新。 */
  private beginActivity(name: string, label: string): void {
    const act: ChatActivity = { name: name, label: label, state: 'doing', books: [], summary: '' };
    this.liveActivities = this.liveActivities.concat([act]);
    this.scrollToEnd();
  }

  /** 工具执行完：把最后一条同名 doing 翻成 done/rejected，书目结果转结构化条目。 */
  private endActivity(name: string, label: string, text: string): void {
    const books: ToolBookLine[] = parseToolBookLines(text);
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
        return `bubble-${index}-${bubble.role}-${bubble.streaming ? 's' : 'd'}-${bubble.activities.length}-${bubble.content.length}`;
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
      Row({ space: 10 }) {
        TextInput({ placeholder: this.thinking ? '生成中…' : '输入问题', text: this.input })
          .layoutWeight(1)
          .height(44)
          .borderRadius(22)
          .backgroundColor($r('app.color.page_background'))
          .enabled(!this.thinking)
          .onChange((value: string) => this.input = value)
          .onSubmit(() => this.send(this.input));

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
            this.send(this.input);
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
