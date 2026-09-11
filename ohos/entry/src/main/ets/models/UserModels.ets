/** 用户中心数据模型：留言、求书期望。字段对齐 webserver/handlers/user.py。 */

export interface UserMemoItem {
  id: number;
  readerId: number;
  readerName: string;
  memo: string;
  memoType: number;
  reply: string;
  stage: string;
  createDate: string;
  updateDate: string;
}

export interface ExpectedItemModel {
  id: number;
  title: string;
  author: string;
  publisher: string;
  createTime: string;
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

export function parseUserMemo(raw: Record<string, Object>): UserMemoItem {
  return {
    id: asNumber(raw['id']),
    readerId: asNumber(raw['reader_id']),
    readerName: asString(raw['reader_name']),
    memo: asString(raw['memo']),
    memoType: asNumber(raw['memo_type']),
    reply: asString(raw['reply']),
    stage: asString(raw['stage']),
    createDate: asString(raw['create_date']),
    updateDate: asString(raw['update_date']),
  };
}

export function parseUserMemos(raw: Object | undefined): UserMemoItem[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: UserMemoItem[] = [];
  for (let i = 0; i < list.length; i++) {
    result.push(parseUserMemo(list[i]));
  }
  return result;
}

export function parseExpectedItem(raw: Record<string, Object>): ExpectedItemModel {
  return {
    id: asNumber(raw['id']),
    title: asString(raw['title']),
    author: asString(raw['author']),
    publisher: asString(raw['publisher']),
    createTime: asString(raw['create_time']),
  };
}

export function parseExpectedItems(raw: Object | undefined): ExpectedItemModel[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: ExpectedItemModel[] = [];
  for (let i = 0; i < list.length; i++) {
    result.push(parseExpectedItem(list[i]));
  }
  return result;
}

export function memoTypeLabel(type: number): string {
  if (type === 1) {
    return '求书';
  }
  if (type === 2) {
    return '求助';
  }
  return '建议';
}

export function memoStageLabel(stage: string): string {
  if (stage === 'done') {
    return '已完成';
  }
  if (stage === 'suspend') {
    return '已搁置';
  }
  return '待处理';
}
