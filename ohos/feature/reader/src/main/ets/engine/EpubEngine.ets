import { zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookEngine, ReaderCatalogItem, ReaderChapter } from '../model/ReaderTypes';
import { BookFile } from './BookFile';
import { EpubXml } from './EpubXml';
import { MarkupText } from './MarkupText';

const TAG: string = 'EpubEngine';

const NCX_MEDIA_TYPE: string = 'application/x-dtbncx+xml';
const XHTML_MEDIA_TYPES: string[] = ['application/xhtml+xml', 'text/html'];
const CONTAINER_RELATIVE: string = 'META-INF/container.xml';
const MAX_CACHED_CHAPTERS: number = 6;

interface ManifestItem {
  id: string;
  href: string;
  mediaType: string;
  properties: string;
}

/** TOC 解析中间结果：出现位置 + 值。 */
interface TocMatch {
  position: number;
  value: string;
}

/**
 * EPUB 引擎：`zlib` 解压到缓存目录 → 解析 container.xml / OPF / NCX(nav) → 逐章取文。
 *
 * 解压产物按「文件路径哈希」缓存，二次打开不再解压；
 * 章节正文按需读取，仅保留最近数章，避免大书常驻内存。
 */
export class EpubEngine implements BookEngine {
  private readonly bookTitle: string;
  private readonly extractDir: string;
  private readonly spinePaths: string[] = [];
  private readonly spineTitles: string[] = [];
  private readonly catalogItems: ReaderCatalogItem[] = [];
  private readonly cache: Map<number, ReaderChapter> = new Map();
  /** 章节文件（相对解压根目录，小写）→ spine 序号 */
  private readonly hrefIndex: Map<string, number> = new Map();
  /** 章节文件名（小写）→ spine 序号，用于 TOC href 解析失败时兜底 */
  private readonly nameIndex: Map<string, number> = new Map();

  private constructor(bookTitle: string, extractDir: string) {
    this.bookTitle = bookTitle;
    this.extractDir = extractDir;
  }

  static async open(filePath: string, bookTitle: string, cacheDir: string): Promise<EpubEngine> {
    const extractDir = BookFile.join(cacheDir, `reader_epub_${EpubEngine.hashPath(filePath)}`);
    const containerPath = BookFile.join(extractDir, CONTAINER_RELATIVE);
    const cached = BookFile.exists(containerPath);
    hilog.info(0x0000, TAG, 'extractDir=%{public}s cached=%{public}s', extractDir, `${cached}`);
    if (!cached) {
      // 上次解压中断会留下不完整目录，先清掉再解，避免解压报错
      BookFile.removeDir(extractDir);
      BookFile.ensureDir(cacheDir);
      // decompressFile 要求目标目录已存在，否则报 900002（The input destination file is invalid）
      BookFile.ensureDir(extractDir);
      try {
        await zlib.decompressFile(filePath, extractDir);
      } catch (error) {
        hilog.error(0x0000, TAG, 'decompress failed: %{public}s (%{public}s)',
          filePath, (error as Error).message);
        throw new Error(`EPUB 解压失败：${(error as Error).message}`);
      }
      hilog.info(0x0000, TAG, 'decompressed %{public}s, container=%{public}s',
        extractDir, `${BookFile.exists(containerPath)}`);
    }
    const opfRelative = EpubEngine.findOpfPath(BookFile.readText(containerPath));
    if (opfRelative.length === 0) {
      throw new Error('EPUB 缺少 OPF 描述文件');
    }
    const opf = BookFile.readText(BookFile.join(extractDir, opfRelative));
    if (opf.length === 0) {
      throw new Error('EPUB 的 OPF 文件为空');
    }
    const opfDir = BookFile.dirName(opfRelative);
    const manifest = EpubEngine.readManifest(opf);
    const engine = new EpubEngine(EpubEngine.resolveTitle(opf, bookTitle), extractDir);
    engine.buildSpine(manifest, EpubEngine.readSpineIds(opf), opfDir);
    if (engine.spinePaths.length === 0) {
      throw new Error('EPUB 没有可阅读的正文');
    }
    engine.applyToc(manifest, opfDir);
    return engine;
  }

  getTitle(): string {
    return this.bookTitle;
  }

  getCatalog(): ReaderCatalogItem[] {
    return this.catalogItems;
  }

