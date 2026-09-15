import {
  PageScaffold, EmptyState, LoadingState, AuthImage,
  PrimaryButton, SecondaryButton, DangerButton, LazyDataSource,
  QuickActionGrid, QuickActionItem,
} from '../components';
import {
  TalebookApi, ApiMessageResult, apiErrorMessage
} from '../services/TalebookApi';
import {
  AudioFileInfo, AudioInfoResponse, AudioConversionResponse,
  AudioPurchaseResponse, AudioCollectionResponse
} from '../common/ApiTypes';
import { TalebookService } from '../services/TalebookService';

interface VoiceOption {
  voiceName: string;
  displayName: string;
  gender: string;
  language: string;
}

/** 快捷操作宫格一行的高度（QuickActionGrid 内部的 Grid 不设高会撑满剩余空间）。 */
const QUICK_ACTION_ROW_HEIGHT: number = 114;

const VOICE_OPTIONS: VoiceOption[] = [
  { voiceName: 'zh-CN-liaoning-XiaobeiNeural', displayName: '晓北（辽宁）', gender: '女声', language: 'zh-CN' },
  { voiceName: 'zh-CN-XiaoxiaoNeural', displayName: '晓晓', gender: '女声', language: 'zh-CN' },
  { voiceName: 'zh-CN-XiaoyiNeural', displayName: '晓伊', gender: '女声', language: 'zh-CN' },
  { voiceName: 'zh-HK-HiuGaaiNeural', displayName: '晓佳（粤语）', gender: '女声', language: 'zh-HK' },
  { voiceName: 'zh-CN-YunjianNeural', displayName: '云健', gender: '男声', language: 'zh-CN' },
  { voiceName: 'zh-CN-YunxiNeural', displayName: '云希', gender: '男声', language: 'zh-CN' },
  { voiceName: 'zh-CN-YunyangNeural', displayName: '云扬', gender: '男声', language: 'zh-CN' },
  { voiceName: 'zh-HK-WanLungNeural', displayName: '云龙（粤语）', gender: '男声', language: 'zh-HK' },
  { voiceName: 'en-US-AndrewNeural', displayName: 'Andrew（英语）', gender: '男声', language: 'en-US' },
  { voiceName: 'en-GB-RyanNeural', displayName: 'Ryan（英语）', gender: '男声', language: 'en-GB' },
  { voiceName: 'en-GB-SoniaNeural', displayName: 'Sonia（英语）', gender: '女声', language: 'en-GB' },
  { voiceName: 'en-US-AnaNeural', displayName: 'Ana（英语）', gender: '女声', language: 'en-US' },
  { voiceName: 'en-US-EmmaNeural', displayName: 'Emma（英语）', gender: '女声', language: 'en-US' },
];

@Entry
@Component
struct AudioFilesPage {
  @State bookId: number = 0;
  @State bookTitle: string = '';
  @State bookAuthor: string = '';
  @State bookCover: string = '';
  @State @Watch('onFilesChanged') files: AudioFileInfo[] = [];
  @State loading: boolean = true;
  @State errorMessage: string = '';
  @State busy: boolean = false;
  @State converting: boolean = false;
  @State conversionHint: string = '';
  @State isPaid: boolean = false;
  @State actionHint: string = '';
  @State showVoiceSheet: boolean = false;
  @State selectedVoice: string = 'zh-CN-YunjianNeural';
  @State convertedChapters: number = 0;
  @State totalChapters: number = 0;
  @State currentChapterTitle: string = '';
  @State conversionError: string = '';
  private pollTimer: number = -1;
  private filesSource: LazyDataSource<AudioFileInfo> = new LazyDataSource<AudioFileInfo>();

