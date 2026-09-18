import { PathShape } from '@ohos.arkui.shape';
import { batteryInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ReaderAnnotation,
  BookEngine,
  READER_FLIP_COVER,
  READER_FLIP_DEFAULT,
  READER_FLIP_FADE,
  READER_FLIP_NONE,
  READER_FLIP_OPTIONS,
  READER_FLIP_SIM,
  READER_PANEL_APPEARANCE,
  READER_PANEL_SETTINGS,
  READER_PANEL_TOC,
  READER_PARAGRAPH_PREFIX,
  ReaderBlock,
  READER_DEFAULT_FONT_FAMILY,
  ReaderBlockKind,
  ReaderCallbacks,
  ReaderCatalogItem,
  ReaderFlip,
  ReaderFontResolve,
  ReaderLocation,
  ReaderOpenOptions,
  ReaderSettings,
  ReaderTheme,
} from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { BookEngineFactory } from '../engine/BookEngineFactory';
import { PageLayout, PageMetrics, PagePager, ReaderPage } from '../engine/PageLayout';
import { LazyDataSource } from './LazyDataSource';
import { ReaderBattery } from './ReaderBattery';
import { ReaderChrome } from './ReaderChrome';
import { ReaderClock } from './ReaderClock';
import { ReaderFlipAnimator } from './ReaderFlipAnimator';
import { ReaderFrameWatch } from './ReaderFrameWatch';
import { CurlFold, FoldBandSegment, curlFoldGeometry, foldBandSegments, foldCurveGeometry,
  foldFrontPath } from './SimCurl';
import { ReaderControlPanel } from './ReaderControlPanel';
import { ReaderOverlayBar } from './ReaderOverlayBar';
import { PAGE_FOOTER_SPACE, PAGE_HEADER_SPACE, ReaderPageView } from './ReaderPageView';


const TAG: string = 'ReaderView';
const CONTENT_HORIZONTAL_SPACE: number = 22;
/** 正文上下留白：工具栏为浮层，留白保证文字不被浮层遮住。 */
const CONTENT_TOP_SPACE: number = 28;
const CONTENT_BOTTOM_SPACE: number = 18;
const PARAGRAPH_SPACING: number = 12;
/** 进度上报粒度：变化超过 0.5% 才回调宿主，避免滚动/翻页中频繁落盘。 */
const PROGRESS_REPORT_STEP: number = 0.005;
/** 切章/恢复位置后等待一帧（≈1 帧 16ms）再滚动，确保 LazyForEach 已应用重载。 */
const SCROLL_AFTER_RELOAD_MS: number = 32;
/** 翻页动画时长（ms）与翻页判定阈值（占内容区宽度的比例）。 */
const PAGE_ANIM_MS: number = 220;
/**
 * 翻页动画期望帧率：高刷屏（90/120Hz）让折痕按面板能力走，60Hz 设备由系统钳制到 60。
 * 只声明「翻页动画」这一段的期望，滚动/其他交互不受影响（省电）。
 */
const PAGE_TURN_FPS_MIN: number = 60;
const PAGE_TURN_FPS_MAX: number = 120;
const PAGE_TURN_FPS_EXPECTED: number = 120;
const PAGE_TURN_RATIO: number = 0.25;
/** 三区点击：左右各 1/3 翻页，中间切换工具栏。 */
const TAP_ZONE_RATIO: number = 0.33;
/** 甩动翻页的速度阈值（vp/s）：拖动距离不够但甩得快也翻页，不必拖满 1/4 屏。 */
const FLING_VELOCITY_VP: number = 400;
/**
 * 刚拖动过这段时间（ms）内的点击事件忽略掉。
 * ArkUI 的并行手势里点击与拖动可能同时送达，放任两者各翻一次就是「一次手势翻两页」。
 */
const CLICK_AFTER_PAN_MS: number = 400;
/**
 * 仿真翻页的三段视觉元素宽度（vp），按「纸卷横截面」从当前页一侧排到新页一侧：
 * 卷边柱面（当前页上）→ 折痕 → 纸背（新页上、纸卷绕过柱面后朝向读者的那一面）→ 折痕投影（新页上）。
 */
const SIM_FOLD_SHADOW_VP: number = 30;
const SIM_ROLL_VP: number = 20;
/**
 * 纸卷（圆柱）的投影半径（vp）：折痕到纸面离开柱面处的距离。
 * 纸背带宽度取 `2 × 半径`——纸面绕过柱面后，朝读者的那一半在屏幕上正好铺开一个直径。
 */
const SIM_CYLINDER_R_VP: number = 14;
/** 拖动到这个距离（vp）时纸卷长到满尺寸；更近的距离按比例缩小（取 `SIM_CURL_MIN_RATIO` 保底）。 */
const SIM_CURL_FULL_VP: number = 50;
const SIM_CURL_MIN_RATIO: number = 0.35;
const SIM_ROLL_GLINT_VP: number = 1.5;
/** 柱面高光（crest）在卷边带内的相对位置：0 = 靠当前页一侧，1 = 折痕处。 */
const SIM_ROLL_CREST_RATIO: number = 0.45;

/**
 * 折痕渐变带的 `ForEach` 键。
 *
 * **必须把位置量化后编进键里**：ArkUI 的 `ForEach` 对「键没变的项」不会更新组件属性，
 * 键里只有 `kind` 和序号时，各条带子会在第一帧定住——折痕在扫、明暗带却停在原地
 * （实测：动画期间几何逐帧重算了 40 次，画面上的带子一动不动）。
 * 位置按 8vp 量化：带子挪过一格才重建组件，一次整页翻动只重建几十次，
 * 不会退化成「每帧销毁重建 12 个渐变图层」。
 */
function bandKey(seg: FoldBandSegment, index: number): string {
  const gx: number = Math.round(seg.x / 8);
  const gy: number = Math.round(seg.y / 8);
  return `${seg.kind}_${index}_${gx}_${gy}`;
}

/**
 * 纸卷的展开程度 0.35~1：按拖动距离线性长起来，`SIM_CURL_FULL_VP` 处封顶。
 * 见 `foldBands` 里对横截面三个宽度的缩放。
 */
function curlProgress(drag: number): number {
  const t: number = Math.abs(drag) / SIM_CURL_FULL_VP;
  return Math.min(1, Math.max(SIM_CURL_MIN_RATIO, t));
}

/** 翻页动画期望的帧率范围：高刷屏（90/120Hz）按面板能力走，60Hz 设备由系统钳制。 */
function pageTurnFrameRate(): ExpectedFrameRateRange {
  return { min: PAGE_TURN_FPS_MIN, max: PAGE_TURN_FPS_MAX, expected: PAGE_TURN_FPS_EXPECTED };
}

/**
 * 仿真翻页的折痕横坐标（vp）：向右翻（dir = 1）时折痕随手指左移，向左回（dir = -1）时右移。
 *
 * 这些几何关系写成模块级纯函数（而不是组件方法）是刻意的：`@Builder` 只登记
 * 「构建函数体里直接出现过的状态变量」，一旦把 dragOffset/dragDir 的读取藏进方法，
 * 视图层就不会随拖拽刷新。
 */
function simFoldX(width: number, offset: number, dir: number): number {
  const distance = Math.min(width, Math.max(0, Math.abs(offset)));
  return dir === -1 ? distance : width - distance;
}

/** 折痕露出的下层新页宽度（vp）。 */
function simRevealedWidth(width: number, offset: number, dir: number): number {
  const foldX = simFoldX(width, offset, dir);
  return dir === -1 ? foldX : Math.max(0, width - foldX);
}

/** 投影宽度：贴住折痕、不超过被露出的新页宽度。 */
function simShadowWidth(width: number, offset: number, dir: number): number {
  return Math.min(SIM_FOLD_SHADOW_VP, simRevealedWidth(width, offset, dir));
}

/** 投影起始横坐标：投影永远落在折痕靠新页的一侧。 */
function simShadowX(width: number, offset: number, dir: number): number {
  const foldX = simFoldX(width, offset, dir);
  return dir === -1 ? Math.max(0, foldX - simShadowWidth(width, offset, dir)) : foldX;
}

