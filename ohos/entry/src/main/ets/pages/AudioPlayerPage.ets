import { common } from '@kit.AbilityKit';
import { PageScaffold, LoadingState, EmptyState, AuthImage } from '../components';
import { AudioFileInfo } from '../common/ApiTypes';
import { AudioPlaybackListener, AudioPlaybackService, AudioPlaybackState } from '../services/AudioPlaybackService';

const SPEEDS: number[] = [0.75, 1, 1.25, 1.5, 2];

/**
 * 听书播放页：只做状态绑定，播放器归 AudioPlaybackService（单例）所有。
 * 因此离开本页（返回/切页）不会中断播放，App 退后台/锁屏也能继续播，并可在系统播控中心控制。
 */
@Entry
@Component
struct AudioPlayerPage {
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
  private bookId: number = 0;
  private sliderDragging: boolean = false;
  private listener: AudioPlaybackListener = (state: AudioPlaybackState): void => {
    this.applyState(state);
  };

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    // 书名/作者/封面要先存局部变量：applyState 会立刻用服务状态覆盖 @State，
    // 之后再从 this.* 取值会拿到被覆盖后的空串（元数据会因此丢掉书名与封面）。
    this.bookId = Number(params['bookId'] ?? 0);
    const title = String(params['title'] ?? '');
    const author = String(params['author'] ?? '');
    const cover = String(params['cover'] ?? '');
    const startIndex = Number(params['startIndex'] ?? 0);
    // 播控中心/通知回跳时只回到播放页，不打断正在播的章节
    const resumeParam = params['resume'];
    const resume = resumeParam === true || resumeParam === 'true';
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const service = AudioPlaybackService.getInstance();
    service.addListener(this.listener);
    // 先按服务当前状态渲染（同一本书回跳时能立刻显示播放进度）
    this.applyState(service.currentState());
    void service.openBook(context, this.bookId, title, author, cover, startIndex, resume);
  }

  aboutToDisappear(): void {
    // 只解绑 UI，不释放播放器：听书后台播放要继续
    AudioPlaybackService.getInstance().removeListener(this.listener);
  }

  private applyState(state: AudioPlaybackState): void {
    this.bookTitle = state.bookTitle;
    this.bookAuthor = state.bookAuthor;
    this.bookCover = state.bookCover;
    this.files = state.files;
    this.loading = state.loading;
    this.errorMessage = state.errorMessage;
    this.currentIndex = state.currentIndex;
    this.isPlaying = state.isPlaying;
    this.currentTimeMs = state.currentTimeMs;
    this.durationMs = state.durationMs;
    this.trackLoading = state.trackLoading;
    this.speed = state.speed;
    if (!this.sliderDragging) {
      this.sliderValue = state.durationMs > 0 ? state.currentTimeMs / state.durationMs * 100 : 0;
    }
    if (state.notice.length > 0) {
      const notice = AudioPlaybackService.getInstance().consumeNotice();
      if (notice.length > 0) {
        this.toast(notice);
      }
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
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
            .onClick(() => AudioPlaybackService.getInstance().playIndex(index));
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
              AudioPlaybackService.getInstance().seekToPercent(value);
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
          .onClick(() => AudioPlaybackService.getInstance().previous());
        if (this.trackLoading) {
          LoadingState({});
        } else {
          SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_circle') : $r('sys.symbol.play_circle'))
            .fontSize(56)
            .fontColor([$r('app.color.brand_primary')])
            .onClick(() => AudioPlaybackService.getInstance().toggle());
        }
        SymbolGlyph($r('sys.symbol.arrow_right'))
          .fontSize(26)
          .fontColor([this.currentIndex < this.files.length - 1 ? $r('app.color.text_primary') : $r('app.color.text_tertiary')])
          .onClick(() => AudioPlaybackService.getInstance().next());
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
            .onClick(() => AudioPlaybackService.getInstance().setSpeed(value));
        }, (value: number) => `speed-${value}`);
      }
      .width('100%')
      .justifyContent(FlexAlign.Center);
    }
    .width('100%');
  }
}
