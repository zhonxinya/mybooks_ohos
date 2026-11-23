/**
 * 轻量 Markdown 解析（AI 回复排版子集），纯函数、无 ArkUI 依赖，可离线回归。
 * 支持：标题 #~####、无序/有序列表、围栏代码块、引用、表格、分隔线、
 * 行内 **粗体**、*斜体*、`代码`、[链接](url)（着色+保留 href 供渲染层出可点链接清单）。
 */

export interface MdInline {
  text: string;
  /** 0 普通 1 粗体 2 行内代码 3 链接 4 斜体 5 打字光标（#1622，渲染层控颜色闪烁） */
  style: number;
  /** style=3 链接目标 url（#1511 起解析保留） */
  href?: string;
}

export interface MdBlock {
  /** p | h | ul | ol | quote | code | table | hr */
  kind: string;
  /** 标题级别（h）；有序列表起始序号（ol，恒 1） */
  level: number;
  /** 每行一组行内段：p 为多行、h 取 [0]、ul/ol/quote 每项一行 */
  segs: MdInline[][];
  /** code 块原文 */
  raw: string;
  /** table 行×列（表头为首行） */
  rows: string[][];
}

export function mdParseInline(line: string): MdInline[] {
  const out: MdInline[] = [];
  let buf = '';
  let i = 0;
  while (i < line.length) {
    const c = line.charAt(i);
    if (c === '`') {
      const end = line.indexOf('`', i + 1);
      if (end > i) {
        if (buf.length > 0) { out.push({ text: buf, style: 0 }); buf = ''; }
        out.push({ text: line.substring(i + 1, end), style: 2 });
        i = end + 1;
        continue;
      }
    }
    if (c === '*' && line.charAt(i + 1) === '*') {
      const end = line.indexOf('**', i + 2);
      if (end > i) {
        if (buf.length > 0) { out.push({ text: buf, style: 0 }); buf = ''; }
        out.push({ text: line.substring(i + 2, end), style: 1 });
        i = end + 2;
        continue;
      }
    }
    if (c === '[') {
      const mid = line.indexOf('](', i);
      if (mid > i) {
        const close = line.indexOf(')', mid + 2);
        if (close > mid) {
          if (buf.length > 0) { out.push({ text: buf, style: 0 }); buf = ''; }
          out.push({ text: line.substring(i + 1, mid), style: 3,
            href: line.substring(mid + 2, close).trim() });
          i = close + 1;
          continue;
        }
      }
    }
    if (c === '*' && line.charAt(i + 1) !== '*') {
      const end = line.indexOf('*', i + 1);
      if (end > i) {
        if (buf.length > 0) { out.push({ text: buf, style: 0 }); buf = ''; }
        out.push({ text: line.substring(i + 1, end), style: 4 });
        i = end + 1;
        continue;
      }
    }
    buf += c;
    i++;
  }
  if (buf.length > 0) { out.push({ text: buf, style: 0 }); }
  return out;
}

function splitTableRow(trimmed: string): string[] {
  let inner = trimmed;
  if (inner.startsWith('|')) { inner = inner.substring(1); }
  if (inner.endsWith('|')) { inner = inner.substring(0, inner.length - 1); }
  const cells = inner.split('|');
  const out: string[] = [];
  for (const cell of cells) { out.push(cell.trim()); }
  return out;
}

function isSeparatorRow(trimmed: string): boolean {
  if (!trimmed.startsWith('|')) { return false; }
  const body = trimmed.replace(/[|:\-\s]/g, '');
  return body.length === 0 && trimmed.indexOf('-') >= 0;
}