/** 卷边柱面宽度：贴住折痕、不超过当前页还没卷走的宽度。 */
function simRollWidth(width: number, offset: number, dir: number): number {
  return Math.min(SIM_ROLL_VP, width - simRevealedWidth(width, offset, dir));
}

/** 卷边柱面起始横坐标：永远落在当前页一侧。 */
function simRollX(width: number, offset: number, dir: number): number {
  const foldX = simFoldX(width, offset, dir);
  return dir === -1 ? foldX : Math.max(0, foldX - simRollWidth(width, offset, dir));
}

/** 柱面高光细线宽度：卷边带太窄时按比例缩，避免高光超出纸卷。 */
function simGlintWidth(width: number, offset: number, dir: number): number {
  return Math.min(SIM_ROLL_GLINT_VP, simRollWidth(width, offset, dir));
}

/** 柱面高光细线横坐标：位于卷边带内靠折痕一侧的受光面（crest）上。 */
function simGlintX(width: number, offset: number, dir: number): number {
  const rollX = simRollX(width, offset, dir);
  const rollW = simRollWidth(width, offset, dir);
  const crest = dir === -1
    ? rollX + rollW * (1 - SIM_ROLL_CREST_RATIO) - simGlintWidth(width, offset, dir)
    : rollX + rollW * SIM_ROLL_CREST_RATIO;
  return Math.max(rollX, Math.min(rollX + rollW, crest));
}

/**
 * 页面层不透明度（只有淡入淡出模式会 < 1）。
 *
 * 与 `simFoldX` 同样是模块级纯函数：`dragOffset`/`dragDir`/`flipMode` 必须在构建函数体里
 * 直接读出来，藏进组件方法时 ArkUI 不会把它们登记成这一块的依赖，拖动时整块不再重建
 * ——表现就是「跟手失效」（页不跟手指走，只有抬手后的翻页动画生效）。
 */
function layerOpacity(mode: string, width: number, offset: number, dir: number, drag: number): number {
  if (mode !== READER_FLIP_FADE || offset === 0) {
    return 1;
  }
  const incoming = dir === 1 ? 1 : (dir === -1 ? -1 : 0);
  if (incoming === 0 || offset !== incoming) {
    return 0;
  }
  return width <= 0 ? 0 : Math.min(1, Math.abs(drag) / width);
}

/** 折痕投影的渐变：深色主题下纸面本身很暗，投影要加重才看得出来。 */
function simShadowColors(theme: ReaderTheme, dir: number): Array<[ResourceColor, number]> {
  const strong: string = theme === ReaderTheme.DARK ? '#80000000' : '#48000000';
  const clear: string = '#00000000';
  return dir === -1 ? [[clear, 0], [strong, 1]] : [[strong, 0], [clear, 1]];
}

/**
 * 卷边柱面渐变（圆筒质感）：贴合处压暗（接触阴影）→ 渐亮 → 受光高光 → 转暗 → 折痕处再压暗。
 * 五段比「暗-亮-暗」三段更像卷起来的纸筒：两头暗得自然、中间那道是柱面的高光面。
 */
function simRollColors(theme: ReaderTheme, dir: number): Array<[ResourceColor, number]> {
  const dark: string = theme === ReaderTheme.DARK ? '#66000000' : '#38000000';
  const mid: string = theme === ReaderTheme.DARK ? '#33000000' : '#1A000000';
  const light: string = theme === ReaderTheme.DARK ? '#26FFFFFF' : '#40FFFFFF';
  const clear: string = '#00000000';
  if (dir === -1) {
    // 从折痕（左）到当前页（右）：先压暗，再亮起，最后融进纸面
    return [[dark, 0], [light, 0.35], [mid, 0.65], [clear, 1]];
  }
  // 从当前页（左）到折痕（右）：从纸面渐出、高光、再收进折痕的暗边
  return [[clear, 0], [mid, 0.3], [light, 0.6], [dark, 1]];
}

/** 柱面高光细线：柱面最亮的那一条，缺了它就只剩一块渐变色块。 */
function simGlintColor(theme: ReaderTheme): string {
  return theme === ReaderTheme.DARK ? '#33FFFFFF' : '#59FFFFFF';
}
/** 测量入参单位自校准用的探针宽度（vp）。 */
const PROBE_WIDTH_VP: number = 80;
/** 分页结果最多缓存几章。 */
const MAX_PAGE_CACHE: number = 2;
/** 分片分页：首屏同步推进的步数、以及每帧推进的步数（步 ≈ 一个块/一次切分，含 1–4 次测量）。 */
const INITIAL_PAGINATION_STEPS: number = 24;
const PAGINATION_STEPS_PER_FRAME: number = 24;
/** 每个分页切片的毫秒预算：保证单帧不被分页拖长（分页只能用 UI 线程，measureTextSize 依赖 UIContext）。 */
const PAGINATION_SLICE_MS: number = 8;
/** 翻页时为「确认目标页是否存在」允许的分页补算时间上限（ms）：超时就让这次翻页先不生效，避免卡住 UI。 */
const PAGE_TURN_PAGINATION_MS: number = 8;
/** 工具栏显示后自动隐藏的延时（ms）。 */
const BARS_AUTO_HIDE_MS: number = 4000;
/** 页脚电量的刷新间隔（ms）：系统不提供电量变化订阅，这里按分钟级轮询。 */
const BATTERY_REFRESH_MS: number = 60000;
const DEFAULT_SETTINGS: ReaderSettings = {
  fontSize: 18,
  lineHeight: 1.6,
  theme: ReaderTheme.LIGHT,
  flipMode: READER_FLIP_DEFAULT,
  keepScreenOn: false,
  oneHandMode: false,
  selectMode: false,
  fontId: 'system',
};
const DEFAULT_OPTIONS: ReaderOpenOptions = {
  filePath: '',
  format: '',
  title: '',
  cacheDir: '',
  location: '',
  settings: DEFAULT_SETTINGS,
  fontOptions: [],
  annotations: [],
};

interface ParsedLocation {
  chapterIndex: number;
  paragraphIndex: number;
}

/**
 * 页面层参数。`@Builder` 只有**按引用传参**（单一对象）时才会随状态变化刷新内部 UI，
 * 因此页码与层偏移必须打包成对象传入，不能用两个 number 参数。
 */
interface ReaderLayerSpec {
  index: number;
  offset: number;
  /** 该层不透明度（仅淡入淡出模式 < 1；其余模式恒为 1）。 */
  opacity: number;
}

/**
 * 仿真翻页的页面层参数（同 `ReaderLayerSpec`，必须按单一对象传参才会随拖拽刷新）：
 * `clipX/clipW` 是这一层在内容区里的可见区域（vp），页面本体始终按整页宽度渲染，不重排。
 */
