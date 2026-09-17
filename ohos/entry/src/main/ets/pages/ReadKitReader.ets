import { BusinessError, batteryInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ReadPageComponent, readerCore, bookParser } from '@kit.ReaderKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReadKitSession } from '../services/ReadKitSession';
import { ReadKitBookmarkPayload, ReadKitLocation } from '../models/ReadKitTypes';
import { ReaderTheme } from '../models/ReaderTheme';
import { ReaderFontCatalog } from '../models/ReaderFontCatalog';
import { ReaderThemeColors } from '../theme/ReaderThemeColors';
import { TalebookService } from '../services/TalebookService';
import { ReaderFontService, ReaderFontResolve } from '../services/ReaderFontService';
import { WindowAbility } from '../entryability/WindowAbility';
import { ReaderChrome, ReaderClock, ReaderBattery, ReaderOverlayBar } from 'reader';
import {
  READKIT_FLIP_LABELS,
  ReaderFontOption,
  READKIT_FLIP_VALUES,
  ReaderBookmark,
  ReaderCatalogItem,
  ReaderControlPanel,
} from 'reader';
import { ReaderTtsService, ReaderTtsProgress, ReaderTtsState, ReaderTtsVoice } from '../services/ReaderTtsService';
import { HtmlTextUtil } from '../utils/HtmlTextUtil';

interface ReadKitParams {
  filePath: string;
  sessionId?: string;
  bookId?: string;
  resourceIndex?: number;
  domPos?: string;
  bookTitle?: string;
  format?: string;
  location?: string;
  bookmarks?: ReadKitBookmarkPayload[];
}

interface ReadKitSettingsParams {
  fontName?: string;
  fontPath?: string;
  fontSize?: number;
  lineHeight?: number;
  themeColor?: string;
  fontColor?: string;
  flipMode?: string;
  nightMode?: boolean;
}

interface ReadKitLocationPayload extends ReadKitLocation {
}

interface ParsedReadLocation {
  resourceIndex: number;
  domPos: string;
}

const TAG: string = 'ReadKitReader';
const PANEL_SLIDE_MS: number = 300;
const SCRIM_FADE_MS: number = 280;
const HINT_FADE_MS: number = 200;
const READER_OVERLAY_TOP_PADDING_VP: number = 48;
const READER_OVERLAY_BOTTOM_PADDING_VP: number = 12;
/** 页脚电量刷新间隔（ms）：与内置阅读器一致，一分钟一次足够。 */
const BATTERY_REFRESH_MS: number = 60000;
/** 阅读页顶部章节名 / 页脚的字号（与内置阅读器同一套：15 / 10）。 */
const READER_HEADER_FONT_SIZE: number = 15;
const READER_FOOTER_FONT_SIZE: number = 10;
const START_TIMEOUT_MS: number = 15000;
const START_TIMEOUT_MSG: string = '打开阅读器超时';
const RENDER_TIMEOUT_MSG: string = '渲染超时';
const TTS_PAGE_TURN_TIMEOUT_MS: number = 1200;

@Entry
@Component
struct ReadKitReader {
  private controller: readerCore.ReaderComponentController =
    new readerCore.ReaderComponentController();
  private handler: bookParser.BookParserHandler | null = null;
  private pageShowCallback: ((data: readerCore.PageDataInfo) => void) | null = null;
  private resourceRequestCallback: ((filePath: string) => ArrayBuffer) | null = null;
  private lastResourceIndex: number = -1;
  private lastDomPos: string = '';
  private lastCurrentPage: number = 0;
  private lastChapterName: string = '';
  @State private catalogItems: bookParser.CatalogItem[] = [];
  @State private bookmarks: ReadKitBookmarkPayload[] = [];
  /** 控制面板用模块类型（目录按下标、书签按 id 回查），与源数据同步维护，避免每次渲染重建数组。 */
  @State private panelCatalogItems: ReaderCatalogItem[] = [];
  @State private panelBookmarks: ReaderBookmark[] = [];
  @State private showControlPanel: boolean = false;
  @State private subPanelSheet: string = '';
  @State private overlayNav: string = '';
  @State private bookTitle: string = '';
  @State private chapterTitle: string = '';
  @State private pageIndicatorText: string = '';
  /** 页脚电量（-1 表示读取失败，不显示）；与内置阅读器页脚一致。 */
  @State private batteryLevel: number = -1;
  @State private batteryCharging: boolean = false;
  @State @Watch('onReadyChanged') private ready: boolean = false;
  @State private fontSize: number = 18;
  @State private lineHeight: number = 1.6;
  @State private selectedFontId: string = ReaderFontCatalog.SYSTEM_ID;
  @State private fontDownloading: boolean = false;
  /** 字体列表：静态清单，提到 build 外，避免每次重建都调用。 */
  private readonly fontOptions: ReaderFontOption[] = ReaderFontCatalog.listOptions();
  @State private readerTheme: ReaderTheme = ReaderTheme.LIGHT;
  @State private flipMode: string = '0';
  @State @Watch('onKeepScreenOnChanged') private keepScreenOn: boolean = false;
  @StorageLink('windowWidth') @Watch('onWindowDimensionsChanged') private windowWidth: number = 0;
  @StorageLink('windowHeight') @Watch('onWindowDimensionsChanged') private windowHeight: number = 0;
  private sessionId: string = '';
  private bookId: string = '';
  private filePath: string = '';
  private bookFormat: string = '';
  private selectFontPath: string = '';
  private appliedFontName: string = 'system';
  private appliedFontPath: string = '';
  private viewPortWidth: number = 0;
  private viewPortHeight: number = 0;
  private densityChangeCallback: Callback<number> | null = null;
  private pendingParams: ReadKitParams | null = null;
  private readerStarted: boolean = false;
  private controllerBound: boolean = false;
  private areaMeasured: boolean = false;
  private restoringPosition: boolean = false;
  private restoreResourceIndex: number = 0;
  private restoreDomPos: string = '';
  private destroyed: boolean = false;
  private retryPending: boolean = false;
  private chapterPageTotals: Map<number, number> = new Map();
  private componentWidthVp: number = 0;
  private componentHeightVp: number = 0;
  private layoutReady: boolean = false;
  private ttsService: ReaderTtsService = new ReaderTtsService();
  @State private ttsState: ReaderTtsState = 'idle';
  @State @Watch('onTtsSpeedChanged') private ttsSpeed: number = 1.0;
  @State private ttsChunkIndex: number = 0;
  @State private ttsChunkTotal: number = 0;
  @State private ttsPerson: number = 0;
  @State private ttsVoices: ReaderTtsVoice[] = [];
  @State private ttsVoiceLoading: boolean = false;
  private ttsVoicesLoaded: boolean = false;
  private ttsPageEndDomPos: string = '';
  private ttsPageDriven: boolean = false;
  private ttsPageTurnPending: boolean = false;
  private ttsPageTurnTimer: number = -1;
  private ttsChapterStartTimer: number = -1;
  private pendingTtsChapterIndex: number = -1;
  private batteryTimer: number = -1;

