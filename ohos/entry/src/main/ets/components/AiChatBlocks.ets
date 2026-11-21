import { LengthMetrics } from '@kit.ArkUI';
import { MarkdownText } from './MarkdownText';
import { TextButton } from './TextButton';
import { ToolResultList } from './ToolResultList';
import { ActivityGroup, formatThinkMs, groupActivities } from '../services/AiChatModel';
import { AiChatStore, ChatActivity, ChatSession } from '../services/AiChatStore';
import { ToolBookLine } from '../services/AiToolsDefs';

/**
 * AI 对话页的视图组件集（自 AiAssistantPage 外移，页面只留状态机与装配）。
 * 各组件渲染语义与原页面内版本一致；交互一律回调上抛，页面决定 toast/关面板。
 */

/** 思考过程块：流式（live）默认展开实时滚动，历史气泡默认折叠，点标题行切换。 */
@Component
export struct ReasoningBlock {
  @Prop @Watch('onReasoningChange') reasoning: string = '';
  live: boolean = false;
  /** 思考耗时毫秒（#1515）：0=未知（旧存档/未打点），标题不带时长。 */
  thinkMs: number = 0;
  @State expanded: boolean = false;
  private bodyScroller: Scroller = new Scroller();

  private thinkSuffix(): string {
    const t: string = formatThinkMs(this.thinkMs > 0 ? this.thinkMs : undefined);
    return t.length > 0 ? ` · ${t}` : '';
  }

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
          Text(this.live ? '正在思考' : `思考过程${this.thinkSuffix()}`)
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

/** 书目计数折叠行：默认只显「共 N 本」，点开才渲染封面卡列表（流式刷新只动计数）。 */
@Component
struct BookListFold {
  @Prop items: ToolBookLine[] = [];
  @State open: boolean = false;

