import { router } from '@kit.ArkUI';
import {
  PageScaffold, EmptyState, LoadingState, SettingCell,
  PrimaryButton, SecondaryButton, DangerButton, LazyDataSource
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
    const params = router.getParams() as Record<string, Object>;
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
    this.getUIContext().getPromptAction().showToast({ message: message });
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

  private onFileTap(file: AudioFileInfo, index: number): void {
    router.pushUrl({
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
        if (this.conversionHint.length > 0 || this.converting) {
          Text(this.converting
            ? `转换中：${this.conversionHint}`
            : this.conversionHint)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
        }
        if (this.converting && this.totalChapters > 0) {
          Progress({
            value: this.convertedChapters,
            total: this.totalChapters,
            type: ProgressType.Linear,
          })
            .width('100%')
            .color($r('app.color.brand_primary'));
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
        if (this.conversionError.length > 0) {
          Text(`转换失败：${this.conversionError}`)
            .fontSize(12)
            .fontColor($r('app.color.error'))
            .width('100%');
        }
        if (this.isPaid) {
          Text('已购买音频')
            .fontSize(12)
            .fontColor($r('app.color.success'))
            .width('100%');
        }
        if (this.actionHint.length > 0) {
          Text(this.actionHint)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%');
        }

        this.actionButtons();

        if (this.files.length === 0) {
          EmptyState({
            message: this.errorMessage.length > 0 ? this.errorMessage : '暂无音频文件',
          });
        } else {
          List() {
            LazyForEach(this.filesSource, (file: AudioFileInfo) => {
              ListItem() {
                SettingCell({
                  title: file.filename.length > 0 ? file.filename :
                    `音频 ${this.files.indexOf(file) + 1}`,
                  subtitle: this.formatSize(file.size),
                  showChevron: true,
                  onTap: () => {
                    this.onFileTap(file, this.files.indexOf(file));
                  },
                });
              }
            }, (file: AudioFileInfo, index: number) => `${file.filename}_${index}`);
          }
          .layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider') });
        }
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      .width('100%')
      .height('100%');
    }
  }

  @Builder
  actionButtons() {
    Column({ space: 8 }) {
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
          label: this.busy ? '处理中…' : '开始语音转换',
          buttonEnabled: !this.busy,
          onTap: () => {
            void this.startConversion();
          },
        });
      }
      SecondaryButton({
        label: '购买音频',
        buttonEnabled: !this.busy,
        onTap: () => {
          void this.purchase();
        },
      });
      SecondaryButton({
        label: '打包下载',
        buttonEnabled: !this.busy && this.files.length > 0,
        onTap: () => {
          void this.createCollection();
        },
      });
      SecondaryButton({
        label: '刷新',
        buttonEnabled: !this.busy,
        onTap: () => {
          void this.reloadAll();
        },
      });
      if (this.files.length > 0) {
        DangerButton({
          label: '删除全部音频',
          buttonEnabled: !this.busy,
          onTap: () => {
            this.confirmDelete();
          },
        });
      }
    }
    .width('100%');
  }
}
