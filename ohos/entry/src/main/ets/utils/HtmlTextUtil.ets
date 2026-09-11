const HTML_TAG_PATTERN: RegExp = /<[^>]+>/g;
const WHITESPACE_PATTERN: RegExp = /\s+/g;
const CHUNK_MAX_LEN: number = 1500;

const HTML_ENTITIES: Record<string, string> = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': '\'',
  '&apos;': '\'',
};

export class HtmlTextUtil {
  static stripHtml(html: string): string {
    if (html.length === 0) {
      return '';
    }
    let text = html.replace(HTML_TAG_PATTERN, ' ');
    const keys = Object.keys(HTML_ENTITIES);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      text = text.split(key).join(HTML_ENTITIES[key]);
    }
    text = text.replace(/&#(\d+);/g, (_match: string, code: string) => {
      const num = Number(code);
      return Number.isNaN(num) ? '' : String.fromCharCode(num);
    });
    return HtmlTextUtil.normalizeText(text);
  }

  static normalizeText(text: string): string {
    return text.replace(WHITESPACE_PATTERN, ' ').trim();
  }

  /** 转义正则元字符，使外部数据只能作为字面量参与匹配。 */
  private static escapeRegExp(value: string): string {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  static sliceFromDomPos(html: string, domPos: string): string | null {
    const index = HtmlTextUtil.indexOfDomPos(html, domPos);
    return index >= 0 ? html.substring(index) : null;
  }

  /** 截取 [startDomPos, endDomPos) 区间；endDomPos 缺失或早于起点时截到内容末尾。 */
  static sliceBetweenDomPos(html: string, startDomPos: string, endDomPos: string): string | null {
    const startIndex = HtmlTextUtil.indexOfDomPos(html, startDomPos);
    if (startIndex < 0) {
      return null;
    }
    const endIndex = HtmlTextUtil.indexOfDomPos(html, endDomPos);
    if (endIndex <= startIndex) {
      return html.substring(startIndex);
    }
    return html.substring(startIndex, endIndex);
  }

  private static indexOfDomPos(html: string, domPos: string): number {
    if (html.length === 0 || domPos.length === 0) {
      return -1;
    }
    const anchorId = HtmlTextUtil.resolveDomAnchorId(domPos);
    if (anchorId.length === 0) {
      return -1;
    }
    // domPos 来自服务端同步的阅读进度（或路由参数），属外部可控数据：
    // 必须转义后才能拼进 RegExp，否则可触发正则注入/回溯耗尽（ReDoS）或 SyntaxError。
    const safeId = HtmlTextUtil.escapeRegExp(anchorId);
    const patterns: RegExp[] = [
      new RegExp(`id=["']${safeId}["']`, 'i'),
      new RegExp(`name=["']${safeId}["']`, 'i'),
    ];
    for (let i = 0; i < patterns.length; i++) {
      const match = patterns[i].exec(html);
      if (match !== null && match.index !== undefined) {
        return match.index;
      }
    }
    return html.indexOf(anchorId);
  }

  static chunkText(text: string, maxLen: number = CHUNK_MAX_LEN): string[] {
    const normalized = HtmlTextUtil.normalizeText(text);
    if (normalized.length === 0) {
      return [];
    }
    if (normalized.length <= maxLen) {
      return [normalized];
    }
    const paragraphs = normalized.split(/\n+/).map((part: string) => part.trim()).filter((part: string) => part.length > 0);
    const units: string[] = paragraphs.length > 0 ? paragraphs : [normalized];
    const chunks: string[] = [];
    let current = '';
    for (let i = 0; i < units.length; i++) {
      let unit = units[i];
      while (unit.length > maxLen) {
        const splitAt = HtmlTextUtil.findSplitIndex(unit, maxLen);
        if (current.length > 0) {
          chunks.push(current);
          current = '';
        }
        chunks.push(unit.substring(0, splitAt).trim());
        unit = unit.substring(splitAt).trim();
      }
      const candidate = current.length > 0 ? `${current} ${unit}` : unit;
      if (candidate.length <= maxLen) {
        current = candidate;
      } else {
        if (current.length > 0) {
          chunks.push(current);
        }
        current = unit;
      }
    }
    if (current.length > 0) {
      chunks.push(current);
    }
    return chunks.filter((chunk: string) => chunk.length > 0);
  }

  private static resolveDomAnchorId(domPos: string): string {
    const trimmed = domPos.trim();
    if (trimmed.length === 0) {
      return '';
    }
    if (trimmed.startsWith('{')) {
      try {
        const parsed = JSON.parse(trimmed) as Record<string, Object>;
        const idValue = parsed['id'] ?? parsed['dataId'] ?? parsed['nodeId'];
        if (idValue !== undefined && idValue !== null) {
          return String(idValue);
        }
      } catch (_error) {
      }
    }
    if (trimmed.includes('=')) {
      const parts = trimmed.split('=');
      return parts[parts.length - 1].trim();
    }
    return trimmed;
  }

  private static findSplitIndex(text: string, maxLen: number): number {
    const preferred = ['。', '！', '？', '；', '.', '!', '?', ';', '，', ',', ' '];
    for (let i = 0; i < preferred.length; i++) {
      const index = text.lastIndexOf(preferred[i], maxLen);
      if (index > maxLen * 0.4) {
        return index + 1;
      }
    }
    return maxLen;
  }
}