interface SimLayerSpec {
  index: number;
  clipX: number;
  clipW: number;
  order: number;
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
    onFontSelected: async (fontId: string): Promise<ReaderFontResolve> => {
      return { fontName: 'system', fontPath: '' };
    },
    onAnnotationsChanged: (annotations: ReaderAnnotation[]): void => {},
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
  /** 正文字体：fontId 持久化，fontFamily 是注册后的家族名（空 = 系统默认）。 */
  @State private fontId: string = DEFAULT_SETTINGS.fontId;
  @State private fontFamily: string = '';
  @State private fontDownloading: boolean = false;
  @State private flipMode: string = DEFAULT_SETTINGS.flipMode;
  @State private keepScreenOn: boolean = DEFAULT_SETTINGS.keepScreenOn;
  /** 单手模式：点击左右两侧均为下一页，只有滑动才能回上一页。 */
  @State private oneHandMode: boolean = DEFAULT_SETTINGS.oneHandMode;
  /**
   * 选词复制：正文可长按选中/复制；开启期间滑动不翻页。
   * 见 `READER_SELECT_MODE_PREF_KEY` 的说明——可选中正文与拖动翻页在当前 ArkUI 结构下无法共存。
   */
  @State @Watch('onSelectModeChanged') private selectMode: boolean = DEFAULT_SETTINGS.selectMode;
  /**
   * 特效降级：帧采样判定掉帧后置位。先去掉折痕的两条全屏渐变（省合成开销），
   * 仍掉帧则把仿真翻页降级成覆盖翻页，保证低端设备上「跟手」优先。
   */
  @State private reduceEffects: boolean = false;
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
  /** 拖拽的原始位移（vp）：无动画模式不做位移动画，但离阈值判定仍需真实拖距。 */
  private dragRaw: number = 0;
  /** 仿真翻页用的手指按下点（vp，内容区坐标）与纵向位移：折痕要过手指并按拖动方向倾斜。 */
  @State private touchX: number = 0;
  @State private touchY: number = 0;
  @State private dragOffsetY: number = 0;
  /** 手势轴向锁：纵向为主的拖动不算翻页（分页模式下纵向滑动不做事），避免误卷。 */
  private dragVertical: boolean = false;
  /** 每次拖拽只在第一帧记一次折痕几何，便于现场核对倾角。 */
  private foldLogged: boolean = false;
  /** 最近一次拖拽时刻：拖动过的这一串事件不再当成点击（否则斜向拖动会翻两页）。 */
  private lastPanAt: number = 0;
  /**
   * 翻页动画进行中：多指手势会并行触发两条 PanGesture（同一套回调），
   * 用这个标记保证一次手势只结算一次，避免两指拖动被算成翻两页。
   */
  private turning: boolean = false;

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
  /** 翻页帧耗时采样（按设备性能自动降级特效）。 */
  private frameWatch: ReaderFrameWatch = new ReaderFrameWatch();
  /** 翻页/回弹动画：按帧推进折痕位移（`animateTo` 不会带动现算的几何）。 */
  private flipAnim: ReaderFlipAnimator = new ReaderFlipAnimator();
  /** 页脚电量（-1 表示读取失败，不显示）。 */
  @State private batteryLevel: number = -1;
  @State private batteryCharging: boolean = false;
  private batteryTimer: number = -1;
  /** 已注册进 ArkUI 的字体家族名，避免重复注册。 */
  private registeredFonts: Set<string> = new Set<string>();
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
  /** 划线批注（阅读器只持有当前书的内存副本，落盘交给宿主）。 */
  @State private annotations: ReaderAnnotation[] = [];
  /** 划线数量上限：防止宿主那份偏好值无限增长（超出后丢弃最早的）。 */
  private static readonly MAX_ANNOTATIONS: number = 500;
  private pageCache: Map<string, ReaderPage[]> = new Map<string, ReaderPage[]>();

  aboutToAppear(): void {
    this.refreshBattery();
    this.batteryTimer = setInterval(() => {
      this.refreshBattery();
    }, BATTERY_REFRESH_MS);
    const settings = this.options.settings;
    this.fontSize = settings.fontSize;
    this.lineHeight = settings.lineHeight;
    this.theme = settings.theme;
    this.flipMode = ReaderFlip.normalize(settings.flipMode);
    this.keepScreenOn = settings.keepScreenOn;
    this.oneHandMode = settings.oneHandMode === true;
    this.selectMode = settings.selectMode === true;
    this.annotations = this.options.annotations.length > 0 ? this.options.annotations.slice() : [];
    this.fontId = settings.fontId.length > 0 ? settings.fontId : DEFAULT_SETTINGS.fontId;
    // 打开时把已选字体注册进 ArkUI（宿主侧 ensureCached 命中缓存时立即返回）
    void this.applyFont(this.fontId, false);
    const start = ReaderView.parseLocation(this.options.location);
    this.initialIndex = start.paragraphIndex;
    this.lastParagraph = start.paragraphIndex;
    void this.openBook(start);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.pendingScrollIndex = -1;
    this.frameWatch.stop();
    this.flipAnim.cancel();
    this.cancelBarsAutoHide();
    if (this.batteryTimer >= 0) {
      clearInterval(this.batteryTimer);
      this.batteryTimer = -1;
    }
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
          selectedFontId: this.fontId,
          fontOptions: this.options.fontOptions,
          fontDownloading: this.fontDownloading,
          onSelectFont: (fontId: string) => {
            void this.applyFont(fontId, true);
          },
          flipLabels: ReaderFlip.labels(),
          flipValues: READER_FLIP_OPTIONS,
          flipValue: $flipMode,
          keepScreenOn: $keepScreenOn,
          oneHandMode: this.oneHandMode,
          selectMode: $selectMode,
          showOneHandMode: true,
          onOneHandModeChange: (enabled: boolean) => this.setOneHandMode(enabled),
          // 内置阅读器只有「界面」一个入口：把常亮也放进界面页
          behaviorInAppearance: true,
          ttsSpeed: $ttsSpeed,
          showBookmarks: false,
          showAloud: false,
          onSelectCatalogIndex: (index: number) => this.goToChapter(index),
          onSettingsChanged: (relayout: boolean) => this.onPanelSettingsChanged(relayout),
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
  private onPanelSettingsChanged(relayout: boolean): void {
    this.applySettings(this.currentSettings(), relayout);
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
      if (this.flipMode === READER_FLIP_SIM) {
        this.simLayers();
      } else {
        // 相邻页只在真的处于翻页过程中才渲染：静止时少一整页正文的组件与排版对象
        // （翻页第一帧才建下一页，跟手延迟实测仍在 20ms 内）。
        if (this.dragDir === -1) {
          this.pageLayer({
            index: this.pageIndex - 1,
            offset: -1,
            // 参数里直接读 dragOffset/dragDir：这一块才会随拖拽逐帧重建（跟手）
            opacity: layerOpacity(this.flipMode, this.contentWidthVp, -1, this.dragDir, this.dragOffset),
          });
        }
        if (this.dragDir === 1) {
          this.pageLayer({
            index: this.pageIndex + 1,
            offset: 1,
            opacity: layerOpacity(this.flipMode, this.contentWidthVp, 1, this.dragDir, this.dragOffset),
          });
        }
        this.pageLayer({ index: this.pageIndex, offset: 0, opacity: 1 });
      }
    }
    .width('100%')
    .height('100%')
    // 手势：一条 PanGesture 同时覆盖单指与多指（ArkUI 的 `fingers` 是「最少手指数」，
    // 默认 1 指 ⇒ 两指拖动走的是同一条手势）。**不要**再额外注册一条 `fingers: 2` 的手势：
    // 实测那样一条单指拖动会被两条手势同时识别，回调交错、一次滑动翻两页。
    // 方向放开成 All 是为了拿到纵向位移给折痕定倾角，纵向为主的手势在 updatePageDrag 里被挡掉
    // （分页模式下纵向滑动本来就不做事）。
    //
    // 关于「翻页手势与缩放/选词/批注手势共存」的实测结论（2026-09-17，模拟器 127.0.0.1:5555）：
    // 正文 `Text` 一旦设为可选中（`.copyOption(CopyOptions.InApp)`），它会把点按与拖动全部收进
    // 自己的内部识别，父组件这边实测：
    //   - `.onClick` 收不到            ⇒ 点按翻页失效
    //   - `.gesture(PanGesture)` 收不到 ⇒ 滑动翻页失效
    //   - `parallelGesture(TapGesture)` 能收到 ⇒ 点按翻页可恢复
    //   - 但 `parallelGesture(PanGesture)` 仍收不到；把 Pan 与 Tap 一起塞进
    //     `parallelGesture(GestureGroup(GestureMode.Parallel, …))`、或连续写两次
    //     `parallelGesture`，两条会一起失效（页面完全无响应）
    // 即：**「可选中正文」与「父组件拖动翻页」在当前组件结构下无法同时生效**，
    // 没有「放进同一个 GestureGroup 就万事大吉」这种写法。将来要加选词/批注，只能二选一：
    //   ① 用模式开关切换：选词态把这条 PanGesture 让开、同时把正文设为可选中，退出即恢复；
    //   ② 把翻页从 PanGesture 改成 `onTouch` 原始触摸事件驱动，不再依赖父组件的手势识别。
    // 在此之前不要再往这里加手势：`fingers: 2` 的 Pan 会与这条互相抢识别（一次滑动翻两页）。
    .gesture(
      PanGesture({ direction: PanDirection.All, distance: 6 })
        .onActionStart((event: GestureEvent) => this.beginPageDrag(event))
        .onActionUpdate((event: GestureEvent) => this.updatePageDrag(event.offsetX, event.offsetY))
        .onActionEnd((event: GestureEvent) => this.endPageDrag(event.velocityX))
        .onActionCancel(() => this.cancelPageDrag()),
    )
    .onClick((event: ClickEvent) => this.onPagerClick(event));
  }

