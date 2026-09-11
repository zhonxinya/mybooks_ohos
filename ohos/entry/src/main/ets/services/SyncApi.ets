import { TalebookCoreService } from './TalebookCoreService';

/**
 * `/api/sync` 系列端点的强类型封装（mybooks 专有）。
 * 参考源码：`docs/mybooks/webserver/handlers/sync.py` 与
 * `docs/mybooks/webserver/services/sync_service.py`（逐项核对上游，勿凭印象改动）。
 *
 * 端点与参数：
 * - `GET  /api/sync?since=&type=&book=&own=` 拉取增量。`since` 必填（时间戳，非数字报 params.invalid）；
 *   `type` 可选（books|notes|configs，缺省返回全部 kind）；`book` 可选（book_hash，限制单本书）；
 *   `own` 可选（缺省 1，仅返回自己的记录；0 时额外并入同书其他用户的共享批注，需带 `book`）。
 * - `POST /api/sync` 推送（body: books/notes/configs 数组）。按 (book_hash, record_id) 做
 *   last-write-wins 合并，响应只含本次实际采纳的 kind（全部未采纳时为 `{}`）。
 * - `POST /api/sync/import` 第三方批注导入（预览/提交），anchor 形如 `{id, text?, chapterHint?, note?}`。
 * - `POST /api/sync/import/clear` 清理本用户该书经导入写入的 `wxread-` 批注。
 *
 * 失败均为 `{err, msg}`（如 `sync.disabled` 表示服务端未启用同步）。
 */

/** 同步记录种类（对应服务端 `MyReaderSyncService.KINDS`）。 */
export type SyncKind = 'books' | 'notes' | 'configs';

/** 全部记录种类，顺序与服务端 KINDS 一致。 */
export const SYNC_KINDS: SyncKind[] = ['books', 'notes', 'configs'];

/** 单条同步记录：声明协议层确定存在的键，完整记录体保留在 `raw` 中便于原样回推。 */
export interface SyncRecord {
  /** 记录 id（notes 必填；books/configs 服务端复用 book_hash 作为 record_id）。 */
  id?: string;
  /** 记录所属书籍 hash（服务端按此分组，缺失的记录 push 时会被丢弃）。 */
  book_hash?: string;
  /** 记录作者 uid（notes 必带；服务端在缺失时补当前用户）。 */
  uid?: number;
  /** 最后写入时间戳（last-write-wins 合并依据）。 */
  updated_at?: number;
  /** 软删除时间戳；有值表示该记录已删除。 */
  deleted_at?: number;
  /** 服务端原样透传的完整记录体（含客户端自定义字段）。 */
  raw: Record<string, Object>;
}

/** `GET /api/sync` 拉取结果；未请求或服务端返回 null 的 kind 归一化为空数组。 */
export interface SyncPullResult {
  err?: string;
  msg?: string;
  books: SyncRecord[];
  notes: SyncRecord[];
  configs: SyncRecord[];
}

/** 推送体：按 kind 分组的记录列表（记录结构由客户端定义，服务端只做 LWW 合并）。 */
export interface SyncPushPayload {
  books?: Array<Record<string, Object>>;
  notes?: Array<Record<string, Object>>;
  configs?: Array<Record<string, Object>>;
}

/** `POST /api/sync` 推送结果：值为服务端合并后实际采纳的记录，未提及的 kind 为空数组。 */
export interface SyncPushResult {
  err?: string;
  msg?: string;
  books: Array<Record<string, Object>>;
  notes: Array<Record<string, Object>>;
  configs: Array<Record<string, Object>>;
}

/** 导入锚点（服务端校验每一项都必须带 `id`）。 */
export interface SyncImportAnchor {
  id: string;
  /** 命中文本，用于定位 CFI。 */
  text?: string;
  /** 章节提示（服务端字段名为 camelCase 的 chapterHint）。 */
  chapterHint?: string;
  /** 批注正文。 */
  note?: string;
}

