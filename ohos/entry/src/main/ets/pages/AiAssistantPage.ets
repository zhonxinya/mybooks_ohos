import { pasteboard } from '@kit.BasicServicesKit';
import { PageScaffold, SecondaryButton, TextButton } from '../components';
import { MarkdownText } from '../components/MarkdownText';
import { AI_SKILLS, AiSkill } from '../services/AiSkills';
import { AiService, AiMessage, AiStreamHandlers, AiAbortHandle } from '../services/AiService';
import { AppRouter } from '../utils/AppRouter';

/** 界面上的消息：与协议层 AiMessage 分开，因为要额外带状态。 */
interface ChatBubble {
  role: string;
  content: string;
  /** 是否正在流式输出（末尾光标用）。 */
  streaming: boolean;
  error: boolean;
}

/** 技能卡片/芯片点击：把现成提示词填入输入框，用户可先补书名再发送。 */

const SYSTEM_PROMPT: string =
  '你是一个电子书阅读应用的助手，回答简洁、准确、中文优先。' +
  '你可以调用只读工具查询用户的真实数据：search_books（搜书架）、book_detail（书籍详情，需 id）、' +
  'book_notes（该书标注，需 id）、reading_history（最近阅读记录）。' +
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
  /** 工具回路进行中的人话提示（如「正在调用工具：搜索书架」），替代「思考中…」。 */
  @State toolHint: string = '';
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
      this.messages = this.messages.slice();
    }
    this.streamingText = '';
    this.toolHint = '';
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

    this.messages.push({ role: 'user', content: question, streaming: false, error: false });
    this.messages.push({ role: 'assistant', content: '', streaming: true, error: false });
    this.streamingText = '';
    this.toolHint = '';
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
      onTool: (label: string) => {
        if (requestId === this.requestId && this.thinking) {
          this.toolHint = `正在调用工具：${label}…`;
        }
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
    this.messages = this.messages.slice();
    this.thinking = false;
    this.streamingText = '';
    this.toolHint = '';
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
          Row() {
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
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'))
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
      }, (bubble: ChatBubble, index: number) => `bubble-${index}-${bubble.role}`);
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 12, right: 12, top: 8 })
    .scrollBar(BarState.Off);
  }

  @Builder
  bubbleView(bubble: ChatBubble, index: number) {
    Column({ space: 6 }) {
      Row() {
        Text(bubble.role === 'user' ? '你' : 'AI')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'));
        Blank();
      }
      .width('100%');

      if (bubble.role === 'assistant' && !bubble.error) {
        // AI 回复走轻量 Markdown 渲染；流式期间实时重解析
        if (bubble.streaming && this.streamingText.length === 0) {
          Text(this.toolHint.length > 0 ? this.toolHint : '思考中…')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'));
        } else {
          MarkdownText({ content: bubble.streaming ? this.streamingText : bubble.content });
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
    .backgroundColor(bubble.role === 'user' ? $r('app.color.brand_primary_light') : $r('app.color.card_background'));
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

        if (this.thinking) {
          Button({ type: ButtonType.Circle })
            .width(44)
            .height(44)
            .backgroundColor($r('app.color.error'))
            .onClick(() => this.stopStreaming()) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(20)
                .fontColor([Color.White]);
            }
        } else {
          Button({ type: ButtonType.Circle })
            .width(44)
            .height(44)
            .backgroundColor(this.input.trim().length > 0 ? $r('app.color.brand_primary') : $r('app.color.divider'))
            .onClick(() => this.send(this.input)) {
              SymbolGlyph($r('sys.symbol.arrow_up'))
                .fontSize(20)
                .fontColor([Color.White]);
            }
        }
      }
      .width('100%');
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    .backgroundColor($r('app.color.card_background'));
  }
}