  // ---- 仿真翻页 ----
  //
  // 折痕几何见 `SimCurl.ets`：折痕**过当前手指位置**、方向**垂直于拖动方向**，手指按下点决定
  // 哪一侧是被抓住、要卷起来的纸。水平拖动 ⇒ 竖直折痕（跟手 1:1）；斜向拖动 ⇒ 折痕倾斜，
  // 于是「从不同区域、不同方向起手，卷页效果不一样」。
  // 当前页按折痕做路径裁剪，折痕处叠三条渐变带（投影 / 卷边柱面 / 柱面高光），
  // 抬手后的动画把折痕扫到页面另一端，视觉上就是整页翻过去。

  @Builder
  simLayers() {
    // 下层：翻页后要显示的那一页（整页铺满，未卷走的地方就从这里露出来）
    this.simTargetLayer();
    this.simFoldShading();
    // 上层：当前页按折痕裁切（折痕过手指、垂直于拖动方向）
    this.simFrontLayer();
  }

  /** 仿真翻页的下层：翻页后要显示的那一页（未拖动时铺下一页，方向确定后按方向切）。 */
  @Builder
  simTargetLayer() {
    // 静止时不铺目标页：省一整页正文的组件/排版对象，拖动第一帧才建
    if (this.dragDir !== 0 &&
      (this.dragDir === -1 ? (this.pageIndex > 0) : (this.pageIndex + 1 < this.pageCount))) {
      Stack() {
        this.pageView({
          index: this.dragDir === -1 ? this.pageIndex - 1 : this.pageIndex + 1,
          offset: 0,
          opacity: 1,
        });
      }
      .width('100%')
      .height('100%')
      .zIndex(1);
    }
  }

  /**
   * 仿真翻页的当前页层：整页渲染 + `clipShape` 按折痕裁掉被卷走的一侧。
   * 用路径裁剪而不是「窄容器 + 固定宽内层」，折痕才能是任意角度的直线（斜向拖动时纸边也是斜的）。
   * 几何在这里现算：`@Builder` 只登记构建函数体里直接出现过的状态变量，藏进方法就不跟手。
   */
  @Builder
  simFrontLayer() {
    if (this.pageIndex >= 0 && this.pageIndex < this.pageCount) {
      // 只有折痕真的存在时才做裁剪：`clipShape` 会给这一层加一个裁剪图层
      // （离屏缓冲）。静止时每翻一页都建一次裁剪层，实测把进程内存顶到 1GB 并被系统杀掉；
      // 不裁剪时静止态就是一整页普通正文，翻页内存曲线与「覆盖翻页」一致。
      if (Math.abs(this.dragOffset) > 0 && !this.reduceEffects) {
        Stack() {
          this.pageView({ index: this.pageIndex, offset: 0, opacity: 1 });
        }
        .width('100%')
        .height('100%')
        .clipShape(this.foldClipShape(foldFrontPath(this.contentWidthVp, this.contentHeightVp,
          this.touchX, this.touchY, this.dragOffset, this.dragOffsetY, this.vpToPx(1))))
        .zIndex(3);
      } else {
        Stack() {
          this.pageView({ index: this.pageIndex, offset: 0, opacity: 1 });
        }
        .width('100%')
        .height('100%')
        .zIndex(3);
      }
    }
  }

  /**
   * 折痕裁剪路径的形状对象。
   *
   * 每次都新建：`PathShape` 不是可观察对象，改动同一个实例的 `commands` 不会让 ArkUI
   * 重新应用裁剪（同一引用会被当成「没变化」而跳过），裁剪会停在第一次那条路径上。
   * 路径字符串每帧都不同，新建的开销远小于「裁剪不更新」这件事本身。
   */
  private foldClipShape(commands: string): PathShape {
    return new PathShape({ commands: commands });
  }

  /**
   * 折痕阴影：沿折痕曲线铺「卷边柱面 + 纸背 + 投影」三条带，按纸卷横截面从当前页排到新页。
   *
   * 折痕是曲线（纸张卷曲），直条渐变对不上，所以把每条带拆成若干短直段拼出来
   * （`foldBandSegments`）；每段只有一小块，比原来横跨整页的直条更省。
   */
  @Builder
  simFoldShading() {
    ForEach(this.foldBands(this.dragOffset, this.dragOffsetY, this.touchX, this.touchY,
      this.contentWidthVp, this.contentHeightVp, this.theme, this.reduceEffects),
      (seg: FoldBandSegment) => {
        Column()
          .width(seg.width)
          .height(seg.length)
          .linearGradient({ angle: 90, colors: this.foldBandColors(seg.kind, seg.flip) })
          .position({ x: seg.x, y: seg.y })
          .rotate({ angle: seg.rotationDeg })
          .zIndex(6);
        // 键必须带量化位置，理由见 `bandKey`
      }, (seg: FoldBandSegment, index: number) => bandKey(seg, index));
  }

  /** 供构建函数体直接调用：状态变量都在参数里读出来，@Builder 才会登记依赖。 */
  private foldBands(
    drag: number,
    dragY: number,
    touchX: number,
    touchY: number,
    width: number,
    height: number,
    theme: ReaderTheme,
    reduce: boolean,
  ): FoldBandSegment[] {
    const out: FoldBandSegment[] = [];
    if (reduce || Math.abs(drag) <= 0 || width <= 0 || height <= 0) {
      return out;
    }
    // 段数只影响曲线带的平滑度：4 段在这条 18vp 量级的弧上已经看不出折角，
    // 组件数却只有 12 个（每段都是带渐变的图层，越多越吃渲染内存）。
    const segments: number = 4;
    // 纸卷随拖动长起来：一按下（识别距离 6vp）就摆出整条卷边会很假——真实纸页是
    // 先被掀起一个小角、卷曲半径随掀起的长度增大。这里按拖动距离把横截面的
    // 三个宽度等比缩放（保底 0.35，避免折痕变成一条没有厚度的硬缝）。
    const curl: number = curlProgress(drag);
    const radius: number = SIM_CYLINDER_R_VP * curl;
    const backWidth: number = radius * 2;
    const shadowWidth: number = SIM_FOLD_SHADOW_VP * curl;
    const rollWidth: number = SIM_ROLL_VP * curl;
    // 投影（新页上）：落在纸卷外缘之外，纸卷挡住的那一段不该有投影
    const shadow = foldBandSegments(width, height, touchX, touchY, drag, dragY,
      shadowWidth, true, backWidth + shadowWidth / 2, 0, segments);
    for (let i = 0; i < shadow.length; i++) {
      out.push(shadow[i]);
    }
    // 纸背（新页上）：被卷起的纸绕过柱面后朝向读者的那一面，紧贴折痕铺一个直径宽
    const back = foldBandSegments(width, height, touchX, touchY, drag, dragY,
      backWidth, true, radius, 2, segments);
    for (let i = 0; i < back.length; i++) {
      out.push(back[i]);
    }
    // 卷边柱面（当前页上）：高光已经做在柱面渐变里，不再单独画高光细线
    const roll = foldBandSegments(width, height, touchX, touchY, drag, dragY,
      rollWidth, false, rollWidth / 2, 1, segments);
    for (let i = 0; i < roll.length; i++) {
      out.push(roll[i]);
    }
    return out;
  }

  /**
   * 折痕带的配色（0 投影 / 1 卷边柱面 / 2 纸背）。
   *
   * 数组顺序是「折痕 → 带子外缘」；`flip`（来自 `FoldBandSegment`）表示渐变实际是从外缘流向折痕，
   * 此时把数组反过来，两种拖动方向才会得到同一种明暗。
   */
  private foldBandColors(kind: number, flip: boolean): Array<[ResourceColor, number]> {
    const dark: boolean = this.theme === ReaderTheme.DARK;
    let colors: Array<[ResourceColor, number]>;
    if (kind === 1) {
      // 卷边柱面：折痕处压暗（接触阴影）→ 受光高光 → 融进纸面
      const edge: string = dark ? '#66000000' : '#38000000';
      const light: string = dark ? '#26FFFFFF' : '#40FFFFFF';
      colors = [[edge, 0], [light, 0.45], ['#00000000', 1]];
    } else if (kind === 2) {
      // 纸背：必须是实色，否则下层新页的正文会透出来（纸背挡住了它）
      const paper: string = ReaderPalette.pageBackground(this.theme);
      if (dark) {
        colors = [['#101020', 0], ['#2C2C48', 0.45], [paper, 1]];
      } else if (this.theme === ReaderTheme.EYE) {
        colors = [['#A6CCA9', 0], ['#DCF7E0', 0.45], [paper, 1]];
      } else {
        colors = [['#D5CCBB', 0], ['#FCF9F3', 0.45], [paper, 1]];
      }
    } else {
      colors = dark ? [['#80000000', 0], ['#00000000', 1]] : [['#48000000', 0], ['#00000000', 1]];
    }
    if (!flip) {
      return colors;
    }
    const reversed: Array<[ResourceColor, number]> = [];
    for (let i = colors.length - 1; i >= 0; i--) {
      reversed.push([colors[i][0], 1 - colors[i][1]]);
    }
    return reversed;
  }

