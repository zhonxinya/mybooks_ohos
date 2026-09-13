import { BookFile } from './BookFile';
import { EpubXml } from './EpubXml';
import { MarkupText } from './MarkupText';

/**
 * EPUB 结构与目录解析（**纯计算 + 文件读取，不含任何 UI/ArkUI 调用**）。
 *
 * 之所以单独成模块：这些正则解析与文件读取都属于重活，
 * 必须能在 taskpool 子线程里跑（见 `ReaderTasks`），不能在 UI 线程同步执行。
 */
const NCX_MEDIA_TYPE: string = 'application/x-dtbncx+xml';
const XHTML_MEDIA_TYPES: string[] = ['application/xhtml+xml', 'text/html'];
const CONTAINER_RELATIVE: string = 'META-INF/container.xml';

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

/** 解析结果：spine 顺序、章节文件（相对解压根目录）、目录标题、书名。 */
export interface EpubStructureData {
  bookTitle: string;
  opfDir: string;
  spineHrefs: string[];
  spineTitles: string[];
}

export class EpubStructure {
  static containerRelative(): string {
    return CONTAINER_RELATIVE;
  }

  /** 解析 container.xml / OPF / NCX(nav)：返回 spine 与目录标题（全程不做 UI 调用）。 */
  static parse(extractDir: string, fallbackTitle: string): EpubStructureData {
    const containerPath = BookFile.join(extractDir, CONTAINER_RELATIVE);
    const opfRelative = EpubStructure.findOpfPath(BookFile.readText(containerPath));
    if (opfRelative.length === 0) {
      throw new Error('EPUB 缺少 OPF 描述文件');
    }
    const opf = BookFile.readText(BookFile.join(extractDir, opfRelative));
    if (opf.length === 0) {
      throw new Error('EPUB 的 OPF 文件为空');
    }
    const opfDir = BookFile.dirName(opfRelative);
    const manifest = EpubStructure.readManifest(opf);
    const spineHrefs = EpubStructure.buildSpineHrefs(manifest, EpubStructure.readSpineIds(opf), opfDir);
    if (spineHrefs.length === 0) {
      throw new Error('EPUB 没有可阅读的正文');
    }
    const titles = EpubStructure.resolveTitles(extractDir, manifest, opfDir, spineHrefs);
    return {
      bookTitle: EpubStructure.resolveTitle(opf, fallbackTitle),
      opfDir: opfDir,
      spineHrefs: spineHrefs,
      spineTitles: titles,
    };
  }

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

