/**
 * 独立阅读器的公共类型。
 *
 * 本模块（`feature/reader`）不依赖 entry 的任何代码，也不依赖系统 ReaderKit：
 * 宿主只通过 `ReaderOpenOptions` 传参、通过 `ReaderCallbacks` 回收进度，
 * 因此可在模拟器与非华为 HarmonyOS 发行版上运行。
 */

/** 阅读主题（与宿主既有阅读器保持同一套取值，便于共用设置）。 */
export enum ReaderTheme {
  LIGHT = 0,
  DARK = 1,
  EYE = 2,
}

/** 引擎标识，写入 location JSON 的 engine 字段，用于区分阅读进度来源。 */
export const READER_ENGINE_BUILTIN: string = 'builtin';

/**
 * 内置阅读器把段落下标写进 location 的 `domPos` 字段（与 ReaderKit 同结构）。
 * 加前缀是为了和 ReaderKit 的 `epubcfi(...)` 明确区分：
 * 纯数字可能在正文里被误匹配成锚点，带前缀则一定会落回章首。
 */
export const READER_PARAGRAPH_PREFIX: string = 'builtin:';

/**
 * 阅读器引擎偏好（宿主写入 preferences，`ReaderLauncher` 读取）：
 * - `auto`：设备有系统 ReaderKit 就用它，否则回退内置阅读器；
 * - `builtin`：只要格式支持（EPUB / TXT）就用内置阅读器，便于在任意设备上使用自研渲染。
 */
export const READER_MODE_PREF_KEY: string = 'reader_mode';
export const READER_MODE_AUTO: string = 'auto';
export const READER_MODE_BUILTIN: string = 'builtin';

/**
 * 翻页方式（内置阅读器自己的偏好，与 ReaderKit 阅读器的 `reader_flip_mode` 分开，
 * 因为两者可选效果不同：ReaderKit 有仿真翻页，内置阅读器是自绘翻页）。
 */
export const READER_FLIP_PREF_KEY: string = 'reader_flip_mode_builtin';
/** 覆盖翻页：新页盖住旧页（默认）。 */
export const READER_FLIP_COVER: string = 'cover';
/** 左右滑动：新旧页整体平移。 */
export const READER_FLIP_SLIDE: string = 'slide';
/** 无动画：点按/滑动后瞬时切换。 */
export const READER_FLIP_NONE: string = 'none';
/** 上下滚动：不分页，沿用滚动列表。 */
export const READER_FLIP_SCROLL: string = 'scroll';
export const READER_FLIP_DEFAULT: string = READER_FLIP_COVER;

/** 是否为分页模式（除上下滚动外都分页）。 */
export class ReaderFlip {
  static isPaged(flipMode: string): boolean {
    return flipMode !== READER_FLIP_SCROLL;
  }

  /** 非法值回落到默认，避免偏好被改坏后整页空白。 */
  static normalize(flipMode: string): string {
    if (flipMode === READER_FLIP_COVER || flipMode === READER_FLIP_SLIDE ||
      flipMode === READER_FLIP_NONE || flipMode === READER_FLIP_SCROLL) {
      return flipMode;
    }
    return READER_FLIP_DEFAULT;
  }

  /** 设置面板显示名。 */
  static label(flipMode: string): string {
    if (flipMode === READER_FLIP_SLIDE) {
      return '左右滑动';
    }
    if (flipMode === READER_FLIP_NONE) {
      return '无动画';
    }
    if (flipMode === READER_FLIP_SCROLL) {
      return '上下滚动';
    }
    return '覆盖翻页';
  }
}

/** 分页阅读器的可选翻页方式（顺序即设置面板顺序）。 */
export const READER_FLIP_OPTIONS: string[] =
  [READER_FLIP_COVER, READER_FLIP_SLIDE, READER_FLIP_NONE, READER_FLIP_SCROLL];

export interface ReaderSettings {
  /** 正文字号，单位 fp。 */
  fontSize: number;
  /** 行高倍数。 */
  lineHeight: number;
  theme: ReaderTheme;
  /** 翻页方式，取值见 `READER_FLIP_*`。 */
  flipMode: string;
  /** 阅读时常亮屏幕（由宿主用 window API 应用）。 */
  keepScreenOn: boolean;
}

export interface ReaderCatalogItem {
  /** 章节目录序号（从 0 开始，与 `ReaderChapter.index` 一致）。 */
  index: number;
  title: string;
}

