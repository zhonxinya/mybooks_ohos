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
/** `<img src=...>` 与 SVG `<image xlink:href=...>`（EPUB 封面常用后者）。 */
const IMAGE_TAG_PATTERN: RegExp = /<(?:img|image)\b[^>]*>/gi;
/** 块级标签（`br` 单独处理，它只是行内换行）。 */
const BLOCK_PATTERN: RegExp =
  /<\/?(?:p|div|hr|li|ul|ol|tr|td|th|table|h[1-6]|section|article|blockquote|figure|figcaption|pre|body|html|svg)\b[^>]*>/gi;
const BR_PATTERN: RegExp = /<br\b[^>]*>/gi;
const TAG_PATTERN: RegExp = /<[^>]*>/g;
/** 空白（含源码硬换行）→ 单空格。 */
const WHITESPACE_PATTERN: RegExp = /\s+/g;
/** 行首缩进（CJK 常用全角空格）判定：先去掉换行，再看是否以空白开头。 */
const LEADING_NEWLINE_PATTERN: RegExp = /^[\r\n]+/;
const LEADING_INDENT_PATTERN: RegExp = /^[ \t\u00a0\u3000]/;
/** 句末标点：遇到它才算「一段说完」。 */
const SENTENCE_END_CHARS: string = '。！？；…!?;:.';
const TRAILING_QUOTE_CHARS: string = '”"』」\'';
/** 块级边界占位符（正文里不可能出现，避免与源码换行混淆）。 */
const BLOCK_BREAK: string = '\u0000';
/** 行内换行占位符。 */
const LINE_BREAK: string = '\u0001';
/** 图片占位符：`<IMAGE_BREAK>序号<IMAGE_BREAK>`，插入在文档原位置。 */
const IMAGE_BREAK: string = '\u0002';

