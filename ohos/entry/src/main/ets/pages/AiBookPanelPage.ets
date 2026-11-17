import { pasteboard } from '@kit.BasicServicesKit';
import { PageScaffold, SecondaryButton, TextButton } from '../components';
import { AiService } from '../services/AiService';
import { AiBookService, BookContext, MetaSuggestion } from '../services/AiBookService';
import { AppRouter } from '../utils/AppRouter';

/**
 * 书籍 AI 面板：摘要 / 书评 / 元数据建议。
 *
 * 从书籍详情页带参数进入（title / author / publisher / description / tags），
 * 结果只展示与复制，不自动写库——元数据改动走「复制 → 编辑页粘贴」，
 * 避免模型幻觉直接污染书库。
 */
@Entry
@Component
struct AiBookPanelPage {
  @State bookTitle: string = '';
  @State bookAuthor: string = '';
  @State bookPublisher: string = '';
  @State bookDescription: string = '';
  @State bookTags: string = '';
  @State activeTab: number = 0;
  @State loading: boolean = false;
  @State result: string = '';
  @State errorText: string = '';
  @State configured: boolean = false;
  @State suggestion: MetaSuggestion | null = null;

  aboutToAppear(): void {
    const params = AppRouter.getParams(this.getUIContext()) as Record<string, Object>;
    this.bookTitle = String(params['title'] ?? '');
    this.bookAuthor = String(params['author'] ?? '');
    this.bookPublisher = String(params['publisher'] ?? '');
    this.bookDescription = String(params['description'] ?? '');
    this.bookTags = String(params['tags'] ?? '');
    this.configured = AiService.isReady();
  }

  onPageShow(): void {
    this.configured = AiService.isReady();
  }

  private context(): BookContext {
    const tags: string[] = this.bookTags.length > 0 ? this.bookTags.split(',') : [];
    return {
      title: this.bookTitle,
      author: this.bookAuthor,
      publisher: this.bookPublisher,
      description: this.bookDescription,
      tags: tags,
    };
  }

  private async run(kind: string): Promise<void> {
    if (this.loading) {
      return;
    }
    if (!AiService.isReady()) {
      this.configured = false;
      return;
    }
    this.configured = true;
    this.activeTab = kind === 'summary' ? 0 : (kind === 'review' ? 1 : 2);
    this.loading = true;
    this.result = '';
    this.errorText = '';
    this.suggestion = null;
    try {
      if (kind === 'summary') {
        this.result = await AiBookService.summarize(this.context(), 200);
      } else if (kind === 'review') {
        this.result = await AiBookService.review(this.context(), 4);
      } else {
        this.suggestion = await AiBookService.suggestMeta(this.context());
      }
    } catch (error) {
      this.errorText = error instanceof Error ? error.message : String(error);
    } finally {
      this.loading = false;
    }
  }

  private suggestText(): string {
    if (this.suggestion === null) {
      return '';
    }
    const s: MetaSuggestion = this.suggestion;
    const lines: string[] = [];
    if (s.title.length > 0) {
      lines.push(`书名：${s.title}`);
    }
    if (s.author.length > 0) {
      lines.push(`作者：${s.author}`);
    }
    if (s.publisher.length > 0) {
      lines.push(`出版社：${s.publisher}`);
    }
    if (s.tags.length > 0) {
      lines.push(`标签：${s.tags}`);
    }
    if (s.summary.length > 0) {
      lines.push(`简介：${s.summary}`);
    }
    return lines.join('\n');
  }

  private copy(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data);
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
        title: 'AI 书籍助手',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  pageContent() {
    Column({ space: 14 }) {
      // 书籍上下文一览：让用户确认 AI 看到的是什么
      Column({ space: 4 }) {
        Text(this.bookTitle.length > 0 ? this.bookTitle : '未提供书名')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text(this.bookAuthor.length > 0 ? this.bookAuthor : '作者未知')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        if (this.bookDescription.length === 0) {
          Text('该书缺少简介，摘要与书评只能依据书名与作者推断，质量可能有限')
            .fontSize(11)
            .fontColor($r('app.color.warning'))
            .width('100%');
        }
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'))
      .alignItems(HorizontalAlign.Start);

      if (!this.configured) {
        Column({ space: 14 }) {
          Text('尚未配置 AI 模型')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'));
          Text('key 只保存在本机，不经过项目服务端')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'));
          SecondaryButton({
            label: '去配置',
            fullWidth: false,
            onTap: () => AppRouter.pushUrl(this.getUIContext(), { url: 'pages/AiSettingsPage' }),
          });
        }
        .width('100%')
        .padding(20)
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'));
      } else {
        Row({ space: 10 }) {
          SecondaryButton({
            label: this.loading && this.activeTab === 0 ? '生成中…' : '内容摘要',
            fullWidth: false,
            buttonEnabled: !this.loading,
            onTap: () => {
              void this.run('summary');
            },
          }).layoutWeight(1);
          SecondaryButton({
            label: this.loading && this.activeTab === 1 ? '生成中…' : '写书评',
            fullWidth: false,
            buttonEnabled: !this.loading,
            onTap: () => {
              void this.run('review');
            },
          }).layoutWeight(1);
          SecondaryButton({
            label: this.loading && this.activeTab === 2 ? '分析中…' : '元数据建议',
            fullWidth: false,
            buttonEnabled: !this.loading,
            onTap: () => {
              void this.run('meta');
            },
          }).layoutWeight(1);
        }
        .width('100%');

        if (this.errorText.length > 0) {
          Text(this.errorText)
            .fontSize(12)
            .fontColor($r('app.color.error'))
            .width('100%');
        }

        if (this.suggestion !== null) {
          this.suggestionView();
        } else if (this.result.length > 0) {
          this.resultView();
        }
        if (this.loading) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color($r('app.color.brand_primary'));
            Text('AI 正在生成，请稍候')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'));
          }
          .width('100%');
        }
      }
      Blank();
    }
    .width('100%')
    .height('100%')
    .padding($r('app.float.page_padding'))
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  resultView() {
    Scroll() {
      Column({ space: 10 }) {
        Text(this.result)
          .fontSize(15)
          .lineHeight(24)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
          .textAlign(TextAlign.Start);
        Row({ space: 12 }) {
          TextButton({ label: '复制', onTap: () => {
            this.copy(this.result);
          } });
        }
        .width('100%');
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
    .layoutWeight(1)
    .width('100%')
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .align(Alignment.Top);
  }

  @Builder
  suggestionView() {
    Scroll() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('模型建议')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          if (this.suggestion !== null && this.suggestion.confidence.length > 0) {
            Text(`置信度 ${this.suggestion.confidence}`)
              .fontSize(11)
              .fontColor(this.suggestion.confidence === 'low' ? $r('app.color.error') : $r('app.color.text_tertiary'));
          }
          Blank();
        }
        .width('100%');

        Text(this.suggestText().length > 0 ? this.suggestText() : '模型没有给出可用的字段')
          .fontSize(14)
          .lineHeight(22)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
          .textAlign(TextAlign.Start);

        Text('建议不会自动写入书库。请复制后到「编辑元数据」里核对再保存。')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        Row({ space: 12 }) {
          TextButton({ label: '复制建议', onTap: () => {
            this.copy(this.suggestText());
          } });
        }
        .width('100%');
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
    .layoutWeight(1)
    .width('100%')
    .padding($r('app.float.page_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .align(Alignment.Top);
  }
}