/** 第三方批注导入请求。 */
export interface SyncImportRequest {
  /** MyBooks 书籍 id，必须存在 EPUB 格式，否则服务端返回 book.no_epub。 */
  bookId: number;
  /** 锚点列表，不能为空。 */
  anchors: SyncImportAnchor[];
  /** 歧义处理：'error'（默认）| 'first_match'。 */
  onAmbiguous?: string;
  /** true（默认）只做定位预览不落库；false 提交写入。 */
  dryRun?: boolean;
  /** true 绕过重复导入的 CFI 去重，强制全部重新定位。 */
  force?: boolean;
}

/** `POST /api/sync/import` 响应；`pushed` 仅在提交模式（dryRun=false）下返回。 */
export interface SyncImportResult {
  err?: string;
  msg?: string;
  book_id?: number;
  book_hash?: string;
  dry_run?: boolean;
  /** 每个锚点的定位结果（含 `reused: true` 表示复用上次导入的 CFI）。 */
  results: Array<Record<string, Object>>;
  /** 提交模式下 push 的返回值，结构同拉取结果的 notes。 */
  pushed?: Record<string, Object>;
}

/** `POST /api/sync/import/clear` 响应。 */
export interface SyncImportClearResult {
  err?: string;
  msg?: string;
  book_id?: number;
  book_hash?: string;
  /** 被清理（tombstone）的批注条数。 */
  cleared?: number;
}

/** 取服务端错误提示（优先 msg，回退 err；返回空串表示成功）。 */
export function syncErrorMessage(err: string | undefined, msg: string | undefined): string {
  if (msg !== undefined && msg.length > 0) {
    return msg;
  }
  if (err !== undefined && err !== 'ok' && err.length > 0) {
    return err;
  }
  return '';
}

/** 读可选的字符串字段（缺失/空串返回 undefined）。 */
function syncOptionalString(raw: Record<string, Object>, key: string): string | undefined {
  const value = raw[key];
  if (value === undefined || value === null) {
    return undefined;
  }
  const text = `${value}`;
  return text.length > 0 ? text : undefined;
}

/** 读字符串字段（缺失返回空串）。 */
function syncString(raw: Record<string, Object>, key: string): string {
  return syncOptionalString(raw, key) ?? '';
}

/** 读数字字段（缺失/非数字返回 0）。 */
function syncNumber(raw: Record<string, Object>, key: string): number {
  const value = raw[key];
  if (value === undefined || value === null) {
    return 0;
  }
  if (typeof value === 'number') {
    const num = value as number;
    return isNaN(num) ? 0 : num;
  }
  const parsed = Number(`${value}`);
  return isNaN(parsed) ? 0 : parsed;
}

/** 把数组字段归一化为 `Array<Record<string, Object>>`（缺失/null/非数组返回空数组）。 */
function syncRawRows(value: Object | undefined): Array<Record<string, Object>> {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  return value as Array<Record<string, Object>>;
}

/** 把单条原始记录转成 `SyncRecord`（保留完整 body 便于回推）。 */
export function parseSyncRecord(json: Record<string, Object>): SyncRecord {
  const record: SyncRecord = {
    id: syncOptionalString(json, 'id'),
    book_hash: syncOptionalString(json, 'book_hash'),
    raw: json,
  };
  const uid = json['uid'];
  if (uid !== undefined && uid !== null) {
    record.uid = syncNumber(json, 'uid');
  }
  const updatedAt = json['updated_at'];
  if (updatedAt !== undefined && updatedAt !== null) {
    record.updated_at = syncNumber(json, 'updated_at');
  }
  const deletedAt = json['deleted_at'];
  if (deletedAt !== undefined && deletedAt !== null) {
    record.deleted_at = syncNumber(json, 'deleted_at');
  }
  return record;
}

/** 把一个 kind 的原始记录数组转成 `SyncRecord[]`（缺失/null/非数组返回空数组）。 */
export function parseSyncRecords(value: Object | undefined): SyncRecord[] {
  const rows = syncRawRows(value);
  const out: SyncRecord[] = [];
  for (let i = 0; i < rows.length; i++) {
    out.push(parseSyncRecord(rows[i]));
  }
  return out;
}