  /**
   * 单个页面层。
   *
   * **必须传单一对象**：ArkUI 的 `@Builder` 按值传参时「状态变量变化不会触发 Builder 内部 UI 刷新」，
   * 早期写法 `pageLayer(index, offset)`（两个 number）会导致翻页时底栏页码在变、页面内容却永远停在
   * 首次构建那一页（表现为「翻页失败、始终回到第一页」）。
   */
  @Builder
  pageLayer(layer: ReaderLayerSpec) {
    // opacity 为 0 的层（淡入淡出里没轮到的相邻页）直接不建，省掉一次整页文本构建
    if (layer.index >= 0 && layer.index < this.pageCount && layer.opacity > 0) {
      if (layer.opacity < 1) {
        Stack() {
          this.pageView(layer);
        }
        .width('100%')
        .height('100%')
        .opacity(layer.opacity);
      } else {
        this.pageView(layer);
      }
    }
  }

  /** 单页内容：所有翻页方式共用，参数仍是那个对象（刷新语义见 `pageLayer` 注释）。 */
  @Builder
  pageView(layer: ReaderLayerSpec) {
    ReaderPageView({
      pages: this.pageSource,
      pageIndex: layer.index,
      pageCount: this.pageCount,
      pageToken: this.paginationToken,
      offsetX: this.layerX(layer.offset),
      layerOrder: this.layerZ(layer.offset),
      fontSize: this.fontSize,
      lineHeight: this.lineHeight,
      theme: this.theme,
      horizontalSpace: CONTENT_HORIZONTAL_SPACE,
      topSpace: CONTENT_TOP_SPACE,
      bottomSpace: CONTENT_BOTTOM_SPACE,
      pageWidthVp: this.textWidthVp(),
      pageHeightVp: this.textHeightVp(),
      chapterTitle: this.chapterTitle,
      bookTitle: this.bookTitle,
      batteryLevel: this.batteryLevel,
      batteryCharging: this.batteryCharging,
      fontFamily: this.fontFamily,
      selectable: this.selectMode,
      chapterIndex: this.chapterIndex,
      annotations: this.annotations,
      onMark: (paragraphIndex: number, text: string) => this.addAnnotation(paragraphIndex, text),
      onUnmark: (paragraphIndex: number, text: string) => this.removeAnnotation(paragraphIndex, text),
    });
  }