/** 正文块类型：文本段落或插图。 */
export enum ReaderBlockKind {
  TEXT = 0,
  IMAGE = 1,
}

/**
 * 正文块（按文档顺序）。
 * 图片与文字混排，分页/滚动都按块处理；`paragraphIndex` 让位置与进度仍以「文本段落」
 * 为基准，保持与 ReaderKit 阅读器的 `location` 语义一致。
 */
export interface ReaderBlock {
  kind: ReaderBlockKind;
  /** TEXT：段落文本。 */
  text: string;
  /** IMAGE：图片的沙箱绝对路径。 */
  src: string;
  /** IMAGE：替代文本（缺失时用于占位说明）。 */
  alt: string;
  /** IMAGE：宽高比（宽/高）；0 表示未取到，按默认比例渲染。 */
  aspect: number;
  /** 该块对应/之前的文本段落序号。 */
  paragraphIndex: number;
}

export interface ReaderChapter {
  index: number;
  title: string;
  /** 仅文本段落（滚动模式的百分比、进度统计仍用它）。 */
  paragraphs: string[];
  /** 文本 + 图片的有序块，渲染与分页以此为唯一来源。 */
  blocks: ReaderBlock[];
}

export interface ReaderLocation {
  chapterIndex: number;
  /** 章内段落序号，用于恢复滚动位置。 */
  paragraphIndex: number;
  /** 全书进度 0 ~ 1。 */
  percent: number;
}

/** 打开参数（宿主提供；模块自身不持有 context）。 */
export interface ReaderOpenOptions {
  filePath: string;
  /** 书籍格式，大小写与点号均可（如 `EPUB` / `.epub`）。 */
  format: string;
  title: string;
  /** 沙箱缓存目录（EPUB 解压用），由宿主传入。 */
  cacheDir: string;
  /**
   * 起始位置（与 ReaderKit 阅读器共用同一份 location JSON）。
   * 本模块写出的形如 `{"engine":"builtin","resourceIndex":0,"domPos":"builtin:12"}`；
   * 传入 ReaderKit 格式（`domPos` 为 CFI）时会从本章开头起读。
   */
  location: string;
  /** 初始阅读设置（宿主从既有偏好读取，与 ReaderKit 阅读器共用同一份偏好）。 */
  settings: ReaderSettings;
}

/** 宿主回调。 */
export interface ReaderCallbacks {
  /** 翻页/切章时回调（宿主自行防抖落盘）。 */
  onProgress: (location: ReaderLocation, chapterTitle: string) => void;
  /** 用户点击返回时回调。 */
  onClose: () => void;
  /** 字号/行高/主题变化时回调（由宿主持久化）。 */
  onSettingsChanged: (settings: ReaderSettings) => void;
}

/** 书籍解析引擎：TXT / EPUB 各自实现。 */
export interface BookEngine {
  getTitle(): string;
  getCatalog(): ReaderCatalogItem[];
  /** 按需加载章节正文（EPUB 逐章读文件，TXT 已在内存）。 */
  loadChapter(index: number): Promise<ReaderChapter>;
  close(): void;
}

/** 格式判定：宿主用它决定是否回退到内置阅读器，避免两处各写一份格式清单。 */
export class ReaderFormats {
  static readonly TXT: string = 'txt';
  static readonly EPUB: string = 'epub';

  /** 归一化：去空格、去前导点、转小写。 */
  static normalize(format: string): string {
    return format.trim().toLowerCase().replace(/^\./, '');
  }

  /** 内置阅读器是否支持该格式。 */
  static supports(format: string): boolean {
    const value = ReaderFormats.normalize(format);
    return value === ReaderFormats.TXT || value === ReaderFormats.EPUB;
  }
}

/** 阅读位置的编解码：宿主不需要了解 `domPos` 的内部格式。 */
export class ReaderLocations {
  /** 编码为与 ReaderKit 阅读器同结构的 location JSON。 */
  static encode(location: ReaderLocation): string {
    const payload: Record<string, Object> = {
      'engine': READER_ENGINE_BUILTIN,
      'resourceIndex': location.chapterIndex,
      'domPos': `${READER_PARAGRAPH_PREFIX}${location.paragraphIndex}`,
      'percent': Math.round(location.percent * 100),
    };
    return JSON.stringify(payload);
  }
}
