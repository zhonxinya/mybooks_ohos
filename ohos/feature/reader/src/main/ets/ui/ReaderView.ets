import {
  BookEngine,
  READER_PARAGRAPH_PREFIX,
  ReaderCallbacks,
  ReaderCatalogItem,
  ReaderLocation,
  ReaderOpenOptions,
  ReaderSettings,
  ReaderTheme,
} from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { BookEngineFactory } from '../engine/BookEngineFactory';
import { LazyDataSource } from './LazyDataSource';
import { ReaderCatalogSheet } from './ReaderCatalogSheet';
import { ReaderSettingsSheet } from './ReaderSettingsSheet';

const TOP_BAR_HEIGHT: number = 52;
const CONTENT_HORIZONTAL_SPACE: number = 22;
/** 正文上下留白：工具栏为浮层，留白保证文字不被浮层遮住。 */
const CONTENT_TOP_SPACE: number = 44;
const CONTENT_BOTTOM_SPACE: number = 32;
const PARAGRAPH_SPACING: number = 12;
/** 进度上报粒度：变化超过 0.5% 才回调宿主，避免滚动中频繁落盘。 */
const PROGRESS_REPORT_STEP: number = 0.005;
/** 切章/恢复位置后等待一帧（≈1 帧 16ms）再滚动，确保 LazyForEach 已应用重载。 */
const SCROLL_AFTER_RELOAD_MS: number = 32;
const DEFAULT_SETTINGS: ReaderSettings = { fontSize: 18, lineHeight: 1.6, theme: ReaderTheme.LIGHT };
const DEFAULT_OPTIONS: ReaderOpenOptions = {
  filePath: '',
  format: '',
  title: '',
  cacheDir: '',
  location: '',
  settings: DEFAULT_SETTINGS,
};

interface ParsedLocation {
  chapterIndex: number;
  paragraphIndex: number;
}

/**
 * 独立阅读器视图（不依赖系统 ReaderKit）。
 *
 * 宿主只需提供文件路径/缓存目录/初始设置，并通过回调接收进度与设置变更；
 * 解压、解析、分章、渲染全部在本模块内完成。
 */
@Component
export struct ReaderView {
  /** 打开参数（宿主一次性传入）。 */
  options: ReaderOpenOptions = DEFAULT_OPTIONS;
  /** 宿主回调。 */
  callbacks: ReaderCallbacks = {
    onProgress: (location: ReaderLocation, chapterTitle: string): void => {},
    onClose: (): void => {},
    onSettingsChanged: (settings: ReaderSettings): void => {},
  };

  @State private bookTitle: string = '';
  /** 仅首屏打开（含 EPUB 解压）显示整页加载态；切章不重建列表，避免闪屏。 */
  @State private opening: boolean = true;
  @State private errorMessage: string = '';
  @State private chapterIndex: number = 0;
  @State private chapterTitle: string = '';
  @State private catalogSize: number = 0;
  @State private showBars: boolean = false;
  @State private showCatalog: boolean = false;
  @State private showSettings: boolean = false;
  @State private fontSize: number = DEFAULT_SETTINGS.fontSize;
  @State private lineHeight: number = DEFAULT_SETTINGS.lineHeight;
  @State private theme: ReaderTheme = DEFAULT_SETTINGS.theme;

  private engine: BookEngine | null = null;
  private paragraphs: LazyDataSource<string> = new LazyDataSource<string>();
  private catalogSource: LazyDataSource<ReaderCatalogItem> = new LazyDataSource<ReaderCatalogItem>();
  private listScroller: Scroller = new Scroller();
  private initialIndex: number = 0;
  private paragraphCount: number = 0;
  private pendingScrollIndex: number = -1;
  private lastReportedPercent: number = -1;
  private chapterLoading: boolean = false;
  private destroyed: boolean = false;

  aboutToAppear(): void {
    const settings = this.options.settings;
    this.fontSize = settings.fontSize;
    this.lineHeight = settings.lineHeight;
    this.theme = settings.theme;
    const start = ReaderView.parseLocation(this.options.location);
    this.initialIndex = start.paragraphIndex;
    void this.openBook(start);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.pendingScrollIndex = -1;
    if (this.engine !== null) {
      this.engine.close();
      this.engine = null;
    }
  }