  @Builder
  scrollContent() {
    Column() {
      // 阅读区顶部：章节名（与分页模式一致）+ 右上角时间（与章节名齐平）
      Row({ space: 8 }) {
        Text(this.chapterTitle)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ReaderPalette.hintColor(this.theme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        ReaderClock({ theme: this.theme });
      }
      .width('100%')
      .height(PAGE_HEADER_SPACE)
      .alignItems(VerticalAlign.Center)
      .padding({ left: CONTENT_HORIZONTAL_SPACE, right: CONTENT_HORIZONTAL_SPACE });
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
                .fontFamily(this.fontFamily.length > 0 ? this.fontFamily : READER_DEFAULT_FONT_FAMILY)
                // 两端对齐：与分页模式一致，避免每行右侧参差
                .textAlign(TextAlign.JUSTIFY)
                .width('100%');
            }
          }
        }, (block: ReaderBlock, index: number) => `${this.chapterIndex}_${index}`);
      }
      .width('100%')
      .layoutWeight(1)
      .padding({
        left: CONTENT_HORIZONTAL_SPACE,
        right: CONTENT_HORIZONTAL_SPACE,
        bottom: CONTENT_BOTTOM_SPACE,
      })
      .cachedCount(4)
      .scrollBar(BarState.Off)
      .onScrollIndex((start: number) => {
        this.onListScroll(start);
      })
      .onClick((event: ClickEvent) => {
        this.onScrollTap(event);
      });

      // 底部分隔线 + 页脚：左侧书名，右侧全书进度
      Column() {
        Divider()
          .color(ReaderPalette.dividerColor(this.theme))
          .strokeWidth(0.5);
        Row({ space: 10 }) {
          Text(this.bookTitle.length > 0 ? this.bookTitle : ' ')
            .fontSize(10)
            .fontColor(ReaderPalette.hintColor(this.theme))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          ReaderBattery({
            theme: this.theme,
            level: this.batteryLevel,
            charging: this.batteryCharging,
          });
          Text(`${Math.round(this.lastReportedPercent * 100)}%`)
            .fontSize(10)
            .fontColor(ReaderPalette.hintColor(this.theme));
        }
        .width('100%')
        .height(PAGE_FOOTER_SPACE)
        .alignItems(VerticalAlign.Center)
        .padding({ left: CONTENT_HORIZONTAL_SPACE, right: CONTENT_HORIZONTAL_SPACE });
      }
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .padding({ top: CONTENT_TOP_SPACE })
    .onClick((event: ClickEvent) => {
      this.onScrollTap(event);
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
      ReaderChrome({
        bookTitle: this.bookTitle,
        chapterTitle: this.chapterTitle,
        chapterProgressText: this.progressText(),
        theme: this.theme,
        expanded: this.showBars,
        // 内置阅读器暂无书签能力：隐藏两个书签入口，避免点了没反应
        showBookmarkActions: false,
        onBack: () => this.callbacks.onClose(),
        onRefresh: () => this.reloadChapter(),
      });
      // Blank 也必须放行：它是子节点，默认会吃掉中间区域的点击/滑动
      Blank()
        .hitTestBehavior(HitTestMode.None);
      ReaderOverlayBar({
        theme: this.theme,
        chapterProgress: this.chapterProgressValue(),
        canGoPrevChapter: this.chapterIndex > 0,
        canGoNextChapter: this.chapterIndex + 1 < this.catalogSize,
        activeNav: this.showPanel ? this.panelTab : '',
        // 搜索/朗读未实现，先隐藏
        showSearch: false,
        showAloud: false,
        showRefresh: true,
        showNight: true,
        onRefresh: () => this.reloadChapter(),
        onToggleNight: () => this.toggleNightTheme(),
        onPrevChapter: () => this.goToChapter(this.chapterIndex - 1),
        onNextChapter: () => this.goToChapter(this.chapterIndex + 1),
        onChapterProgressChange: (value: number) => this.jumpToChapterProgress(value),
        onOpenToc: () => this.openPanel(READER_PANEL_TOC),
        onOpenAppearance: () => this.openPanel(READER_PANEL_APPEARANCE),
        onOpenSettings: () => this.openPanel(READER_PANEL_SETTINGS),
      });
    }
    .width('100%')
    .height('100%')
    // 工具栏之间的空白必须让点击穿透到正文：否则工具栏显示时中间点击/左右翻页都失效
    .hitTestBehavior(HitTestMode.None);
  }

  /** 本章进度 0~1（分页按页数，滚动按段落数）。 */
  private chapterProgressValue(): number {
    if (ReaderFlip.isPaged(this.flipMode)) {
      return this.pageCount <= 1 ? 0 : this.pageIndex / (this.pageCount - 1);
    }
    return this.paragraphCount <= 1 ? 0 : this.lastParagraph / (this.paragraphCount - 1);
  }

  /** 拖动章节进度滑杆：分页按页跳转，滚动按段跳转并滚动到该处。 */
  private jumpToChapterProgress(value: number): void {
    const ratio = Math.min(1, Math.max(0, value));
    if (ReaderFlip.isPaged(this.flipMode)) {
      if (this.pageCount <= 0) {
        return;
      }
      const target = Math.round(ratio * (this.pageCount - 1));
      this.pageIndex = target;
      this.reportProgress(this.firstParagraphOf(target), false);
      return;
    }
    const paragraph = Math.round(ratio * Math.max(0, this.paragraphCount - 1));
    this.lastParagraph = paragraph;
    this.reportProgress(paragraph, false);
    this.scheduleScroll(paragraph);
  }

  /** 重新排版本章（清掉解析与分页缓存，回到当前位置）。 */
  private reloadChapter(): void {
    if (this.chapterLoading) {
      return;
    }
    const paragraph = this.currentFirstParagraph();
    this.pageCache.clear();
    // 清掉引擎的章节缓存，保证真的是「从文件重新解析」
    const engine = this.engine;
    if (engine !== null) {
      engine.close();
    }
    void this.loadChapter(this.chapterIndex, paragraph, false);
  }

  /** 夜间 ⇄ 浅色（主题不影响排版，沿用同一条设置持久化回调）。 */
  private toggleNightTheme(): void {
    const next: ReaderTheme = this.theme === ReaderTheme.DARK ? ReaderTheme.LIGHT : ReaderTheme.DARK;
    const settings: ReaderSettings = this.currentSettings();
    settings.theme = next;
    this.applySettings(settings, false);
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

  /**
   * 工具栏显示后自动隐藏，避免长时间占住正文（打开面板时不隐藏）。
   *
   * 选词模式下也不隐藏：那时正文会吃掉内容区的点按，「点中间唤出工具栏」失效，
   * 工具栏是用户关掉选词模式的唯一入口，必须常驻（见 `onSelectModeChanged`）。
   */
  private scheduleBarsAutoHide(): void {
    this.cancelBarsAutoHide();
    this.barTimer = setTimeout(() => {
      this.barTimer = -1;
      if (this.showBars && !this.showPanel && !this.selectMode) {
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

  /**
   * 应用正文字体：宿主解析（下载/缓存）→ 模块用 ArkUI 注册 → 正文改用该家族。
   * `persist=false` 用于打开时恢复（失败静默回退系统字体）；`true` 用于用户主动切换。
   */
  private async applyFont(fontId: string, persist: boolean): Promise<void> {
    const target = fontId.length > 0 ? fontId : DEFAULT_SETTINGS.fontId;
    this.fontId = target;
    const resolved = await this.resolveFont(target);
    if (resolved === null) {
      // 下载或注册失败：回退系统字体；用户主动切换时把偏好也回退，避免下次打开又失败
      this.fontFamily = '';
      if (persist) {
        this.fontId = DEFAULT_SETTINGS.fontId;
        this.notifySettingsChanged();
      }
      return;
    }
    this.fontFamily = resolved.fontPath.length > 0 ? resolved.fontName : '';
    if (persist) {
      // 换字体后正文宽高都变，必须重新测量分页（applySettings 的 relayout 分支）并落盘偏好
      this.applySettings(this.currentSettings(), true);
    }
  }

  /** 让宿主解析字体（下载/缓存），并按需注册进 ArkUI；失败返回 null。 */
  private async resolveFont(fontId: string): Promise<ReaderFontResolve | null> {
    if (fontId === DEFAULT_SETTINGS.fontId) {
      return { fontName: 'system', fontPath: '' };
    }
    this.fontDownloading = true;
    try {
      const resolved = await this.callbacks.onFontSelected(fontId);
      if (resolved.fontPath.length > 0 && !this.registeredFonts.has(resolved.fontName)) {
        this.getUIContext().getFont().registerFont({
          familyName: resolved.fontName,
          familySrc: `file://${resolved.fontPath}`,
        });
        this.registeredFonts.add(resolved.fontName);
      }
      return resolved;
    } catch (error) {
      hilog.warn(0x0000, TAG, 'font resolve failed: %{public}s', (error as Error).message);
      return null;
    } finally {
      this.fontDownloading = false;
    }
  }

  /** 把当前设置（含字体）回调给宿主持久化。 */
  private notifySettingsChanged(): void {
    this.callbacks.onSettingsChanged(this.currentSettings());
  }

  /** 当前设置快照：所有落盘路径统一走它，避免新增设置项时漏传。 */
  private currentSettings(): ReaderSettings {
    const settings: ReaderSettings = {
      fontSize: this.fontSize,
      lineHeight: this.lineHeight,
      theme: this.theme,
      flipMode: this.flipMode,
      keepScreenOn: this.keepScreenOn,
      oneHandMode: this.oneHandMode,
      selectMode: this.selectMode,
      fontId: this.fontId,
    };
    return settings;
  }

  /**
   * 读取设备电量供页脚显示（系统 API，开销极小）。
   * 系统未向普通应用开放电量变化订阅，这里在打开时读一次并按分钟级轮询刷新。
   */
  private refreshBattery(): void {
    try {
      this.batteryLevel = batteryInfo.batterySOC;
      this.batteryCharging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ||
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
    } catch (_error) {
      this.batteryLevel = -1;
    }
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
      this.paragraphCount = chapter.paragraphCount;
      this.chapterBlocks = chapter.blocks;
      this.blockCount = chapter.blocks.length;
      this.blocks.update(chapter.blocks);
      // 选词模式下工具栏常驻（它是关掉选词模式的唯一入口），切章也不收起
      if (!this.selectMode) {
        this.showBars = false;
      }
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

  /**
   * 翻页前补齐分页：**只推进到「够判断目标页是否存在」为止**。
   *
   * 不能在这里一次性同步分完剩余整章：长章节（实测 840 章 TXT 的第 1 章有 1216 页，后台分页需 4.7s）
   * 会让点击卡住数秒（表现为「翻页失败」）；而且分页收尾还会用恢复位置改写当前页（表现为「又回到前面」）。
   * @returns 目标页是否已存在（false 且 `activePager === null` ⇒ 分页已完成、确实到了章末）
   */
  private ensurePagesFor(target: number): boolean {
    const pager = this.activePager;
    if (pager === null || pager.isFinished()) {
      return target < this.pageCount;
    }
    const deadline: number = Date.now() + PAGE_TURN_PAGINATION_MS;
    while (!pager.isFinished() && pager.getPages().length <= target && Date.now() < deadline) {
      pager.advance(PAGINATION_STEPS_PER_FRAME, PAGINATION_SLICE_MS);
    }
    const pages = pager.getPages().slice();
    this.pages = pages;
    this.pageSource.update(pages);
    this.pageCount = pages.length;
    if (pager.isFinished()) {
      this.finishPagination(this.paginationCacheKey(), pages);
    }
    return target < this.pageCount;
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
    return Math.max(1, this.contentHeightVp - CONTENT_TOP_SPACE - CONTENT_BOTTOM_SPACE - PAGE_HEADER_SPACE - PAGE_FOOTER_SPACE);
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

  // ---- 单手模式 ----

  /**
   * 单手模式开关。
   *
   * 只改点击分区语义（点左右两侧都前进，后退只能靠滑动），不改变排版，
   * 因此无需重新分页，仅落盘偏好。
   */
  private setOneHandMode(enabled: boolean): void {
    if (this.oneHandMode === enabled) {
      return;
    }
    this.oneHandMode = enabled;
    this.notifySettingsChanged();
  }

  // ---- 翻页交互 ----

  /**
   * 新增一条划线。
   *
   * 同章同段同原文不重复添加（同一句话划两次没有意义）；总数超上限时丢掉最早的一条。
   */
  private addAnnotation(paragraphIndex: number, text: string): void {
    const selected: string = text.trim();
    if (selected.length === 0) {
      return;
    }
    for (let i = 0; i < this.annotations.length; i++) {
      const item: ReaderAnnotation = this.annotations[i];
      if (item.chapterIndex === this.chapterIndex && item.paragraphIndex === paragraphIndex &&
        item.text === selected) {
        return;
      }
    }
    const next: ReaderAnnotation[] = this.annotations.slice();
    next.push({
      chapterIndex: this.chapterIndex,
      paragraphIndex: paragraphIndex,
      text: selected,
      createdAt: Date.now(),
    });
    while (next.length > ReaderView.MAX_ANNOTATIONS) {
      next.shift();
    }
    this.annotations = next;
    this.callbacks.onAnnotationsChanged(next);
    hilog.debug(0x0000, TAG, '划线：第 %{public}d 段「%{public}s」（共 %{public}d 条）',
      paragraphIndex, selected, next.length);
  }

  /** 删除划线；`text` 为空表示删掉该段的全部划线（该段有多条时的兜底）。 */
  private removeAnnotation(paragraphIndex: number, text: string): void {
    const selected: string = text.trim();
    const next: ReaderAnnotation[] = [];
    let removed: number = 0;
    for (let i = 0; i < this.annotations.length; i++) {
      const item: ReaderAnnotation = this.annotations[i];
      const sameBlock: boolean = item.chapterIndex === this.chapterIndex &&
        item.paragraphIndex === paragraphIndex;
      if (sameBlock && (selected.length === 0 || item.text === selected)) {
        removed++;
        continue;
      }
      next.push(item);
    }
    if (removed === 0) {
      return;
    }
    this.annotations = next;
    this.callbacks.onAnnotationsChanged(next);
    hilog.debug(0x0000, TAG, '取消划线 %{public}d 条（剩 %{public}d 条）', removed, next.length);
  }

  /**
   * 选词模式开关变化。
   *
   * 选词模式下正文会把内容区的点按吃掉（`copyOption` 的必然结果），「点中间唤出工具栏」这条路
   * 就断了 —— 用户再没有入口进设置面板把它关掉。所以进入选词模式时直接展开工具栏并让它常驻。
   */
  private onSelectModeChanged(): void {
    if (this.selectMode) {
      this.showBars = true;
      this.cancelBarsAutoHide();
    } else {
      this.scheduleBarsAutoHide();
    }
  }

  // 命名避开 CustomComponent 内置的 onDragStart/onDragEnd（拖拽事件回调）
  private beginPageDrag(event: GestureEvent): void {
    this.dragDir = 0;
    this.dragOffset = 0;
    this.dragOffsetY = 0;
    this.dragRaw = 0;
    this.dragVertical = false;
    this.foldLogged = false;
    this.lastPanAt = Date.now();
    const fingers: FingerInfo[] = event.fingerList;
    if (fingers.length > 0) {
      this.touchX = fingers[0].localX;
      this.touchY = fingers[0].localY;
    }
    this.frameWatch.start(this.getUIContext(), () => this.onMeasuredJank());
  }

  /**
   * 帧采样判定掉帧：第一级去掉折痕渐变（保留裁切，依然跟手），
   * 第二级把仿真翻页降级成覆盖翻页。只影响本次会话，不改用户偏好。
   */
  private onMeasuredJank(): void {
    if (!this.reduceEffects) {
      this.reduceEffects = true;
      hilog.info(0x0000, TAG, '翻页帧采样判定掉帧，先关闭折痕渐变特效');
      return;
    }
    if (this.flipMode === READER_FLIP_SIM || this.flipMode === READER_FLIP_FADE) {
      this.flipMode = READER_FLIP_COVER;
      hilog.info(0x0000, TAG, '持续掉帧，本次会话把翻页方式降级为覆盖翻页');
    }
  }

  /**
   * 跟手位移：无动画模式不做位移，只在抬手时按方向瞬时翻页。
   * `dy` 只用于仿真翻页的折痕倾斜（横向平移仍只看 `dx`）。
   */
  private updatePageDrag(dx: number, dy: number): void {
    const width = this.contentWidthVp;
    // 钳制在左右各一屏内：拖过头也不会把页面甩出可视区
    this.dragRaw = Math.min(width, Math.max(-width, dx));
    if (this.dragDir === 0) {
      if (Math.abs(dx) < 2 && Math.abs(dy) < 2) {
        return;
      }
      // 轴向锁：纵向为主的手势不是翻页（分页模式下纵向滑动本来就不做事）
      if (Math.abs(dy) > Math.abs(dx)) {
        this.dragVertical = true;
        return;
      }
      this.dragDir = dx < 0 ? 1 : -1;
    }
    if (this.dragVertical) {
      return;
    }
    // 位移不允许跨过起点：折痕的「抓取侧」由按下点与手指的相对位置决定，位移一旦跨过 0，
    // 被卷起的一侧会整体翻到对面（画面突然换边，且露出的是同一张新页从另一头冒出来）。
    // 钳在 0 上，往回拖就是沿原路把纸铺回去，抬起手按阈值回弹。
    this.dragRaw = this.dragDir === 1 ? Math.min(0, this.dragRaw) : Math.max(0, this.dragRaw);
    this.lastPanAt = Date.now();
    this.dragOffsetY = dy;
    if (this.flipMode === READER_FLIP_NONE) {
      return;
    }
    this.dragOffset = this.dragRaw;
    // 打一次跟手延迟探针：下一帧渲染回调时结算「手势事件 → 画面更新」的耗时
    this.frameWatch.probe();
    if (!this.foldLogged) {
      this.foldLogged = true;
      const fold: CurlFold = curlFoldGeometry(this.contentWidthVp, this.contentHeightVp,
        this.touchX, this.touchY, this.dragOffset, this.dragOffsetY);
      const path: string = foldFrontPath(this.contentWidthVp, this.contentHeightVp,
        this.touchX, this.touchY, this.dragOffset, this.dragOffsetY);
      const curve = foldCurveGeometry(this.contentWidthVp, this.contentHeightVp,
        this.touchX, this.touchY, this.dragOffset, this.dragOffsetY);
      hilog.debug(0x0000, TAG,
        '折痕几何：倾角 %{public}s°，跨度 %{public}s，抓取侧 %{public}d，弯曲 %{public}s vp，裁剪路径含曲线 %{public}s',
        fold.rotationDeg.toFixed(1), fold.span.toFixed(0), fold.peelSign,
        curve.bulge.toFixed(1), path.indexOf('Q') > 0 ? '是' : '否');
    }
  }

  /**
   * 抬手结算：拖动距离超过 `PAGE_TURN_RATIO` 或甩动速度超过阈值都翻页，否则回弹。
   * `velocity` 为手势速度（vp/s，正 = 向右），方向与拖动方向一致时才算甩页。
   */
  private endPageDrag(velocity: number): void {
    const dir = this.dragDir;
    if (dir === 0) {
      this.dragOffset = 0;
      return;
    }
    // 多指并行触发时可能收到第二次结算：动画还在跑就忽略，避免翻两页
    if (this.turning) {
      return;
    }
    const threshold = this.contentWidthVp * PAGE_TURN_RATIO;
    const fling = Math.abs(velocity) >= FLING_VELOCITY_VP && velocity * dir < 0;
    hilog.debug(0x0000, TAG, '抬手结算：dir=%{public}d 拖距 %{public}s vp 速度 %{public}s ⇒ %{public}s',
      dir, this.dragRaw.toFixed(0), velocity.toFixed(0), (fling || dir * this.dragRaw <= -threshold) ? '翻页' : '回弹');
    if (!fling && dir * this.dragRaw > -threshold) {
      this.animateBack();
      return;
    }
    this.dragRaw = 0;
    if (this.flipMode === READER_FLIP_NONE) {
      // 无动画模式：不做位移动画，直接瞬切（含切章）
      this.dragDir = 0;
      this.dragOffset = 0;
      this.frameWatch.stop();
      this.turnPage(dir);
      return;
    }
    this.animateTurn(dir);
  }

  /** 手势被中断（父组件/系统抢走）：回弹，不翻页。 */
  private cancelPageDrag(): void {
    if (this.dragDir === 0) {
      return;
    }
    this.dragRaw = 0;
    if (this.flipMode === READER_FLIP_NONE || this.dragOffset === 0) {
      this.dragDir = 0;
      this.dragOffset = 0;
      this.frameWatch.stop();
      return;
    }
    this.animateBack();
  }

  /**
   * 翻页动画：折痕从当前手指位置扫到页面另一端，扫完再切页码。
   *
   * 动画由 `ReaderFlipAnimator` 按帧推进（而不是 `animateTo`）——仿真翻页的画面每帧都由
   * `dragOffset` 现算，`animateTo` 不会带着中间值重跑构建函数，卷曲就一动不动。
   */
  private animateTurn(delta: number): void {
    const width = this.contentWidthVp;
    const target = delta > 0 ? -width : width;
    this.turning = true;
    this.flipAnim.start(pageTurnFrameRate(), this.dragOffset, target, PAGE_ANIM_MS, false,
      (value: number) => {
        this.dragOffset = value;
      },
      () => {
        this.dragOffset = 0;
        this.dragDir = 0;
        this.turning = false;
        this.frameWatch.stop();
        this.turnPage(delta);
      });
  }

  /**
   * 回弹：距离不够时弹回原位。
   * 用轻微过冲的弹簧曲线而不是单调减速 —— 收尾时会有一点点过冲再落回，
   * 手感更像纸页被松开（过冲约 3.4%，幅度极小，不会翻错方向）。
   */
  private animateBack(): void {
    this.turning = true;
    this.flipAnim.start(pageTurnFrameRate(), this.dragOffset, 0, PAGE_ANIM_MS, true,
      (value: number) => {
        this.dragOffset = value;
      },
      () => {
        this.dragDir = 0;
        this.dragOffset = 0;
        this.turning = false;
        this.frameWatch.stop();
      });
  }

  /** 翻页：越界时切到相邻章（下一章首页 / 上一章末页）。 */
  private turnPage(delta: number): void {
    if (!ReaderFlip.isPaged(this.flipMode)) {
      return;
    }
    // 正在加载章节：忽略。此时 pageCount=0，继续往下会把点击判成「越界」而跳章，
    // 连点几下就连续跳章、每次都停在新章第 1 页（表现为「翻页总是回到第一页」）。
    if (this.chapterLoading) {
      return;
    }
    // 本章没有可渲染内容（空白页、图片都解析不到）：不要卡住，翻页直接跳相邻章
    if (this.blockCount === 0) {
      const neighbour = this.chapterIndex + delta;
      if (neighbour >= 0 && neighbour < this.catalogSize) {
        void this.loadChapter(neighbour, 0, delta < 0);
      }
      return;
    }
    // 有内容但还没分出页：稍后即可翻，先忽略这一次
    if (this.pageCount === 0) {
      return;
    }
    // 用户已手动翻页：此后不再用「恢复位置」改写当前页
    this.pagerPositionApplied = true;
    const target = this.pageIndex + delta;
    // 分页还没补完时按预算推进到「够判断目标页是否存在」为止，避免长章一次性同步分完卡住 UI
    const targetExists = this.ensurePagesFor(target);
    if (target < 0) {
      const previousChapter = this.chapterIndex - 1;
      if (previousChapter >= 0) {
        void this.loadChapter(previousChapter, 0, true);
      }
      return;
    }
    if (!targetExists) {
      // 分页已完成仍越界 ⇒ 真的到了章末；分页未完成（activePager 还在）⇒ 本次先不生效，避免误跳章
      if (this.activePager !== null) {
        return;
      }
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

  /**
   * 点击翻页：目标页已存在时走左右滑动动效，
   * 否则交给 `turnPage`（章首章末切章、分页还没补完）。
   */
  private turnPageAnimated(delta: number): void {
    if (this.turning) {
      return;
    }
    if (this.flipMode === READER_FLIP_NONE || this.chapterLoading || this.blockCount === 0) {
      this.turnPage(delta);
      return;
    }
    const target = this.pageIndex + delta;
    if (target < 0 || !this.ensurePagesFor(target)) {
      this.turnPage(delta);
      return;
    }
    this.pagerPositionApplied = true;
    this.dragDir = delta > 0 ? 1 : -1;
    // 点按翻页没有按下点：折痕几何是按「按下点 + 位移」算的，这里补一个等效按下点
    // ——抓住要翻的那一边的页边中点（下一页 ⇒ 右边缘中点，上一页 ⇒ 左边缘中点），
    // 折痕才会从该边扫到另一边；不补的话按下点是 (0,0)，折痕算到屏幕外，动画期间看不到卷页。
    this.touchX = delta > 0 ? this.contentWidthVp : 0;
    this.touchY = this.contentHeightVp / 2;
    this.dragOffsetY = 0;
    this.frameWatch.start(this.getUIContext(), () => this.onMeasuredJank());
    this.animateTurn(delta);
  }

  /**
   * 三区点击：左/右 1/3 翻页、中间切换工具栏。
   * 单手模式下左右两侧都是「下一页」，后退只能靠向右滑动（拇指够不到左侧）。
   */
  private onPagerClick(event: ClickEvent): void {
    // 刚拖动过（含被识别成拖动但最终回弹的情况）就不当点击
    if (Date.now() - this.lastPanAt < CLICK_AFTER_PAN_MS) {
      return;
    }
    const width = this.contentWidthVp;
    if (width <= 0) {
      this.toggleBars();
      return;
    }
    const x = event.x;
    const inMiddle = x > width * TAP_ZONE_RATIO && x < width * (1 - TAP_ZONE_RATIO);
    if (inMiddle) {
      this.toggleBars();
      return;
    }
    const back = !this.oneHandMode && x <= width * TAP_ZONE_RATIO;
    hilog.debug(0x0000, TAG, '点击翻页：x=%{public}s vp / 宽 %{public}s vp ⇒ %{public}s',
      x.toFixed(0), width.toFixed(0), back ? '上一页' : '下一页');
    this.turnPageAnimated(back ? -1 : 1);
  }

  /** 页面层横向位移：覆盖模式只动「上面那一页」，滑动模式两页同步平移；淡入淡出不位移。 */
  private layerX(offset: number): number {
    const width = this.contentWidthVp;
    const dx = this.dragOffset;
    // 淡入淡出与仿真都不做横向平移：仿真的「动」全部由折痕裁剪 + 纸背镜像表达，
    // 这里若还跟着拖位移，纸面会一边滑动一边折（页面内容会整体左移）。
    if (this.flipMode === READER_FLIP_FADE || this.flipMode === READER_FLIP_SIM) {
      return 0;
    }
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

  /** 层序：覆盖模式向右拖时「上一页」要盖在当前页之上；淡入淡出时目标页恒在当前页之上。 */
  private layerZ(offset: number): number {
    if (this.flipMode === READER_FLIP_FADE) {
      return offset === 0 ? 1 : 2;
    }
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

  /**
   * 滚动模式的「下一页」：已到列表末尾则切下一章，否则往下翻一屏。
   * 用 `Scroller.isAtEnd()` 而不是记 `onScrollIndex`：一屏就放完的短章节也要能点着翻到下一章。
   */
  private scrollOneScreen(): void {
    if (this.listAtEnd()) {
      const next = this.chapterIndex + 1;
      if (next < this.catalogSize) {
        void this.loadChapter(next, 0, false);
      }
      return;
    }
    try {
      this.listScroller.scrollPage({ next: true });
    } catch (_error) {
      // 列表尚未布局完成时忽略；位置由当前滚动位置兜底
    }
  }

  private listAtEnd(): boolean {
    try {
      return this.listScroller.isAtEnd();
    } catch (_error) {
      return false;
    }
  }

  /** 滚动模式下的点击：单手模式左右两侧都为下一页，其余仍为切换工具栏。 */
  private onScrollTap(event: ClickEvent): void {
    const width = this.contentWidthVp;
    const inMiddle = width > 0 && event.x > width * TAP_ZONE_RATIO &&
      event.x < width * (1 - TAP_ZONE_RATIO);
    if (!this.oneHandMode || inMiddle) {
      this.toggleBars();
      return;
    }
    this.scrollOneScreen();
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
  private applySettings(settings: ReaderSettings, relayout: boolean): void {
    const nextFlip = ReaderFlip.normalize(settings.flipMode);
    const metricsChanged = relayout && (settings.fontSize !== this.appliedFontSize ||
      settings.lineHeight !== this.appliedLineHeight);
    const flipChanged = relayout && nextFlip !== this.appliedFlipMode;
    this.appliedFontSize = settings.fontSize;
    this.appliedLineHeight = settings.lineHeight;
    this.appliedFlipMode = nextFlip;
    this.fontSize = settings.fontSize;
    this.lineHeight = settings.lineHeight;
    this.theme = settings.theme;
    this.flipMode = nextFlip;
    this.keepScreenOn = settings.keepScreenOn;
    const applied: ReaderSettings = this.currentSettings();
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
