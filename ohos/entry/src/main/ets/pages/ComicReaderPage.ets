import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  PageScaffold, EmptyState, LoadingState, LazyDataSource,
} from '../components';
import { AuthImage } from '../components/AuthImage';
import {
  ComicApi, ComicManifestResponse, ComicPageInfo, ComicProgress, ComicProgressResponse,
} from '../services/ComicApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { WindowAbility } from '../entryability/WindowAbility';
import { ReaderTheme } from '../models/ReaderTheme';
import { ReaderChrome } from 'reader';
import { ReaderThemeColors } from '../theme/ReaderThemeColors';
import { CoverCache } from '../utils/CoverCache';

/**
 * talebook 漫画阅读器（竖向连续翻页）。
 *
 * 端点（核对自 docs/talebook/webserver/handlers/comic.py）：
 * - `GET  /api/book/{id}/comic/pages` 页面清单（含 revision、每页尺寸与带 token 的图片地址）；
 * - `GET  /api/book/{id}/comic/pages/{index}` 单页图片二进制，由 AuthImage 走图片通道取回；
 * - `GET  /api/book/{id}/comic/progress` 读取上次进度；
 * - `POST /api/book/{id}/comic/progress` 节流上报进度。
 */

const TAG: string = 'ComicReaderPage';
/**
 * 进度上报节流窗口（毫秒）。
 * 与项目分页防抖思路一致（`PaginationConstants.LOAD_MORE_DEBOUNCE_MS` 的思路），
 * 连续翻页只在窗口结束时发一次请求，避免逐页打服务端。
 */
const PROGRESS_REPORT_THROTTLE_MS: number = 1500;
/** 阅读区底色（深色，避免书页边缘漏白）。 */
const READER_BACKGROUND: string = '#141414';
/** 单页占位高度（宽高未知时的兜底，vp）。 */
const PAGE_FALLBACK_RATIO: number = 1.4;
/** 列表宽度尚未测出时的占位高度（vp，仅首帧短暂出现）。 */
const PAGE_FALLBACK_HEIGHT_VP: number = 360;
/** 页间留白（vp）。 */
const PAGE_GAP_VP: number = 4;
/** 页图落盘探测延迟（毫秒）：超时仍不在缓存中则提示加载失败。 */
const IMAGE_PROBE_DELAY_MS: number = 6000;
/** 失败后的复查间隔（毫秒），图片晚到时自动清除提示。 */
const IMAGE_PROBE_RETRY_MS: number = 5000;