export function mdParseBlocks(content: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  const lines = content.split('\n');
  let para: string[] = [];
  let inCode = false;
  let codeLines: string[] = [];
  const flushPara = (): void => {
    if (para.length === 0) { return; }
    const segs: MdInline[][] = [];
    for (const l of para) { segs.push(mdParseInline(l)); }
    blocks.push({ kind: 'p', level: 0, segs: segs, raw: '', rows: [] });
    para = [];
  };
  let i = 0;
  while (i < lines.length) {
    const trimmed = lines[i].trim();
    if (trimmed.startsWith('```')) {
      if (inCode) {
        blocks.push({ kind: 'code', level: 0, segs: [], raw: codeLines.join('\n'), rows: [] });
        codeLines = [];
        inCode = false;
      } else {
        flushPara();
        inCode = true;
      }
      i++;
      continue;
    }
    if (inCode) { codeLines.push(lines[i]); i++; continue; }
    if (trimmed.length === 0) { flushPara(); i++; continue; }

    // 表格：连续 | 行
    if (trimmed.startsWith('|') && trimmed.endsWith('|')) {
      const rows: string[][] = [];
      while (i < lines.length) {
        const t = lines[i].trim();
        if (!t.startsWith('|')) { break; }
        if (!isSeparatorRow(t)) { rows.push(splitTableRow(t)); }
        i++;
      }
      if (rows.length > 0) {
        blocks.push({ kind: 'table', level: 0, segs: [], raw: '', rows: rows });
      }
      continue;
    }

    // 分隔线
    if (/^(-{3,}|\*{3,})$/.test(trimmed)) {
      flushPara();
      blocks.push({ kind: 'hr', level: 0, segs: [], raw: '', rows: [] });
      i++;
      continue;
    }

    // 标题
    if (trimmed.startsWith('#')) {
      let level = 0;
      while (level < trimmed.length && level < 4 && trimmed.charAt(level) === '#') { level++; }
      if (level < trimmed.length && trimmed.charAt(level) === ' ') {
        flushPara();
        blocks.push({ kind: 'h', level: level, segs: [mdParseInline(trimmed.substring(level + 1).trim())], raw: '', rows: [] });
        i++;
        continue;
      }
    }

    // 引用
    if (trimmed.startsWith('>')) {
      flushPara();
      const segs: MdInline[][] = [];
      while (i < lines.length) {
        const t = lines[i].trim();
        if (!t.startsWith('>')) { break; }
        segs.push(mdParseInline(t.substring(1).trim()));
        i++;
      }
      blocks.push({ kind: 'quote', level: 0, segs: segs, raw: '', rows: [] });
      continue;
    }

    // 无序列表
    if (/^[-*+]\s+/.test(trimmed)) {
      flushPara();
      const segs: MdInline[][] = [];
      while (i < lines.length) {
        const t = lines[i].trim();
        if (!/^[-*+]\s+/.test(t)) { break; }
        segs.push(mdParseInline(t.substring(2).trim()));
        i++;
      }
      blocks.push({ kind: 'ul', level: 0, segs: segs, raw: '', rows: [] });
      continue;
    }

    // 有序列表
    if (/^\d+\.\s+/.test(trimmed)) {
      flushPara();
      const segs: MdInline[][] = [];
      while (i < lines.length) {
        const t = lines[i].trim();
        if (!/^\d+\.\s+/.test(t)) { break; }
        const dot = t.indexOf('.');
        segs.push(mdParseInline(t.substring(dot + 1).trim()));
        i++;
      }
      blocks.push({ kind: 'ol', level: 1, segs: segs, raw: '', rows: [] });
      continue;
    }

    para.push(trimmed);
    i++;
  }
  flushPara();
  if (inCode) {
    blocks.push({ kind: 'code', level: 0, segs: [], raw: codeLines.join('\n'), rows: [] });
  }
  return blocks;
}

/**
 * 打字光标注入（#1622）：把光标 seg（style=5，文本恒为 '▌'）追加到末块尾行行尾。
 * 闪烁由渲染层切换颜色实现——宽度恒占，光标绝不影响文本布局，
 * 根治旧实现「把 ▌ 拼进 content 致每 530ms 长度±1：末行回绕抖动 + 段落整体重建」。
 * 仅注入走 inlineText 的块（p/ul/ol/quote）；h/code/table/hr 或空文档不注入
 * （标题分支不带颜色逻辑会显黑光标；流式收尾恰在代码/表格内时宁可不显示光标，
 * 也不污染其解析结果）。
 */
export function mdAppendCaret(blocks: MdBlock[]): void {
  if (blocks.length === 0) {
    return;
  }
  const last: MdBlock = blocks[blocks.length - 1];
  if (last.kind !== 'p' && last.kind !== 'ul' && last.kind !== 'ol' && last.kind !== 'quote') {
    return;
  }
  const lines: MdInline[][] = last.segs;
  if (lines.length === 0) {
    return;
  }
  const tail: MdInline[] = lines[lines.length - 1];
  tail.push({ text: '▌', style: 5 });
}

/** 链接展示用主机名：去协议与路径（https://a.b/c?d → a.b），供可点链接清单副标。 */
export function linkHost(url: string): string {
  const noProto: string = url.startsWith('http://') ? url.substring(7) :
    (url.startsWith('https://') ? url.substring(8) : url);
  const end = noProto.search('[/?#]');
  return end > 0 ? noProto.substring(0, end) : noProto;
}

/**
 * 从块行内段收集可点链接（#1511）：Span 无点击事件，渲染层把链接收成分离清单统一点开。
 * 同 url 去重（引用重复出现只列一次），无 href 的旧样式段跳过。
 */
export function collectLinks(lines: MdInline[][]): MdInline[] {
  const seen: string[] = [];
  const out: MdInline[] = [];
  for (const line of lines) {
    for (const seg of line) {
      if (seg.style === 3 && seg.href !== undefined && seg.href.length > 0 && seen.indexOf(seg.href) < 0) {
        seen.push(seg.href);
        out.push(seg);
      }
    }
  }
  return out;
}
