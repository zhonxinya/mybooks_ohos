import { READER_FLIP_DEFAULT, READER_FLIP_OPTIONS, ReaderFlip, ReaderSettings, ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';

const MIN_FONT_SIZE: number = 12;
const MAX_FONT_SIZE: number = 32;
/** 行高以 10 倍整数参与滑块（步长 1 → 0.1 倍行高）。 */
const MIN_LINE_HEIGHT: number = 12;
const MAX_LINE_HEIGHT: number = 24;

interface ThemeOption {
  theme: ReaderTheme;
  label: string;
}

const THEME_OPTIONS: ThemeOption[] = [
  { theme: ReaderTheme.LIGHT, label: '浅色' },
  { theme: ReaderTheme.EYE, label: '护眼' },
  { theme: ReaderTheme.DARK, label: '夜间' },
];

/**
 * 阅读设置面板（底部）。
 *
 * 拖动中只改本地 draft（滑块跟手、正文不逐帧重排），松手才回调宿主应用。
 * 各行用无参 @Builder：按值传参的 @Builder 不会因参数变化重绘，故状态在 builder 内部直接读取。
 */
@Component
export struct ReaderSettingsSheet {
  @Prop fontSize: number = 18;
  @Prop lineHeight: number = 1.6;
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop flipMode: string = READER_FLIP_DEFAULT;
  @Prop keepScreenOn: boolean = false;
  onSettingsChange: (settings: ReaderSettings) => void = () => {};
  onClose: () => void = () => {};

  @State private draftFontSize: number = 18;
  @State private draftLineHeight: number = 16;

  aboutToAppear(): void {
    this.draftFontSize = this.fontSize;
    this.draftLineHeight = Math.round(this.lineHeight * 10);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => this.onClose());
      Column({ space: 6 }) {
        this.titleRow();
        this.fontSizeRow();
        this.lineHeightRow();
        this.themeRow();
        this.flipRow();
        this.keepScreenOnRow();
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 28 })
      .backgroundColor(ReaderPalette.panelBackground(this.theme))
      .borderRadius({ topLeft: 16, topRight: 16 });
    }
    .width('100%')
    .height('100%')
  }

  /** 当前 draft + 主题组成设置对象回传宿主。 */
  private emit(theme: ReaderTheme, flipMode: string, keepScreenOn: boolean): void {
    const settings: ReaderSettings = {
      fontSize: this.draftFontSize,
      lineHeight: this.draftLineHeight / 10,
      theme: theme,
      flipMode: flipMode,
      keepScreenOn: keepScreenOn,
    };
    this.onSettingsChange(settings);
  }

  @Builder
  titleRow() {
    Row() {
      Text('阅读设置')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(ReaderPalette.textColor(this.theme))
        .layoutWeight(1);
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(20)
        .fontColor([ReaderPalette.hintColor(this.theme)])
        .onClick(() => this.onClose());
    }
    .width('100%')
    .padding({ bottom: 8 });
  }

  @Builder
  fontSizeRow() {
    Row({ space: 12 }) {
      Text('字号')
        .fontSize(14)
        .fontColor(ReaderPalette.textColor(this.theme));
      Slider({ value: this.draftFontSize, min: MIN_FONT_SIZE, max: MAX_FONT_SIZE, step: 1, style: SliderStyle.OutSet })
        .layoutWeight(1)
        .blockColor(ReaderPalette.textColor(this.theme))
        .trackColor(ReaderPalette.dividerColor(this.theme))
        .selectedColor(ReaderPalette.accentColor())
        .onChange((next: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.draftFontSize = Math.round(next);
            this.emit(this.theme, this.flipMode, this.keepScreenOn);
          }
        });
      Text(`${this.draftFontSize}`)
        .fontSize(14)
        .width(40)
        .textAlign(TextAlign.End)
        .fontColor(ReaderPalette.hintColor(this.theme));
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  lineHeightRow() {
    Row({ space: 12 }) {
      Text('行距')
        .fontSize(14)
        .fontColor(ReaderPalette.textColor(this.theme));
      Slider({ value: this.draftLineHeight, min: MIN_LINE_HEIGHT, max: MAX_LINE_HEIGHT, step: 1, style: SliderStyle.OutSet })
        .layoutWeight(1)
        .blockColor(ReaderPalette.textColor(this.theme))
        .trackColor(ReaderPalette.dividerColor(this.theme))
        .selectedColor(ReaderPalette.accentColor())
        .onChange((next: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.draftLineHeight = Math.round(next);
            this.emit(this.theme, this.flipMode, this.keepScreenOn);
          }
        });
      Text((this.draftLineHeight / 10).toFixed(1))
        .fontSize(14)
        .width(40)
        .textAlign(TextAlign.End)
        .fontColor(ReaderPalette.hintColor(this.theme));
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  themeRow() {
    Row({ space: 12 }) {
      Text('主题')
        .fontSize(14)
        .fontColor(ReaderPalette.textColor(this.theme));
      ForEach(THEME_OPTIONS, (option: ThemeOption) => {
        Text(option.label)
          .fontSize(14)
          .fontColor(this.theme === option.theme ? ReaderPalette.accentColor() : ReaderPalette.textColor(this.theme))
          .backgroundColor(this.theme === option.theme ?
            ReaderPalette.selectedBackground(this.theme) : Color.Transparent)
          .borderRadius(8)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .onClick(() => this.emit(option.theme, this.flipMode, this.keepScreenOn));
      }, (option: ThemeOption) => option.label);
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  flipRow() {
    Row({ space: 8 }) {
      Text('翻页')
        .fontSize(14)
        .fontColor(ReaderPalette.textColor(this.theme));
      ForEach(READER_FLIP_OPTIONS, (mode: string) => {
        Text(ReaderFlip.label(mode))
          .fontSize(13)
          .fontColor(this.flipMode === mode ? ReaderPalette.accentColor() : ReaderPalette.textColor(this.theme))
          .backgroundColor(this.flipMode === mode ?
            ReaderPalette.selectedBackground(this.theme) : Color.Transparent)
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .onClick(() => this.emit(this.theme, mode, this.keepScreenOn));
      }, (mode: string) => mode);
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  keepScreenOnRow() {
    Row({ space: 8 }) {
      Text('常亮')
        .fontSize(14)
        .fontColor(ReaderPalette.textColor(this.theme))
        .layoutWeight(1);
      Toggle({ type: ToggleType.Switch, isOn: this.keepScreenOn })
        .selectedColor(ReaderPalette.accentColor())
        .onChange((isOn: boolean) => this.emit(this.theme, this.flipMode, isOn));
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center);
  }
}
