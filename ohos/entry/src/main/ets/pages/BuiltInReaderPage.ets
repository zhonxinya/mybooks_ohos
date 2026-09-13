import { common } from '@kit.AbilityKit';
import {
  ReaderCallbacks,
  ReaderLocation,
  ReaderLocations,
  ReaderOpenOptions,
  ReaderSettings,
  ReaderTheme,
  ReaderView,
} from 'reader';
import { TalebookService } from '../services/TalebookService';
import { ReadKitSession } from '../services/ReadKitSession';

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
/** 主题取值顺序必须与 `ReaderTheme` 枚举一致。 */
const THEMES: ReaderTheme[] = [ReaderTheme.LIGHT, ReaderTheme.DARK, ReaderTheme.EYE];

const DEFAULT_OPTIONS: ReaderOpenOptions = {
  filePath: '',
  format: '',
  title: '',
  cacheDir: '',
  location: '',
  settings: { fontSize: DEFAULT_FONT_SIZE, lineHeight: DEFAULT_LINE_HEIGHT, theme: ReaderTheme.LIGHT },
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
  private options: ReaderOpenOptions = DEFAULT_OPTIONS;
  private callbacks: ReaderCallbacks = DEFAULT_CALLBACKS;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const params = this.getUIContext().getRouter().getParams() as BuiltInReaderParams;
    this.filePath = params.filePath ?? '';
    this.bookId = params.bookId ?? '';
    this.bookTitle = params.bookTitle ?? '';
    this.bookFormat = params.format ?? '';
    this.options = {
      filePath: this.filePath,
      format: this.bookFormat,
      title: this.bookTitle,
      cacheDir: context.cacheDir,
      location: params.location ?? '',
      settings: BuiltInReaderPage.loadSettings(),
    };
    this.callbacks = {
      onProgress: (location: ReaderLocation, chapterTitle: string): void => {
        this.persistProgress(location, chapterTitle);
      },
      onClose: (): void => {
        this.getUIContext().getRouter().back();
      },
      onSettingsChanged: (settings: ReaderSettings): void => {
        BuiltInReaderPage.saveSettings(settings);
      },
    };
  }

  aboutToDisappear(): void {
    ReadKitSession.flushProgress();
  }

  build() {
    Column() {
      ReaderView({ options: this.options, callbacks: this.callbacks });
    }
    .width('100%')
    .height('100%');
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
    };
  }

  private static saveSettings(settings: ReaderSettings): void {
    const values: Record<string, string> = {};
    values[FONT_SIZE_KEY] = `${settings.fontSize}`;
    values[LINE_HEIGHT_KEY] = `${settings.lineHeight}`;
    values[THEME_KEY] = `${settings.theme}`;
    TalebookService.prefSetBatch(values);
  }

  private static clamp(value: number, min: number, max: number, fallback: number): number {
    if (Number.isNaN(value)) {
      return fallback;
    }
    return Math.min(max, Math.max(min, value));
  }
}
