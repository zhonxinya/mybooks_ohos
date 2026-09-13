/**
 * 标记文本（EPUB 的 XHTML）转纯文本段落。
 *
 * 本模块独立于 entry，故不复用 entry 的 `HtmlTextUtil`：那里服务于 ReaderKit 的
 * TTS 分段，语义（按 1500 字切块）与本处（按块级标签分段）不同。
 */
const SCRIPT_PATTERN: RegExp = /<script\b[^>]*>[\s\S]*?<\/script\s*>/gi;
const STYLE_PATTERN: RegExp = /<style\b[^>]*>[\s\S]*?<\/style\s*>/gi;
const HEAD_PATTERN: RegExp = /<head\b[^>]*>[\s\S]*?<\/head\s*>/gi;
const COMMENT_PATTERN: RegExp = /<!--[\s\S]*?-->/g;
const BLOCK_PATTERN: RegExp =
  /<\/?(?:p|div|br|hr|li|ul|ol|tr|td|th|table|h[1-6]|section|article|blockquote|figure|figcaption|pre|body|html)\b[^>]*>/gi;
const TAG_PATTERN: RegExp = /<[^>]*>/g;
const WHITESPACE_PATTERN: RegExp = /[ \t\r\f\v\u00a0\u3000]+/g;

const NAMED_ENTITIES: Record<string, string> = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': '\'',
  '&mdash;': '—',
  '&ndash;': '–',
  '&hellip;': '…',
  '&ldquo;': '“',
  '&rdquo;': '”',
  '&lsquo;': '‘',
  '&rsquo;': '’',
};

export class MarkupText {
  /** XHTML → 段落数组（块级标签断段，行内标签丢弃）。 */
  static toParagraphs(markup: string): string[] {
    if (markup.length === 0) {
      return [];
    }
    let text = markup.replace(SCRIPT_PATTERN, ' ');
    text = text.replace(STYLE_PATTERN, ' ');
    text = text.replace(HEAD_PATTERN, ' ');
    text = text.replace(COMMENT_PATTERN, ' ');
    text = text.replace(BLOCK_PATTERN, '\n');
    text = text.replace(TAG_PATTERN, '');
    text = MarkupText.decodeEntities(text);
    const lines: string[] = text.split('\n');
    const paragraphs: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = MarkupText.collapse(lines[i]);
      if (line.length > 0) {
        paragraphs.push(line);
      }
    }
    return paragraphs;
  }

  /** 去标签 + 解实体 + 折叠空白，用于取标签内的一句文案（非分段）。 */
  static stripTags(raw: string): string {
    return MarkupText.collapse(MarkupText.decodeEntities(raw.replace(TAG_PATTERN, ' ')));
  }

  /** 解码 HTML 实体（命名实体 + 十进制/十六进制数值实体）。 */
  static decodeEntities(text: string): string {
    let result = text;
    const keys: string[] = Object.keys(NAMED_ENTITIES);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      if (result.indexOf(key) >= 0) {
        result = result.split(key).join(NAMED_ENTITIES[key]);
      }
    }
    result = result.replace(/&#x([0-9a-fA-F]+);/g, (_match: string, hex: string) => {
      const code = Number.parseInt(hex, 16);
      return Number.isNaN(code) ? '' : String.fromCharCode(code);
    });
    result = result.replace(/&#(\d+);/g, (_match: string, dec: string) => {
      const code = Number.parseInt(dec, 10);
      return Number.isNaN(code) ? '' : String.fromCharCode(code);
    });
    return result;
  }

  /** 行内空白折叠为单空格并去首尾（不跨行，段边界已由换行确定）。 */
  private static collapse(line: string): string {
    return line.replace(WHITESPACE_PATTERN, ' ').trim();
  }
}