  build() {
    Stack() {
      this.readerContent();
      if (this.showBars && !this.opening && this.errorMessage.length === 0) {
        this.overlayBars();
      }
      if (this.showCatalog) {
        ReaderCatalogSheet({
          catalog: this.catalogSource,
          currentIndex: this.chapterIndex,
          theme: this.theme,
          onSelect: (index: number) => this.goToChapter(index),
          onClose: () => {
            this.showCatalog = false;
          },
        });
      }
      if (this.showSettings) {
        ReaderSettingsSheet({
          fontSize: this.fontSize,
          lineHeight: this.lineHeight,
          theme: this.theme,
          onSettingsChange: (settings: ReaderSettings) => this.applySettings(settings),
          onClose: () => {
            this.showSettings = false;
          },
        });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ReaderPalette.pageBackground(this.theme));
  }

  // ---- 正文 ----

  @Builder
  readerContent() {
    if (this.opening) {
      Column({ space: 12 }) {
        LoadingProgress()
          .width(36)
          .height(36)
          .color(ReaderPalette.accentColor());
        Text('正在打开…')
          .fontSize(14)
          .fontColor(ReaderPalette.hintColor(this.theme));
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center);
    } else if (this.errorMessage.length > 0) {
      Column({ space: 16 }) {
        Text(this.errorMessage)
          .fontSize(15)
          .textAlign(TextAlign.Center)
          .fontColor(ReaderPalette.textColor(this.theme))
          .padding({ left: 32, right: 32 });
        Text('返回')
          .fontSize(15)
          .fontColor(ReaderPalette.accentColor())
          .padding(10)
          .onClick(() => this.callbacks.onClose());
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center);
    } else {
      List({ scroller: this.listScroller, initialIndex: this.initialIndex, space: PARAGRAPH_SPACING }) {
        LazyForEach(this.paragraphs, (paragraph: string, index: number) => {
          ListItem() {
            Text(paragraph)
              .fontSize(this.fontSize)
              .lineHeight(this.lineHeight * this.fontSize)
              .fontColor(ReaderPalette.textColor(this.theme))
              .width('100%');
          }
        }, (paragraph: string, index: number) => `${this.chapterIndex}_${index}`);
      }
      .width('100%')
      .height('100%')
      .padding({
        left: CONTENT_HORIZONTAL_SPACE,
        right: CONTENT_HORIZONTAL_SPACE,
        top: CONTENT_TOP_SPACE,
        bottom: CONTENT_BOTTOM_SPACE,
      })
      .cachedCount(4)
      .scrollBar(BarState.Off)
      .onScrollIndex((start: number, end: number) => {
        this.onListScroll(start);
      })
      .onClick(() => {
        this.showBars = !this.showBars;
      });
    }
  }

  @Builder
  overlayBars() {
    Column() {
      this.topBar();
      Blank();
      this.bottomBar();
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  topBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([ReaderPalette.textColor(this.theme)])
        .padding(8)
        .onClick(() => this.callbacks.onClose());
      Text(this.bookTitle)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(ReaderPalette.textColor(this.theme))
        .layoutWeight(1);
      SymbolGlyph($r('sys.symbol.list_bullet'))
        .fontSize(20)
        .fontColor([ReaderPalette.textColor(this.theme)])
        .padding(8)
        .onClick(() => {
          this.showCatalog = true;
        });
    }
    .width('100%')
    .height(TOP_BAR_HEIGHT)
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(ReaderPalette.barBackground(this.theme))
    .shadow({ radius: 16, color: '#28000000', offsetX: 0, offsetY: 4 });
  }

  @Builder
  bottomBar() {
    Row({ space: 8 }) {
      Text('上一章')
        .fontSize(14)
        .fontColor(this.chapterNavColor(this.chapterIndex > 0))
        .padding(10)
        .onClick(() => this.goToChapter(this.chapterIndex - 1));
      Column({ space: 2 }) {
        Text(this.chapterTitle)
          .fontSize(13)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(ReaderPalette.textColor(this.theme));
        Text(`第 ${this.chapterIndex + 1}/${this.catalogSize} 章`)
          .fontSize(11)
          .fontColor(ReaderPalette.hintColor(this.theme));
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center);
      Text('下一章')
        .fontSize(14)
        .fontColor(this.chapterNavColor(this.chapterIndex + 1 < this.catalogSize))
        .padding(10)
        .onClick(() => this.goToChapter(this.chapterIndex + 1));
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(20)
        .fontColor([ReaderPalette.textColor(this.theme)])
        .padding(8)
        .onClick(() => {
          this.showSettings = true;
        });
    }
    .width('100%')
    .height(TOP_BAR_HEIGHT)
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(ReaderPalette.barBackground(this.theme))
    .shadow({ radius: 16, color: '#28000000', offsetX: 0, offsetY: -4 });
  }

  private chapterNavColor(enabled: boolean): ResourceColor {
    return enabled ? ReaderPalette.textColor(this.theme) : ReaderPalette.hintColor(this.theme);
  }

  // ---- 打开 / 切章 ----

  private async openBook(start: ParsedLocation): Promise<void> {
    this.opening = true;
    this.errorMessage = '';
    try {
      const engine = await BookEngineFactory.open(this.options);
      if (this.destroyed) {
        engine.close();
        return;
      }
      this.engine = engine;
      const catalog = engine.getCatalog();
      this.catalogSource.update(catalog);
      this.catalogSize = catalog.length;
      this.bookTitle = this.options.title.length > 0 ? this.options.title : engine.getTitle();
      const target = start.chapterIndex >= 0 && start.chapterIndex < catalog.length ?
        start.chapterIndex : 0;
      await this.loadChapter(target, start.paragraphIndex);
    } catch (error) {
      this.errorMessage = ReaderView.describeError(error as Error);
    } finally {
      this.opening = false;
    }
  }

  private async loadChapter(index: number, paragraphIndex: number): Promise<void> {
    const engine = this.engine;
    if (engine === null || this.chapterLoading) {
      return;
    }
    this.chapterLoading = true;
    try {
      const chapter = await engine.loadChapter(index);
      if (this.destroyed) {
        return;
      }
      this.chapterIndex = chapter.index;
      this.chapterTitle = chapter.title;
      this.paragraphCount = chapter.paragraphs.length;
      this.paragraphs.update(chapter.paragraphs);
      this.showBars = false;
      const target = paragraphIndex < 0 ? 0 : paragraphIndex;
      this.reportProgress(target, false);
      this.scheduleScroll(target);
    } catch (error) {
      this.errorMessage = ReaderView.describeError(error as Error);
    } finally {
      this.chapterLoading = false;
    }
  }

  /** 切章（含上一章/下一章/目录跳转）；越界直接忽略。 */
  private goToChapter(index: number): void {
    if (index < 0 || index >= this.catalogSize || index === this.chapterIndex) {
      return;
    }
    this.showCatalog = false;
    void this.loadChapter(index, 0);
  }

  // ---- 滚动与进度 ----

  private scheduleScroll(paragraphIndex: number): void {
    this.pendingScrollIndex = paragraphIndex;
    // 等一帧让 LazyForEach 应用重载通知后再定位；列表未就绪时由 applyPendingScroll 吞掉异常
    setTimeout(() => {
      this.applyPendingScroll();
    }, SCROLL_AFTER_RELOAD_MS);
  }

  private applyPendingScroll(): void {
    const index = this.pendingScrollIndex;
    this.pendingScrollIndex = -1;
    if (this.destroyed || index < 0) {
      return;
    }
    try {
      if (index === 0) {
        this.listScroller.scrollEdge(Edge.Top);
      } else {
        this.listScroller.scrollToIndex(index, true, ScrollAlign.START);
      }
    } catch (_error) {
      // 列表尚未布局完成时忽略；首屏位置由 List 的 initialIndex 兜底
    }
  }

  private onListScroll(start: number): void {
    this.reportProgress(start, true);
  }

  /** 上报进度；`throttled` 为 true 时按 0.5% 粒度去抖。 */
  private reportProgress(paragraphIndex: number, throttled: boolean): void {
    const chapterCount = this.catalogSize > 0 ? this.catalogSize : 1;
    const total = this.paragraphCount > 0 ? this.paragraphCount : 1;
    const within = paragraphIndex > 0 ? paragraphIndex / total : 0;
    const percent = Math.min(1, Math.max(0, (this.chapterIndex + within) / chapterCount));
    if (throttled && Math.abs(percent - this.lastReportedPercent) < PROGRESS_REPORT_STEP) {
      return;
    }
    this.lastReportedPercent = percent;
    const location: ReaderLocation = {
      chapterIndex: this.chapterIndex,
      paragraphIndex: paragraphIndex,
      percent: percent,
    };
    this.callbacks.onProgress(location, this.chapterTitle);
  }

  private applySettings(settings: ReaderSettings): void {
    this.fontSize = settings.fontSize;
    this.lineHeight = settings.lineHeight;
    this.theme = settings.theme;
    this.callbacks.onSettingsChanged(settings);
  }

  // ---- 工具 ----

  /** 解析宿主传入的起始位置（与 ReaderKit 阅读器共用同一份 location JSON）。 */
  private static parseLocation(location: string): ParsedLocation {
    const parsed: ParsedLocation = { chapterIndex: 0, paragraphIndex: 0 };
    if (location.length === 0) {
      return parsed;
    }
    try {
      const raw = JSON.parse(location) as Record<string, Object>;
      const chapterIndex = Number(raw['resourceIndex'] ?? 0);
      // domPos 形如 `builtin:12`；来自 ReaderKit 的位置（epubcfi(...)）解析为 NaN → 从章首开始
      const rawDomPos = `${raw['domPos'] ?? 0}`;
      const paragraphText = rawDomPos.startsWith(READER_PARAGRAPH_PREFIX) ?
        rawDomPos.substring(READER_PARAGRAPH_PREFIX.length) : rawDomPos;
      const paragraphIndex = Number(paragraphText);
      parsed.chapterIndex = Number.isNaN(chapterIndex) || chapterIndex < 0 ? 0 : chapterIndex;
      parsed.paragraphIndex = Number.isNaN(paragraphIndex) || paragraphIndex < 0 ? 0 : paragraphIndex;
    } catch (_error) {
      // location 非法时从头开始，不阻断阅读
    }
    return parsed;
  }

  private static describeError(error: Error): string {
    const message = error.message;
    return message !== undefined && message.length > 0 ? message : '打开书籍失败';
  }
}
