import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  READER_FLIP_DEFAULT,
  READER_FLIP_PREF_KEY,
  ReaderCallbacks,
  ReaderFlip,
  ReaderLocation,
  ReaderLocations,
  ReaderOpenOptions,
  ReaderSettings,
  ReaderTheme,
  ReaderView,
} from 'reader';
import { TalebookService } from '../services/TalebookService';
import { ReadKitSession } from '../services/ReadKitSession';
import { WindowAbility } from '../entryability/WindowAbility';

const TAG: string = 'BuiltInReaderPage';

/** 与 `ReaderLauncher` 的 `ReaderOpenParams` 一致。 */
interface BuiltInReaderParams {
  filePath?: string;
  bookId?: string;
  bookTitle?: string;
  format?: string;
  location?: string;
}

const DEFAULT_FONT_SIZE: number = 18;
const DEFAULT_LINE_HEIGHT: number = 1.6;
const MIN_FONT_SIZE: number = 10;
const MAX_FONT_SIZE: number = 48;
const MIN_LINE_HEIGHT: number = 1;
const MAX_LINE_HEIGHT: number = 3;
const FONT_SIZE_KEY: string = 'reader_font_size';
const LINE_HEIGHT_KEY: string = 'reader_line_height';
const THEME_KEY: string = 'reader_theme';
const KEEP_SCREEN_ON_KEY: string = 'reader_keep_screen_on';
/** 主题取值顺序必须与 `ReaderTheme` 枚举一致。 */
const THEMES: ReaderTheme[] = [ReaderTheme.LIGHT, ReaderTheme.DARK, ReaderTheme.EYE];

const DEFAULT_OPTIONS: ReaderOpenOptions = {
  filePath: '',
  format: '',
  title: '',
  cacheDir: '',
  location: '',
  settings: {
    fontSize: DEFAULT_FONT_SIZE,
    lineHeight: DEFAULT_LINE_HEIGHT,
    theme: ReaderTheme.LIGHT,
    flipMode: READER_FLIP_DEFAULT,
    keepScreenOn: false,
  },
};

const DEFAULT_CALLBACKS: ReaderCallbacks = {
  onProgress: (location: ReaderLocation, chapterTitle: string): void => {},
  onClose: (): void => {},
  onSettingsChanged: (settings: ReaderSettings): void => {},
};

/**
 * 独立阅读器宿主页（设备无 ReaderKit 时由 `ReaderLauncher` 路由到此处）。
 *
 * 本页只做三件事：取路由参数、提供缓存目录、把进度/设置落盘；
 * 解压、解析、分章、渲染全部由 `reader` 模块（`feature/reader`）完成。
 * 阅读设置与 ReaderKit 阅读器共用同一组偏好键，两套阅读器观感一致。
 */