  /** files 变更后同步 LazyForEach 数据源，避免逐处手写 update。 */
  private onFilesChanged(): void {
    this.filesSource.update(this.files);
  }

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.bookId = Number(params['bookId'] ?? 0);
    this.bookTitle = String(params['title'] ?? '');
    this.bookAuthor = String(params['author'] ?? '');
    this.bookCover = String(params['cover'] ?? '');
    const savedVoice = TalebookService.prefGet('last_audio_voice', '');
    if (savedVoice.length > 0) {
      this.selectedVoice = savedVoice;
    }
    void this.reloadAll();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private stopPoll(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private schedulePoll(): void {
    this.stopPoll();
    if (!this.converting) {
      return;
    }
    this.pollTimer = setTimeout(() => {
      void this.refreshConversion(true);
    }, 2000);
  }

  private async reloadAll(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.errorMessage = '请先配置 Talebook 服务器';
        this.files = [];
        return;
      }
      await this.loadFiles();
      await this.refreshConversion(false);
    } finally {
      this.loading = false;
    }
  }

  private async loadFiles(): Promise<void> {
    try {
      const rsp: AudioInfoResponse = await TalebookApi.getAudioList(this.bookId);
      const err = rsp.err ?? rsp.status ?? '';
      if (err.length > 0 && err !== 'ok' && err !== 'ready' && err !== 'available') {
        // audio.not_found / unavailable：列表为空但可发起转换
        if (err === 'audio.not_found' || err === 'unavailable') {
          this.files = [];
          this.errorMessage = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '暂无音频文件';
          this.isPaid = false;
          return;
        }
        this.errorMessage = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : err;
        this.files = [];
        return;
      }
      this.files = rsp.audios ?? [];
      this.isPaid = Boolean(rsp.is_paid);
      this.errorMessage = this.files.length === 0
        ? (rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '暂无音频文件')
        : '';
    } catch (e) {
      this.errorMessage = `${e}`;
      this.files = [];
    }
  }

  private async refreshConversion(fromPoll: boolean): Promise<void> {
    if (this.bookId <= 0) {
      return;
    }
    try {
      const rsp: AudioConversionResponse = await TalebookApi.getAudioConversionStatus(this.bookId);
      const progress = rsp.data;
      const status = progress !== undefined && progress.status !== undefined ? progress.status : '';
      const percent = progress !== undefined && progress.percent !== undefined ? progress.percent : -1;
      const message = progress !== undefined && progress.message !== undefined ? progress.message : '';
      const converted = progress !== undefined && progress.converted_chapters !== undefined
        ? progress.converted_chapters : -1;
      const total = progress !== undefined && progress.total_chapters !== undefined
        ? progress.total_chapters : 0;
      const chapterRaw = progress !== undefined && progress.current_chapter !== undefined
        ? progress.current_chapter : undefined;
      const chapterTitle = chapterRaw !== undefined ? String(chapterRaw['title'] ?? '') : '';
      const errorMsg = progress !== undefined && progress.error_message !== undefined
        ? String(progress.error_message) : '';
      this.convertedChapters = converted >= 0 ? converted : 0;
      this.totalChapters = total > 0 ? total : 0;
      this.currentChapterTitle = chapterTitle;
      this.conversionError = errorMsg;
      const running = status === 'running' || status === 'pending' || status === 'converting' ||
        status === 'processing' || status === 'importing' || (percent >= 0 && percent < 100 &&
        status.length > 0 && status !== 'done' && status !== 'finished' && status !== 'success' &&
        status !== 'idle' && status !== 'none');

      // 无任务时接口也可能返回 err
      if (!running && (rsp.err === undefined || rsp.err === 'ok' || rsp.err === 'audio.not_found' ||
        rsp.err === 'not_found' || rsp.err === 'idle')) {
        if (fromPoll && this.converting) {
          // 刚结束：刷新文件列表
          this.converting = false;
          this.conversionHint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '转换已结束';
          this.stopPoll();
          await this.loadFiles();
          return;
        }
        this.converting = false;
        this.conversionHint = message.length > 0 ? message : (rsp.msg ?? '');
        this.stopPoll();
        return;
      }

      if (running) {
        this.converting = true;
        const pct = percent >= 0 ? ` ${percent}%` : '';
        this.conversionHint = message.length > 0
          ? `${message}${pct}`
          : `转换中${pct}`;
        this.schedulePoll();
        return;
      }

      this.converting = false;
      this.conversionHint = rsp.msg ?? message;
      this.stopPoll();
    } catch (e) {
      if (!fromPoll) {
        this.conversionHint = '';
      }
      // 轮询失败不打断，稍后再试
      if (this.converting) {
        this.schedulePoll();
      }
    }
  }

  private startConversion(): void {
    if (this.busy || this.bookId <= 0) {
      return;
    }
    this.showVoiceSheet = true;
  }

  private async startConversionWithVoice(voice: string): Promise<void> {
    if (this.busy || this.bookId <= 0) {
      return;
    }
    const option = VOICE_OPTIONS.find((item: VoiceOption) => item.voiceName === voice);
    const language = option !== undefined ? option.language : 'zh-CN';
    this.selectedVoice = voice;
    TalebookService.prefSet('last_audio_voice', voice);
    this.showVoiceSheet = false;
    this.convertedChapters = 0;
    this.totalChapters = 0;
    this.currentChapterTitle = '';
    this.conversionError = '';
    this.busy = true;
    try {
      const rsp: AudioConversionResponse = await TalebookApi.startAudioConversion(this.bookId, voice, language);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        const errMsg = apiErrorMessage(rsp as ApiMessageResult);
        this.toast(errMsg.length > 0 ? errMsg : '启动转换失败');
        return;
      }
      this.converting = true;
      this.conversionHint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已开始转换';
      this.toast(this.conversionHint);
      this.schedulePoll();
      await this.refreshConversion(false);
    } catch (e) {
      this.toast(`启动转换失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private async cancelConversion(): Promise<void> {
    if (this.busy || this.bookId <= 0) {
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.cancelAudioConversion(this.bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '取消失败');
        return;
      }
      this.converting = false;
      this.stopPoll();
      this.conversionHint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已取消转换';
      this.toast(this.conversionHint);
    } catch (e) {
      this.toast(`取消失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private async purchase(): Promise<void> {
    if (this.busy || this.bookId <= 0) {
      return;
    }
    this.busy = true;
    try {
      const rsp: AudioPurchaseResponse = await TalebookApi.purchaseAudio(this.bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        const errMsg = apiErrorMessage(rsp as ApiMessageResult);
        this.toast(errMsg.length > 0 ? errMsg : '购买失败');
        return;
      }
      this.isPaid = true;
      const msg = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '购买成功';
      this.actionHint = msg;
      this.toast(msg);
      await this.loadFiles();
    } catch (e) {
      this.toast(`购买失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private async createCollection(): Promise<void> {
    if (this.busy || this.bookId <= 0) {
      return;
    }
    this.busy = true;
    try {
      const rsp: AudioCollectionResponse = await TalebookApi.createAudioCollectionDownload(this.bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        const errMsg = apiErrorMessage(rsp as ApiMessageResult);
        this.toast(errMsg.length > 0 ? errMsg : '打包失败');
        return;
      }
      let hint = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg :
        (rsp.message !== undefined && rsp.message.length > 0 ? rsp.message : '打包完成');
      if (rsp.download_url !== undefined && rsp.download_url.length > 0) {
        hint = `${hint}\n${rsp.download_url}`;
      }
      this.actionHint = hint;
      this.toast(rsp.download_url !== undefined && rsp.download_url.length > 0
        ? '已生成打包下载链接（见页面提示）'
        : hint);
    } catch (e) {
      this.toast(`打包失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  private confirmDelete(): void {
    if (this.busy || this.bookId <= 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除音频',
      message: '确认删除本书全部音频文件？此操作不可恢复。',
      primaryButton: {
        value: '删除',
        action: () => {
          void this.deleteAudio();
        },
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        },
      },
    });
  }

  private async deleteAudio(): Promise<void> {
    if (this.busy || this.bookId <= 0) {
      return;
    }
    this.busy = true;
    try {
      const rsp: ApiMessageResult = await TalebookApi.deleteAudio(this.bookId);
      if (rsp.err !== undefined && rsp.err !== 'ok') {
        this.toast(apiErrorMessage(rsp).length > 0 ? apiErrorMessage(rsp) : '删除失败');
        return;
      }
      this.toast(rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '已删除');
      this.files = [];
      this.errorMessage = '暂无音频文件';
      this.actionHint = '';
    } catch (e) {
      this.toast(`删除失败：${e}`);
    } finally {
      this.busy = false;
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private onFileTap(file: AudioFileInfo, index: number): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/AudioPlayerPage',
      params: {
        bookId: this.bookId,
        title: this.bookTitle,
        author: this.bookAuthor,
        cover: this.bookCover,
        startIndex: index,
      },
    });
  }

  private formatSize(size: number): string {
    if (size <= 0) {
      return '';
    }
    if (size >= 1024 * 1024) {
      return `${(size / (1024 * 1024)).toFixed(1)} MB`;
    }
    return `${Math.round(size / 1024)} KB`;
  }

  /** 全部音频合计大小（列表头展示）。 */
  private totalSizeText(): string {
    let bytes = 0;
    for (const file of this.files) {
      bytes += file.size;
    }
    return this.formatSize(bytes);
  }

  /** 当前音色的展示名（用于快捷操作与按钮文案）。 */
  private voiceLabel(): string {
    const option = VOICE_OPTIONS.find((item: VoiceOption) => item.voiceName === this.selectedVoice);
    return option !== undefined ? option.displayName : '默认';
  }

  private fileTitle(file: AudioFileInfo, index: number): string {
    return file.filename.length > 0 ? file.filename : `音频 ${index + 1}`;
  }

  build() {
    Column() {
      PageScaffold({
        title: this.bookTitle.length > 0 ? this.bookTitle : '音频文件',
        showBack: true,
        content: () => {
          this.audioContent();
        },
      });
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.showVoiceSheet, this.voiceSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: true,
      title: { title: '选择语音' },
    });
  }

  @Builder
  voiceSheet() {
    Column({ space: 4 }) {
      List({ space: 2 }) {
        ForEach(VOICE_OPTIONS, (voice: VoiceOption) => {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text(voice.displayName)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'));
                Text(voice.gender)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'));
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
              if (this.selectedVoice === voice.voiceName) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(18)
                  .fontColor([$r('app.color.brand_primary')]);
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 11, bottom: 11 })
            .borderRadius(8)
            .backgroundColor(this.selectedVoice === voice.voiceName ?
              $r('app.color.brand_primary_light') : Color.Transparent)
            .onClick(() => {
              void this.startConversionWithVoice(voice.voiceName);
            });
          }
        }, (voice: VoiceOption) => voice.voiceName);
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off);
    }
    .width('100%')
    .height(380)
    .padding({ top: 4, bottom: 8 });
  }

  @Builder
  audioContent() {
    if (this.loading) {
      LoadingState({});
    } else {
      Column({ space: 12 }) {
        this.bookCard();
        this.statusBanner();
        this.primaryAction();
        this.quickActions();

        if (this.files.length === 0) {
          EmptyState({
            message: this.errorMessage.length > 0 ? this.errorMessage : '暂无音频文件',
            detail: '点上方「开始语音转换」为该书籍生成音频。',
          });
        } else {
          this.listHeader();
          List({ space: 8 }) {
            LazyForEach(this.filesSource, (file: AudioFileInfo, index: number) => {
              ListItem() {
                this.fileRow(file, index);
              }
            }, (file: AudioFileInfo, index: number) => `${file.filename}_${index}`);
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off);
          DangerButton({
            label: '删除全部音频',
            buttonEnabled: !this.busy,
            onTap: () => {
              this.confirmDelete();
            },
          });
        }
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      .width('100%')
      .height('100%');
    }
  }

  /** 书籍信息卡：封面 + 书名/作者 + 音频概览（数量/总大小/是否已购买）。 */
  @Builder
  bookCard() {
    Row({ space: 12 }) {
      if (this.bookCover.length > 0) {
        AuthImage({
          url: this.bookCover,
          imageWidth: 56,
          imageHeight: 76,
          radius: $r('app.float.cover_radius'),
        });
      }
      Column({ space: 5 }) {
        Text(this.bookTitle.length > 0 ? this.bookTitle : '音频文件')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        if (this.bookAuthor.length > 0) {
          Text(this.bookAuthor)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        Row({ space: 8 }) {
          Text(this.files.length > 0
            ? `${this.files.length} 个音频 · 共 ${this.totalSizeText()}`
            : '还没有音频')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'));
          if (this.isPaid) {
            Text('已购买')
              .fontSize(11)
              .fontColor($r('app.color.success'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius($r('app.float.badge_radius'))
              .backgroundColor($r('app.color.success_light'));
          }
        };
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'));
  }

  /**
   * 状态横幅：把原来散落的 6 行小字（转换中/进度/正在转换/失败/已购买/操作结果）收进一块，
   * 失败用浅红、进行中用浅蓝，进度条与章节文案跟在横幅里。
   */
  @Builder
  statusBanner() {
    if (this.conversionError.length > 0) {
      Column({ space: 4 }) {
        Text(`转换失败：${this.conversionError}`)
          .fontSize(12)
          .fontColor($r('app.color.error'))
          .width('100%');
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius($r('app.float.chip_radius'))
      .backgroundColor($r('app.color.error_light'));
    } else if (this.converting || this.conversionHint.length > 0) {
      Column({ space: 8 }) {
        Text(this.converting ? `转换中：${this.conversionHint}` : this.conversionHint)
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'))
          .width('100%');
        if (this.converting && this.totalChapters > 0) {
          Progress({
            value: this.convertedChapters,
            total: this.totalChapters,
            type: ProgressType.Linear,
          })
            .width('100%')
            .height(4)
            .color($r('app.color.brand_primary'))
            .backgroundColor($r('app.color.divider'));
          Text(`已完成 ${this.convertedChapters}/${this.totalChapters} 章`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
        }
        if (this.currentChapterTitle.length > 0) {
          Text(`正在转换：${this.currentChapterTitle}`)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius($r('app.float.chip_radius'))
      .backgroundColor($r('app.color.brand_primary_light'));
    } else if (this.actionHint.length > 0) {
      Text(this.actionHint)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius($r('app.float.chip_radius'))
        .backgroundColor($r('app.color.card_background'));
    }
  }

  /** 主操作：开始/取消语音转换（开始按钮带上当前音色，避免再去猜用哪个音色）。 */
  @Builder
  primaryAction() {
    if (this.converting) {
      SecondaryButton({
        label: this.busy ? '处理中…' : '取消转换',
        buttonEnabled: !this.busy,
        onTap: () => {
          void this.cancelConversion();
        },
      });
    } else {
      PrimaryButton({
        label: this.busy ? '处理中…' : `开始语音转换 · ${this.voiceLabel()}`,
        buttonEnabled: !this.busy,
        onTap: () => {
          this.startConversion();
        },
      });
    }
  }

  /** 次级操作收进四宫格，替掉原来 5 个占满整行的大按钮。 */
  private quickActionItems(): QuickActionItem[] {
    return [
      {
        icon: $r('sys.symbol.speaker'),
        label: `音色 · ${this.voiceLabel()}`,
        onTap: () => {
          if (this.busy) {
            return;
          }
          this.showVoiceSheet = true;
        },
      },
      {
        icon: $r('sys.symbol.cart'),
        label: this.isPaid ? '已购买' : '购买音频',
        onTap: () => {
          if (this.isPaid) {
            this.toast('已购买音频');
            return;
          }
          void this.purchase();
        },
      },
      {
        icon: $r('sys.symbol.archivebox_fill'),
        label: '打包下载',
        onTap: () => {
          if (this.files.length === 0) {
            this.toast('暂无可下载的音频');
            return;
          }
          void this.createCollection();
        },
      },
      {
        icon: $r('sys.symbol.arrow_clockwise'),
        label: '刷新',
        onTap: () => {
          void this.reloadAll();
        },
      },
    ];
  }

  @Builder
  quickActions() {
    // QuickActionGrid 内部的 Grid 不设高时会撑满 Column 的剩余空间，把下面的列表整段挤出屏幕，
    // 所以这里套一层固定为一行的容器（图标 48 + 间距 6 + 文案 16 + 单元格内边距 16 + 网格内边距 28）。
    Column() {
      QuickActionGrid({ items: this.quickActionItems() });
    }
    .width('100%')
    .height(QUICK_ACTION_ROW_HEIGHT);
  }

  /** 列表头：与页面 16vp 边距对齐（不用 SectionTitle，它自带左右 16 会造成双重缩进）。 */
  @Builder
  listHeader() {
    Row() {
      Text('音频章节')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Blank();
      Text(`${this.files.length} 个 · 共 ${this.totalSizeText()}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'));
    }
    .width('100%')
    .padding({ top: 2, bottom: 2 });
  }

  @Builder
  fileRow(file: AudioFileInfo, index: number) {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.play_circle'))
          .fontSize(20)
          .fontColor([$r('app.color.brand_primary')]);
      }
      .width(36)
      .height(36)
      .justifyContent(FlexAlign.Center)
      .borderRadius(18)
      .backgroundColor($r('app.color.brand_primary_light'));

      Column({ space: 3 }) {
        Text(this.fileTitle(file, index))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${index + 1}${this.formatSize(file.size).length > 0 ? ` · ${this.formatSize(file.size)}` : ''}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'));
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('app.color.text_tertiary')]);
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .onClick(() => {
      this.onFileTap(file, index);
    });
  }
}
