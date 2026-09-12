/**
 * 阅读进度与书籍属性（Talebook）。
 *
 * - 进度：`GET/POST /api/book/{id}/progress`，服务端按客户端自定义 JSON 结构存储，上限 8KiB；
 *   上游**没有删除端点**，「清空」以空对象覆盖实现。
 * - 可见范围：`GET /api/book/{id}` 读取 + `POST /api/book/{id}/setscope` 翻转（无请求体）。
 * - 媒体类型：`GET /api/book/{id}` 读取 + `POST /api/book/{id}/media_type` 设置（`ebook` / `comic`）。
 */
import {
  PageScaffold, LoadingState, EmptyState, SectionTitle, PrimaryButton,
  SecondaryButton, DangerButton, FilterChips, FilterChipItem, SettingCell,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { apiErrorMessage } from '../services/TalebookApi';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import {
  BookAttributes, BookMediaType, BookScope, ReadingProgressResponse,
  ShelfApi, isShelfApiOk, parseBookAttributes,
} from '../services/ShelfApi';

@Entry
@Component
struct ReadingProgressPage {
  @State bookId: number = 0;
  @State loading: boolean = true;
  @State loadError: string = '';
  /** 服务端最后一次保存的进度（只读展示）。 */
  @State savedProgressText: string = '{}';
  /** 编辑中的进度 JSON 文本。 */
  @State progressText: string = '{}';
  @State updateTime: string = '';
  @State saving: boolean = false;
  @State jsonError: string = '';
  @State attributes: BookAttributes | null = null;
  @State attributesError: string = '';
  @State scopeBusy: boolean = false;
  @State mediaTypeBusy: boolean = false;
  @State selectedMediaType: number = -1;
  private progressSupported: boolean = ServerRegistry.supports(ServerFeature.BOOK_PROGRESS);
  private scopeSupported: boolean = ServerRegistry.supports(ServerFeature.BOOK_SCOPE);
  private mediaTypeSupported: boolean = ServerRegistry.supports(ServerFeature.BOOK_MEDIA_TYPE);
  private mediaTypeItems: FilterChipItem[] = [
    { label: '电子书', value: 0 },
    { label: '漫画', value: 1 },
  ];
  private mediaTypeValues: string[] = [BookMediaType.EBOOK, BookMediaType.COMIC];

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.bookId = Number(params['bookId'] ?? 0);
    void this.load();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      if (!this.progressSupported) {
        this.loadError = `${ServerRegistry.profile().displayName} 服务端不支持跨端阅读进度`;
        return;
      }
      if (this.bookId <= 0) {
        this.loadError = '缺少书籍参数';
        return;
      }
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '请先配置服务器';
        return;
      }
      if (TalebookService.hasAuthCredentials()) {
        await TalebookService.ensureAuthenticated();
      }
      const rsp: ReadingProgressResponse = await ShelfApi.getReadingProgress(this.bookId);
      if (!isShelfApiOk(rsp)) {
        this.loadError = apiErrorMessage(rsp);
        return;
      }
      const progress = rsp.progress ?? {};
      this.savedProgressText = this.prettyJson(progress);
      this.progressText = this.savedProgressText;
      this.updateTime = rsp.update_time !== undefined && rsp.update_time !== null ? rsp.update_time : '';
      if (this.scopeSupported || this.mediaTypeSupported) {
        await this.loadAttributes();
      }
    } catch (error) {
      this.loadError = error instanceof Error ? error.message : `${error}`;
    } finally {
      this.loading = false;
    }
  }

  /** 属性读取失败不阻断进度主流程，仅在属性区提示。 */
  private async loadAttributes(): Promise<void> {
    this.attributesError = '';
    try {
      const rsp = await ShelfApi.getBookAttributes(this.bookId);
      if (!isShelfApiOk(rsp) || rsp.book === undefined) {
        this.attributesError = isShelfApiOk(rsp) ? '未获取到书籍属性' : apiErrorMessage(rsp);
        return;
      }
      const parsed = parseBookAttributes(rsp.book);
      this.attributes = parsed;
      this.selectedMediaType = parsed.mediaType === BookMediaType.COMIC ? 1 :
        (parsed.mediaType === BookMediaType.EBOOK ? 0 : -1);
    } catch (error) {
      this.attributesError = `读取书籍属性失败：${error}`;
    }
  }

  private prettyJson(value: Record<string, Object>): string {
    return JSON.stringify(value, null, 2);
  }

  /** 解析编辑框内容：必须是 JSON 对象（上游要求 dict），空文本等价于 `{}`。 */
  private parseProgressInput(text: string): Record<string, Object> | null {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      const empty: Record<string, Object> = {};
      return empty;
    }
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(trimmed) as Object;
    } catch (error) {
      return null;
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return null;
    }
    return parsed as Record<string, Object>;
  }

  private async saveProgress(): Promise<void> {
    const parsed = this.parseProgressInput(this.progressText);
    if (parsed === null) {
      this.jsonError = '进度必须是合法的 JSON 对象';
      this.toast('进度 JSON 格式不合法');
      return;
    }
    this.jsonError = '';
    this.saving = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await ShelfApi.saveReadingProgress(this.bookId, parsed);
      if (!isShelfApiOk(rsp)) {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.savedProgressText = this.prettyJson(rsp.progress ?? parsed);
      this.progressText = this.savedProgressText;
      this.toast('阅读进度已保存');
      const latest = await ShelfApi.getReadingProgress(this.bookId);
      if (isShelfApiOk(latest)) {
        this.updateTime = latest.update_time !== undefined && latest.update_time !== null ?
          latest.update_time : '';
      }
    } catch (error) {
      this.toast(`保存失败：${error}`);
    } finally {
      this.saving = false;
    }
  }

  private confirmClearProgress(): void {
    this.getUIContext().showAlertDialog({
      title: '清空阅读进度',
      message: '上游没有删除端，将以空对象覆盖服务端进度，确定继续吗？',
      primaryButton: {
        value: '清空',
        action: () => {
          void this.clearProgress();
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async clearProgress(): Promise<void> {
    this.saving = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await ShelfApi.clearReadingProgress(this.bookId);
      if (!isShelfApiOk(rsp)) {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.savedProgressText = '{}';
      this.progressText = '{}';
      this.jsonError = '';
      const latest = await ShelfApi.getReadingProgress(this.bookId);
      this.updateTime = isShelfApiOk(latest) && latest.update_time !== undefined &&
        latest.update_time !== null ? latest.update_time : '';
      this.toast('已清空服务端阅读进度');
    } catch (error) {
      this.toast(`清空失败：${error}`);
    } finally {
      this.saving = false;
    }
  }

  private async toggleScope(): Promise<void> {
    if (this.attributes === null || this.scopeBusy) {
      return;
    }
    this.scopeBusy = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await ShelfApi.toggleBookScope(this.bookId);
      if (!isShelfApiOk(rsp)) {
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast('可见范围已切换');
      await this.loadAttributes();
    } catch (error) {
      this.toast(`设置失败：${error}`);
    } finally {
      this.scopeBusy = false;
    }
  }

  private async changeMediaType(value: number): Promise<void> {
    const mediaType = this.mediaTypeValues[value];
    if (mediaType === undefined || this.attributes === null || this.mediaTypeBusy) {
      return;
    }
    if (this.attributes.mediaType === mediaType) {
      return;
    }
    this.mediaTypeBusy = true;
    try {
      await TalebookService.ensureAuthenticated();
      const rsp = await ShelfApi.setBookMediaType(this.bookId, mediaType);
      if (!isShelfApiOk(rsp)) {
        // 常见失败：media_type.not_mixed（书籍未同时包含电子书与漫画格式）
        this.toast(apiErrorMessage(rsp));
        return;
      }
      this.toast('媒体类型已更新');
      await this.loadAttributes();
    } catch (error) {
      this.toast(`设置失败：${error}`);
    } finally {
      this.mediaTypeBusy = false;
    }
  }

  private scopeLabel(value: string): string {
    return value === BookScope.PRIVATE ? '私藏（仅自己可见）' : '公开';
  }

  private mediaTypeLabel(value: string): string {
    if (value === BookMediaType.COMIC) {
      return '漫画';
    }
    if (value === BookMediaType.EBOOK) {
      return '电子书';
    }
    return '未识别';
  }

  private updateTimeText(): string {
    return this.updateTime.length > 0 ? this.updateTime : '尚无记录';
  }

  build() {
    Column() {
      PageScaffold({
        title: '阅读进度',
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
    if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({
        message: this.loadError,
        actionLabel: this.loadError.includes('配置') ? '去配置' : '',
        onAction: () => this.getUIContext().getRouter().pushUrl({ url: 'pages/TalebookConfigPage' }),
      });
    } else {
      Scroll() {
        Column({ space: 12 }) {
          this.progressSection();
          if (this.scopeSupported || this.mediaTypeSupported) {
            this.attributesSection();
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
        .alignItems(HorizontalAlign.Start);
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top);
    }
  }

  @Builder
  progressSection() {
    Column({ space: 10 }) {
      SectionTitle({ title: '服务端阅读进度' });
      Column({ space: 8 }) {
        Row() {
          Text('更新时间')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'));
          Blank();
          Text(this.updateTimeText())
            .fontSize(13)
            .fontColor($r('app.color.text_primary'));
        }
        .width('100%');
        Text(this.savedProgressText)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.page_background'))
          .borderRadius($r('app.float.cover_radius'));
      }
      .width('100%')
      .padding($r('app.float.card_padding'))
      .backgroundColor($r('app.color.card_background'))
      .borderRadius($r('app.float.card_radius'));

      Text('编辑进度（JSON 对象，服务端上限 8KiB；保存为整体覆盖）')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'));
      TextArea({ text: this.progressText, placeholder: '例如 {"chapter": 12, "percent": 0.35}' })
        .height(160)
        .fontSize(13)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius($r('app.float.card_radius'))
        .onChange((value: string) => {
          this.progressText = value;
          this.jsonError = '';
        });
      if (this.jsonError.length > 0) {
        Text(this.jsonError)
          .fontSize(12)
          .fontColor($r('app.color.error'));
      }
      PrimaryButton({
        label: this.saving ? '保存中…' : '保存进度',
        buttonEnabled: !this.saving,
        onTap: () => {
          void this.saveProgress();
        },
      });
      SecondaryButton({
        label: '重置为已保存内容',
        compact: true,
        buttonEnabled: !this.saving,
        onTap: () => {
          this.progressText = this.savedProgressText;
          this.jsonError = '';
        },
      });
      DangerButton({
        label: '清空服务端进度',
        buttonEnabled: !this.saving,
        onTap: () => this.confirmClearProgress(),
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  attributesSection() {
    Column({ space: 8 }) {
      SectionTitle({ title: '书籍属性' });
      if (this.attributesError.length > 0) {
        Text(this.attributesError)
          .fontSize(12)
          .fontColor($r('app.color.error'));
      }
      if (this.attributes === null && this.attributesError.length === 0) {
        Text('正在读取书籍属性…')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
      if (this.attributes !== null) {
        Column() {
          if (this.scopeSupported) {
            SettingCell({
              title: '可见范围',
              subtitle: '上游为翻转接口，点按即在公开/私藏之间切换',
              valueText: this.scopeLabel(this.attributes!.scope),
              showChevron: true,
              onTap: () => {
                void this.toggleScope();
              },
            })
          }
          if (this.mediaTypeSupported) {
            Column({ space: 8 }) {
              SettingCell({
                title: '媒体类型',
                subtitle: this.attributes!.mediaTypeLocked ? '已手动锁定' : '由服务端自动分析',
                valueText: this.mediaTypeLabel(this.attributes!.mediaType),
              })
              Text(`现有格式：${this.attributes!.formats.length > 0 ?
                this.attributes!.formats.join('、') : '未知'}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'));
              FilterChips({
                items: this.mediaTypeItems,
                selected: $selectedMediaType,
                onChange: (value: number) => {
                  void this.changeMediaType(value);
                },
              })
              Text('仅当书籍同时包含电子书与漫画格式时，服务端才允许手动设置。')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'));
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start);
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.card_background'))
        .borderRadius($r('app.float.card_radius'));
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