  build() {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        SymbolGlyph(this.open ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([$r('app.color.text_tertiary')]);
        Text(`共 ${this.items.length} 本`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
      .onClick(() => {
        this.open = !this.open;
      });
      if (this.open) {
        ToolResultList({ items: this.items });
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%');
  }
}

/** 工具调用活动区：摘要折叠行 + 展开明细；相邻同名调用合并为一条（×N）。
 * 流式期固定展开且禁用折叠点击——气泡随增量重建，组件内折叠态必被复位（同 ReasoningBlock）。
 * 单步活动默认展开：折叠只对多步有意义。
 */
@Component
export struct ActivityTimeline {
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
                BookListFold({ items: g.books });
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
export struct StreamBubble {
  @State text: string = '';
  @State reasoning: string = '';
  @State acts: ChatActivity[] = [];
  /** 打字光标位（#1515）：530ms 交替；只存在于流式泡挂载期，固化即随组件销毁。 */
  @State caret: boolean = true;
  private caretTimer: number | null = null;
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
    this.caretTimer = setInterval((): void => {
      this.caret = !this.caret;
    }, 530);
  }

  aboutToDisappear(): void {
    AiChatStore.instance().detachStreamView(this.viewToken);
    if (this.caretTimer !== null) {
      clearInterval(this.caretTimer);
      this.caretTimer = null;
    }
  }

  build() {
    // space 与 bubbleView 外层一致（6），避免流式→固化瞬间子项间距跳动
    Column({ space: 6 }) {
      ReasoningBlock({ reasoning: this.reasoning, live: true });
      ActivityTimeline({ acts: this.acts, live: true });
      if (this.text.length > 0) {
        MarkdownText({ content: this.text + (this.caret ? '▌' : '') });
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

/**
 * ask_user 反问卡片：AI 需要用户拍板时挂在输入条上方，点选项即把答复归还回路续跑。
 * 显示与否由父级 `if (pendingAsk !== null)` 控制——问题文本在展示期不变，值传递安全。
 */
@Component
export struct AskUserCard {
  question: string = '';
  options: string[] = [];
  onAnswer: (opt: string) => void = () => {};

  build() {
    Column({ space: 10 }) {
      Text(this.question)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%');
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        ForEach(this.options, (opt: string) => {
          Text(opt)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(14)
            .backgroundColor($r('app.color.brand_primary_light'))
            .onClick(() => this.onAnswer(opt));
        }, (opt: string) => opt);
        Text('跳过')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(14)
          .border({ width: 1, color: $r('app.color.divider') })
          .onClick(() => this.onAnswer(''));
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
}

/** 会话行的图标动作钮（改名/导出/删除同一形态）。 */
@Component
struct SheetIconBtn {
  icon: Resource = $r('sys.symbol.square_and_pencil');
  onTap: () => void = () => {};

  build() {
    Stack() {
      SymbolGlyph(this.icon)
        .fontSize(14)
        .fontColor([$r('app.color.text_secondary')]);
    }
    .width(28)
    .height(28)
    .borderRadius(14)
    .backgroundColor($r('app.color.page_background'))
    .onClick(() => this.onTap());
  }
}

/**
 * 对话管理面板：当前会话置顶带勾（不可点对比），存档会话点击切换。
 * #1513 增强：顶部搜索框（标题+正文过滤，过滤结果由页面传入）、
 * 每行改名（铅笔）与导出 Markdown（下载图标），存档行另有删除。
 * 生成中拒绝切换/新建（store 返回 false 转提示）由页面判断。
 */
@Component
export struct SessionsSheet {
  @Prop sessions: ChatSession[] = [];
  currentTitle: string = '';
  currentId: string = '';
  query: string = '';
  /** 行内改名（#1513）：PromptAction 无输入弹窗 API，编辑态放面板行内。 */
  @State editingId: string = '';
  @State draft: string = '';
  onPick: (id: string) => void = () => {};
  onDelete: (id: string) => void = () => {};
  onNew: () => void = () => {};
  onQuery: (kw: string) => void = () => {};
  onRename: (id: string, name: string) => void = () => {};
  onExport: (id: string) => void = () => {};

  private startEdit(id: string, cur: string): void {
    this.editingId = id;
    this.draft = cur;
  }

  private commitEdit(): void {
    if (this.editingId.length > 0) {
      this.onRename(this.editingId, this.draft);
    }
    this.editingId = '';
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

  build() {
    Column({ space: 6 }) {
      TextInput({ placeholder: '搜索对话（标题或内容）', text: this.query })
        .fontSize(14)
        .height(38)
        .backgroundColor($r('app.color.page_background'))
        .onChange((v: string) => this.onQuery(v));

      Column({ space: 6 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(14)
            .fontColor([$r('app.color.brand_primary')]);
          if (this.editingId === this.currentId) {
            TextInput({ text: this.draft })
              .fontSize(14)
              .layoutWeight(1)
              .onChange((v: string) => {
                this.draft = v;
              })
              .onSubmit(() => this.commitEdit());
            SheetIconBtn({ icon: $r('sys.symbol.checkmark'), onTap: () => this.commitEdit() });
            SheetIconBtn({ icon: $r('sys.symbol.xmark'), onTap: (): void => {
              this.editingId = '';
            } });
          } else {
            Text(this.currentTitle)
              .fontSize(14)
              .fontColor($r('app.color.brand_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
            SheetIconBtn({ icon: $r('sys.symbol.square_and_pencil'), onTap: () => this.startEdit(this.currentId, this.currentTitle) });
            SheetIconBtn({ icon: $r('sys.symbol.square_and_arrow_down'), onTap: () => this.onExport('') });
          }
          Text('当前')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'));
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 10, bottom: 10 });

        if (this.sessions.length === 0) {
          Text(this.query.trim().length > 0 ? '没有匹配的对话'
            : '没有其它对话：切换话题时点「新建对话」，当前对话会完整存档')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .padding(10)
            .width('100%');
        }
        ForEach(this.sessions, (s: ChatSession) => {
          Row({ space: 8 }) {
            if (this.editingId === s.id) {
              TextInput({ text: this.draft })
                .fontSize(14)
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.draft = v;
                })
                .onSubmit(() => this.commitEdit());
              SheetIconBtn({ icon: $r('sys.symbol.checkmark'), onTap: () => this.commitEdit() });
              SheetIconBtn({ icon: $r('sys.symbol.xmark'), onTap: (): void => {
                this.editingId = '';
              } });
            } else {
              Text(s.title)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
              Text(this.sessionTime(s.updatedAt))
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'));
              SheetIconBtn({ icon: $r('sys.symbol.square_and_pencil'), onTap: () => this.startEdit(s.id, s.title) });
              SheetIconBtn({ icon: $r('sys.symbol.square_and_arrow_down'), onTap: () => this.onExport(s.id) });
              SheetIconBtn({ icon: $r('sys.symbol.trash'), onTap: () => this.onDelete(s.id) });
            }
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 10, bottom: 10 })
          .onClick(() => {
            // 编辑态点行不触发切换（会连带吞掉正在输入的焦点）
            if (this.editingId !== s.id) {
              this.onPick(s.id);
            }
          });
        }, (s: ChatSession) => `${s.id}-${s.title}`);
      }
      .width('100%');

      TextButton({
        label: '＋ 新建对话',
        onTap: () => this.onNew(),
      });
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 16 });
  }
}
