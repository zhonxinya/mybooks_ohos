/** 书单（BookList）数据模型，字段对齐 webserver/handlers/booklist.py::_serialize。 */

export interface BookListOwner {
  id: number;
  username: string;
  avatar: string;
}

export interface BookListCoverBook {
  bookId: number;
  title: string;
  thumb: string;
  img: string;
}

export interface BookListSummary {
  id: number;
  name: string;
  description: string;
  color: string;
  isPublic: boolean;
  isSticky: boolean;
  viewCount: number;
  likeCount: number;
  bookCount: number;
  owner: BookListOwner | null;
  isOwner: boolean;
  likedByMe: boolean;
  coverBooks: BookListCoverBook[];
}

export interface BookListDetailData extends BookListSummary {
  books: BookListCoverBook[];
  booksTotal: number;
  page: number;
  pageSize: number;
}

/** 书籍详情页"快速加入书单"面板条目（/api/book/:id/booklists）。 */
export interface BookListQuickItem {
  id: number;
  name: string;
  color: string;
  isPublic: boolean;
  containsBook: boolean;
}

/** 书单颜色色板（8 色），对齐 docs/mybooks/app/src/utils/booklistColors.js。 */
export interface BookListColorOption {
  key: string;
  label: string;
  hex: string;
}

export const BOOKLIST_COLORS: BookListColorOption[] = [
  { key: 'marine', label: '海蓝', hex: '#1B6E8C' },
  { key: 'velvet', label: '丝绒', hex: '#7D3C5E' },
  { key: 'night_blue', label: '藏青', hex: '#1A2456' },
  { key: 'green', label: '翠绿', hex: '#2E7D32' },
  { key: 'yellow', label: '明黄', hex: '#F9A825' },
  { key: 'red', label: '赤红', hex: '#C62828' },
  { key: 'purple', label: '绛紫', hex: '#6A1B9A' },
  { key: 'orange', label: '橙橘', hex: '#EF6C00' },
];

export const DEFAULT_BOOKLIST_COLOR: string = 'marine';

export function booklistColorHex(key: string): string {
  for (let i = 0; i < BOOKLIST_COLORS.length; i++) {
    if (BOOKLIST_COLORS[i].key === key) {
      return BOOKLIST_COLORS[i].hex;
    }
  }
  return BOOKLIST_COLORS[0].hex;
}

function asString(value: Object | undefined | null, fallback: string = ''): string {
  if (value === undefined || value === null) {
    return fallback;
  }
  const text = String(value);
  return text === 'undefined' || text === 'null' ? fallback : text;
}

function asNumber(value: Object | undefined | null, fallback: number = 0): number {
  if (value === undefined || value === null) {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isNaN(parsed) ? fallback : parsed;
}

function asBool(value: Object | undefined | null): boolean {
  if (typeof value === 'boolean') {
    return value as boolean;
  }
  return asNumber(value, 0) > 0;
}

function parseOwner(raw: Object | undefined): BookListOwner | null {
  if (raw === undefined || raw === null) {
    return null;
  }
  const owner = raw as Record<string, Object>;
  return {
    id: asNumber(owner['id']),
    username: asString(owner['username']),
    avatar: asString(owner['avatar']),
  };
}

function parseCoverBooks(raw: Object | undefined): BookListCoverBook[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: BookListCoverBook[] = [];
  for (let i = 0; i < list.length; i++) {
    const item = list[i] as Record<string, Object>;
    result.push({
      bookId: asNumber(item['book_id']),
      title: asString(item['title']),
      thumb: asString(item['thumb']),
      img: asString(item['img']),
    });
  }
  return result;
}

export function parseBookListSummary(raw: Record<string, Object>): BookListSummary {
  return {
    id: asNumber(raw['id']),
    name: asString(raw['name']),
    description: asString(raw['description']),
    color: asString(raw['color'], DEFAULT_BOOKLIST_COLOR),
    isPublic: asBool(raw['is_public']),
    isSticky: asBool(raw['is_sticky']),
    viewCount: asNumber(raw['view_count']),
    likeCount: asNumber(raw['like_count']),
    bookCount: asNumber(raw['book_count']),
    owner: parseOwner(raw['owner']),
    isOwner: asBool(raw['is_owner']),
    likedByMe: asBool(raw['liked_by_me']),
    coverBooks: parseCoverBooks(raw['cover_books']),
  };
}

export function parseBookListSummaries(raw: Object | undefined): BookListSummary[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: BookListSummary[] = [];
  for (let i = 0; i < list.length; i++) {
    result.push(parseBookListSummary(list[i]));
  }
  return result;
}

export function parseBookListDetail(raw: Record<string, Object>): BookListDetailData {
  const summary = parseBookListSummary(raw);
  return {
    id: summary.id,
    name: summary.name,
    description: summary.description,
    color: summary.color,
    isPublic: summary.isPublic,
    isSticky: summary.isSticky,
    viewCount: summary.viewCount,
    likeCount: summary.likeCount,
    bookCount: summary.bookCount,
    owner: summary.owner,
    isOwner: summary.isOwner,
    likedByMe: summary.likedByMe,
    coverBooks: summary.coverBooks,
    books: parseCoverBooks(raw['books']),
    booksTotal: asNumber(raw['books_total']),
    page: asNumber(raw['page'], 1),
    pageSize: asNumber(raw['page_size'], 24),
  };
}

export function parseBookListQuickItems(raw: Object | undefined): BookListQuickItem[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: BookListQuickItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const item = list[i] as Record<string, Object>;
    result.push({
      id: asNumber(item['id']),
      name: asString(item['name']),
      color: asString(item['color'], DEFAULT_BOOKLIST_COLOR),
      isPublic: asBool(item['is_public']),
      containsBook: asBool(item['contains_book']),
    });
  }
  return result;
}
