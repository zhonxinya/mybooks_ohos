/** 首页板块数据模型：阅读统计、阅读时长横幅、首页书籍（随机/社交推荐）。 */

export interface ReadingStatsSummary {
  totalReading: number;
  totalReadDone: number;
  monthReading: number;
  monthReadDone: number;
}

export interface WeeklyBucket {
  weekStart: string;
  readingSeconds: number;
  downloadCount: number;
  pushCount: number;
}

export interface ReadingDashboard {
  enabled: boolean;
  totalReadingSeconds: number;
  downloadCount: number;
  pushCount: number;
  weekly: WeeklyBucket[];
  statusReading: number;
  statusToRead: number;
  statusFinished: number;
}

export interface BookRecommender {
  nickname: string;
  avatar: string;
}

export interface HomeBook {
  id: number;
  title: string;
  author: string;
  cover: string;
  recommender: BookRecommender | null;
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

export function parseReadingStatsSummary(stats: Record<string, Object>): ReadingStatsSummary {
  return {
    totalReading: asNumber(stats['total_reading']),
    totalReadDone: asNumber(stats['total_read_done']),
    monthReading: asNumber(stats['month_reading']),
    monthReadDone: asNumber(stats['month_read_done']),
  };
}

export function parseReadingDashboard(body: Record<string, Object>): ReadingDashboard {
  const totals = (body['totals'] as Record<string, Object> | undefined) ?? {};
  const status = (body['book_status'] as Record<string, Object> | undefined) ?? {};
  const weeklyRaw = (body['weekly'] as Array<Record<string, Object>> | undefined) ?? [];
  const weekly: WeeklyBucket[] = [];
  for (let i = 0; i < weeklyRaw.length; i++) {
    const item = weeklyRaw[i];
    weekly.push({
      weekStart: asString(item['week_start']),
      readingSeconds: asNumber(item['reading_seconds']),
      downloadCount: asNumber(item['download_count']),
      pushCount: asNumber(item['push_count']),
    });
  }
  return {
    enabled: body['enabled'] === true,
    totalReadingSeconds: asNumber(totals['total_reading_seconds']),
    downloadCount: asNumber(totals['download_count']),
    pushCount: asNumber(totals['push_count']),
    weekly: weekly,
    statusReading: asNumber(status['reading']),
    statusToRead: asNumber(status['to_read']),
    statusFinished: asNumber(status['finished']),
  };
}

export function parseHomeBook(raw: Record<string, Object>): HomeBook {
  let recommender: BookRecommender | null = null;
  const recRaw = raw['recommender'] as Record<string, Object> | undefined;
  if (recRaw !== undefined) {
    recommender = {
      nickname: asString(recRaw['nickname']),
      avatar: asString(recRaw['avatar']),
    };
  }
  return {
    id: asNumber(raw['id']),
    title: asString(raw['title'], '未知'),
    author: asString(raw['author']),
    cover: asString(raw['cover'] ?? raw['cover_url'] ?? raw['img']),
    recommender: recommender,
  };
}

export function parseHomeBooks(raw: Object | undefined): HomeBook[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: HomeBook[] = [];
  for (let i = 0; i < list.length; i++) {
    result.push(parseHomeBook(list[i]));
  }
  return result;
}

export function formatDuration(seconds: number): string {
  if (seconds <= 0) {
    return '0 分钟';
  }
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours <= 0) {
    return `${minutes} 分钟`;
  }
  return `${hours} 小时 ${minutes} 分`;
}