  private static buildSpineHrefs(manifest: ManifestItem[], spineIds: string[], opfDir: string): string[] {
    const byId: Map<string, ManifestItem> = new Map();
    for (let i = 0; i < manifest.length; i++) {
      byId.set(manifest[i].id, manifest[i]);
    }
    const hrefs: string[] = [];
    for (let i = 0; i < spineIds.length; i++) {
      const item = byId.get(spineIds[i]);
      if (item === undefined || !EpubStructure.isHtml(item.mediaType)) {
        continue;
      }
      hrefs.push(BookFile.join(opfDir, item.href));
    }
    return hrefs;
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

  // ---- 目录 ----

  /** 用 NCX（EPUB2）或 nav（EPUB3）补章节标题，缺失时用序号兜底。 */
  private static resolveTitles(extractDir: string, manifest: ManifestItem[], opfDir: string,
    spineHrefs: string[]): string[] {
    const titles: string[] = [];
    for (let i = 0; i < spineHrefs.length; i++) {
      titles.push(`第${i + 1}章`);
    }
    const index: EpubTocIndex = EpubStructure.buildHrefIndex(spineHrefs);
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
    let found: Map<number, string> = new Map();
    if (navHref.length > 0) {
      found = EpubStructure.collectNavTitles(extractDir, navHref, opfDir, index);
    }
    if (found.size === 0 && ncxHref.length > 0) {
      found = EpubStructure.collectNcxTitles(extractDir, ncxHref, opfDir, index);
    }
    for (let i = 0; i < titles.length; i++) {
      const fromToc = found.get(i);
      if (fromToc !== undefined && fromToc.length > 0) {
        titles[i] = fromToc;
      }
    }
    return titles;
  }

  private static buildHrefIndex(spineHrefs: string[]): EpubTocIndex {
    const byPath: Map<string, number> = new Map();
    const byName: Map<string, number> = new Map();
    for (let i = 0; i < spineHrefs.length; i++) {
      const key = spineHrefs[i].toLowerCase();
      byPath.set(key, i);
      const slash = key.lastIndexOf('/');
      const name = slash < 0 ? key : key.substring(slash + 1);
      if (!byName.has(name)) {
        byName.set(name, i);
      }
    }
    return { byPath: byPath, byName: byName };
  }

  private static collectNavTitles(extractDir: string, navHref: string, opfDir: string, index: EpubTocIndex): Map<number, string> {
    const titles: Map<number, string> = new Map();
    try {
      const navPath = BookFile.join(extractDir, BookFile.join(opfDir, navHref));
      const anchors = EpubXml.anchors(BookFile.readText(navPath));
      const tocDir = BookFile.dirName(navHref);
      for (let i = 0; i < anchors.length; i++) {
        EpubStructure.putTitle(titles, EpubStructure.resolveTocIndex(anchors[i].href, tocDir, index),
          anchors[i].text);
      }
    } catch (_error) {
      titles.clear();
    }
    return titles;
  }

  private static collectNcxTitles(extractDir: string, ncxHref: string, opfDir: string, index: EpubTocIndex): Map<number, string> {
    const titles: Map<number, string> = new Map();
    try {
      const ncx = BookFile.readText(BookFile.join(extractDir, BookFile.join(opfDir, ncxHref)));
      // 不能按下标配对：`<docTitle>` 的 `<text>` 没有对应 `<content src>`，会让整份目录错位一章。
      // 改为按文档顺序扫描，每个 `content src` 归属它前面最近的 `<text>`（navPoint 可嵌套，此法不受影响）。
      const labels = EpubStructure.matches(ncx, new RegExp('<text\\b[^>]*>([\\s\\S]*?)<\\/text\\s*>', 'gi'));
      const sources = EpubStructure.matches(ncx, new RegExp('<content\\b[^>]*\\bsrc\\s*=\\s*"([^"]+)"', 'gi'));
      const tocDir = BookFile.dirName(ncxHref);
      let labelIndex = 0;
      let currentLabel = '';
      for (let i = 0; i < sources.length; i++) {
        while (labelIndex < labels.length && labels[labelIndex].position < sources[i].position) {
          currentLabel = MarkupText.stripTags(labels[labelIndex].value);
          labelIndex++;
        }
        EpubStructure.putTitle(titles, EpubStructure.resolveTocIndex(sources[i].value, tocDir, index),
          currentLabel);
      }
    } catch (_error) {
      titles.clear();
    }
    return titles;
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
  private static resolveTocIndex(href: string, tocDir: string, index: EpubTocIndex): number {
    const clean = BookFile.normalizeHref(href);
    if (clean.length === 0) {
      return -1;
    }
    const candidates: string[] = [
      BookFile.normalizeHref(BookFile.join(tocDir, clean)).toLowerCase(),
      clean.toLowerCase(),
    ];
    for (let i = 0; i < candidates.length; i++) {
      const hit = index.byPath.get(candidates[i]);
      if (hit !== undefined) {
        return hit;
      }
    }
    const normalized = clean.toLowerCase();
    const slash = normalized.lastIndexOf('/');
    const byName = index.byName.get(slash < 0 ? normalized : normalized.substring(slash + 1));
    return byName === undefined ? -1 : byName;
  }
}

interface EpubTocIndex {
  byPath: Map<string, number>;
  byName: Map<string, number>;
}
