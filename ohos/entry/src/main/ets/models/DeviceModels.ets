/** 阅读设备、每格式阅读统计、推荐图书数据模型。字段对齐 webserver/models.py 与 handlers/book.py。 */

export interface ReadingDevice {
  name: string;
  type: string;
  ip: string;
  port: number;
  schema: string;
  mailbox: string;
  ftpUsername: string;
  ftpPassword: string;
  ftpPath: string;
}

export interface FormatReadingStat {
  format: string;
  state: number;
  totalSeconds: number;
  progressCurrent: number;
  progressTotal: number;
  progressPercent: number;
  startTime: string;
  finishTime: string;
  startCount: number;
  updateTime: string;
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

export function parseReadingDevice(raw: Record<string, Object>): ReadingDevice {
  return {
    name: asString(raw['name']),
    type: asString(raw['type'], 'kindle'),
    ip: asString(raw['ip']),
    port: asNumber(raw['port'], 12121),
    schema: asString(raw['schema'], 'http'),
    mailbox: asString(raw['mailbox']),
    ftpUsername: asString(raw['ftp_username']),
    ftpPassword: asString(raw['ftp_password']),
    ftpPath: asString(raw['ftp_path']),
  };
}

export function parseReadingDevices(raw: Object | undefined): ReadingDevice[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: ReadingDevice[] = [];
  for (let i = 0; i < list.length; i++) {
    result.push(parseReadingDevice(list[i]));
  }
  return result;
}

export function parseFormatStat(raw: Record<string, Object>): FormatReadingStat {
  return {
    format: asString(raw['format']),
    state: asNumber(raw['state']),
    totalSeconds: asNumber(raw['total_seconds']),
    progressCurrent: asNumber(raw['progress_current']),
    progressTotal: asNumber(raw['progress_total']),
    progressPercent: asNumber(raw['progress_percent']),
    startTime: asString(raw['start_time']),
    finishTime: asString(raw['finish_time']),
    startCount: asNumber(raw['start_count']),
    updateTime: asString(raw['update_time']),
  };
}

export function parseFormatStats(raw: Object | undefined): FormatReadingStat[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: FormatReadingStat[] = [];
  for (let i = 0; i < list.length; i++) {
    result.push(parseFormatStat(list[i]));
  }
  return result;
}

export function formatStatDuration(seconds: number): string {
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

export function deviceTypeLabel(type: string): string {
  if (type === 'kindle') {
    return 'Kindle';
  }
  if (type === 'duokan') {
    return '多看';
  }
  if (type === 'ireader') {
    return '掌阅';
  }
  if (type === 'hanwang') {
    return '汉王';
  }
  if (type === 'boox') {
    return '文石';
  }
  if (type === 'dangdang') {
    return '当当';
  }
  if (type === 'purelibro') {
    return 'PureLibro';
  }
  if (type === 'ftp') {
    return 'FTP';
  }
  if (type === 'koreader') {
    return 'KOReader';
  }
  return type;
}
