import { MarkupText } from './MarkupText';

/**
 * EPUB 内部 XML（container.xml / OPF / NCX / nav）的轻量解析。
 *
 * 为什么用正则而不是 `@ohos.xml`：本 SDK（compatibleSdkVersion 17）的
 * `XmlPullParser`/`ParseInfo` **没有暴露属性读取**（仅有 getName/getText/getAttributeCount），
 * 而 OPF 必须读 `href`/`id`/`idref`/`media-type`。这些文件都由工具机生成、结构规整，
 * 且统一忽略命名空间前缀（`dc:` / `opf:`），正则可稳定覆盖。
 * 正则中的标签名/属性名均为内部常量，不含外部输入。
 */
export interface EpubAnchor {
  href: string;
  text: string;
}

export class EpubXml {
  /** 取出所有指定标签的原始串（忽略命名空间前缀，属性顺序无关）。 */
  static tags(xml: string, name: string): string[] {
    const pattern = new RegExp(`<\\s*(?:[A-Za-z0-9_.-]+:)?${name}\\b[^>]*>`, 'gi');
    const found: RegExpMatchArray | null = xml.match(pattern);
    return found === null ? [] : found;
  }

  /** 取属性值（单/双引号均支持，无该属性返回空串）。 */
  static attr(tag: string, name: string): string {
    const doubleQuoted = new RegExp(`\\b${name}\\s*=\\s*"([^"]*)"`, 'i').exec(tag);
    if (doubleQuoted !== null) {
      return doubleQuoted[1];
    }
    const singleQuoted = new RegExp(`\\b${name}\\s*=\\s*'([^']*)'`, 'i').exec(tag);
    if (singleQuoted !== null) {
      return singleQuoted[1];
    }
    return '';
  }

  /** 取首个同名标签的文本内容（去标签 + 解实体 + 折叠空白）。 */
  static firstText(xml: string, name: string): string {
    const openPattern = new RegExp(`<\\s*(?:[A-Za-z0-9_.-]+:)?${name}\\b[^>]*>`, 'i');
    const open: RegExpExecArray | null = openPattern.exec(xml);
    if (open === null) {
      return '';
    }
    const closePattern = new RegExp(`<\\/\\s*(?:[A-Za-z0-9_.-]+:)?${name}\\s*>`, 'i');
    const rest = xml.substring(open.index + open[0].length);
    const close: RegExpExecArray | null = closePattern.exec(rest);
    const raw = close === null ? rest : rest.substring(0, close.index);
    return MarkupText.stripTags(raw);
  }

  /** 按正则逐个取第 1 个捕获组（避免依赖 `String.matchAll`）。 */
  static captures(xml: string, pattern: RegExp): string[] {
    const results: string[] = [];
    let match: RegExpExecArray | null = pattern.exec(xml);
    while (match !== null) {
      results.push(match[1]);
      if (match.index === pattern.lastIndex) {
        pattern.lastIndex++;
      }
      match = pattern.exec(xml);
    }
    return results;
  }

  /** 取 nav 文档中的超链接（href + 文案）。 */
  static anchors(html: string): EpubAnchor[] {
    const pattern = new RegExp('<a\\b[^>]*href\\s*=\\s*"([^"]+)"[^>]*>([\\s\\S]*?)<\\/a\\s*>', 'gi');
    const anchors: EpubAnchor[] = [];
    let match: RegExpExecArray | null = pattern.exec(html);
    while (match !== null) {
      anchors.push({ href: match[1], text: MarkupText.stripTags(match[2]) });
      if (match.index === pattern.lastIndex) {
        pattern.lastIndex++;
      }
      match = pattern.exec(html);
    }
    return anchors;
  }
}