/** 解析出的块：文本或图片（图片待调用方解析为绝对路径）。 */
export interface ParsedBlock {
  /** true = 图片。 */
  isImage: boolean;
  text: string;
  /** 图片的相对引用（未做路径解析）。 */
  src: string;
  alt: string;
}

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
  /**
   * XHTML → 段落数组。
   *
   * 分段规则：
   * - **块级标签**（`p`/`div`/`h1`…）= 段落边界；
   * - **`<br/>` 不一定是段落**：大量中文 EPUB（含 Gutenberg）用 `<br/>` 做 40 字硬折行，
   *   一律当段边界会把一句话切成好几段。故仅当上一行以句末标点结尾、或下一行本身带
   *   缩进（TXT 转 EPUB 的常见写法）时才算新段，否则视为折行拼回同一段。
   */
  static toParagraphs(markup: string): string[] {
    const blocks: ParsedBlock[] = MarkupText.toBlocks(markup);
    const paragraphs: string[] = [];
    for (let i = 0; i < blocks.length; i++) {
      if (!blocks[i].isImage && blocks[i].text.length > 0) {
        paragraphs.push(blocks[i].text);
      }
    }
    return paragraphs;
  }

  /**
   * XHTML → 有序块（文本段落 + 图片）。
   *
   * 图片标签先在原位置替换成占位符，最后再还原成图片块，
   * 这样插图能落在文档里的正确位置（而不是被丢在章首或章尾）。
   */
  static toBlocks(markup: string): ParsedBlock[] {
    if (markup.length === 0) {
      return [];
    }
    const images: ParsedBlock[] = [];
    let text: string = markup.replace(IMAGE_TAG_PATTERN, (tag: string) => {
      const src: string = MarkupText.imageSrc(tag);
      if (src.length === 0) {
        return ' ';
      }
      images.push({ isImage: true, text: '', src: src, alt: MarkupText.attr(tag, 'alt') });
      return `${IMAGE_BREAK}${images.length - 1}${IMAGE_BREAK}`;
    });
    text = text.replace(SCRIPT_PATTERN, BLOCK_BREAK);
    text = text.replace(STYLE_PATTERN, BLOCK_BREAK);
    text = text.replace(HEAD_PATTERN, BLOCK_BREAK);
    text = text.replace(COMMENT_PATTERN, BLOCK_BREAK);
    text = text.replace(BLOCK_PATTERN, BLOCK_BREAK);
    text = text.replace(BR_PATTERN, LINE_BREAK);
    text = text.replace(TAG_PATTERN, '');
    text = MarkupText.decodeEntities(text);
    const blocks: ParsedBlock[] = [];
    const parts: string[] = text.split(BLOCK_BREAK);
    for (let i = 0; i < parts.length; i++) {
      MarkupText.appendPartBlocks(parts[i], images, blocks);
    }
    return blocks;
  }

  /** 处理一个块级片段：其中可能夹着图片占位符。 */
  private static appendPartBlocks(part: string, images: ParsedBlock[], blocks: ParsedBlock[]): void {
    const pieces: string[] = part.split(IMAGE_BREAK);
    for (let i = 0; i < pieces.length; i++) {
      if (i % 2 === 1) {
        const index: number = Number(pieces[i]);
        if (!Number.isNaN(index) && index >= 0 && index < images.length) {
          blocks.push(images[index]);
        }
        continue;
      }
      MarkupText.appendTextPieces(pieces[i], blocks);
    }
  }

  /** 处理一段纯文本：按 `<br/>` 折行合并/断段，产出 0..n 个文本块。 */
  private static appendTextPieces(block: string, blocks: ParsedBlock[]): void {
    const lines: string[] = block.split(LINE_BREAK);
    let current: string = '';
    for (let i = 0; i < lines.length; i++) {
      const raw: string = lines[i];
      const piece: string = MarkupText.collapse(raw);
      if (piece.length === 0) {
        continue;
      }
      if (current.length === 0) {
        current = piece;
        continue;
      }
      if (MarkupText.startsNewParagraph(current, raw)) {
        blocks.push({ isImage: false, text: current, src: '', alt: '' });
        current = piece;
      } else {
        current = MarkupText.joinWrapped(current, piece);
      }
    }
    if (current.length > 0) {
      blocks.push({ isImage: false, text: current, src: '', alt: '' });
    }
  }

  /** 取图片引用：`src` 或 `xlink:href` / `href`（SVG `<image>`）。 */
  private static imageSrc(tag: string): string {
    const src: string = MarkupText.attr(tag, 'src');
    if (src.length > 0) {
      return src;
    }
    const xlink: string = MarkupText.attr(tag, 'xlink:href');
    if (xlink.length > 0) {
      return xlink;
    }
    return MarkupText.attr(tag, 'href');
  }

  /** 取标签属性（单/双引号都支持）。 */
  private static attr(tag: string, name: string): string {
    const doubleQuoted = new RegExp(`\\b${name}\\s*=\\s*"([^"]*)"`, 'i').exec(tag);
    if (doubleQuoted !== null) {
      return doubleQuoted[1];
    }
    const singleQuoted = new RegExp(`\\b${name}\\s*=\\s*'([^']*)'`, 'i').exec(tag);
    return singleQuoted === null ? '' : singleQuoted[1];
  }

  /** 上一行以句末标点结尾，或下一行（去掉换行后）带缩进 → 新段。 */
  private static startsNewParagraph(left: string, rawRight: string): boolean {
    if (MarkupText.endsSentence(left)) {
      return true;
    }
    const afterNewline: string = rawRight.replace(LEADING_NEWLINE_PATTERN, '');
    return afterNewline.length > 0 && LEADING_INDENT_PATTERN.test(afterNewline);
  }

  private static endsSentence(text: string): boolean {
    let end: number = text.length - 1;
    while (end >= 0 && TRAILING_QUOTE_CHARS.indexOf(text.charAt(end)) >= 0) {
      end--;
    }
    return end >= 0 && SENTENCE_END_CHARS.indexOf(text.charAt(end)) >= 0;
  }

  /** 折行拼接：中文直接相连，西文补一个空格。 */
  private static joinWrapped(left: string, right: string): string {
    const cjkAdjacent: boolean = MarkupText.isCjk(left.charCodeAt(left.length - 1)) ||
      MarkupText.isCjk(right.charCodeAt(0));
    return cjkAdjacent ? `${left}${right}` : `${left} ${right}`;
  }

  /** CJK 及中文标点区间。 */
  private static isCjk(code: number): boolean {
    return (code >= 0x3000 && code <= 0x303F) ||
      (code >= 0x3400 && code <= 0x4DBF) ||
      (code >= 0x4E00 && code <= 0x9FFF) ||
      (code >= 0xF900 && code <= 0xFAFF) ||
      (code >= 0xFF00 && code <= 0xFFEF);
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

  /** 空白折叠为单空格并去首尾（换行也算空白）。 */
  private static collapse(text: string): string {
    return text.replace(WHITESPACE_PATTERN, ' ').trim();
  }
}