  async loadChapter(index: number): Promise<ReaderChapter> {
    const safeIndex = index < 0 || index >= this.spinePaths.length ? 0 : index;
    const cached = this.cache.get(safeIndex);
    if (cached !== undefined) {
      return cached;
    }
    let paragraphs: string[] = [];
    try {
      const markup = BookFile.readText(this.spinePaths[safeIndex]);
      paragraphs = MarkupText.toParagraphs(markup);
      hilog.debug(0x0000, TAG, 'chapter %{public}d: markup=%{public}d paragraphs=%{public}d',
        safeIndex, markup.length, paragraphs.length);
    } catch (error) {
      hilog.error(0x0000, TAG, 'chapter %{public}d failed: %{public}s',
        safeIndex, (error as Error).message);
      paragraphs = ['（本章内容读取失败）'];
    }
    const chapter: ReaderChapter = {
      index: safeIndex,
      title: this.spineTitles[safeIndex],
      paragraphs: paragraphs,
    };
    if (this.cache.size >= MAX_CACHED_CHAPTERS) {
      this.cache.clear();
    }
    this.cache.set(safeIndex, chapter);
    return chapter;
  }

  close(): void {
    this.cache.clear();
  }

  // ---- container / OPF ----

  /** container.xml → 首个 rootfile 的 full-path。 */
  private static findOpfPath(container: string): string {
    const rootfiles = EpubXml.tags(container, 'rootfile');
    for (let i = 0; i < rootfiles.length; i++) {
      const fullPath = EpubXml.attr(rootfiles[i], 'full-path');
      if (fullPath.length > 0) {
        return BookFile.normalizeHref(fullPath);
      }
    }
    return '';
  }

  private static readManifest(opf: string): ManifestItem[] {
    const items: ManifestItem[] = [];
    const tags = EpubXml.tags(opf, 'item');
    for (let i = 0; i < tags.length; i++) {
      const id = EpubXml.attr(tags[i], 'id');
      const href = EpubXml.attr(tags[i], 'href');
      if (id.length === 0 || href.length === 0) {
        continue;
      }
      items.push({
        id: id,
        href: BookFile.normalizeHref(href),
        mediaType: EpubXml.attr(tags[i], 'media-type').toLowerCase(),
        properties: EpubXml.attr(tags[i], 'properties').toLowerCase(),
      });
    }
    return items;
  }

  /** spine 阅读顺序；`linear="no"`（如封面、版权页）跳过。 */
  private static readSpineIds(opf: string): string[] {
    const ids: string[] = [];
    const refs = EpubXml.tags(opf, 'itemref');
    for (let i = 0; i < refs.length; i++) {
      if (EpubXml.attr(refs[i], 'linear').toLowerCase() === 'no') {
        continue;
      }
      const idref = EpubXml.attr(refs[i], 'idref');
      if (idref.length > 0) {
        ids.push(idref);
      }
    }
    return ids;
  }

  private static resolveTitle(opf: string, bookTitle: string): string {
    const fromOpf = EpubXml.firstText(opf, 'title');
    return fromOpf.length > 0 ? fromOpf : bookTitle;
  }

  private static isHtml(mediaType: string): boolean {
    for (let i = 0; i < XHTML_MEDIA_TYPES.length; i++) {
      if (mediaType === XHTML_MEDIA_TYPES[i]) {
        return true;
      }
    }
    return false;
  }

  private static hashPath(value: string): string {
    let hash = 5381;
    for (let i = 0; i < value.length; i++) {
      hash = (hash * 33 + value.charCodeAt(i)) % 0x7FFFFFFF;
    }
    return hash.toString(16);
  }

  // ---- spine / 目录 ----

  private buildSpine(manifest: ManifestItem[], spineIds: string[], opfDir: string): void {
    const byId: Map<string, ManifestItem> = new Map();
    for (let i = 0; i < manifest.length; i++) {
      byId.set(manifest[i].id, manifest[i]);
    }
    for (let i = 0; i < spineIds.length; i++) {
      const item = byId.get(spineIds[i]);
      if (item === undefined || !EpubEngine.isHtml(item.mediaType)) {
        continue;
      }
      const relative = BookFile.join(opfDir, item.href);
      this.spinePaths.push(BookFile.join(this.extractDir, relative));
      this.spineTitles.push('');
      const key = relative.toLowerCase();
      this.hrefIndex.set(key, this.spinePaths.length - 1);
      const slash = key.lastIndexOf('/');
      const name = slash < 0 ? key : key.substring(slash + 1);
      if (!this.nameIndex.has(name)) {
        this.nameIndex.set(name, this.spinePaths.length - 1);
      }
    }
  }

  /** 用 NCX（EPUB2）或 nav（EPUB3）补章节标题，缺失时用序号兜底。 */
  private applyToc(manifest: ManifestItem[], opfDir: string): void {
    const titles = this.readTocTitles(manifest, opfDir);
    this.catalogItems.length = 0;
    for (let i = 0; i < this.spinePaths.length; i++) {
      const fromToc = titles.get(i);
      if (fromToc !== undefined && fromToc.length > 0) {
        this.spineTitles[i] = fromToc;
      }
      if (this.spineTitles[i].length === 0) {
        this.spineTitles[i] = `第${i + 1}章`;
      }
      this.catalogItems.push({ index: i, title: this.spineTitles[i] });
    }
  }