/** `/api/sync` 系列端点的调用入口。 */
export class SyncApi {
  /**
   * 拉取同步增量（GET /api/sync?since=&type=&book=&own=）。
   * since：时间戳，服务端只返回 `updated_at`/`deleted_at` 大于它的记录；
   * type：省略时返回全部 kind；bookHash：限定单本书；own：0 时并入同书其他用户的共享批注。
   */
  static async pull(since: number, type?: string, bookHash?: string, own: number = 1):
    Promise<SyncPullResult> {
    let path = `/api/sync?since=${since}&own=${own}`;
    if (type !== undefined && type.length > 0) {
      path = `${path}&type=${encodeURIComponent(type)}`;
    }
    if (bookHash !== undefined && bookHash.length > 0) {
      path = `${path}&book=${encodeURIComponent(bookHash)}`;
    }
    const raw = await TalebookCoreService.talebookGet(path);
    const parsed = JSON.parse(raw) as Record<string, Object>;
    const result: SyncPullResult = {
      err: syncOptionalString(parsed, 'err'),
      msg: syncOptionalString(parsed, 'msg'),
      books: parseSyncRecords(parsed['books']),
      notes: parseSyncRecords(parsed['notes']),
      configs: parseSyncRecords(parsed['configs']),
    };
    return result;
  }

  /** 推送同步记录（POST /api/sync，JSON body: books/notes/configs）。 */
  static async push(payload: SyncPushPayload): Promise<SyncPushResult> {
    const raw = await TalebookCoreService.talebookPost('/api/sync',
      JSON.stringify(payload as Record<string, Object>));
    return SyncApi.parsePushResult(raw);
  }

  /** 按原始 JSON 文本推送（供页面直接透传用户编辑的文本域，避免二次序列化丢字段）。 */
  static async pushRaw(bodyJson: string): Promise<SyncPushResult> {
    const raw = await TalebookCoreService.talebookPost('/api/sync', bodyJson);
    return SyncApi.parsePushResult(raw);
  }

  /**
   * 第三方批注导入预览/提交（POST /api/sync/import）。
   * dryRun 默认 true（只定位不落库）；提交时服务端走 sync push 写入。
   */
  static async importAnchors(request: SyncImportRequest): Promise<SyncImportResult> {
    const body: Record<string, Object> = {
      'book_id': request.bookId,
      'anchors': request.anchors as Object,
      'on_ambiguous': request.onAmbiguous ?? 'error',
      'dry_run': request.dryRun ?? true,
      'force': request.force ?? false,
    };
    const raw = await TalebookCoreService.talebookPost('/api/sync/import', JSON.stringify(body));
    const parsed = JSON.parse(raw) as Record<string, Object>;
    const result: SyncImportResult = {
      err: syncOptionalString(parsed, 'err'),
      msg: syncOptionalString(parsed, 'msg'),
      book_id: syncNumber(parsed, 'book_id'),
      book_hash: syncString(parsed, 'book_hash'),
      dry_run: parsed['dry_run'] === true,
      results: syncRawRows(parsed['results']),
    };
    const pushed = parsed['pushed'];
    if (pushed !== undefined && pushed !== null) {
      result.pushed = pushed as Record<string, Object>;
    }
    return result;
  }

  /** 清理本用户该书经 /api/sync/import 写入的 `wxread-` 批注（POST /api/sync/import/clear）。 */
  static async clearImported(bookId: number): Promise<SyncImportClearResult> {
    const body: Record<string, Object> = { 'book_id': bookId };
    const raw = await TalebookCoreService.talebookPost('/api/sync/import/clear', JSON.stringify(body));
    const parsed = JSON.parse(raw) as Record<string, Object>;
    const result: SyncImportClearResult = {
      err: syncOptionalString(parsed, 'err'),
      msg: syncOptionalString(parsed, 'msg'),
      book_id: syncNumber(parsed, 'book_id'),
      book_hash: syncString(parsed, 'book_hash'),
      cleared: syncNumber(parsed, 'cleared'),
    };
    return result;
  }

  private static parsePushResult(raw: string): SyncPushResult {
    const parsed = JSON.parse(raw) as Record<string, Object>;
    const result: SyncPushResult = {
      err: syncOptionalString(parsed, 'err'),
      msg: syncOptionalString(parsed, 'msg'),
      books: syncRawRows(parsed['books']),
      notes: syncRawRows(parsed['notes']),
      configs: syncRawRows(parsed['configs']),
    };
    return result;
  }
}
