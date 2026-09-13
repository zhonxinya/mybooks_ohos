import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  BookEngine,
  READER_FLIP_COVER,
  READER_FLIP_DEFAULT,
  READER_FLIP_NONE,
  READER_FLIP_OPTIONS,
  READER_PANEL_APPEARANCE,
  READER_PANEL_TOC,
  READER_PARAGRAPH_PREFIX,
  ReaderBlock,
  ReaderBlockKind,
  ReaderCallbacks,
  ReaderCatalogItem,
  ReaderFlip,
  ReaderLocation,
  ReaderOpenOptions,
  ReaderSettings,
  ReaderTheme,
} from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { BookEngineFactory } from '../engine/BookEngineFactory';
import { PageLayout, PageMetrics, PagePager, ReaderPage } from '../engine/PageLayout';
import { LazyDataSource } from './LazyDataSource';
import { ReaderControlPanel } from './ReaderControlPanel';
import { PAGE_FOOTER_SPACE, ReaderPageView } from './ReaderPageView';


const TAG: string = 'ReaderView';
const TOP_BAR_HEIGHT: number = 52;
const CONTENT_HORIZONTAL_SPACE: number = 22;
/** 正文上下留白：工具栏为浮层，留白保证文字不被浮层遮住。 */
const CONTENT_TOP_SPACE: number = 44;
const CONTENT_BOTTOM_SPACE: number = 32;
const PARAGRAPH_SPACING: number = 12;
/** 进度上报粒度：变化超过 0.5% 才回调宿主，避免滚动/翻页中频繁落盘。 */
const PROGRESS_REPORT_STEP: number = 0.005;
/** 切章/恢复位置后等待一帧（≈1 帧 16ms）再滚动，确保 LazyForEach 已应用重载。 */
const SCROLL_AFTER_RELOAD_MS: number = 32;
/** 翻页动画时长（ms）与翻页判定阈值（占内容区宽度的比例）。 */
const PAGE_ANIM_MS: number = 220;
const PAGE_TURN_RATIO: number = 0.25;
/** 三区点击：左右各 1/3 翻页，中间切换工具栏。 */
const TAP_ZONE_RATIO: number = 0.33;
/** 测量入参单位自校准用的探针宽度（vp）。 */
const PROBE_WIDTH_VP: number = 80;
/** 分页结果最多缓存几章。 */
const MAX_PAGE_CACHE: number = 4;
/** 分片分页：首屏同步推进的步数、以及每帧推进的步数（步 ≈ 一个块/一次切分，含 1–4 次测量）。 */
const INITIAL_PAGINATION_STEPS: number = 24;
const PAGINATION_STEPS_PER_FRAME: number = 24;
/** 每个分页切片的毫秒预算：保证单帧不被分页拖长（分页只能用 UI 线程，measureTextSize 依赖 UIContext）。 */
const PAGINATION_SLICE_MS: number = 8;
/** 工具栏显示后自动隐藏的延时（ms）。 */
const BARS_AUTO_HIDE_MS: number = 4000;
const DEFAULT_SETTINGS: ReaderSettings = {
  fontSize: 18,
  lineHeight: 1.6,
  theme: ReaderTheme.LIGHT,
  flipMode: READER_FLIP_DEFAULT,
  keepScreenOn: false,
};
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
 * 两种阅读形态：
 * - **分页**（覆盖翻页 / 左右滑动 / 无动画）：按测量结果把当前章切成页，
 *   自绘 Stack + 手势实现翻页特效；超长段落会跨页切分；
 * - **上下滚动**：沿用 LazyForEach 列表。
 *
 * 宿主只需提供文件路径/缓存目录/初始设置，并通过回调接收进度与设置变更。
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
  /** 必须是 @State：空页占位/正文的显隐由它决定，普通字段不会触发重渲染。 */
  @State private paragraphCount: number = 0;
  /** 当前章的正文块数（含插图），为 0 才显示空页占位。 */
  @State private blockCount: number = 0;
  @State private showBars: boolean = false;
  /** 控制面板（目录/界面/设置）与当前标签页。 */
  @State private showPanel: boolean = false;
  @State private panelTab: string = READER_PANEL_TOC;
  @State private fontSize: number = DEFAULT_SETTINGS.fontSize;
  @State private lineHeight: number = DEFAULT_SETTINGS.lineHeight;
  @State private theme: ReaderTheme = DEFAULT_SETTINGS.theme;
  @State private flipMode: string = DEFAULT_SETTINGS.flipMode;
  @State private keepScreenOn: boolean = DEFAULT_SETTINGS.keepScreenOn;
  /** 控制面板朗读页的语速：本阅读器未启用朗读，仅满足面板的 @Link 绑定。 */
  @State private ttsSpeed: number = 1.0;
  /** 分页状态。 */
  @State private pageCount: number = 0;
  @State private pageIndex: number = 0;
  @State private paginating: boolean = false;
  @State private paginationToken: number = 0;
  /** 翻页拖拽位移（vp）与方向（-1 上一页 / 0 未拖 / 1 下一页）。 */
  @State private dragOffset: number = 0;
  @State private dragDir: number = 0;

  private engine: BookEngine | null = null;
  private blocks: LazyDataSource<ReaderBlock> = new LazyDataSource<ReaderBlock>();
  private catalogSource: LazyDataSource<ReaderCatalogItem> = new LazyDataSource<ReaderCatalogItem>();
  private catalogItems: ReaderCatalogItem[] = [];
  private pageSource: LazyDataSource<ReaderPage> = new LazyDataSource<ReaderPage>();
  private listScroller: Scroller = new Scroller();
  private initialIndex: number = 0;
  private pendingScrollIndex: number = -1;
  private lastReportedPercent: number = -1;
  /** 最近一次上报的段落下标：重新分页（改字号/翻页方式）时据此回到原处。 */
  private lastParagraph: number = 0;
  private chapterLoading: boolean = false;
  private destroyed: boolean = false;
  private chapterBlocks: ReaderBlock[] = [];
  private pages: ReaderPage[] = [];
  private restoreParagraph: number = 0;
  private pendingLastPage: boolean = false;
  private paginationPending: boolean = false;
  private contentWidthVp: number = 0;
  private contentHeightVp: number = 0;
  /** 测量入参单位换算系数：1 = 入参按 vp/fp，密度值 = 入参按 px。 */
  private measureArgScale: number = 0;
  /** 工具栏自动隐藏定时器。 */
  private barTimer: number = -1;
  /** 分片分页：进行中的分页器与调度状态。 */
  private activePager: PagePager | null = null;
  private pagerGeneration: number = 0;
  private pagerTargetBlock: number = 0;
  private pagerRestore: number = 0;
  private pagerPositionApplied: boolean = false;
  private paginationStartedAt: number = 0;
  /** 上次已生效的排版参数：面板用 @Link 改状态后据此判断是否需要重排。 */
  private appliedFontSize: number = 0;
  private appliedLineHeight: number = 0;
  private appliedFlipMode: string = '';
  /**
   * 分页结果缓存：同一章在相同排版参数下不重复测量。
   * 长章节（近 500 段、含跨页切分）测量要 1.5s 量级，来回翻章时缓存收益明显。
   */
  private pageCache: Map<string, ReaderPage[]> = new Map<string, ReaderPage[]>();

  aboutToAppear(): void {
    const settings = this.options.settings;
    this.fontSize = settings.fontSize;
    this.lineHeight = settings.lineHeight;
    this.theme = settings.theme;
    this.flipMode = ReaderFlip.normalize(settings.flipMode);
    this.keepScreenOn = settings.keepScreenOn;
    const start = ReaderView.parseLocation(this.options.location);
    this.initialIndex = start.paragraphIndex;
    this.lastParagraph = start.paragraphIndex;
    void this.openBook(start);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.pendingScrollIndex = -1;
    this.cancelBarsAutoHide();
    if (this.engine !== null) {
      this.engine.close();
      this.engine = null;
    }
  }

  build() {
    Stack() {
      // 正文常驻：状态切换只用叠加层，避免在分支里销毁重建正文
      this.contentArea();
      if (!this.opening && this.errorMessage.length === 0 && this.blockCount === 0) {
        this.emptyChapterView();
      }
      if (this.opening) {
        this.loadingView();
      }
      if (this.paginating && !this.opening) {
        this.paginatingView();
      }
      if (this.errorMessage.length > 0) {
        this.errorView();
      }
      if (this.showBars && !this.opening && this.errorMessage.length === 0) {
        this.overlayBars();
      }
      if (this.showPanel) {
        this.controlPanelSheet();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ReaderPalette.pageBackground(this.theme));
  }

  /**
   * 控制面板：与 ReaderKit 阅读器共用 `ReaderControlPanel`
   * （目录 / 界面 / 设置；书签与朗读页本阅读器未启用）。
   */
  @Builder
  controlPanelSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.closePanel();
        });
      Column() {
        ReaderControlPanel({
          sheetOnly: this.panelTab,
          catalogItems: this.catalogItems,
          currentCatalogIndex: this.chapterIndex,
          fontSize: $fontSize,
          lineHeight: $lineHeight,
          theme: $theme,
          selectedFontId: '',
          fontOptions: [],
          flipLabels: ReaderFlip.labels(),
          flipValues: READER_FLIP_OPTIONS,
          flipValue: $flipMode,
          keepScreenOn: $keepScreenOn,
          // 内置阅读器只有「界面」一个入口：把常亮也放进界面页
          behaviorInAppearance: true,
          ttsSpeed: $ttsSpeed,
          showBookmarks: false,
          showAloud: false,
          onSelectCatalogIndex: (index: number) => this.goToChapter(index),
          onSettingsChanged: () => this.onPanelSettingsChanged(),
          onClose: () => {
            this.closePanel();
          },
        });
      }
      .width('100%')
      .height(this.panelHeight());
    }
    .width('100%')
    .height('100%');
  }

  private panelHeight(): string {
    return this.panelTab === READER_PANEL_TOC ? '62%' : '46%';
  }

  private openPanel(tab: string): void {
    this.panelTab = tab;
    this.showPanel = true;
    this.cancelBarsAutoHide();
  }

  private closePanel(): void {
    this.showPanel = false;
    this.scheduleBarsAutoHide();
  }

  /** 面板里改动的字号/行距/主题/翻页/常亮统一在这里落盘并重排。 */
  private onPanelSettingsChanged(): void {
    const settings: ReaderSettings = {
      fontSize: this.fontSize,
      lineHeight: this.lineHeight,
      theme: this.theme,
      flipMode: this.flipMode,
      keepScreenOn: this.keepScreenOn,
    };
    this.applySettings(settings);
  }

  // ---- 正文 ----

  @Builder
  contentArea() {
    Stack() {
      if (ReaderFlip.isPaged(this.flipMode)) {
        this.pagedContent();
      } else {
        this.scrollContent();
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.onContentAreaChanged(newArea.width as number, newArea.height as number);
    });
  }

  /** 分页阅读：三个页面层（上一页 / 当前页 / 下一页）+ 跟手拖拽。 */
  @Builder
  pagedContent() {
    Stack() {
      if (this.pageIndex > 0 || this.dragDir === -1) {
        this.pageLayer(this.pageIndex - 1, -1);
      }
      if (this.pageIndex < this.pageCount - 1 || this.dragDir === 1) {
        this.pageLayer(this.pageIndex + 1, 1);
      }
      this.pageLayer(this.pageIndex, 0);
    }
    .width('100%')
    .height('100%')
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 6 })
        .onActionStart(() => this.beginPageDrag())
        .onActionUpdate((event: GestureEvent) => this.updatePageDrag(event.offsetX))
        .onActionEnd(() => this.endPageDrag())
        .onActionCancel(() => this.endPageDrag()),
    )
    .onClick((event: ClickEvent) => this.onPagerClick(event));
  }

  @Builder
  pageLayer(index: number, offset: number) {
    if (index >= 0 && index < this.pageCount) {
      ReaderPageView({
        pages: this.pageSource,
        pageIndex: index,
        pageCount: this.pageCount,
        pageToken: this.paginationToken,
        offsetX: this.layerX(offset),
        layerOrder: this.layerZ(offset),
        fontSize: this.fontSize,
        lineHeight: this.lineHeight,
        theme: this.theme,
        horizontalSpace: CONTENT_HORIZONTAL_SPACE,
        topSpace: CONTENT_TOP_SPACE,
        bottomSpace: CONTENT_BOTTOM_SPACE,
        pageWidthVp: this.textWidthVp(),
        pageHeightVp: this.textHeightVp(),
      });
    }
  }

  @Builder
  scrollContent() {
    List({ scroller: this.listScroller, initialIndex: this.initialIndex, space: PARAGRAPH_SPACING }) {
      LazyForEach(this.blocks, (block: ReaderBlock, index: number) => {
        ListItem() {
          if (block.kind === ReaderBlockKind.IMAGE) {
            this.scrollImageBlock(block);
          } else {
            Text(block.text)
              .fontSize(this.fontSize)
              .lineHeight(this.lineHeight * this.fontSize)
              .fontColor(ReaderPalette.textColor(this.theme))
              .width('100%');
          }
        }
      }, (block: ReaderBlock, index: number) => `${this.chapterIndex}_${index}`);
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
      this.toggleBars();
    });
  }

  /** 滚动模式下的插图：与分页模式同一个高度公式，保证切换方式时观感一致。 */
  @Builder
  scrollImageBlock(block: ReaderBlock) {
    Image('file://' + block.src)
      .width('100%')
      .height(this.pxToVp(PageLayout.imageHeightPx(block, this.pageMetrics())))
      .objectFit(ImageFit.Contain)
      .sourceSize({
        width: Math.max(1, Math.round(this.vpToPx(this.textWidthVp()))),
        height: Math.max(1, Math.round(PageLayout.imageHeightPx(block, this.pageMetrics()))),
      })
      .backgroundColor(ReaderPalette.imageBackground(this.theme))
      .borderRadius(4);
  }

  @Builder
  loadingView() {
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
    .justifyContent(FlexAlign.Center)
    .backgroundColor(ReaderPalette.pageBackground(this.theme));
  }

  @Builder
  paginatingView() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(28)
        .height(28)
        .color(ReaderPalette.accentColor());
      Text('正在分页…')
        .fontSize(13)
        .fontColor(ReaderPalette.hintColor(this.theme));
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(ReaderPalette.pageBackground(this.theme));
  }

  @Builder
  errorView() {
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
    .justifyContent(FlexAlign.Center)
    .backgroundColor(ReaderPalette.pageBackground(this.theme));
  }

  /**
   * 纯图片页（封面、插图页）没有文字时给的占位视图。
   * EPUB 的 cover 页只有 `<img>`，若不提示会整屏空白，用户会以为打开失败。
   */
  @Builder
  emptyChapterView() {
    Column({ space: 10 }) {
      Text(this.chapterTitle)
        .fontSize(16)
        .fontColor(ReaderPalette.textColor(this.theme));
      Text('本页没有文字内容（可能是封面或插图页）')
        .fontSize(13)
        .fontColor(ReaderPalette.hintColor(this.theme));
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(ReaderPalette.pageBackground(this.theme))
    .onClick(() => {
      this.toggleBars();
    });
  }

  @Builder
  overlayBars() {
    Column() {
      this.topBar();
      // Blank 也必须放行：它是子节点，默认会吃掉中间区域的点击/滑动
      Blank()
        .hitTestBehavior(HitTestMode.None);
      this.bottomBar();
    }
    .width('100%')
    .height('100%')
    // 工具栏之间的空白必须让点击穿透到正文：否则工具栏显示时中间点击/左右翻页都失效
    .hitTestBehavior(HitTestMode.None);
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
          this.openPanel(READER_PANEL_TOC);
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
        Text(this.progressText())
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
          this.openPanel(READER_PANEL_APPEARANCE);
        });
    }
    .width('100%')
    .height(TOP_BAR_HEIGHT)
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(ReaderPalette.barBackground(this.theme))
    .shadow({ radius: 16, color: '#28000000', offsetX: 0, offsetY: -4 });
  }

  /** 底部进度：分页模式额外显示当前页/总页数，并给出全书百分比。 */
  private progressText(): string {
    const chapterPart = `第 ${this.chapterIndex + 1}/${this.catalogSize} 章`;
    const percentPart = `${Math.round(Math.max(0, this.lastReportedPercent) * 100)}%`;
    if (!ReaderFlip.isPaged(this.flipMode)) {
      return `${chapterPart} · ${percentPart}`;
    }
    return `${chapterPart} · 第 ${this.pageIndex + 1}/${this.pageCount} 页 · ${percentPart}`;
  }

  // ---- 工具栏显隐 ----

  private toggleBars(): void {
    this.showBars = !this.showBars;
    if (this.showBars) {
      this.scheduleBarsAutoHide();
    } else {
      this.cancelBarsAutoHide();
    }
  }

  /** 工具栏显示后自动隐藏，避免长时间占住正文（打开面板时不隐藏）。 */
  private scheduleBarsAutoHide(): void {
    this.cancelBarsAutoHide();
    this.barTimer = setTimeout(() => {
      this.barTimer = -1;
      if (this.showBars && !this.showPanel) {
        this.showBars = false;
      }
    }, BARS_AUTO_HIDE_MS);
  }

  private cancelBarsAutoHide(): void {
    if (this.barTimer >= 0) {
      clearTimeout(this.barTimer);
      this.barTimer = -1;
    }
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
      this.catalogItems = catalog;
      this.catalogSize = catalog.length;
      this.bookTitle = this.options.title.length > 0 ? this.options.title : engine.getTitle();
      const target = start.chapterIndex >= 0 && start.chapterIndex < catalog.length ?
        start.chapterIndex : 0;
      await this.loadChapter(target, start.paragraphIndex, false);
    } catch (error) {
      this.errorMessage = ReaderView.describeError(error as Error);
    } finally {
      this.opening = false;
    }
  }

  private async loadChapter(index: number, paragraphIndex: number, toLastPage: boolean): Promise<void> {
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
      this.chapterBlocks = chapter.blocks;
      this.blockCount = chapter.blocks.length;
      this.blocks.update(chapter.blocks);
      this.showBars = false;
      this.cancelBarsAutoHide();
      this.restoreParagraph = paragraphIndex < 0 ? 0 : paragraphIndex;
      this.pendingLastPage = toLastPage;
      this.pages = [];
      this.pageSource.update(this.pages);
      this.pageCount = 0;
      this.pageIndex = 0;
      this.paginationToken++;
      // 切章即作废进行中的分页调度，避免旧章的分片结果覆盖新章
      this.activePager = null;
      this.pagerGeneration++;
      this.pagerPositionApplied = false;
      if (ReaderFlip.isPaged(this.flipMode)) {
        this.paginateCurrentChapter();
      } else {
        this.lastParagraph = this.restoreParagraph;
        this.reportProgress(this.restoreParagraph, false);
        this.scheduleScroll(this.restoreParagraph);
      }
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
    this.showPanel = false;
    void this.loadChapter(index, 0, false);
  }

  // ---- 分页 ----

  private paginateCurrentChapter(): void {
    if (this.contentWidthVp <= 0 || this.contentHeightVp <= 0 || this.chapterBlocks.length === 0) {
      // 首帧还没拿到内容区尺寸（或本章无正文）：等 onAreaChange 再补做
      this.paginationPending = true;
      return;
    }
    this.paginationPending = false;
    this.paginating = true;
    const restore = this.restoreParagraph;
    const toLastPage = this.pendingLastPage;
    // 下一帧再开始：让「正在分页」先上屏，测量期间界面不至于完全无反馈
    setTimeout(() => {
      this.beginPagination(restore, toLastPage);
    }, 0);
  }

  /** 分页入口：命中缓存直接用，否则按帧分片推进（长章节不再一次阻塞 UI）。 */
  private beginPagination(restoreParagraph: number, toLastPage: boolean): void {
    if (this.destroyed) {
      return;
    }
    this.calibrateMeasureUnit();
    const started = Date.now();
    this.paginationStartedAt = started;
    const cacheKey = this.paginationCacheKey();
    const cached = this.pageCache.get(cacheKey);
    if (cached !== undefined) {
      this.applyPages(cached, restoreParagraph, toLastPage);
      this.paginating = false;
      hilog.info(0x0000, TAG, 'paged chapter=%{public}d pages=%{public}d cached=true ms=%{public}d',
        this.chapterIndex, cached.length, Date.now() - started);
      return;
    }
    this.pagerGeneration++;
    const measure = (text: string, size: number, width: number, lineHeight: number) =>
      this.measureTextHeightPx(text, size, width, lineHeight);
    if (toLastPage) {
      // 翻上一章的末页：必须先知道总页数，直接同步分完（有「正在分页」提示兜底）
      const pager = new PagePager(this.chapterBlocks, this.pageMetrics(), measure);
      pager.advance(Number.MAX_SAFE_INTEGER);
      this.cachePages(cacheKey, pager.getPages());
      this.applyPages(pager.getPages(), restoreParagraph, true);
      this.paginating = false;
      hilog.info(0x0000, TAG, 'paged chapter=%{public}d pages=%{public}d sync=true ms=%{public}d',
        this.chapterIndex, this.pageCount, Date.now() - started);
      return;
    }
    this.activePager = new PagePager(this.chapterBlocks, this.pageMetrics(), measure);
    this.pagerRestore = restoreParagraph;
    this.pagerTargetBlock = PageLayout.blockIndexForParagraph(this.chapterBlocks, restoreParagraph);
    this.pagerPositionApplied = false;
    // 首屏：同步推进一小段（通常几页），让用户立刻看到内容；其余按帧补完
    this.activePager.advance(INITIAL_PAGINATION_STEPS, PAGINATION_SLICE_MS);
    this.publishPagination(cacheKey, this.pagerGeneration);
  }

  /** 把当前已分页的结果发布到界面；未完成时继续调度下一帧。 */
  private publishPagination(cacheKey: string, generation: number): void {
    const pager = this.activePager;
    if (pager === null || this.destroyed || generation !== this.pagerGeneration) {
      return;
    }
    const pages = pager.getPages().slice();
    this.pages = pages;
    this.pageSource.update(pages);
    this.pageCount = pages.length;
    if (!this.pagerPositionApplied && pager.getNextBlockIndex() > this.pagerTargetBlock && pages.length > 0) {
      this.pagerPositionApplied = true;
      this.pageIndex = PageLayout.pageForParagraph(pages, this.pagerRestore);
      this.paginating = false;
      hilog.info(0x0000, TAG, 'first page ready chapter=%{public}d pages=%{public}d ms=%{public}d',
        this.chapterIndex, pages.length, Date.now() - this.paginationStartedAt);
      this.reportProgress(this.firstParagraphOf(this.pageIndex), false);
    }
    if (pager.isFinished()) {
      this.finishPagination(cacheKey, pages);
      return;
    }
    setTimeout(() => {
      const running = this.activePager;
      if (running === null || this.destroyed || generation !== this.pagerGeneration) {
        return;
      }
      running.advance(PAGINATION_STEPS_PER_FRAME, PAGINATION_SLICE_MS);
      this.publishPagination(cacheKey, generation);
    }, 0);
  }

  private finishPagination(cacheKey: string, pages: ReaderPage[]): void {
    this.cachePages(cacheKey, pages);
    this.activePager = null;
    this.paginating = false;
    this.pendingLastPage = false;
    if (!this.pagerPositionApplied && pages.length > 0) {
      // 边界情况（如恢复位置落在最后一页）：收尾时再定位一次
      this.pagerPositionApplied = true;
      this.pageIndex = PageLayout.pageForParagraph(pages, this.pagerRestore);
      this.reportProgress(this.firstParagraphOf(this.pageIndex), false);
    }
    hilog.info(0x0000, TAG, 'paged chapter=%{public}d pages=%{public}d cached=false ms=%{public}d',
      this.chapterIndex, pages.length, Date.now() - this.paginationStartedAt);
  }

  /** 把完整页表应用到界面（缓存命中 / 同步分页路径）。 */
  private applyPages(pages: ReaderPage[], restoreParagraph: number, toLastPage: boolean): void {
    this.pages = pages;
    this.pageSource.update(pages);
    this.pageCount = pages.length;
    this.pageIndex = toLastPage ? Math.max(0, pages.length - 1) :
      PageLayout.pageForParagraph(pages, restoreParagraph);
    this.paginationToken++;
    this.pendingLastPage = false;
    this.reportProgress(this.firstParagraphOf(this.pageIndex), false);
  }

  private cachePages(cacheKey: string, pages: ReaderPage[]): void {
    if (this.pageCache.size >= MAX_PAGE_CACHE) {
      this.pageCache.clear();
    }
    this.pageCache.set(cacheKey, pages.slice());
  }

  private firstParagraphOf(pageIndex: number): number {
    const page = this.pages[pageIndex];
    return page === undefined ? 0 : page.firstParagraph;
  }

  /** 交互发生前先把分页补完，避免「还没分到的页」被误判为越界而跳章。 */
  private drainPagination(): void {
    const pager = this.activePager;
    if (pager === null || pager.isFinished()) {
      return;
    }
    pager.advance(Number.MAX_SAFE_INTEGER);
    const pages = pager.getPages().slice();
    this.pages = pages;
    this.pageSource.update(pages);
    this.pageCount = pages.length;
    this.finishPagination(this.paginationCacheKey(), pages);
  }

  /** 缓存键：章 + 排版参数（字号/行高/正文可用区），任一变化即重新分页。 */
  private paginationCacheKey(): string {
    return `${this.chapterIndex}|${this.fontSize}|${this.lineHeight}|` +
      `${Math.round(this.textWidthVp())}x${Math.round(this.textHeightVp())}`;
  }

  private onContentAreaChanged(width: number, height: number): void {
    if (width === this.contentWidthVp && height === this.contentHeightVp) {
      return;
    }
    this.contentWidthVp = width;
    this.contentHeightVp = height;
    if (!ReaderFlip.isPaged(this.flipMode) || this.chapterBlocks.length === 0) {
      return;
    }
    if (this.paginationPending || this.pageCount === 0) {
      this.paginateCurrentChapter();
    }
  }

  private textWidthVp(): number {
    return Math.max(1, this.contentWidthVp - CONTENT_HORIZONTAL_SPACE * 2);
  }

  private textHeightVp(): number {
    // 扣掉页脚页码占位，避免正文与页码重叠
    return Math.max(1, this.contentHeightVp - CONTENT_TOP_SPACE - CONTENT_BOTTOM_SPACE - PAGE_FOOTER_SPACE);
  }

  /** 当前正文可用区参数：分页与插图高度都用它，保证两处公式一致。 */
  private pageMetrics(): PageMetrics {
    const widthVp = this.textWidthVp();
    return {
      widthVp: widthVp,
      widthPx: this.vpToPx(widthVp),
      heightPx: this.vpToPx(this.textHeightVp()),
      fontSize: this.fontSize,
      lineHeight: this.lineHeight,
      paragraphSpacingPx: this.vpToPx(PARAGRAPH_SPACING),
    };
  }

  /**
   * 测量入参单位自校准。
   *
   * `MeasureUtils.measureTextSize` 的返回值是 px，但入参（constraintWidth / fontSize）在文档里
   * 只写「number」——用一条长探针实测：返回宽度≈vp2px(探针宽度) 说明入参按 vp/fp 处理，
   * 否则按 px 处理；后续测量统一乘上密度，保证两种约定下算出的物理排版一致。
   */
  private calibrateMeasureUnit(): void {
    if (this.measureArgScale > 0) {
      return;
    }
    let probe: string = '';
    for (let i = 0; i < 40; i++) {
      probe += '一二三四五六七八九十';
    }
    try {
      const size = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: probe,
        fontSize: 16,
        constraintWidth: PROBE_WIDTH_VP,
      });
      const widthPx = Number(size.width);
      const expectedPx = this.vpToPx(PROBE_WIDTH_VP);
      this.measureArgScale = widthPx >= expectedPx * 0.75 ? 1 : this.vpToPx(1);
      hilog.info(0x0000, TAG, 'measure unit probe: width=%{public}d expected=%{public}d scale=%{public}s',
        widthPx, expectedPx, `${this.measureArgScale}`);
    } catch (error) {
      hilog.warn(0x0000, TAG, 'measure probe failed: %{public}s', (error as Error).message);
      this.measureArgScale = 1;
    }
  }

  /** 测量一段文本的高度（px）。 */
  private measureTextHeightPx(text: string, fontSize: number, widthVp: number, lineHeight: number): number {
    const scale = this.measureArgScale > 0 ? this.measureArgScale : 1;
    try {
      const size = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: text,
        fontSize: fontSize * scale,
        constraintWidth: widthVp * scale,
        lineHeight: lineHeight * fontSize * scale,
      });
      const height = Number(size.height);
      if (height > 0) {
        return height;
      }
    } catch (error) {
      hilog.warn(0x0000, TAG, 'measure failed: %{public}s', (error as Error).message);
    }
    // 兜底估算：按行数 × 行高（宁可高估，避免页面溢出）
    const linePx = lineHeight * fontSize * this.vpToPx(1);
    return linePx * Math.max(1, Math.ceil(text.length / 24));
  }

  // ---- 翻页交互 ----

  // 命名避开 CustomComponent 内置的 onDragStart/onDragEnd（拖拽事件回调）
  private beginPageDrag(): void {
    this.dragDir = 0;
    this.dragOffset = 0;
  }

  private updatePageDrag(dx: number): void {
    if (this.flipMode === READER_FLIP_NONE) {
      return;
    }
    if (this.dragDir === 0) {
      if (Math.abs(dx) < 2) {
        return;
      }
      this.dragDir = dx < 0 ? 1 : -1;
    }
    this.dragOffset = dx;
  }

  private endPageDrag(): void {
    if (this.flipMode === READER_FLIP_NONE || this.dragDir === 0) {
      this.dragDir = 0;
      this.dragOffset = 0;
      return;
    }
    const threshold = this.contentWidthVp * PAGE_TURN_RATIO;
    const dx = this.dragOffset;
    if (this.dragDir === 1 && dx <= -threshold) {
      this.animateTurn(1);
      return;
    }
    if (this.dragDir === -1 && dx >= threshold) {
      this.animateTurn(-1);
      return;
    }
    this.animateBack();
  }

  /** 翻页动画结束后再切换页码，避免切换瞬间跳变。 */
  private animateTurn(delta: number): void {
    const width = this.contentWidthVp;
    const target = delta > 0 ? -width : width;
    this.getUIContext().animateTo({
      duration: PAGE_ANIM_MS,
      curve: Curve.Friction,
      onFinish: () => {
        this.dragOffset = 0;
        this.dragDir = 0;
        this.turnPage(delta);
      },
    }, () => {
      this.dragOffset = target;
    });
  }

  private animateBack(): void {
    this.getUIContext().animateTo({
      duration: PAGE_ANIM_MS,
      curve: Curve.Friction,
      onFinish: () => {
        this.dragDir = 0;
      },
    }, () => {
      this.dragOffset = 0;
    });
  }

  /** 翻页：越界时切到相邻章（下一章首页 / 上一章末页）。 */
  private turnPage(delta: number): void {
    if (!ReaderFlip.isPaged(this.flipMode)) {
      return;
    }
    // 分片分页还没补完时先补完：否则「未分到的页」会被误判为章末而跳章
    this.drainPagination();
    const target = this.pageIndex + delta;
    if (target < 0) {
      const previousChapter = this.chapterIndex - 1;
      if (previousChapter >= 0) {
        void this.loadChapter(previousChapter, 0, true);
      }
      return;
    }
    if (target >= this.pageCount) {
      const nextChapter = this.chapterIndex + 1;
      if (nextChapter < this.catalogSize) {
        void this.loadChapter(nextChapter, 0, false);
      }
      return;
    }
    this.pageIndex = target;
    const page = this.pages[target];
    this.reportProgress(page === undefined ? 0 : page.firstParagraph, false);
  }

  /** 三区点击：左 1/3 上一页、右 1/3 下一页、中间切换工具栏。 */
  private onPagerClick(event: ClickEvent): void {
    const width = this.contentWidthVp;
    if (width <= 0) {
      this.toggleBars();
      return;
    }
    const x = event.x;
    if (x < width * TAP_ZONE_RATIO) {
      this.turnPage(-1);
      return;
    }
    if (x > width * (1 - TAP_ZONE_RATIO)) {
      this.turnPage(1);
      return;
    }
    this.toggleBars();
  }

  /** 页面层横向位移：覆盖模式只动「上面那一页」，滑动模式两页同步平移。 */
  private layerX(offset: number): number {
    const width = this.contentWidthVp;
    const dx = this.dragOffset;
    if (this.flipMode === READER_FLIP_COVER) {
      if (offset === 0) {
        return this.dragDir === 1 ? dx : 0;
      }
      if (offset === 1) {
        return 0;
      }
      return this.dragDir === -1 ? -width + dx : -width;
    }
    if (offset === 0) {
      return dx;
    }
    return offset > 0 ? width + dx : -width + dx;
  }

  /** 层序：覆盖模式向右拖时「上一页」要盖在当前页之上。 */
  private layerZ(offset: number): number {
    if (this.flipMode === READER_FLIP_COVER && this.dragDir === -1 && offset === -1) {
      return 3;
    }
    return offset === 0 ? 2 : 1;
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
    // 滚动模式的 item 是「块」，进度仍按文本段落序号上报
    const block = this.chapterBlocks[start];
    this.reportProgress(block === undefined ? 0 : block.paragraphIndex, true);
  }

  /** 上报进度；`throttled` 为 true 时按 0.5% 粒度去抖。 */
  private reportProgress(paragraphIndex: number, throttled: boolean): void {
    const chapterCount = this.catalogSize > 0 ? this.catalogSize : 1;
    let percent: number;
    if (ReaderFlip.isPaged(this.flipMode)) {
      const pages = this.pageCount > 0 ? this.pageCount : 1;
      percent = Math.min(1, Math.max(0, (this.chapterIndex + (this.pageIndex + 1) / pages) / chapterCount));
    } else {
      const total = this.paragraphCount > 0 ? this.paragraphCount : 1;
      percent = Math.min(1, Math.max(0, (this.chapterIndex + paragraphIndex / total) / chapterCount));
    }
    if (throttled && Math.abs(percent - this.lastReportedPercent) < PROGRESS_REPORT_STEP) {
      return;
    }
    this.lastReportedPercent = percent;
    this.lastParagraph = paragraphIndex < 0 ? 0 : paragraphIndex;
    const location: ReaderLocation = {
      chapterIndex: this.chapterIndex,
      paragraphIndex: this.lastParagraph,
      percent: percent,
    };
    this.callbacks.onProgress(location, this.chapterTitle);
  }

  /**
   * 应用设置。控制面板通过 `@Link` 直接改本组件的状态，所以这里不能拿「新旧状态」比较，
   * 而是与**上次已生效**的排版参数比较，决定是否需要重新分页或切换阅读形态。
   */
  private applySettings(settings: ReaderSettings): void {
    const nextFlip = ReaderFlip.normalize(settings.flipMode);
    const metricsChanged = settings.fontSize !== this.appliedFontSize ||
      settings.lineHeight !== this.appliedLineHeight;
    const flipChanged = nextFlip !== this.appliedFlipMode;
    this.appliedFontSize = settings.fontSize;
    this.appliedLineHeight = settings.lineHeight;
    this.appliedFlipMode = nextFlip;
    this.fontSize = settings.fontSize;
    this.lineHeight = settings.lineHeight;
    this.theme = settings.theme;
    this.flipMode = nextFlip;
    this.keepScreenOn = settings.keepScreenOn;
    const applied: ReaderSettings = {
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      theme: settings.theme,
      flipMode: nextFlip,
      keepScreenOn: settings.keepScreenOn,
    };
    this.callbacks.onSettingsChanged(applied);
    if (ReaderFlip.isPaged(nextFlip)) {
      if (flipChanged || metricsChanged) {
        // 重新分页：回到当前位置（先记住当前页首段，避免用旧位置）
        this.restoreParagraph = this.currentFirstParagraph();
        this.pendingLastPage = false;
        this.paginateCurrentChapter();
      }
      return;
    }
    if (flipChanged) {
      // 切到滚动模式：定位到当前页首段
      this.lastParagraph = this.currentFirstParagraph();
      this.reportProgress(this.lastParagraph, false);
      this.scheduleScroll(this.lastParagraph);
    }
  }

  private currentFirstParagraph(): number {
    const page = this.pages[this.pageIndex];
    return page === undefined ? this.lastParagraph : page.firstParagraph;
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

  /** vp→px：用 `UIContext.vp2px`（全局 `vp2px` 已废弃），参数非法时降级为原值。 */
  private vpToPx(value: number): number {
    try {
      return this.getUIContext().vp2px(value);
    } catch (_error) {
      return value;
    }
  }

  private pxToVp(value: number): number {
    try {
      return this.getUIContext().px2vp(value);
    } catch (_error) {
      return value;
    }
  }
}
