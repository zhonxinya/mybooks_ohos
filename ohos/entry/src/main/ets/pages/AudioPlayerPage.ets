import { router } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PageScaffold, LoadingState, EmptyState, AuthImage } from '../components';
import { TalebookApi, AudioInfoResponse } from '../services/TalebookApi';
import { AudioFileInfo } from '../common/ApiTypes';
import { TalebookService } from '../services/TalebookService';

const SPEEDS: number[] = [0.75, 1, 1.25, 1.5, 2];

@Entry
@Component
struct AudioPlayerPage {
  @State bookId: number = 0;
  @State bookTitle: string = '';
  @State bookAuthor: string = '';
  @State bookCover: string = '';
  @State files: AudioFileInfo[] = [];
  @State loading: boolean = true;
  @State errorMessage: string = '';
  @State currentIndex: number = 0;
  @State isPlaying: boolean = false;
  @State currentTimeMs: number = 0;
  @State durationMs: number = 0;
  @State trackLoading: boolean = false;
  @State speed: number = 1;
  @State sliderValue: number = 0;
  private avPlayer: media.AVPlayer | null = null;
  private audioDir: string = '';
  private switching: boolean = false;
  private sliderDragging: boolean = false;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.bookId = Number(params['bookId'] ?? 0);
    this.bookTitle = String(params['title'] ?? '');
    this.bookAuthor = String(params['author'] ?? '');
    this.bookCover = String(params['cover'] ?? '');
    const context = getContext(this) as common.UIAbilityContext;
    this.audioDir = `${context.filesDir}/audio/${this.bookId}`;
    void this.loadList();
  }

  aboutToDisappear(): void {
    this.releasePlayer();
    this.cleanupDistantAudioFiles();
  }

  /** 只保留当前曲目附近缓存，控制 audio 目录膨胀 */
  private cleanupDistantAudioFiles(): void {
    if (this.files.length === 0 || this.audioDir.length === 0) {
      return;
    }
    const keep = new Set<string>();
    for (let i = Math.max(0, this.currentIndex - 1); i <= Math.min(this.files.length - 1, this.currentIndex + 1); i++) {
      keep.add(this.files[i].filename);
    }
    try {
      if (!fs.accessSync(this.audioDir)) {
        return;
      }
      const names = fs.listFileSync(this.audioDir);
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        if (!keep.has(name)) {
          try {
            fs.unlinkSync(`${this.audioDir}/${name}`);
          } catch (_error) {
          }
        }
      }
    } catch (_error) {
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async loadList(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.errorMessage = '请先配置 Talebook 服务器';
        return;
      }
      const rsp: AudioInfoResponse = await TalebookApi.getAudioList(this.bookId);
      const err = rsp.err ?? rsp.status ?? '';
      if (err.length > 0 && err !== 'ok' && err !== 'ready' && err !== 'available') {
        this.errorMessage = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '暂无音频文件';
        return;
      }
      this.files = rsp.audios ?? [];
      if (this.files.length === 0) {
        this.errorMessage = rsp.msg !== undefined && rsp.msg.length > 0 ? rsp.msg : '暂无音频文件';
        return;
      }
      const params = router.getParams() as Record<string, Object>;
      const start = Number(params['startIndex'] ?? 0);
      this.currentIndex = start >= 0 && start < this.files.length ? start : 0;
      void this.loadTrack(this.currentIndex);
    } catch (error) {
      this.errorMessage = `加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  private localPath(filename: string): string {
    return `${this.audioDir}/${filename}`;
  }

  private hasLocalFile(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_error) {
      return false;
    }
  }

  private async ensureLocalFile(filename: string): Promise<string> {
    const path = this.localPath(filename);
    if (this.hasLocalFile(path)) {
      return path;
    }
    try {
      if (!fs.accessSync(this.audioDir)) {
        fs.mkdirSync(this.audioDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(this.audioDir, true);
    }
    const envelope = await TalebookService.downloadAudioFileAsync(this.bookId, filename, path);
    if (!TalebookService.isApiSuccess(envelope)) {
      throw new Error(envelope.error.length > 0 ? envelope.error : '下载失败');
    }
    if (!this.hasLocalFile(path)) {
      throw new Error('文件未写入');
    }
    return path;
  }

  private async loadTrack(index: number): Promise<void> {
    if (index < 0 || index >= this.files.length || this.switching) {
      return;
    }
    this.switching = true;
    this.trackLoading = true;
    this.currentIndex = index;
    this.currentTimeMs = 0;
    this.durationMs = 0;
    this.sliderValue = 0;
    try {
      const file = this.files[index];
      const path = await this.ensureLocalFile(file.filename);
      if (this.avPlayer === null) {
        this.avPlayer = await media.createAVPlayer();
        this.bindPlayerEvents();
      }
      this.avPlayer.url = `file://${path}`;
      await this.avPlayer.prepare();
      await this.avPlayer.setSpeed(this.speed);
      await this.avPlayer.play();
      this.isPlaying = true;
    } catch (error) {
      this.toast(`播放失败：${error}`);
      this.isPlaying = false;
    } finally {
      this.trackLoading = false;
      this.switching = false;
    }
  }

  private bindPlayerEvents(): void {
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    player.on('stateChange', (state: media.AVPlayerState) => {
      if (state === 'completed') {
        this.isPlaying = false;
        if (this.currentIndex < this.files.length - 1) {
          void this.loadTrack(this.currentIndex + 1);
        } else {
          this.currentTimeMs = 0;
          this.sliderValue = 0;
        }
      } else if (state === 'error') {
        this.isPlaying = false;
      }
    });
    player.on('timeUpdate', (time: number) => {
      if (this.sliderDragging) {
        return;
      }
      // 节流：约 4fps，避免整页高频重建
      if (Math.abs(time - this.currentTimeMs) < 250) {
        return;
      }
      this.currentTimeMs = time;
      this.sliderValue = this.durationMs > 0 ? time / this.durationMs * 100 : 0;
    });
    player.on('durationUpdate', (duration: number) => {
      this.durationMs = duration;
    });
    player.on('error', (err: BusinessError) => {
      this.toast(`播放错误：${err.message ?? err.code}`);
    });
  }

  private releasePlayer(): void {
    if (this.avPlayer !== null) {
      this.avPlayer.release();
      this.avPlayer = null;
    }
  }

  private togglePlay(): void {
    const player = this.avPlayer;
    if (player === null || this.trackLoading) {
      return;
    }
    if (this.isPlaying) {
      player.pause();
      this.isPlaying = false;
    } else {
      player.play();
      this.isPlaying = true;
    }
  }

  private seekTo(percent: number): void {
    const player = this.avPlayer;
    if (player === null || this.durationMs <= 0) {
      return;
    }
    const target = Math.round(this.durationMs * percent / 100);
    player.seek(target);
    this.currentTimeMs = target;
  }

  private changeSpeed(value: number): void {
    this.speed = value;
    if (this.avPlayer !== null) {
      this.avPlayer.setSpeed(value);
    }
  }

  private formatTime(ms: number): string {
    const totalSeconds = Math.max(0, Math.floor(ms / 1000));
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
  }

  private displayName(file: AudioFileInfo, index: number): string {
    if (file.filename.length > 0) {
      return file.filename;
    }
    return `音频 ${index + 1}`;
  }

  build() {
    Column() {
      PageScaffold({
        title: '音频播放',
        showBack: true,
        content: () => {
          this.playerContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  playerContent() {
    if (this.loading) {
      LoadingState({});
    } else if (this.files.length === 0) {
      EmptyState({ message: this.errorMessage.length > 0 ? this.errorMessage : '暂无音频文件' });
    } else {
      Column({ space: 12 }) {
        this.coverSection();
        this.playlistSection();
        this.controlSection();
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
  }

  @Builder
  coverSection() {
    Column({ space: 8 }) {
      AuthImage({
        url: this.bookCover,
        imageWidth: 168,
        imageHeight: 224,
      });
      Text(this.bookTitle.length > 0 ? this.bookTitle : '有声书')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center);
      if (this.bookAuthor.length > 0) {
        Text(this.bookAuthor)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  playlistSection() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('章节列表')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Text(`${this.currentIndex + 1}/${this.files.length}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%');
      List({ space: 4 }) {
        ForEach(this.files, (file: AudioFileInfo, index: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(`${index + 1}`)
                .fontSize(13)
                .fontColor(index === this.currentIndex ? $r('app.color.brand_primary') : $r('app.color.text_tertiary'))
                .width(24);
              Text(this.displayName(file, index))
                .fontSize(14)
                .fontColor(index === this.currentIndex ? $r('app.color.brand_primary') : $r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
              if (index === this.currentIndex && this.trackLoading) {
                LoadingState({});
              } else if (index === this.currentIndex && this.isPlaying) {
                SymbolGlyph($r('sys.symbol.speaker'))
                  .fontSize(16)
                  .fontColor([$r('app.color.brand_primary')]);
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .borderRadius(8)
            .backgroundColor(index === this.currentIndex ? $r('app.color.brand_primary_light') : Color.Transparent)
            .onClick(() => {
              if (index !== this.currentIndex) {
                void this.loadTrack(index);
              }
            });
          }
        }, (file: AudioFileInfo, index: number) => `${file.filename}_${index}`);
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off);
    }
    .width('100%')
    .layoutWeight(1);
  }

  @Builder
  controlSection() {
    Column({ space: 10 }) {
      Row() {
        Text(this.formatTime(this.currentTimeMs))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
        Slider({
          value: this.sliderValue,
          min: 0,
          max: 100,
          step: 0.5,
          style: SliderStyle.OutSet,
        })
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin) {
              this.sliderDragging = true;
            } else if (mode === SliderChangeMode.Moving) {
              this.sliderValue = value;
            } else if (mode === SliderChangeMode.End) {
              this.sliderDragging = false;
              this.seekTo(value);
            }
          });
        Text(this.formatTime(this.durationMs))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%');

      Row({ space: 24 }) {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(26)
          .fontColor([this.currentIndex > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary')])
          .onClick(() => {
            if (this.currentIndex > 0) {
              void this.loadTrack(this.currentIndex - 1);
            }
          });
        if (this.trackLoading) {
          LoadingState({});
        } else {
          SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_circle') : $r('sys.symbol.play_circle'))
            .fontSize(56)
            .fontColor([$r('app.color.brand_primary')])
            .onClick(() => this.togglePlay());
        }
        SymbolGlyph($r('sys.symbol.arrow_right'))
          .fontSize(26)
          .fontColor([this.currentIndex < this.files.length - 1 ? $r('app.color.text_primary') : $r('app.color.text_tertiary')])
          .onClick(() => {
            if (this.currentIndex < this.files.length - 1) {
              void this.loadTrack(this.currentIndex + 1);
            }
          });
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center);

      Row({ space: 8 }) {
        ForEach(SPEEDS, (value: number) => {
          Text(value === 1 ? '1x' : `${value}x`)
            .fontSize(12)
            .fontColor(this.speed === value ? $r('app.color.brand_primary') : $r('app.color.text_secondary'))
            .fontWeight(this.speed === value ? FontWeight.Medium : FontWeight.Normal)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor(this.speed === value ? $r('app.color.brand_primary_light') : Color.Transparent)
            .onClick(() => this.changeSpeed(value));
        }, (value: number) => `speed-${value}`);
      }
      .width('100%')
      .justifyContent(FlexAlign.Center);
    }
    .width('100%');
  }
}