@Entry
@Component
struct BuiltInReaderPage {
  private filePath: string = '';
  private bookId: string = '';
  private bookTitle: string = '';
  private bookFormat: string = '';
  private keepScreenOn: boolean = false;
  private options: ReaderOpenOptions = DEFAULT_OPTIONS;
  private callbacks: ReaderCallbacks = DEFAULT_CALLBACKS;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const params = this.getUIContext().getRouter().getParams() as BuiltInReaderParams;
    this.filePath = params.filePath ?? '';
    this.bookId = params.bookId ?? '';
    this.bookTitle = params.bookTitle ?? '';
    this.bookFormat = params.format ?? '';
    const settings = BuiltInReaderPage.loadSettings();
    this.keepScreenOn = settings.keepScreenOn;
    this.options = {
      filePath: this.filePath,
      format: this.bookFormat,
      title: this.bookTitle,
      cacheDir: context.cacheDir,
      location: params.location ?? '',
      settings: settings,
    };
    this.callbacks = {
      onProgress: (location: ReaderLocation, chapterTitle: string): void => {
        this.persistProgress(location, chapterTitle);
      },
      onClose: (): void => {
        this.exitReader();
      },
      onSettingsChanged: (settings: ReaderSettings): void => {
        BuiltInReaderPage.saveSettings(settings);
        this.applyKeepScreenOn(settings.keepScreenOn);
      },
    };
    void this.enterImmersiveMode();
    this.applyKeepScreenOn(this.keepScreenOn);
  }

  aboutToDisappear(): void {
    ReadKitSession.flushProgress();
    this.restoreSystemBars();
    this.applyKeepScreenOn(false);
  }

  build() {
    Column() {
      ReaderView({ options: this.options, callbacks: this.callbacks });
    }
    .width('100%')
    .height('100%');
  }

  /** 沉浸式：全屏布局 + 隐藏状态栏/导航栏（与既有阅读器一致）。 */
  private async enterImmersiveMode(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await WindowAbility.getInstance().setWindowLayoutFullScreen(true);
      WindowAbility.getInstance().toggleWindowSystemBar([], context);
    } catch (error) {
      hilog.warn(0x0000, TAG, 'enterImmersiveMode failed: %{public}s', (error as Error).message);
    }
  }

  /** 退出阅读器：恢复系统栏后返回（恢复动作放这里，保证点返回与手势返回都覆盖）。 */
  private exitReader(): void {
    this.restoreSystemBars();
    this.getUIContext().getRouter().back();
  }

  private restoreSystemBars(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      WindowAbility.getInstance().toggleWindowSystemBar(['status', 'navigation'], context);
      void WindowAbility.getInstance().setWindowLayoutFullScreen(false);
    } catch (error) {
      hilog.warn(0x0000, TAG, 'restoreSystemBars failed: %{public}s', (error as Error).message);
    }
  }

  /** 阅读时常亮屏幕；离开阅读器时关闭，避免影响其它页面。 */
  private applyKeepScreenOn(keepOn: boolean): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window) => {
        win.setWindowKeepScreenOn(keepOn);
      }).catch(() => {});
    } catch (error) {
      hilog.warn(0x0000, TAG, 'setWindowKeepScreenOn failed: %{public}s', (error as Error).message);
    }
  }

  /** 进度落盘：复用既有的历史/进度通道，location 与 ReaderKit 阅读器同结构。 */
  private persistProgress(location: ReaderLocation, chapterTitle: string): void {
    ReadKitSession.handleProgress(
      this.bookId,
      this.bookTitle,
      this.filePath,
      this.bookFormat,
      chapterTitle,
      location.chapterIndex + 1,
      ReaderLocations.encode(location),
    );
  }

  private static loadSettings(): ReaderSettings {
    const rawTheme = Number(TalebookService.prefGet(THEME_KEY, '0'));
    const theme: ReaderTheme = Number.isNaN(rawTheme) || rawTheme < 0 || rawTheme >= THEMES.length ?
      ReaderTheme.LIGHT : THEMES[Math.floor(rawTheme)];
    return {
      fontSize: BuiltInReaderPage.clamp(Number(TalebookService.prefGet(FONT_SIZE_KEY, `${DEFAULT_FONT_SIZE}`)),
        MIN_FONT_SIZE, MAX_FONT_SIZE, DEFAULT_FONT_SIZE),
      lineHeight: BuiltInReaderPage.clamp(Number(TalebookService.prefGet(LINE_HEIGHT_KEY, `${DEFAULT_LINE_HEIGHT}`)),
        MIN_LINE_HEIGHT, MAX_LINE_HEIGHT, DEFAULT_LINE_HEIGHT),
      theme: theme,
      flipMode: ReaderFlip.normalize(TalebookService.prefGet(READER_FLIP_PREF_KEY, READER_FLIP_DEFAULT)),
      keepScreenOn: TalebookService.prefGet(KEEP_SCREEN_ON_KEY, 'false') === 'true',
    };
  }

  private static saveSettings(settings: ReaderSettings): void {
    const values: Record<string, string> = {};
    values[FONT_SIZE_KEY] = `${settings.fontSize}`;
    values[LINE_HEIGHT_KEY] = `${settings.lineHeight}`;
    values[THEME_KEY] = `${settings.theme}`;
    values[READER_FLIP_PREF_KEY] = ReaderFlip.normalize(settings.flipMode);
    values[KEEP_SCREEN_ON_KEY] = settings.keepScreenOn ? 'true' : 'false';
    TalebookService.prefSetBatch(values);
  }

  private static clamp(value: number, min: number, max: number, fallback: number): number {
    if (Number.isNaN(value)) {
      return fallback;
    }
    return Math.min(max, Math.max(min, value));
  }
}
