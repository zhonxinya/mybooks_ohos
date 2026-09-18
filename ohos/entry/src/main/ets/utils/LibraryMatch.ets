import { BookItem } from '../services/BookModels';

/**
 * SoNovel 搜索结果与书库藏书的同名判定。
 *
 * 用途：SoNovel 搜索页需要标出「这本书书库里已经有了」，判定口径为**书名 + 作者都相同**
 * （同名不同作者的书不算入库，例如《金枝》的多个版本）。
 *
 * 比对前先归一化：去掉空白（含全角空格）、书名号与大小写差异——书库里的书名常带
 * `《》` 或多余空格，直接字符串比较会把同一本书判成两本。
 *
 * 作者缺失时的取舍：任一侧没有作者信息时退化为只比书名。宁可少标也不要漏标——
 * 书源的 author 字段并非每个源都提供，此时若坚持比作者就永远标不出「已入库」。
 */

const AUTHOR_SEPARATORS: RegExp = /[、,，;；/|]+/;

/** 书名/作者归一化：去空白与书名号，统一小写。 */
export function normalizeName(raw: string): string {
  return raw
    .trim()
    .replace(/[\s\u3000]/g, '')
    .replace(/[《》]/g, '')
    .toLowerCase();
}

/** 作者串拆成可比对的词元（`张三、李四` → [`张三`, `李四`]）。 */
export function authorTokens(raw: string): string[] {
  const parts = raw.split(AUTHOR_SEPARATORS);
  const tokens: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const token = normalizeName(parts[i]);
    if (token.length > 0) {
      tokens.push(token);
    }
  }
  return tokens;
}

/**
 * 书库候选里是否存在同书。
 *
 * @param candidates 书库同名查询返回的候选（`GET /api/search?title=`）
 * @param title SoNovel 结果书名
 * @param author SoNovel 结果作者（可为空）
 */
export function hasSameBook(candidates: BookItem[], title: string, author: string): boolean {
  const targetTitle = normalizeName(title);
  if (targetTitle.length === 0) {
    return false;
  }
  const wanted = authorTokens(author);
  for (let i = 0; i < candidates.length; i++) {
    const candidate = candidates[i];
    if (normalizeName(candidate.title) !== targetTitle) {
      continue;
    }
    if (wanted.length === 0 || candidate.authors.length === 0) {
      return true;
    }
    for (let j = 0; j < candidate.authors.length; j++) {
      const have = authorTokens(candidate.authors[j]);
      for (let k = 0; k < have.length; k++) {
        if (wanted.indexOf(have[k]) >= 0) {
          return true;
        }
      }
    }
  }
  return false;
}