@Entry
@Component
struct ComicReaderPage {
  @State private loading: boolean = true;
  @State private loadError: string = '';
  @State private unsupported: boolean = false;
  @State private reading: boolean = false;
  @State private showBar: boolean = true;
  @State private bookTitle: string = '';
  @State private pages: ComicPageInfo[] = [];
  @State private currentIndex: number = 0;
  @State private contentWidth: number = 0;
  @State private reloadToken: number = 0;
  private bookId: number = 0;
  private routePage: number = -1;
  private pageSource: LazyDataSource<ComicPageInfo> = new LazyDataSource<ComicPageInfo>();
  private listScroller: Scroller = new Scroller();
  private pendingJumpIndex: number = -1;
  private lastReportAt: number = 0;
  private lastReportedIndex: number = -1;
  private pendingReportIndex: number = -1;
  private reportTimer: number = -1;
  private progressHintShown: boolean = false;
  /** 已按「先恢复系统栏再返回」退出过，避免重复恢复。 */
  private immersiveExited: boolean = false;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.bookId = Number(params['bookId'] ?? 0);
    const page = Number(params['page'] ?? -1);
    this.routePage = Number.isNaN(page) ? -1 : page;
    void this.load();
  }

  aboutToDisappear(): void {
    this.clearReportTimer();
    void this.flushProgress();
    // 兜底：正常退出已由 onBackPress 恢复并等待，这里只覆盖进程被回收等异常路径
    if (!this.immersiveExited) {
      this.exitImmersiveMode();
    }
  }

  /**
   * 拦截系统返回键/返回手势：走与返回按钮相同的「先恢复系统栏再返回」路径。
   *
   * 不拦的话系统直接 pop 页面：返回的页面会在窗口仍全屏时先布局一次，等系统栏回来后整页下移
   * 一个状态栏高度，表现为退出时页面猛跳一下。
   */
  onBackPress(): boolean {
    void this.exitImmersiveModeThenBack();
    return true;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private async load(): Promise<void> {
    this.reading = false;
    this.loading = true;
    this.loadError = '';
    this.unsupported = false;
    try {
      // 能力门控：不支持时直接给空态，不发任何请求
      if (!ServerRegistry.supports(ServerFeature.COMIC)) {
        this.unsupported = true;
        return;
      }
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '请先配置 Talebook 服务器';
        return;
      }
      if (this.bookId <= 0) {
        this.loadError = '书籍参数无效';
        return;
      }
      const authed = await TalebookService.ensureAuthenticated();
      if (!authed) {
        this.loadError = '登录状态已失效，请重新登录';
        return;
      }
      const manifest: ComicManifestResponse = await ComicApi.getManifest(this.bookId);
      if (!ComicApi.isOk(manifest)) {
        this.loadError = ComicApi.errorMessage(manifest) || '无法打开漫画';
        return;
      }
      const pages = ComicApi.parsePages(manifest.pages);
      if (pages.length === 0) {
        this.pages = [];
        this.pageSource.update(this.pages);
        return;
      }
      this.bookTitle = manifest.title !== undefined && manifest.title.length > 0
        ? manifest.title : '漫画';
      this.pages = pages;
      this.pageSource.update(pages);
      const target = await this.resolveStartIndex(pages.length);
      this.currentIndex = target;
      this.pendingJumpIndex = target;
      this.reading = true;
      this.showBar = true;
      void this.enterImmersiveMode();
      // 列表首帧构建后才能定位，避免 Scroller 在数据生效前调用
      setTimeout(() => {
        this.applyPendingJump();
      }, 0);
      this.scheduleProgressReport(target, true);
    } catch (error) {
      this.loadError = `${error}`;
      this.pages = [];
      this.pageSource.update(this.pages);
      hilog.warn(0x0000, TAG, 'load failed: %{public}s', `${error}`);
    } finally {
      this.loading = false;
    }
  }

  /** 起始页：路由 `page` 参数优先，其次服务端进度（读进度失败不阻塞阅读）。 */
  private async resolveStartIndex(total: number): Promise<number> {
    if (this.routePage >= 0) {
      return this.clampIndex(this.routePage, total);
    }
    const rsp: ComicProgressResponse = await ComicApi.getProgress(this.bookId);
    if (!ComicApi.isOk(rsp)) {
      return this.clampIndex(0, total);
    }
    const progress: ComicProgress | null = ComicApi.parseProgress(rsp.progress);
    if (progress === null) {
      return this.clampIndex(0, total);
    }
    return this.clampIndex(progress.pageIndex, total);
  }

  private clampIndex(index: number, total: number): number {
    if (total <= 0) {
      return 0;
    }
    if (index < 0) {
      return 0;
    }
    return index > total - 1 ? total - 1 : index;
  }

  private applyPendingJump(): void {
    if (this.pendingJumpIndex < 0 || this.pages.length === 0) {
      return;
    }
    const target = this.clampIndex(this.pendingJumpIndex, this.pages.length);
    this.pendingJumpIndex = -1;
    try {
      this.listScroller.scrollToIndex(target, false);
    } catch (error) {
      hilog.warn(0x0000, TAG, 'scrollToIndex failed: %{public}s', `${error}`);
    }
  }

  private onVisibleRangeChanged(first: number): void {
    if (!this.reading || this.pages.length === 0) {
      return;
    }
    const index = this.clampIndex(first, this.pages.length);
    if (index === this.currentIndex) {
      return;
    }
    this.currentIndex = index;
    this.scheduleProgressReport(index, false);
  }

  /**
   * 节流上报：距上次上报超过窗口立即发送，否则合并到窗口结束时发一次；
   * `immediate` 用于进入阅读器时的首次上报。
   */
  private scheduleProgressReport(index: number, immediate: boolean): void {
    const target = this.clampIndex(index, this.pages.length);
    this.pendingReportIndex = target;
    if (!immediate && target === this.lastReportedIndex) {
      return;
    }
    const elapsed = Date.now() - this.lastReportAt;
    if (immediate || elapsed >= PROGRESS_REPORT_THROTTLE_MS) {
      void this.flushProgress();
      return;
    }
    if (this.reportTimer >= 0) {
      return;
    }
    const wait = PROGRESS_REPORT_THROTTLE_MS - elapsed;
    this.reportTimer = setTimeout(() => {
      this.reportTimer = -1;
      void this.flushProgress();
    }, wait);
  }

  private clearReportTimer(): void {
    if (this.reportTimer >= 0) {
      clearTimeout(this.reportTimer);
      this.reportTimer = -1;
    }
  }

  private async flushProgress(): Promise<void> {
    const index = this.pendingReportIndex;
    if (index < 0 || index >= this.pages.length) {
      return;
    }
    const page: ComicPageInfo = this.pages[index];
    this.pendingReportIndex = -1;
    this.lastReportedIndex = index;
    this.lastReportAt = Date.now();
    try {
      const rsp: ComicProgressResponse = await ComicApi.saveProgress(this.bookId, page, index,
        this.pages.length);
      if (!ComicApi.isOk(rsp)) {
        // 失败后保留待上报页，下次翻页（或离开页面时）重试
        this.lastReportedIndex = -1;
        this.pendingReportIndex = index;
        this.notifyProgressFailure(ComicApi.errorMessage(rsp) || '阅读进度暂未保存');
        return;
      }
      this.progressHintShown = false;
    } catch (error) {
      this.lastReportedIndex = -1;
      this.pendingReportIndex = index;
      this.notifyProgressFailure('阅读进度暂未保存，将在后续翻页时重试');
      hilog.warn(0x0000, TAG, 'saveProgress failed: %{public}s', `${error}`);
    }
  }

  /** 进度保存失败只提示一次，避免连续翻页时反复弹 Toast。 */
  private notifyProgressFailure(message: string): void {
    if (this.progressHintShown) {
      return;
    }
    this.progressHintShown = true;
    this.toast(message);
  }

  private async enterImmersiveMode(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await WindowAbility.getInstance().setWindowLayoutFullScreen(true);
      WindowAbility.getInstance().toggleWindowSystemBar([], context);
    } catch (error) {
      hilog.warn(0x0000, TAG, 'enterImmersiveMode failed: %{public}s', `${error}`);
    }
  }

  private exitImmersiveMode(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      WindowAbility.getInstance().toggleWindowSystemBar(['status', 'navigation'], context);
      void WindowAbility.getInstance().setWindowLayoutFullScreen(false);
    } catch (error) {
      hilog.warn(0x0000, TAG, 'exitImmersiveMode failed: %{public}s', `${error}`);
    }
  }

  /**
   * 退出阅读器：先恢复系统栏/窗口并**等生效后再**返回。
   *
   * 顺序不能颠倒：先 `router.back()` 的话，返回的页面会在「系统栏未恢复 + 窗口仍全屏」时先布局
   * 一次，等系统栏回来后整页再下移一个状态栏高度，看起来就是退出时页面猛跳。
   */
  private async exitImmersiveModeThenBack(): Promise<void> {
    if (this.immersiveExited) {
      return;
    }
    this.immersiveExited = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await WindowAbility.getInstance().exitImmersiveMode(context);
    } catch (error) {
      hilog.warn(0x0000, TAG, 'exitImmersiveMode failed: %{public}s', `${error}`);
    }
    this.getUIContext().getRouter().back();
  }

  private close(): void {
    void this.exitImmersiveModeThenBack();
  }

  /** 重新取图：变更 LazyForEach 键强制重建页面项，失败的页会重新走一次图片通道。 */
  private reloadImages(): void {
    this.reloadToken = this.reloadToken + 1;
    this.pendingJumpIndex = this.currentIndex;
    setTimeout(() => {
      this.applyPendingJump();
    }, 0);
    this.toast('正在重新加载页面');
  }

  /** 按服务端给出的原始宽高比换算显示高度，避免页图被裁切。 */
  private pageHeight(page: ComicPageInfo): number {
    if (page.width <= 0 || page.height <= 0) {
      return Math.round(this.contentWidth * PAGE_FALLBACK_RATIO);
    }
    return Math.round(this.contentWidth * page.height / page.width);
  }

  /**
   * 阅读区宽度实测值变化（首帧/旋转/窗口缩放）：页图高度按宽度换算，
   * 宽度变化后需要重建列表项，并回到当前页。
   */
  private applyListWidth(width: number): void {
    if (width <= 0 || width === this.contentWidth) {
      return;
    }
    this.contentWidth = width;
    if (!this.reading) {
      return;
    }
    this.pendingJumpIndex = this.currentIndex;
    this.pageSource.update(this.pages);
    setTimeout(() => {
      this.applyPendingJump();
    }, 0);
  }

  private pageIndicator(): string {
    if (this.pages.length === 0) {
      return '';
    }
    return `${this.currentIndex + 1} / ${this.pages.length}`;
  }

  build() {
    if (this.reading) {
      this.readerView();
    } else {
      PageScaffold({
        title: '漫画阅读',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
  }

  @Builder
  pageContent() {
    if (this.unsupported) {
      EmptyState({ message: `${ServerRegistry.profile().displayName} 服务端不支持漫画阅读` });
    } else if (this.loading) {
      LoadingState({ hint: '正在加载漫画…' });
    } else if (this.loadError.length > 0) {
      EmptyState({
        message: this.loadError,
        actionLabel: '重试',
        onAction: () => {
          void this.load();
        },
      });
    } else {
      EmptyState({ message: '该漫画没有可阅读的页面' });
    }
  }

  @Builder
  readerView() {
    Stack({ alignContent: Alignment.TopStart }) {
      List({ scroller: this.listScroller }) {
        LazyForEach(this.pageSource, (page: ComicPageInfo) => {
          ListItem() {
            this.pageItem(page);
          }
        }, (page: ComicPageInfo) => `${page.id}-${this.reloadToken}`);
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .cachedCount(1)
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        this.applyListWidth(newArea.width as number);
      })
      .onScrollIndex((first: number, _last: number) => {
        this.onVisibleRangeChanged(first);
      })
      .onAppear(() => {
        this.applyPendingJump();
      })
      .onClick(() => {
        this.showBar = !this.showBar;
      });

      if (this.showBar) {
        // 与电子书阅读器共用同一套顶栏（漫画固定深色主题，页码放章节行）
        ReaderChrome({
          bookTitle: this.bookTitle.length > 0 ? this.bookTitle : '漫画',
          chapterTitle: this.pageIndicator(),
          theme: ReaderTheme.DARK,
          expanded: true,
          showBookmarkActions: false,
          onBack: () => this.close(),
          onRefresh: () => this.reloadImages(),
        });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(READER_BACKGROUND);
  }

  @Builder
  pageItem(page: ComicPageInfo) {
    if (this.contentWidth > 0) {
      ComicPageImage({
        url: page.url,
        imageWidth: this.contentWidth,
        imageHeight: this.pageHeight(page),
        label: `第 ${page.index + 1} 页`,
      })
    } else {
      Column() {
        Row()
          .width('100%')
          .height(PAGE_FALLBACK_HEIGHT_VP)
          .backgroundColor(READER_BACKGROUND);
      }
      .width('100%');
    }
  }
}

/**
 * 单页书图：用 `AuthImage` 走鉴权图片通道取图；延迟探测其落盘缓存，
 * 未落盘时在图片下方给出「加载失败」提示（只读探测，不自行下载二进制）。
 */
@Component
struct ComicPageImage {
  @Prop url: string = '';
  @Prop imageWidth: number = 0;
  @Prop imageHeight: number = 0;
  @Prop label: string = '';
  @State private failed: boolean = false;
  private timer: number = -1;

  aboutToAppear(): void {
    this.scheduleProbe(IMAGE_PROBE_DELAY_MS);
  }

  aboutToDisappear(): void {
    this.cancelProbe();
  }

  private cancelProbe(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private scheduleProbe(delay: number): void {
    this.cancelProbe();
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.failed = !this.cached();
      if (this.failed) {
        this.scheduleProbe(IMAGE_PROBE_RETRY_MS);
      }
    }, delay);
  }

  /** 探测 AuthImage 的缓存落盘位置（与 AuthImage 内部保持一致）。 */
  private cached(): boolean {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      CoverCache.ensureDir(context);
      const destPath = CoverCache.pathFor(context, TalebookService.resolveCoverUrl(this.url));
      return fs.accessSync(destPath);
    } catch (_error) {
      return false;
    }
  }

  build() {
    Column({ space: 2 }) {
      AuthImage({
        url: this.url,
        imageWidth: this.imageWidth,
        imageHeight: this.imageHeight,
      })
      Text(this.failed ? `${this.label} 加载失败，可点右上角刷新` : this.label)
        .fontSize(12)
        .fontColor(ReaderThemeColors.textHint(ReaderTheme.DARK))
        .padding({ top: 2, bottom: PAGE_GAP_VP });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center);
  }
}