  private readTocTitles(manifest: ManifestItem[], opfDir: string): Map<number, string> {
    let navHref = '';
    let ncxHref = '';
    for (let i = 0; i < manifest.length; i++) {
      const item = manifest[i];
      if (item.mediaType === NCX_MEDIA_TYPE && ncxHref.length === 0) {
        ncxHref = item.href;
      }
      if (item.properties.split(/\s+/).indexOf('nav') >= 0 && navHref.length === 0) {
        navHref = item.href;
      }
    }
    const titles: Map<number, string> = new Map();
    if (navHref.length > 0) {
      this.collectNavTitles(navHref, opfDir, titles);
    }
    if (titles.size === 0 && ncxHref.length > 0) {
      this.collectNcxTitles(ncxHref, opfDir, titles);
    }
    return titles;
  }

  private collectNavTitles(navHref: string, opfDir: string, titles: Map<number, string>): void {
    try {
      const navPath = BookFile.join(this.extractDir, BookFile.join(opfDir, navHref));
      const anchors = EpubXml.anchors(BookFile.readText(navPath));
      const tocDir = BookFile.dirName(navHref);
      for (let i = 0; i < anchors.length; i++) {
        EpubEngine.putTitle(titles, this.resolveTocIndex(anchors[i].href, tocDir), anchors[i].text);
      }
    } catch (_error) {
      titles.clear();
    }
  }

  private collectNcxTitles(ncxHref: string, opfDir: string, titles: Map<number, string>): void {
    try {
      const ncxPath = BookFile.join(this.extractDir, BookFile.join(opfDir, ncxHref));
      const ncx = BookFile.readText(ncxPath);
      // 不能按下标配对：`<docTitle>` 的 `<text>` 没有对应 `<content src>`，会让整份目录错位一章。
      // 改为按文档顺序扫描，每个 `content src` 归属它前面最近的 `<text>`（navPoint 可嵌套，此法不受影响）。
      const labels = EpubEngine.matches(ncx, new RegExp('<text\\b[^>]*>([\\s\\S]*?)<\\/text\\s*>', 'gi'));
      const sources = EpubEngine.matches(ncx, new RegExp('<content\\b[^>]*\\bsrc\\s*=\\s*"([^"]+)"', 'gi'));
      const tocDir = BookFile.dirName(ncxHref);
      let labelIndex = 0;
      let currentLabel = '';
      for (let i = 0; i < sources.length; i++) {
        while (labelIndex < labels.length && labels[labelIndex].position < sources[i].position) {
          currentLabel = MarkupText.stripTags(labels[labelIndex].value);
          labelIndex++;
        }
        EpubEngine.putTitle(titles, this.resolveTocIndex(sources[i].value, tocDir), currentLabel);
      }
    } catch (_error) {
      titles.clear();
    }
  }

  /** 逐个匹配并记录位置（用 exec 循环，避免依赖 `String.matchAll`）。 */
  private static matches(xml: string, pattern: RegExp): TocMatch[] {
    const results: TocMatch[] = [];
    let match: RegExpExecArray | null = pattern.exec(xml);
    while (match !== null) {
      results.push({ position: match.index, value: match[1] });
      if (match.index === pattern.lastIndex) {
        pattern.lastIndex++;
      }
      match = pattern.exec(xml);
    }
    return results;
  }

  private static putTitle(titles: Map<number, string>, index: number, title: string): void {
    // 同章命中多个锚点时保留第一个（通常是章节标题本身）
    if (index >= 0 && title.length > 0 && !titles.has(index)) {
      titles.set(index, title);
    }
  }

  /** TOC 里的 href 相对 TOC 文件所在目录；解析不到时按文件名兜底。 */
  private resolveTocIndex(href: string, tocDir: string): number {
    const clean = BookFile.normalizeHref(href);
    if (clean.length === 0) {
      return -1;
    }
    const candidates: string[] = [
      BookFile.normalizeHref(BookFile.join(tocDir, clean)).toLowerCase(),
      clean.toLowerCase(),
    ];
    for (let i = 0; i < candidates.length; i++) {
      const hit = this.hrefIndex.get(candidates[i]);
      if (hit !== undefined) {
        return hit;
      }
    }
    const normalized = clean.toLowerCase();
    const slash = normalized.lastIndexOf('/');
    const byName = this.nameIndex.get(slash < 0 ? normalized : normalized.substring(slash + 1));
    return byName === undefined ? -1 : byName;
  }
}
