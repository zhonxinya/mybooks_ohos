import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction, SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { PageScaffold, SecondaryButton, TextButton } from '../components';
import { MarkdownText } from '../components/MarkdownText';
import { AI_SKILLS, AiSkill } from '../services/AiSkills';
import { ToolResultList } from '../components/ToolResultList';
import { AiChatStore, ChatActivity, ChatBubble } from '../services/AiChatStore';
import { AiService } from '../services/AiService';
import { AiPermissionMode } from '../services/AiTools';
import { AppRouter } from '../utils/AppRouter';

/** 技能卡片/芯片点击：把现成提示词填入输入框，用户可先补书名再发送。 */

@Entry
@Component
struct AiAssistantPage {
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
  /** 工具回路实时活动时间线；finishBubble 时快照进气泡成为历史。 */
  @State liveActivities: ChatActivity[] = [];
  /** 流式中的思考过程（store.streamingReasoning 镜像）。 */
  @State streamingReasoning: string = '';
  /** 会话状态机在全局单例里：退出页面不中断流式回复，后台照常完成并落盘。 */
  private store: AiChatStore = AiChatStore.instance();
  /** attachView 凭据：disappear 只解绑自己这一份视图。 */
  private viewToken: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.store.refreshSettings();
    this.store.ensureLoaded();
    this.viewToken = this.store.attachView(
      (): void => this.syncFromStore(),
      (label: string, args: string): Promise<boolean> => this.requestConfirm(label, args));
    this.syncFromStore();
  }

  onPageShow(): void {
    this.store.refreshSettings();
    this.syncFromStore();
  }

  aboutToDisappear(): void {
    // 只解绑视图。曾经的 bug：在这里调 stopStreaming，退出对话页即掐断在途流式回复。
    this.store.detachView(this.viewToken);
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
    this.thinking = this.store.thinking;
    this.errorTip = this.store.errorTip;
    this.configured = this.store.configured;
    this.visionEnabled = this.store.visionEnabled;
    this.contextK = this.store.contextK;
    this.permission = AiService.loadPermission();
    this.scrollToEnd();
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
    }
    await this.store.send(text, images);
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
      // 权限模式徽标：点击弹三档菜单，当前项带勾
      Text(`权限·${this.permissionLabel()}`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius($r('app.float.chip_radius'))
        .border({ width: 1, color: $r('app.color.divider') })
        .bindMenu(this.permissionMenuItems())
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
          return `bubble-${index}-assistant-s-${sig}-${this.streamingText.length}-${this.streamingReasoning.length}`;
        }
        return `bubble-${index}-${bubble.role}-${bubble.streaming ? 's' : 'd'}-${bubble.activities.length}-${bubble.content.length}-${(bubble.images ?? []).length}-${(bubble.reasoning ?? '').length}`;
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
        // 思考过程：流式挂 store 镜像实时显示，固化后挂气泡自身字段默认折叠
        if (bubble.streaming) {
          ReasoningBlock({ reasoning: this.streamingReasoning, live: true });
        } else if ((bubble.reasoning ?? '').length > 0) {
          ReasoningBlock({ reasoning: bubble.reasoning ?? '', live: false });
        }
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

/** 思考过程块：流式（live）默认展开实时滚动，历史气泡默认折叠，点标题行切换。 */
@Component
struct ReasoningBlock {
  reasoning: string = '';
  live: boolean = false;
  @State expanded: boolean = false;

  aboutToAppear(): void {
    this.expanded = this.live;
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
          this.expanded = !this.expanded;
        });
        if (this.expanded) {
          Text(this.reasoning)
            .fontSize(13)
            .lineHeight(20)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }
}