  aboutToAppear(): void {
    this.loadReaderPrefs();
    this.refreshBattery();
    this.batteryTimer = setInterval(() => {
      this.refreshBattery();
    }, BATTERY_REFRESH_MS);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ReaderFontService.init(context.filesDir);
    this.restoreResolvedFont();
    this.initTtsService();
    void this.enterImmersiveMode();
    const params = this.getUIContext().getRouter().getParams() as ReadKitParams;
    const parsed = this.parseLocationParam(
      params.location,
      params.resourceIndex ?? 0,
      params.domPos ?? '',
    );
    this.restoreResourceIndex = parsed.resourceIndex;
    this.restoreDomPos = parsed.domPos;
    this.pendingParams = {
      filePath: params.filePath,
      sessionId: params.sessionId ?? `${Date.now()}`,
      bookId: params.bookId ?? '',
      bookTitle: params.bookTitle ?? '',
      format: params.format ?? '',
      resourceIndex: parsed.resourceIndex,
      domPos: parsed.domPos,
      bookmarks: params.bookmarks ?? [],
    };
    this.resolveViewPort();
  }

  private parseLocationParam(
    location: string | Record<string, Object> | undefined,
    fallbackIndex: number,
    fallbackDomPos: string,
  ): ParsedReadLocation {
    let resourceIndex = fallbackIndex;
    let domPos = fallbackDomPos;
    if (location === undefined || location === null) {
      return { resourceIndex: resourceIndex, domPos: domPos };
    }
    let loc: Record<string, Object>;
    if (typeof location === 'string') {
      if (location.length === 0) {
        return { resourceIndex: resourceIndex, domPos: domPos };
      }
      try {
        loc = JSON.parse(location) as Record<string, Object>;
      } catch (_error) {
        hilog.warn(0x0000, TAG, 'location parse failed');
        return { resourceIndex: resourceIndex, domPos: domPos };
      }
    } else {
      loc = location;
    }
    domPos = String(loc['domPos'] ?? domPos);
    const parsedIndex = Number(loc['resourceIndex'] ?? resourceIndex);
    resourceIndex = Number.isNaN(parsedIndex) || parsedIndex < 0 ? 0 : parsedIndex;
    // 位置也可能来自内置阅读器（engine 非 readkit）：其 domPos 是段落序号而非 CFI，
    // 直接丢给 ReaderKit 可能被当锚点误匹配，故忽略它、从本章开头起读
    if (String(loc['engine'] ?? 'readkit') !== 'readkit') {
      return { resourceIndex: resourceIndex, domPos: fallbackDomPos };
    }
    return { resourceIndex: resourceIndex, domPos: domPos };
  }

  private applyViewPortSize(widthPx: number, heightPx: number): boolean {
    // viewPortWidth/Height must match ReadPageComponent render area (px), per ReaderKit demo.
    const nextWidth = Math.max(Math.round(widthPx), 1);
    const nextHeight = Math.max(Math.round(heightPx), 1);
    if (nextWidth === this.viewPortWidth && nextHeight === this.viewPortHeight) {
      return false;
    }
    this.viewPortWidth = nextWidth;
    this.viewPortHeight = nextHeight;
    return true;
  }

  private resolveViewPort(): boolean {
    const density = this.getScaledDensity();
    if (this.areaMeasured && this.componentWidthVp > 0 && this.componentHeightVp > 0) {
      return this.applyViewPortSize(
        Math.round(this.componentWidthVp * density),
        Math.round(this.componentHeightVp * density),
      );
    }
    let widthPx = this.windowWidth;
    let heightPx = this.windowHeight;
    if (widthPx <= 0 || heightPx <= 0) {
      const storedWidth = AppStorage.get<number>('windowWidth');
      const storedHeight = AppStorage.get<number>('windowHeight');
      widthPx = storedWidth ?? 0;
      heightPx = storedHeight ?? 0;
    }
    if (widthPx > 0 && heightPx > 0) {
      return this.applyViewPortSize(widthPx, heightPx);
    }
    try {
      const displaySync = display.getDefaultDisplaySync();
      return this.applyViewPortSize(displaySync.width, displaySync.height);
    } catch (_error) {
      return this.applyViewPortSize(1080, 2340);
    }
  }

  private async enterImmersiveMode(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await WindowAbility.getInstance().setWindowLayoutFullScreen(true);
      const win = await window.getLastWindow(context);
      const rect = win.getWindowProperties().windowRect;
      AppStorage.setOrCreate<number>('windowWidth', rect.width);
      AppStorage.setOrCreate<number>('windowHeight', rect.height);
      const changed = this.resolveViewPort();
      if (changed && this.readerStarted && this.ready) {
        this.applySettings(false);
        void this.reapplyReadingPosition();
      }
    } catch (error) {
      hilog.warn(0x0000, TAG, 'enterImmersiveMode failed: %{public}s', error.message);
    } finally {
      this.layoutReady = true;
      this.maybeBeginReading();
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private exitImmersiveMode(context: common.UIAbilityContext): void {
    WindowAbility.getInstance().toggleWindowSystemBar(['status', 'navigation'], context);
    void WindowAbility.getInstance().setWindowLayoutFullScreen(false);
  }

  private onReadyChanged(): void {
    if (this.ready) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      WindowAbility.getInstance().toggleWindowSystemBar([], context);
    }
  }

