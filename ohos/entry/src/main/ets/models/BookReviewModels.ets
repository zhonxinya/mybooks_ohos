/** 书评与社交统计数据模型，字段对齐 webserver/handlers/book_review.py。 */

export interface BookReviewItem {
  id: number;
  bookId: number;
  readerId: number;
  nickname: string;
  avatar: string;
  rating: number;
  comment: string;
  status: string;
  updateTime: string;
  isOwn: boolean;
}

export interface BookSocialStats {
  readingCount: number;
  finishedCount: number;
  favoriteCount: number;
  recommendCount: number;
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

export function parseBookReview(raw: Record<string, Object>): BookReviewItem {
  return {
    id: asNumber(raw['id']),
    bookId: asNumber(raw['book_id']),
    readerId: asNumber(raw['reader_id']),
    nickname: asString(raw['nickname']),
    avatar: asString(raw['avatar']),
    rating: asNumber(raw['rating']),
    comment: asString(raw['comment']),
    status: asString(raw['status']),
    updateTime: asString(raw['update_time']),
    isOwn: raw['is_own'] === true,
  };
}

export function parseBookReviews(raw: Object | undefined): BookReviewItem[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: BookReviewItem[] = [];
  for (let i = 0; i < list.length; i++) {
    result.push(parseBookReview(list[i]));
  }
  return result;
}

export function parseSocialStats(body: Record<string, Object>): BookSocialStats {
  return {
    readingCount: asNumber(body['reading_count']),
    finishedCount: asNumber(body['finished_count']),
    favoriteCount: asNumber(body['favorite_count']),
    recommendCount: asNumber(body['recommend_count']),
  };
}
