import { pasteboard } from '@kit.BasicServicesKit';
import {
  PageScaffold, LoadingState, EmptyState, AuthImage, PrimaryButton, SecondaryButton,
  TextButton, LazyDataSource,
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import {
  NetworkLibraryApi, NetworkBookDetail, NetworkChapterItem, NetworkSaveProgress,
  NETWORK_SAVE_FMT_TXT, NETWORK_SAVE_FMT_EPUB,
  NETWORK_SAVE_RUNNING, NETWORK_SAVE_COMPLETED,
} from '../services/NetworkLibraryApi';

/** 保存任务轮询间隔（服务端按章节抓取，进度更新较慢）。 */
const SAVE_POLL_INTERVAL_MS: number = 3000;
/** 保存任务轮询次数上限（约 5 分钟，超出后交回后台继续）。 */
const SAVE_POLL_MAX: number = 100;

/** 连载状态：连载中。 */
const SERIALIZE_SERIAL: string = 'serial';
/** 连载状态：已完结。 */
const SERIALIZE_FINISHED: string = 'finished';
/** 连载状态：未知。 */
const SERIALIZE_UNKNOWN: string = 'unknown';

/** 连载状态 → 中文标签。 */
function serializeLabel(status: string): string {
  if (status === SERIALIZE_SERIAL) {
    return '连载中';
  }
  if (status === SERIALIZE_FINISHED) {
    return '已完结';
  }
  return '状态未知';
}

/**
 * 网络书库书籍详情（talebook 专有）：书籍详情 + 章节目录 + 章节正文 + 保存到本地书库。
 *
 * 路由入参：`sourceId`（书源绑定键 `legado:12`）、`bookUrl`、`bookName`、`sourceName`。
 * 端点与响应结构见 `services/NetworkLibraryApi.ets`；保存为「POST 创建任务 + 轮询
 * `/api/book-sources/save/status`」异步模式（上游 `SaveOnlineBookService.make_tag`）。
 */
@Entry
@Component
struct NetworkBookDetailPage {
  @State sourceId: string = '';
  @State bookUrl: string = '';
  @State bookName: string = '';
  @State sourceName: string = '';
  @State loading: boolean = true;
  @State loadError: string = '';
  @State detail: NetworkBookDetail | null = null;
  @State chapterCount: number = 0;
  @State serializeStatus: string = SERIALIZE_UNKNOWN;
  @State showFullIntro: boolean = false;
  @State showContentSheet: boolean = false;
  @State contentTitle: string = '';
  @State contentText: string = '';
  @State contentError: string = '';
  @State loadingContent: boolean = false;
  @State cleanContent: boolean = true;
  @State saving: boolean = false;
  @State saveText: string = '';
  @State savedBookId: number = 0;
  private featureSupported: boolean = ServerRegistry.supports(ServerFeature.NETWORK_LIBRARY);
  private chapterSource: LazyDataSource<NetworkChapterItem> = new LazyDataSource<NetworkChapterItem>();
  private chapters: NetworkChapterItem[] = [];
  private currentChapterUrl: string = '';
  private saveTimer: number = -1;
  private savePolls: number = 0;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.sourceId = String(params['sourceId'] ?? '');
    this.bookUrl = String(params['bookUrl'] ?? '');
    this.bookName = String(params['bookName'] ?? '');
    this.sourceName = String(params['sourceName'] ?? '');
    if (!this.featureSupported) {
      this.loading = false;
      return;
    }
    void this.load();
  }

  aboutToDisappear(): void {
    this.stopSavePoll();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private async load(): Promise<void> {
    if (this.sourceId.length === 0 || this.bookUrl.length === 0) {
      this.loading = false;
      this.loadError = '缺少书源或书籍地址参数';
      return;
    }
    if (!TalebookService.ensureTalebookConfigured()) {
      this.loading = false;
      this.loadError = '尚未配置服务器地址';
      return;
    }
    this.loading = this.detail === null;
    this.loadError = '';
    try {
      await TalebookService.ensureAuthenticated();
      const detailRsp = await NetworkLibraryApi.getBook(this.sourceId, this.bookUrl);
      if (!NetworkLibraryApi.isOk(detailRsp)) {
        this.loadError = NetworkLibraryApi.errorMessage(detailRsp);
        return;
      }
      const detail = NetworkLibraryApi.parseNetworkBookDetail(detailRsp.book, this.bookUrl, this.sourceName);
      this.detail = detail;
      if (detail !== null) {
        this.bookName = detail.title;
        this.serializeStatus = detail.serializeStatus;
      }
      const tocTarget = detail !== null && detail.tocUrl.length > 0 ? detail.tocUrl : '';
      const tocRsp = tocTarget.length > 0
        ? await NetworkLibraryApi.getTocByUrl(this.sourceId, tocTarget)
        : await NetworkLibraryApi.getToc(this.sourceId, this.bookUrl);
      if (!NetworkLibraryApi.isOk(tocRsp)) {
        this.loadError = NetworkLibraryApi.errorMessage(tocRsp);
        return;
      }
      this.chapters = NetworkLibraryApi.parseNetworkChapters(tocRsp.chapters);
      this.chapterCount = this.chapters.length;
      this.chapterSource.update(this.chapters);
      const tocStatus = tocRsp.serialize_status ?? '';
      if (tocStatus.length > 0) {
        this.serializeStatus = tocStatus;
      }
      if (this.chapters.length === 0) {
        this.toast('未解析到章节，可能是书源规则不支持该书');
      }
    } catch (e) {
      this.loadError = `加载失败：${e}`;
    } finally {
      this.loading = false;
    }
  }

  private metaText(): string {
    const detail = this.detail;
    if (detail === null) {
      return this.sourceName;
    }
    const parts: string[] = [];
    if (this.sourceName.length > 0) {
      parts.push(this.sourceName);
    } else if (detail.sourceName.length > 0) {
      parts.push(detail.sourceName);
    }
    if (detail.kind.length > 0) {
      parts.push(detail.kind);
    }
    if (detail.wordCount.length > 0) {
      parts.push(detail.wordCount);
    }
    if (this.chapterCount > 0) {
      parts.push(`${this.chapterCount} 章`);
    }
    return parts.join(' · ');
  }

  private openChapter(chapter: NetworkChapterItem): void {
    this.contentTitle = chapter.title.length > 0 ? chapter.title : '正文';
    this.contentText = '';
    this.contentError = '';
    this.currentChapterUrl = chapter.url.length > 0 ? chapter.url : chapter.externalId;
    this.showContentSheet = true;
    void this.loadContent();
  }

  private async loadContent(): Promise<void> {
    if (this.currentChapterUrl.length === 0) {
      this.contentError = '章节地址为空';
      return;
    }
    this.loadingContent = true;
    this.contentError = '';
    try {
      const rsp = await NetworkLibraryApi.getContent(this.sourceId, this.currentChapterUrl,
        this.contentTitle, this.cleanContent);
      if (!NetworkLibraryApi.isOk(rsp)) {
        this.contentError = NetworkLibraryApi.errorMessage(rsp);
        return;
      }
      if (rsp.title !== undefined && rsp.title.length > 0) {
        this.contentTitle = rsp.title;
      }
      this.contentText = rsp.content !== undefined ? rsp.content : '';
      if (this.contentText.length === 0) {
        this.contentError = '该书源返回的正文为空';
      }
    } catch (e) {
      this.contentError = `正文加载失败：${e}`;
    } finally {
      this.loadingContent = false;
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private copyContent(): void {
    if (this.contentText.length === 0) {
      this.toast('正文为空，无法复制');
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.contentText);
    pasteboard.getSystemPasteboard().setData(data);
    this.toast('正文已复制到剪贴板');
  }

  private chooseSaveFormat(): void {
    if (this.detail === null || this.saving) {
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '保存到本地书库',
      message: '服务端会后台抓取全部章节并导入书库，完成后发送通知。TXT 直接导入；EPUB 先生成 TXT 再后台转换。',
      buttons: [
        { text: '取消', color: '#999999' },
        { text: 'TXT', color: '#007DFF' },
        { text: 'EPUB', color: '#007DFF' },
      ],
    }).then((result) => {
      if (result.index === 1) {
        void this.startSave(NETWORK_SAVE_FMT_TXT);
      } else if (result.index === 2) {
        void this.startSave(NETWORK_SAVE_FMT_EPUB);
      }
    }).catch(() => {
    });
  }

  private stopSavePoll(): void {
    if (this.saveTimer >= 0) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
  }

  private scheduleSavePoll(delay: number): void {
    this.stopSavePoll();
    this.saveTimer = setTimeout(() => {
      void this.pollSaveStatus();
    }, delay);
  }

  private async startSave(fmt: string): Promise<void> {
    this.saving = true;
    this.savedBookId = 0;
    this.saveText = '正在提交保存任务…';
    try {
      const rsp = await NetworkLibraryApi.save(this.sourceId, this.bookUrl, fmt, true);
      if (!NetworkLibraryApi.isOk(rsp)) {
        this.saving = false;
        this.saveText = '';
        this.toast(NetworkLibraryApi.errorMessage(rsp));
        return;
      }
      const msg = rsp.msg ?? '';
      this.saveText = msg.length > 0 ? msg : '已开始后台保存，正在等待进度…';
      this.savePolls = 0;
      this.scheduleSavePoll(1000);
    } catch (e) {
      this.saving = false;
      this.saveText = '';
      this.toast(`保存失败：${e}`);
    }
  }

  private finishSave(message: string): void {
    this.stopSavePoll();
    this.saving = false;
    this.saveText = message;
    this.toast(message);
  }

  private async pollSaveStatus(): Promise<void> {
    try {
      const rsp = await NetworkLibraryApi.getSaveStatus(this.sourceId, this.bookUrl);
      if (!NetworkLibraryApi.isOk(rsp)) {
        this.finishSave(NetworkLibraryApi.errorMessage(rsp));
        return;
      }
      const progress: NetworkSaveProgress = NetworkLibraryApi.parseSaveProgress(rsp);
      if (!progress.found) {
        this.finishSave('未查到保存任务进度（任务可能已结束或被清理），请到书库或通知确认结果');
        return;
      }
      if (progress.bookId > 0) {
        this.savedBookId = progress.bookId;
      }
      if (progress.status === NETWORK_SAVE_RUNNING) {
        this.saveText = progress.total > 0
          ? `保存中 ${progress.progress}%（章节 ${progress.done}/${progress.total}）`
          : `保存中 ${progress.progress}%`;
      } else if (progress.status === NETWORK_SAVE_COMPLETED) {
        const done = progress.bookId > 0 ? `保存完成（书籍 ID ${progress.bookId}）` : '保存完成';
        this.finishSave(done);
        return;
      } else if (progress.error.length > 0) {
        this.finishSave(`保存失败：${progress.error}`);
        return;
      } else if (progress.finished) {
        this.finishSave('保存任务已结束（未成功导入）');
        return;
      } else {
        this.saveText = `任务状态：${progress.status}`;
      }
    } catch (e) {
      this.finishSave(`查询保存进度失败：${e}`);
      return;
    }
    this.savePolls += 1;
    if (this.savePolls >= SAVE_POLL_MAX) {
      this.finishSave('保存仍在后台进行，可稍后到书库查看结果');
      return;
    }
    this.scheduleSavePoll(SAVE_POLL_INTERVAL_MS);
  }

  build() {
    Column() {
      PageScaffold({
        title: this.bookName.length > 0 ? this.bookName : '网络书籍',
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
    .height('100%')
    .bindSheet($$this.showContentSheet, this.contentSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      title: { title: this.contentTitle },
    });
  }

  @Builder
  headerAction() {
    Text('刷新')
      .fontSize(14)
      .fontColor($r('app.color.brand_primary'))
      .padding({ left: 8, right: 16 })
      .onClick(() => {
        if (!this.loading) {
          void this.load();
        }
      });
  }

  @Builder
  pageContent() {
    if (!this.featureSupported) {
      EmptyState({ message: `${ServerRegistry.profile().displayName} 服务端不支持网络书库` });
    } else if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({
        message: this.loadError,
        actionLabel: '重试',
        onAction: () => {
          void this.load();
        },
      });
    } else {
      Column() {
        List({ space: 0 }) {
          ListItem() {
            this.detailCard();
          }
          LazyForEach(this.chapterSource, (chapter: NetworkChapterItem, index: number) => {
            ListItem() {
              this.chapterRow(chapter, index);
            }
          }, (chapter: NetworkChapterItem, index: number) => `ch-${index}-${chapter.url}`);
        }
        .layoutWeight(1)
        .width('100%')
        .cachedCount(12)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider') });
      }
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  detailCard() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        AuthImage({
          url: this.detail !== null ? this.detail.coverUrl : '',
          imageWidth: 84,
          imageHeight: 118,
        });
        Column({ space: 6 }) {
          Text(this.bookName.length > 0 ? this.bookName : '未知书名')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          Text(this.detail !== null && this.detail.author.length > 0 ? this.detail.author : '佚名')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          Text(this.metaText())
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          Row({ space: 6 }) {
            Text(serializeLabel(this.serializeStatus))
              .fontSize(11)
              .fontColor($r('app.color.brand_primary'))
              .backgroundColor($r('app.color.brand_primary_light'))
              .borderRadius(4)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 });
            if (this.detail !== null && this.detail.lastChapter.length > 0) {
              Text(`末章：${this.detail.lastChapter}`)
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
            }
          }
          .width('100%');
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
      }
      .width('100%')
      .alignItems(VerticalAlign.Top);

      if (this.detail !== null && this.detail.description.length > 0) {
        Column({ space: 4 }) {
          Text(this.detail.description)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(this.showFullIntro ? 999 : 3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          TextButton({
            label: this.showFullIntro ? '收起简介' : '展开简介',
            onTap: () => {
              this.showFullIntro = !this.showFullIntro;
            },
          });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }

      Row({ space: 8 }) {
        PrimaryButton({
          label: this.saving ? '保存中…' : '保存到书库',
          buttonEnabled: !this.saving,
          fullWidth: false,
          onTap: () => this.chooseSaveFormat(),
        });
        if (this.savedBookId > 0) {
          SecondaryButton({
            label: '打开书籍',
            fullWidth: false,
            onTap: () => this.getUIContext().getRouter().pushUrl({
              url: 'pages/BookDetailPage',
              params: { bookId: this.savedBookId },
            }),
          });
        }
      }
      .width('100%');

      if (this.saveText.length > 0) {
        Text(this.saveText)
          .fontSize(12)
          .fontColor(this.saving ? $r('app.color.text_secondary') : $r('app.color.brand_primary'))
          .width('100%');
      }
      if (this.chapters.length === 0) {
        Text('未解析到章节目录，可点击右上角「刷新」重试；若仍为空，可能是该书源规则依赖 JS。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding($r('app.float.page_padding'))
    .backgroundColor($r('app.color.card_background'));
  }

  @Builder
  chapterRow(chapter: NetworkChapterItem, index: number) {
    Row({ space: 8 }) {
      Text(`${index + 1}`)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width(36)
        .textAlign(TextAlign.End);
      Text(chapter.title.length > 0 ? chapter.title : '未命名章节')
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1);
      if (chapter.isVip) {
        Text('VIP')
          .fontSize(10)
          .fontColor($r('app.color.error'))
          .backgroundColor($r('app.color.error_light'))
          .borderRadius(4)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 });
      }
      if (chapter.updatedAt.length > 0) {
        Text(chapter.updatedAt)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'));
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => this.openChapter(chapter));
  }

  @Builder
  contentSheet() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(`${this.contentTitle}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text('净化')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
        Toggle({ type: ToggleType.Switch, isOn: this.cleanContent })
          .onChange((value: boolean) => {
            this.cleanContent = value;
            void this.loadContent();
          });
        TextButton({
          label: '复制',
          onTap: () => this.copyContent(),
        });
      }
      .width('100%');
      if (this.loadingContent) {
        LoadingState({});
      } else if (this.contentError.length > 0) {
        EmptyState({
          message: this.contentError,
          actionLabel: '重试',
          onAction: () => {
            void this.loadContent();
          },
        });
      } else {
        Scroll() {
          Text(this.contentText)
            .fontSize(15)
            .lineHeight(24)
            .fontColor($r('app.color.text_primary'))
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
            .padding({ left: 12, right: 12, top: 4, bottom: 16 });
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.TopStart);
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 8 });
  }
}