  private updateViewPortFromArea(area: Area): boolean {
    const widthVp = area.width as number;
    const heightVp = area.height as number;
    if (widthVp <= 0 || heightVp <= 0) {
      return false;
    }
    this.componentWidthVp = widthVp;
    this.componentHeightVp = heightVp;
    return this.resolveViewPort();
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private chapterNameForSpine(resourceIndex: number): string {
    if (this.handler === null) {
      return '';
    }
    if (this.catalogItems.length === 0) {
      try {
        this.catalogItems = this.handler.getCatalogList();
    this.syncPanelCatalog();
      } catch (_error) {
      }
    }
    const spineList = this.handler.getSpineList();
    const spine = spineList.find((item: bookParser.SpineItem) => item.index === resourceIndex);
    if (spine === undefined) {
      return '';
    }
    const matched = this.catalogItems.find((item: bookParser.CatalogItem) =>
      item.resourceFile === spine.href);
    return matched?.catalogName ?? '';
  }

  private resolveCurrentCatalogIndex(): number {
    if (this.handler === null || this.catalogItems.length === 0 || this.lastResourceIndex < 0) {
      return 0;
    }
    let spineList: bookParser.SpineItem[] = [];
    try {
      spineList = this.handler.getSpineList();
    } catch (_error) {
      return 0;
    }
    let matchedIndex = 0;
    for (let i = 0; i < this.catalogItems.length; i++) {
      const item = this.catalogItems[i];
      const resourceFile = item.resourceFile ?? '';
      const spine = spineList.find((value: bookParser.SpineItem) => value.href === resourceFile);
      if (spine === undefined) {
        continue;
      }
      if (spine.index <= this.lastResourceIndex) {
        matchedIndex = i;
      }
    }
    return matchedIndex;
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private resolveChapterTitle(data: readerCore.PageDataInfo): string {
    const header = data.pageHeaderContent ?? '';
    if (header.length > 0) {
      return header;
    }
    const fromCatalog = this.chapterNameForSpine(data.resourceIndex);
    if (fromCatalog.length > 0) {
      return fromCatalog;
    }
    return this.bookTitle;
  }

  private updateChapterPageTotal(resourceIndex: number, pageOffset: number): number {
    const current = pageOffset + 1;
    const prevMax = this.chapterPageTotals.get(resourceIndex) ?? 0;
    if (current > prevMax) {
      this.chapterPageTotals.set(resourceIndex, current);
    }
    return this.chapterPageTotals.get(resourceIndex) ?? current;
  }

  private parseFooterPageFraction(footer: string): string {
    const slash = footer.indexOf('/');
    if (slash <= 0) {
      return '';
    }
    const current = Number(footer.substring(0, slash).trim());
    const total = Number(footer.substring(slash + 1).trim());
    if (Number.isNaN(current) || Number.isNaN(total) || current <= 0 || total <= 0) {
      return '';
    }
    return `${current}/${total}`;
  }

  private resolvePageIndicator(data: readerCore.PageDataInfo): string {
    const footer = data.pageFooterContent ?? '';
    const footerFraction = this.parseFooterPageFraction(footer);
    if (footerFraction.length > 0) {
      const slash = footerFraction.indexOf('/');
      const total = Number(footerFraction.substring(slash + 1));
      const prevMax = this.chapterPageTotals.get(data.resourceIndex) ?? 0;
      if (total > prevMax) {
        this.chapterPageTotals.set(data.resourceIndex, total);
      }
      return footerFraction;
    }
    if (footer.length > 0) {
      return footer;
    }
    const current = (data.pageOffset ?? 0) + 1;
    const total = this.updateChapterPageTotal(data.resourceIndex, data.pageOffset ?? 0);
    if (current > 0 && total > 0) {
      return `${current}/${total}`;
    }
    return '';
  }

  private maybeBeginReading(): void {
    if (this.readerStarted || this.pendingParams === null || !this.controllerBound ||
      !this.areaMeasured || !this.layoutReady || this.retryPending) {
      return;
    }
    this.resolveViewPort();
    if (this.viewPortWidth <= 0 || this.viewPortHeight <= 0) {
      return;
    }
    this.runStart(this.pendingParams, 0);
  }

  private runStart(params: ReadKitParams, attempt: number): void {
    this.readerStarted = true;
    this.pendingParams = null;
    this.start(params).catch((error: BusinessError) => {
      this.readerStarted = false;
      this.pendingParams = params;
      hilog.error(0x0000, TAG, 'ReadKit start attempt %{public}d failed: %{public}s', attempt + 1, error.message);
      if (error.message === START_TIMEOUT_MSG || error.message === RENDER_TIMEOUT_MSG) {
        this.showFatalError(error.message);
        return;
      }
      this.retryStart(params, attempt + 1, error.message);
    });
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private retryStart(params: ReadKitParams, attempt: number, lastError: string): void {
    if (this.destroyed) {
      return;
    }
    if (attempt > 3) {
      this.showFatalError(lastError.length > 0 ? lastError : '打开阅读器失败');
      return;
    }
    this.retryPending = true;
    setTimeout(() => {
      this.retryPending = false;
      if (this.destroyed || this.readerStarted || this.pendingParams === null) {
        return;
      }
      this.runStart(params, attempt);
    }, 400 * attempt);
  }

  private loadReaderPrefs(): void {
    this.fontSize = Number(TalebookService.prefGet('reader_font_size', '18'));
    this.lineHeight = Number(TalebookService.prefGet('reader_line_height', '1.6'));
    this.selectedFontId = TalebookService.prefGet('reader_font_id', ReaderFontCatalog.SYSTEM_ID);
    if (ReaderFontCatalog.findById(this.selectedFontId) === null) {
      this.selectedFontId = ReaderFontCatalog.SYSTEM_ID;
    }
    this.readerTheme = Number(TalebookService.prefGet('reader_theme', '0')) as ReaderTheme;
    this.flipMode = TalebookService.prefGet('reader_flip_mode', '0');
    this.keepScreenOn = TalebookService.prefGet('reader_keep_screen_on', 'false') === 'true';
    this.ttsSpeed = Number(TalebookService.prefGet('reader_tts_speed', '1'));
    this.ttsPerson = Number(TalebookService.prefGet('reader_tts_person', '0'));
  }

  private saveReaderPrefs(): void {
    const values: Record<string, string> = {};
    values['reader_font_size'] = `${this.fontSize}`;
    values['reader_line_height'] = `${this.lineHeight}`;
    values['reader_font_id'] = this.selectedFontId;
    values['reader_theme'] = `${this.readerTheme}`;
    values['reader_flip_mode'] = this.flipMode;
    values['reader_keep_screen_on'] = this.keepScreenOn ? 'true' : 'false';
    values['reader_tts_speed'] = `${this.ttsSpeed}`;
    values['reader_tts_person'] = `${this.ttsPerson}`;
    TalebookService.prefSetBatch(values);
  }

  private restoreResolvedFont(): void {
    const resolved: ReaderFontResolve = ReaderFontService.resolveForReader(this.selectedFontId);
    if (this.selectedFontId !== ReaderFontCatalog.SYSTEM_ID && resolved.selectFontPath.length === 0) {
      this.selectedFontId = ReaderFontCatalog.SYSTEM_ID;
      TalebookService.prefSet('reader_font_id', ReaderFontCatalog.SYSTEM_ID);
    }
    this.appliedFontName = resolved.fontName;
    this.appliedFontPath = resolved.fontPath;
    this.selectFontPath = resolved.selectFontPath;
  }

  private initTtsService(): void {
    this.ttsService.setSpeed(this.ttsSpeed);
    void this.ttsService.setPerson(this.ttsPerson);
    this.ttsService.setCallbacks(
      (state: ReaderTtsState) => {
        this.ttsState = state;
        this.syncKeepScreenOn();
      },
      (message: string) => {
        this.getUIContext().getPromptAction().showToast({ message: message });
      },
      (progress: ReaderTtsProgress) => {
        this.ttsChunkIndex = progress.chunkIndex;
        this.ttsChunkTotal = progress.totalChunks;
      },
    );
  }

  /** 音色列表按需加载；设备或服务不支持时保持空列表，由面板降级提示。 */
  private async loadTtsVoices(force: boolean): Promise<void> {
    if (this.ttsVoiceLoading || (this.ttsVoicesLoaded && !force)) {
      return;
    }
    this.ttsVoiceLoading = true;
    try {
      this.ttsVoices = await ReaderTtsService.listVoices();
      this.ttsVoicesLoaded = true;
    } finally {
      this.ttsVoiceLoading = false;
    }
  }

  private selectTtsPerson(person: number): void {
    if (person === this.ttsPerson) {
      return;
    }
    this.ttsPerson = person;
    TalebookService.prefSet('reader_tts_person', `${person}`);
    void this.ttsService.setPerson(person);
  }

  private onTtsSpeedChanged(): void {
    this.ttsService.setSpeed(this.ttsSpeed);
    TalebookService.prefSet('reader_tts_speed', `${this.ttsSpeed}`);
  }

  private registerReaderListeners(): void {
    if (this.pageShowCallback !== null) {
      return;
    }
    this.pageShowCallback = (data: readerCore.PageDataInfo): void => {
      if (data.state === readerCore.PageState.PAGE_ON_SHOW && !this.ready) {
        this.ready = true;
      }
      this.emitProgress(data);
    };
    this.resourceRequestCallback = (filePath: string): ArrayBuffer => {
      return this.readResource(filePath);
    };
    this.controller.on('pageShow', this.pageShowCallback);
    this.controller.on('resourceRequest', this.resourceRequestCallback);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async start(params: ReadKitParams): Promise<void> {
    if (!params.filePath) {
      throw new Error('书籍路径为空');
    }
    this.resolveViewPort();
    this.bookTitle = params.bookTitle ?? '';
    this.chapterTitle = this.bookTitle;
    if (this.bookTitle.length === 0) {
      this.bookTitle = this.fileNameFromPath(params.filePath);
    }
    this.sessionId = params.sessionId ?? '';
    this.bookId = params.bookId ?? '';
    this.filePath = params.filePath;
    this.bookFormat = params.format ?? '';
    this.bookmarks = params.bookmarks ?? [];
    this.syncPanelBookmarks();
    const file = fs.openSync(params.filePath, fs.OpenMode.READ_ONLY);
    fs.closeSync(file);

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.registerReaderListeners();
    const initPromise = this.controller.init(context);
    const handlerPromise = bookParser.getDefaultHandler(params.filePath);
    const results: [bookParser.BookParserHandler, void] = await Promise.race([
      Promise.all([handlerPromise, initPromise]),
      new Promise<[bookParser.BookParserHandler, void]>((_resolve, reject) => {
        setTimeout(() => reject(new Error(START_TIMEOUT_MSG)), START_TIMEOUT_MS);
      }),
    ]);
    this.handler = results[0];
    this.controller.registerBookParser(this.handler);
    if (this.bookTitle.length === 0) {
      const info = this.handler.getBookInfo();
      this.bookTitle = info?.bookTitle ?? this.bookTitle;
      this.chapterTitle = this.bookTitle;
    }
    try {
      this.catalogItems = this.handler.getCatalogList();
    this.syncPanelCatalog();
    } catch (_error) {
    }
    this.registerDensityChange();
    this.applySettings(false);
    this.syncKeepScreenOn();
    const spineIndex = params.resourceIndex ?? 0;
    const domPos = params.domPos ?? '';
    await Promise.race([
      this.controller.startPlay(spineIndex >= 0 ? spineIndex : 0, domPos),
      new Promise<void>((_resolve, reject) => {
        setTimeout(() => reject(new Error(RENDER_TIMEOUT_MSG)), START_TIMEOUT_MS);
      }),
    ]);
    if (!this.ready) {
      this.ready = true;
    }
  }

  private fileNameFromPath(path: string): string {
    const normalized = path.replace(/\\/g, '/');
    const name = normalized.substring(normalized.lastIndexOf('/') + 1);
    const dotIndex = name.lastIndexOf('.');
    return dotIndex > 0 ? name.substring(0, dotIndex) : name;
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private applySettings(persist: boolean): void {
    try {
      this.controller.setPageConfig({
        fontName: this.appliedFontName,
        fontPath: this.appliedFontPath,
        fontSize: this.fontSize,
        fontColor: ReaderThemeColors.pageFontColor(this.readerTheme),
        fontWeight: 400,
        lineHeight: this.lineHeight,
        nightMode: ReaderThemeColors.nightMode(this.readerTheme),
        themeColor: ReaderThemeColors.pageThemeColor(this.readerTheme),
        themeBgImg: '',
        flipMode: this.flipMode,
        scaledDensity: this.getScaledDensity(),
        viewPortWidth: this.viewPortWidth,
        viewPortHeight: this.viewPortHeight,
      });
      if (persist) {
        this.saveReaderPrefs();
      }
    } catch (error) {
      hilog.error(0x0000, TAG, 'setPageConfig failed: %{public}s', error.message);
      this.emitError('readerInitFailed', error.message);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async selectFont(fontId: string): Promise<void> {
    if (fontId === this.selectedFontId || this.fontDownloading) {
      return;
    }
    const needDownload = fontId !== ReaderFontCatalog.SYSTEM_ID && !ReaderFontService.isCached(fontId);
    this.fontDownloading = true;
    if (needDownload) {
      this.getUIContext().getPromptAction().showToast({ message: '正在下载字体…' });
    }
    try {
      const resolved = await ReaderFontService.ensureCached(fontId);
      this.selectedFontId = fontId;
      this.appliedFontName = resolved.fontName;
      this.appliedFontPath = resolved.fontPath;
      this.selectFontPath = resolved.selectFontPath;
      this.applySettings(true);
      void this.reapplyReadingPosition();
      if (needDownload) {
        this.getUIContext().getPromptAction().showToast({ message: '字体已应用' });
      }
    } catch (error) {
      const message = `${error}`.length > 0 ? `${error}` : '字体下载失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    } finally {
      this.fontDownloading = false;
    }
  }

  private syncKeepScreenOn(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window) => {
        // 页间过渡与跨章等待期间朗读仍在继续，避免常亮被短暂关掉
        const ttsActive = this.ttsState === 'playing' || this.ttsPageTurnPending ||
          this.pendingTtsChapterIndex >= 0;
        win.setWindowKeepScreenOn(this.keepScreenOn || ttsActive);
      });
    } catch (_error) {
      hilog.warn(0x0000, TAG, 'setWindowKeepScreenOn failed');
    }
  }

  private onKeepScreenOnChanged(): void {
    this.syncKeepScreenOn();
    this.saveReaderPrefs();
  }

  private getScaledDensity(): number {
    try {
      const density = display.getDefaultDisplaySync().scaledDensity;
      return density > 0 ? density : 1;
    } catch (_error) {
      return 1;
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private onWindowDimensionsChanged(): void {
    const prevWidth = this.viewPortWidth;
    const prevHeight = this.viewPortHeight;
    if (!this.resolveViewPort()) {
      return;
    }
    if (!this.readerStarted) {
      this.maybeBeginReading();
      return;
    }
    if (!this.ready) {
      return;
    }
    if (prevWidth === this.viewPortWidth && prevHeight === this.viewPortHeight) {
      return;
    }
    this.applySettings(false);
    void this.reapplyReadingPosition();
  }

  private registerDensityChange(): void {
    if (this.densityChangeCallback !== null) {
      return;
    }
    this.densityChangeCallback = (): void => {
      this.applySettings(false);
      void this.reapplyReadingPosition();
    };
    display.on('change', this.densityChangeCallback);
  }

  private async reapplyReadingPosition(): Promise<void> {
    if (!this.readerStarted || this.restoringPosition) {
      return;
    }
    const index = this.lastResourceIndex >= 0 ? this.lastResourceIndex : this.restoreResourceIndex;
    const domPos = this.lastDomPos.length > 0 ? this.lastDomPos : this.restoreDomPos;
    if (index <= 0 && domPos.length === 0) {
      return;
    }
    this.restoringPosition = true;
    try {
      await this.controller.startPlay(index >= 0 ? index : 0, domPos);
    } catch (error) {
      hilog.warn(0x0000, TAG, 'reapplyReadingPosition failed: %{public}s', error.message);
    } finally {
      this.restoringPosition = false;
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private toggleNightTheme(): void {
    if (this.readerTheme === ReaderTheme.DARK) {
      this.readerTheme = ReaderTheme.LIGHT;
    } else {
      this.readerTheme = ReaderTheme.DARK;
    }
    this.applySettings(true);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private spineCount(): number {
    return this.handler?.getSpineList()?.length ?? 0;
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private chapterProgress(): number {
    const total = this.spineCount();
    if (total <= 1 || this.lastResourceIndex < 0) {
      return 0;
    }
    return this.lastResourceIndex / (total - 1);
  }

  private canGoPrevChapter(): boolean {
    return this.lastResourceIndex > 0;
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private canGoNextChapter(): boolean {
    return this.lastResourceIndex >= 0 && this.lastResourceIndex < this.spineCount() - 1;
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async goSpineIndex(index: number): Promise<void> {
    if (index < 0 || index >= this.spineCount()) {
      return;
    }
    try {
      await this.controller.startPlay(index, '');
    } catch (error) {
      hilog.error(0x0000, TAG, 'goSpineIndex failed: %{public}s', error.message);
    }
  }

  private stopTts(): void {
    this.cancelTtsPageTurn();
    this.cancelTtsChapterStart();
    this.pendingTtsChapterIndex = -1;
    this.ttsPageDriven = false;
    this.ttsService.stop();
    this.syncKeepScreenOn();
  }

  private cancelTtsPageTurn(): void {
    if (this.ttsPageTurnTimer >= 0) {
      clearTimeout(this.ttsPageTurnTimer);
      this.ttsPageTurnTimer = -1;
    }
    this.ttsPageTurnPending = false;
  }

  private cancelTtsChapterStart(): void {
    if (this.ttsChapterStartTimer >= 0) {
      clearTimeout(this.ttsChapterStartTimer);
      this.ttsChapterStartTimer = -1;
    }
  }

  /** 整章文本（自 domPos 起），页级切分不可用时作为降级来源。 */
  private async loadChapterTtsText(spineIndex: number, domPos: string): Promise<string[]> {
    if (this.handler === null || spineIndex < 0) {
      return [];
    }
    try {
      const html = await this.handler.getSpineItemContent(spineIndex);
      const sliced = HtmlTextUtil.sliceFromDomPos(html, domPos);
      const source = sliced ?? html;
      const text = HtmlTextUtil.stripHtml(source);
      return HtmlTextUtil.chunkText(text);
    } catch (error) {
      hilog.error(0x0000, TAG, 'loadChapterTtsText failed: %{public}s', error.message);
      return [];
    }
  }

  /** 当前页文本（startDomPos → endDomPos），用于页级朗读与翻页跟随。 */
  private async loadPageTtsText(spineIndex: number, startDomPos: string, endDomPos: string): Promise<string[]> {
    if (this.handler === null || spineIndex < 0 || startDomPos.length === 0) {
      return [];
    }
    try {
      const html = await this.handler.getSpineItemContent(spineIndex);
      const sliced = HtmlTextUtil.sliceBetweenDomPos(html, startDomPos, endDomPos);
      if (sliced === null) {
        return [];
      }
      return HtmlTextUtil.chunkText(HtmlTextUtil.stripHtml(sliced));
    } catch (error) {
      hilog.warn(0x0000, TAG, 'loadPageTtsText failed: %{public}s', error.message);
      return [];
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async startTtsFromCurrentChapter(): Promise<void> {
    if (this.handler === null || this.lastResourceIndex < 0) {
      this.getUIContext().getPromptAction().showToast({ message: '当前章节不可用' });
      return;
    }
    const pageChunks = await this.loadPageTtsText(
      this.lastResourceIndex, this.lastDomPos, this.ttsPageEndDomPos);
    const chunks = pageChunks.length > 0
      ? pageChunks
      : await this.loadChapterTtsText(this.lastResourceIndex, this.lastDomPos);
    this.ttsPageDriven = pageChunks.length > 0;
    if (chunks.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '本章无可朗读内容' });
      return;
    }
    const started = await this.ttsService.start(chunks, this.ttsSpeed, () => {
      void this.handleTtsFinished();
    });
    if (!started) {
      this.getUIContext().getPromptAction().showToast({ message: '朗读启动失败' });
    }
  }

  /** 翻页到达后接着朗读新页；新页没内容时按章末继续处理。 */
  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async continueTtsOnNewPage(): Promise<void> {
    const chunks = await this.loadPageTtsText(
      this.lastResourceIndex, this.lastDomPos, this.ttsPageEndDomPos);
    if (chunks.length === 0) {
      await this.handleTtsChapterFinished();
      return;
    }
    const started = await this.ttsService.start(chunks, this.ttsSpeed, () => {
      void this.handleTtsFinished();
    });
    if (!started) {
      await this.handleTtsChapterFinished();
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async resumeTts(): Promise<void> {
    const resumed = await this.ttsService.resume();
    if (!resumed) {
      await this.startTtsFromCurrentChapter();
    }
  }

  private pauseTts(): void {
    this.ttsService.pause();
    this.syncKeepScreenOn();
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private handleTtsPlay(): void {
    if (this.ttsState === 'paused') {
      void this.resumeTts();
      return;
    }
    if (this.ttsState === 'playing') {
      return;
    }
    void this.startTtsFromCurrentChapter();
  }

  private handleTtsStop(): void {
    this.stopTts();
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private toggleReadAloud(): void {
    if (this.ttsState === 'playing') {
      this.pauseTts();
      return;
    }
    if (this.ttsState === 'paused') {
      void this.resumeTts();
      return;
    }
    void this.startTtsFromCurrentChapter();
  }

  /** 一段（一页）读完：页级朗读时翻到下一页等回调，否则按章末继续。 */
  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async handleTtsFinished(): Promise<void> {
    if (this.ttsPageDriven && this.turnToNextPage()) {
      return;
    }
    await this.handleTtsChapterFinished();
  }

  /** 翻到下一页并等待 pageShow 回调；超时视为章末。 */
  private turnToNextPage(): boolean {
    if (this.ttsPageTurnPending) {
      return false;
    }
    this.ttsPageTurnPending = true;
    this.ttsPageTurnTimer = setTimeout(() => {
      this.ttsPageTurnTimer = -1;
      if (!this.ttsPageTurnPending) {
        return;
      }
      this.ttsPageTurnPending = false;
      void this.handleTtsChapterFinished();
    }, TTS_PAGE_TURN_TIMEOUT_MS);
    try {
      this.controller.flipPage(true);
    } catch (error) {
      this.cancelTtsPageTurn();
      return false;
    }
    return true;
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async handleTtsChapterFinished(): Promise<void> {
    this.ttsPageDriven = false;
    if (!this.canGoNextChapter()) {
      this.syncKeepScreenOn();
      this.getUIContext().getPromptAction().showToast({ message: '已读完' });
      return;
    }
    const nextIndex = this.lastResourceIndex + 1;
    this.pendingTtsChapterIndex = nextIndex;
    await this.goSpineIndex(nextIndex);
    // 等 pageShow 给出新章首页范围后再按页续读；超时按整章兜底
    this.cancelTtsChapterStart();
    this.ttsChapterStartTimer = setTimeout(() => {
      this.ttsChapterStartTimer = -1;
      if (this.pendingTtsChapterIndex !== nextIndex) {
        return;
      }
      this.pendingTtsChapterIndex = -1;
      void this.startTtsForChapter(nextIndex);
    }, TTS_PAGE_TURN_TIMEOUT_MS);
  }

  /** 兜底：pageShow 未按时到达时按整章续读。 */
  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async startTtsForChapter(spineIndex: number): Promise<void> {
    const chunks = await this.loadChapterTtsText(spineIndex, '');
    if (chunks.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '下一章无可朗读内容' });
      return;
    }
    this.ttsPageDriven = false;
    const started = await this.ttsService.start(chunks, this.ttsSpeed, () => {
      void this.handleTtsFinished();
    });
    if (!started) {
      this.getUIContext().getPromptAction().showToast({ message: '继续朗读失败' });
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async goSpineIndexWithTtsStop(index: number): Promise<void> {
    this.stopTts();
    await this.goSpineIndex(index);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async goPrevChapter(): Promise<void> {
    await this.goSpineIndexWithTtsStop(this.lastResourceIndex - 1);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async goNextChapter(): Promise<void> {
    await this.goSpineIndexWithTtsStop(this.lastResourceIndex + 1);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async goChapterProgress(progress: number): Promise<void> {
    const total = this.spineCount();
    if (total <= 0) {
      return;
    }
    const index = Math.round(progress * (total - 1));
    await this.goSpineIndexWithTtsStop(index);
  }

  private toggleControlPanel(): void {
    if (this.showControlPanel) {
      this.closeControlPanel();
      return;
    }
    this.openControlPanel();
  }

  private openControlPanel(): void {
    if (this.showControlPanel) {
      return;
    }
    this.showControlPanel = true;
    this.subPanelSheet = '';
    this.overlayNav = '';
  }

  private closeControlPanel(): void {
    if (!this.showControlPanel) {
      return;
    }
    this.showControlPanel = false;
  }

  private openSubPanel(sheet: string): void {
    if (!this.showControlPanel) {
      this.openControlPanel();
    }
    this.subPanelSheet = sheet;
    this.overlayNav = sheet;
    if (sheet === 'toc') {
      try {
        this.catalogItems = this.handler?.getCatalogList() ?? [];
    this.syncPanelCatalog();
      } catch (error) {
        hilog.error(0x0000, TAG, 'getCatalogList failed: %{public}s', error.message);
      }
    }
    if (sheet === 'aloud') {
      void this.loadTtsVoices(false);
    }
  }

  private closeSubPanel(): void {
    this.subPanelSheet = '';
    this.overlayNav = '';
  }

  private readResource(filePath: string): ArrayBuffer {
    if (filePath.length === 0) {
      return new ArrayBuffer(0);
    }
    if (this.isFontPath(filePath) && this.selectFontPath.length > 0) {
      return this.loadFileFromPath(this.selectFontPath);
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const raw = context.resourceManager.getRawFileContentSync(filePath);
      return raw.buffer as ArrayBuffer;
    } catch (_error) {
    }
    if (this.handler !== null) {
      try {
        const fromHandler = this.handler.getResourceContent(-1, filePath);
        if (fromHandler !== undefined && fromHandler.byteLength > 0) {
          return fromHandler;
        }
      } catch (_error) {
      }
    }
    // 兜底读文件仅限应用沙箱内：book 内容可携带 ../../ 或绝对路径形式的资源引用，
    // 若无约束则可越权读取沙箱内任意文件并把内容交给渲染引擎。
    if (!this.isInsideSandbox(filePath, context)) {
      return new ArrayBuffer(0);
    }
    return this.loadFileFromPath(filePath);
  }

  /** 仅允许读取应用自身 filesDir 下、且不含 .. 的路径。 */
  private isInsideSandbox(filePath: string, context: common.UIAbilityContext): boolean {
    const root = context.filesDir;
    if (root.length === 0) {
      return false;
    }
    const normalized = filePath.replace(/\\/g, '/');
    if (!normalized.startsWith(`${root}/`)) {
      return false;
    }
    const segments = normalized.split('/');
    for (let i = 0; i < segments.length; i++) {
      if (segments[i] === '..') {
        return false;
      }
    }
    return true;
  }

  private isFontPath(filePath: string): boolean {
    const lower = filePath.toLowerCase();
    return lower.indexOf('.ttf') >= 0 ||
      lower.indexOf('.otf') >= 0 ||
      lower.indexOf('.woff2') >= 0 ||
      lower.indexOf('.woff') >= 0;
  }

  private loadFileFromPath(filePath: string): ArrayBuffer {
    try {
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      return buffer;
    } catch (_error) {
      return new ArrayBuffer(0);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private emitProgress(data: readerCore.PageDataInfo): void {
    if (data.resourceIndex === this.lastResourceIndex &&
      data.startDomPos === this.lastDomPos &&
      data.pageOffset === this.lastCurrentPage) {
      return;
    }
    this.lastResourceIndex = data.resourceIndex;
    this.lastDomPos = data.startDomPos;
    this.ttsPageEndDomPos = data.endDomPos ?? '';
    this.lastCurrentPage = data.pageOffset;
    this.chapterTitle = this.resolveChapterTitle(data);
    this.lastChapterName = this.chapterTitle;
    this.pageIndicatorText = this.resolvePageIndicator(data);
    this.restoreResourceIndex = data.resourceIndex;
    this.restoreDomPos = data.startDomPos;
    const location = JSON.stringify({
      resourceIndex: data.resourceIndex,
      domPos: data.startDomPos,
      pageOffset: data.pageOffset,
      engine: 'readkit',
      version: 1,
    });
    ReadKitSession.handleProgress(
      this.bookId,
      this.bookTitle,
      this.filePath,
      this.bookFormat,
      this.lastChapterName,
      this.lastCurrentPage,
      location,
    );
    this.onTtsPageChanged(data.resourceIndex);
  }

  /** 朗读跟随：翻页后接着读新页，跨章后在新章首页重新起读，手动翻页则改以新页为准。 */
  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private onTtsPageChanged(resourceIndex: number): void {
    if (this.pendingTtsChapterIndex >= 0 && resourceIndex === this.pendingTtsChapterIndex) {
      this.pendingTtsChapterIndex = -1;
      this.cancelTtsChapterStart();
      void this.startTtsFromCurrentChapter();
      return;
    }
    if (this.ttsPageTurnPending) {
      this.cancelTtsPageTurn();
      void this.continueTtsOnNewPage();
      return;
    }
    if (this.ttsPageDriven && this.ttsService.getState() === 'playing') {
      this.ttsService.stop();
      void this.startTtsFromCurrentChapter();
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private emitError(_code: string, message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private showFatalError(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
    this.getUIContext().getRouter().back();
  }

  private async openCatalogItem(item: bookParser.CatalogItem): Promise<void> {
    this.stopTts();
    try {
      const domPos = this.handler?.getDomPosByCatalogHref(item.href ?? '') ?? '';
      const spineItems = this.handler?.getSpineList() ?? [];
      const spineItem = spineItems.find((value: bookParser.SpineItem) =>
        value.href === (item.resourceFile ?? ''));
      await this.controller.startPlay(spineItem?.index ?? 0, domPos);
      this.closeControlPanel();
    } catch (error) {
      hilog.error(0x0000, TAG, 'open catalog item failed: %{public}s', error.message);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private addBookmark(): void {
    if (this.lastResourceIndex < 0) {
      return;
    }
    if (this.bookmarks.some((item: ReadKitBookmarkPayload) =>
      item.location.resourceIndex === this.lastResourceIndex &&
      item.location.domPos === this.lastDomPos)) {
      return;
    }
    const bookmark: ReadKitBookmarkPayload = {
      id: `${new Date().getTime()}-${this.lastResourceIndex}`,
      title: this.lastChapterName.length > 0 ? this.lastChapterName : this.bookTitle,
      location: {
        resourceIndex: this.lastResourceIndex,
        domPos: this.lastDomPos,
      } as ReadKitLocationPayload,
    };
    this.bookmarks = [bookmark, ...this.bookmarks];
    this.syncPanelBookmarks();
    ReadKitSession.handleBookmarkAdded(this.bookId, bookmark);
    this.getUIContext().getPromptAction().showToast({ message: '已添加书签' });
  }

  private removeBookmark(bookmark: ReadKitBookmarkPayload): void {
    this.bookmarks = this.bookmarks.filter((item: ReadKitBookmarkPayload) => item.id !== bookmark.id);
    this.syncPanelBookmarks();
    ReadKitSession.handleBookmarkRemoved(this.bookId, bookmark.id);
  }

  // ---- 控制面板（模块内共用组件）的数据桥接 ----

  /** 目录：面板用模块的 `ReaderCatalogItem`（下标 + 标题），选中回传下标。 */
  private syncPanelCatalog(): void {
    const items: ReaderCatalogItem[] = [];
    for (let i = 0; i < this.catalogItems.length; i++) {
      items.push({ index: i, title: this.catalogItems[i].catalogName });
    }
    this.panelCatalogItems = items;
  }

  /** 书签：面板只展示 id/title，选中/删除按 id 回查完整对象。 */
  private syncPanelBookmarks(): void {
    const items: ReaderBookmark[] = [];
    for (let i = 0; i < this.bookmarks.length; i++) {
      items.push({ id: this.bookmarks[i].id, title: this.bookmarks[i].title });
    }
    this.panelBookmarks = items;
  }

  private openCatalogIndex(index: number): void {
    const item = this.catalogItems[index];
    if (item !== undefined) {
      this.openCatalogItem(item);
    }
  }

  private openBookmarkById(id: string): void {
    const bookmark = this.bookmarks.find((item: ReadKitBookmarkPayload) => item.id === id);
    if (bookmark === undefined) {
      return;
    }
    try {
      void this.openBookmark(bookmark);
    } catch (error) {
      // openBookmark 内部已处理异常；这里只兜底记录（emitError 自身也可能抛，故不用它）
      hilog.warn(0x0000, TAG, 'openBookmark failed: %{public}s', (error as Error).message);
    }
  }

  private removeBookmarkById(id: string): void {
    const bookmark = this.bookmarks.find((item: ReadKitBookmarkPayload) => item.id === id);
    if (bookmark !== undefined) {
      this.removeBookmark(bookmark);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private async openBookmark(bookmark: ReadKitBookmarkPayload): Promise<void> {
    this.stopTts();
    try {
      await this.controller.startPlay(
        bookmark.location.resourceIndex,
        bookmark.location.domPos,
      );
      this.closeControlPanel();
    } catch (error) {
      this.emitError('invalidBookmarkLocation', error.message);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  aboutToDisappear(): void {
    this.destroyed = true;
    if (this.batteryTimer >= 0) {
      clearInterval(this.batteryTimer);
      this.batteryTimer = -1;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.exitImmersiveMode(context);
    if (this.lastResourceIndex >= 0) {
      const location = JSON.stringify({
        resourceIndex: this.lastResourceIndex,
        domPos: this.lastDomPos,
        engine: 'readkit',
        version: 1,
      });
      ReadKitSession.handleProgress(
        this.bookId,
        this.bookTitle,
        this.filePath,
        this.bookFormat,
        this.lastChapterName,
        this.lastCurrentPage,
        location,
      );
    }
    ReadKitSession.flushProgress();
    if (this.densityChangeCallback !== null) {
      display.off('change', this.densityChangeCallback);
      this.densityChangeCallback = null;
    }
    if (this.pageShowCallback !== null) {
      this.controller.off('pageShow');
    }
    if (this.resourceRequestCallback !== null) {
      this.controller.off('resourceRequest');
    }
    this.cancelTtsPageTurn();
    this.cancelTtsChapterStart();
    this.ttsService.shutdown();
    this.controller.releaseBook();
  }

  /**
   * 阅读页顶部：章节名 + 右上角时间。
   * 与内置阅读器同一套版式（章节名 15、右侧 HH:mm），两套阅读器观感一致。
   */
  @Builder
  readingTopBar() {
    Row({ space: 8 }) {
      Text(this.chapterTitle.length > 0 ? this.chapterTitle : this.bookTitle)
        .fontSize(READER_HEADER_FONT_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(ReaderThemeColors.textHint(this.readerTheme))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      ReaderClock({ theme: this.readerTheme });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: 20,
      right: 20,
      top: READER_OVERLAY_TOP_PADDING_VP,
      bottom: 8,
    })
    .hitTestBehavior(HitTestMode.None);
  }

  @Builder
  loadingOverlay() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(48)
        .height(48)
        .color($r('app.color.brand_primary'));
      Text('正在打开阅读器')
        .fontSize(14)
        .fontColor(ReaderThemeColors.textHint(this.readerTheme));
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(ReaderThemeColors.pageBackground(this.readerTheme))
    .transition(TransitionEffect.OPACITY.animation({ duration: HINT_FADE_MS, curve: Curve.EaseOut }));
  }

  /**
   * 阅读页页脚：左侧书名、右侧电量与页码（与内置阅读器的页脚同版式）。
   * 页码文本由 ReaderKit 的 pageFooterContent 解析而来，拿不到时只显示书名与电量。
   */
  @Builder
  readingBottomHint() {
    Column() {
      Divider()
        .color(ReaderThemeColors.divider(this.readerTheme))
        .strokeWidth(0.5);
      Row({ space: 10 }) {
        Text(this.bookTitle.length > 0 ? this.bookTitle : ' ')
          .fontSize(READER_FOOTER_FONT_SIZE)
          .fontColor(ReaderThemeColors.textHint(this.readerTheme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        ReaderBattery({
          theme: this.readerTheme,
          level: this.batteryLevel,
          charging: this.batteryCharging,
        });
        if (this.pageIndicatorText.length > 0) {
          Text(this.pageIndicatorText)
            .fontSize(READER_FOOTER_FONT_SIZE)
            .fontColor(ReaderThemeColors.textHint(this.readerTheme))
            .maxLines(1);
        }
      }
      .width('100%')
      .height(26)
      .alignItems(VerticalAlign.Center);
    }
    .width('100%')
    .padding({
      left: 20,
      right: 20,
      bottom: READER_OVERLAY_BOTTOM_PADDING_VP,
    })
    .hitTestBehavior(HitTestMode.None);
  }

  /** 页脚电量：读不到时置 -1，页脚不渲染电量块。 */
  private refreshBattery(): void {
    try {
      this.batteryLevel = batteryInfo.batterySOC;
      this.batteryCharging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ||
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
    } catch (_error) {
      this.batteryLevel = -1;
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  build() {
    Stack() {
      Stack() {
        ReadPageComponent({
          controller: this.controller,
          readerCallback: (error: BusinessError, data: readerCore.ReaderComponentController): void => {
            if (error) {
              this.showFatalError(error.message.length > 0 ? error.message : '阅读组件初始化失败');
              return;
            }
            this.controller = data;
            this.controllerBound = true;
            this.maybeBeginReading();
          },
        })
          .width('100%')
          .height('100%')
          .hitTestBehavior(this.showControlPanel ? HitTestMode.None : HitTestMode.Default);

        if (this.ready && !this.showControlPanel) {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width('34%')
              .height('38%')
              .onClick(() => this.toggleControlPanel());
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent);
        }
      }
      .width('100%')
      .height('100%')
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        const changed = this.updateViewPortFromArea(newValue);
        this.areaMeasured = true;
        if (!this.readerStarted) {
          this.maybeBeginReading();
          return;
        }
        if (changed && this.ready) {
          this.applySettings(false);
          void this.reapplyReadingPosition();
        }
      });

      if (!this.ready) {
        this.loadingOverlay();
      }

      if (this.ready && !this.showControlPanel) {
        Stack({ alignContent: Alignment.Top }) {
          this.readingTopBar();
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: HINT_FADE_MS, curve: Curve.EaseOut }))
        .zIndex(3);

        Stack({ alignContent: Alignment.Bottom }) {
          this.readingBottomHint();
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: HINT_FADE_MS, curve: Curve.EaseOut }))
        .zIndex(3);
      }

      if (this.showControlPanel && this.ready) {
        Column() {
          ReaderChrome({
            bookTitle: this.bookTitle,
            chapterTitle: this.chapterTitle,
            theme: this.readerTheme,
            expanded: true,
            onBack: () => {
              this.closeControlPanel();
              this.getUIContext().getRouter().back();
            },
            onBookmark: () => {
              this.addBookmark();
            },
            onRefresh: () => {
              this.applySettings(true);
              void this.reapplyReadingPosition();
            },
            onOpenBookmarks: () => {
              this.openSubPanel('bookmarks');
            },
          })
            .width('100%')
            .transition(TransitionEffect.translate({ y: '-100%' }).animation({ duration: PANEL_SLIDE_MS, curve: Curve.EaseOut }));

          Column()
            .layoutWeight(1)
            .width('100%')
            .backgroundColor(ReaderThemeColors.overlay(this.readerTheme))
            .transition(TransitionEffect.OPACITY.animation({ duration: SCRIM_FADE_MS, curve: Curve.EaseOut }))
            .hitTestBehavior(HitTestMode.Default)
            .onClick(() => {
              if (this.subPanelSheet.length > 0) {
                this.closeSubPanel();
                return;
              }
              this.closeControlPanel();
            });

          Column({ space: 0 }) {
            if (this.subPanelSheet.length > 0) {
              Column() {
                ReaderControlPanel({
                  sheetOnly: this.subPanelSheet,
                  catalogItems: this.panelCatalogItems,
                  bookmarks: this.panelBookmarks,
                  currentCatalogIndex: this.resolveCurrentCatalogIndex(),
                  fontSize: $fontSize,
                  lineHeight: $lineHeight,
                  selectedFontId: this.selectedFontId,
                  fontOptions: this.fontOptions,
                  theme: $readerTheme,
                  flipLabels: READKIT_FLIP_LABELS,
                  flipValues: READKIT_FLIP_VALUES,
                  flipValue: $flipMode,
                  keepScreenOn: $keepScreenOn,
                  showBookmarks: true,
                  showAloud: true,
                  ttsState: this.ttsState,
                  ttsChapterTitle: this.chapterTitle,
                  ttsSpeed: $ttsSpeed,
                  ttsChunkIndex: this.ttsChunkIndex,
                  ttsChunkTotal: this.ttsChunkTotal,
                  ttsVoices: this.ttsVoices,
                  ttsPerson: this.ttsPerson,
                  ttsVoiceLoading: this.ttsVoiceLoading,
                  fontDownloading: this.fontDownloading,
                  onTtsPlay: () => {
                    this.handleTtsPlay();
                  },
                  onTtsPause: () => {
                    this.pauseTts();
                  },
                  onTtsStop: () => {
                    this.handleTtsStop();
                  },
                  onSelectVoice: (person: number) => {
                    this.selectTtsPerson(person);
                  },
                  onReloadVoices: () => {
                    void this.loadTtsVoices(true);
                  },
                  onSelectCatalogIndex: (index: number) => {
                    this.openCatalogIndex(index);
                  },
                  onSelectBookmark: (bookmarkId: string) => {
                    this.openBookmarkById(bookmarkId);
                  },
                  onRemoveBookmark: (bookmarkId: string) => {
                    this.removeBookmarkById(bookmarkId);
                  },
                  onSelectFont: (fontId: string) => {
                    void this.selectFont(fontId);
                  },
                  onSettingsChanged: (relayout: boolean) => {
                    if (relayout) {
                      // 字号/行距/主题/翻页：重排版后按当前位置重新定位
                      this.applySettings(true);
                      void this.reapplyReadingPosition();
                    } else {
                      // 仅行为类设置（常亮）：只落盘，避免重排版把正文拉回章首
                      this.saveReaderPrefs();
                    }
                    this.syncKeepScreenOn();
                  },
                  onClose: () => {
                    this.closeSubPanel();
                  },
                });
              }
              .width('100%')
              .height('46%');
            }

            ReaderOverlayBar({
              theme: this.readerTheme,
              chapterProgress: this.chapterProgress(),
              canGoPrevChapter: this.canGoPrevChapter(),
              canGoNextChapter: this.canGoNextChapter(),
              activeNav: this.overlayNav,
              showSearch: true,
              showAloud: true,
              onSearch: () => {
                this.getUIContext().getPromptAction().showToast({ message: '正文搜索开发中' });
              },
              onReadAloud: () => {
                this.toggleReadAloud();
              },
              onRefresh: () => {
                this.applySettings(true);
                void this.reapplyReadingPosition();
              },
              onToggleNight: () => {
                this.toggleNightTheme();
              },
              onPrevChapter: () => {
                this.goPrevChapter();
              },
              onNextChapter: () => {
                this.goNextChapter();
              },
              onChapterProgressChange: (value: number) => {
                this.goChapterProgress(value);
              },
              onOpenToc: () => {
                this.openSubPanel('toc');
              },
              onOpenAloud: () => {
                this.openSubPanel('aloud');
              },
              onOpenAppearance: () => {
                this.openSubPanel('appearance');
              },
              onOpenSettings: () => {
                this.openSubPanel('settings');
              },
            });
          }
          .width('100%')
          .transition(TransitionEffect.translate({ y: '100%' }).animation({ duration: PANEL_SLIDE_MS, curve: Curve.EaseOut }));
        }
        .width('100%')
        .height('100%')
        .zIndex(10);
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
  }
}
