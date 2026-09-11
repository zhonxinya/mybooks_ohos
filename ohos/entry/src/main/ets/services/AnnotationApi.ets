import { TalebookCoreService } from './TalebookCoreService';

/**
 * 书内标注（annotations）API —— talebook 上游专有。
 *
 * 端点核对依据：docs/talebook/webserver/handlers/annotations.py::routes()
 *   GET    /api/book/([0-9]+)/annotations            → BookAnnotations.get（按书列出，scope=visible|public|mine）
 *   POST   /api/book/([0-9]+)/annotations            → BookAnnotations.post（新建；同 client_id 重复提交=原地更新）
 *   PUT    /api/book/([0-9]+)/annotations/([0-9]+)   → BookAnnotationItem.put（更新）
 *   DELETE /api/book/([0-9]+)/annotations/([0-9]+)   → BookAnnotationItem.delete（删除）
 *   GET    /api/annotations                          → AnnotationCollection.get（我的全部标注，无 start/size）
 *   GET    /api/annotations/export                   → AnnotationExport.get（导出）
 *
 * 实体字段核对依据：docs/talebook/webserver/models.py
 *   Annotation.to_api_dict() / AnnotationSource.to_api_dict()，另有 handler 追加的 `can_edit`。
 */

/** 标注类型：高亮。 */
export const ANNOTATION_TYPE_HIGHLIGHT: string = 'highlight';
/** 标注类型：笔记。 */
export const ANNOTATION_TYPE_NOTE: string = 'note';
/** 标注类型：书签。 */
export const ANNOTATION_TYPE_BOOKMARK: string = 'bookmark';
/** 标注类型：章节批注。 */
export const ANNOTATION_TYPE_CHAPTER_COMMENT: string = 'chapter_comment';

/** 可见范围：我与公开标注（上游默认值）。 */
export const ANNOTATION_SCOPE_VISIBLE: string = 'visible';
/** 可见范围：仅公开标注。 */
export const ANNOTATION_SCOPE_PUBLIC: string = 'public';
/** 可见范围：仅我的标注。 */
export const ANNOTATION_SCOPE_MINE: string = 'mine';

/** 标注来源的记录与同步状态（AnnotationSource.to_api_dict）。 */
export interface AnnotationSourceInfo {
  id: number;
  sourceName: string;
  sourceConnectionId: string;
  sourceAnnotationId: string;
  sourceRunId: string;
  sourcePosition: string;
  sourceRawHash: string;
  sourceUpdatedAt: string;
  sourceSyncStatus: string;
  sourceSyncedAt: string;
  sourceSyncError: string;
}

/** 标注实体（Annotation.to_api_dict + handler 追加的 can_edit）。 */
export interface AnnotationItem {
  id: number;
  bookId: number;
  clientId: string;
  annotationType: string;
  isPrivate: boolean;
  cfi: string;
  chapter: string;
  quoteText: string;
  content: string;
  color: string;
  authorName: string;
  userModifiedAt: string;
  createdAt: string;
  updatedAt: string;
  canEdit: boolean;
  sources: AnnotationSourceInfo[];
}

/** 写入字段（POST 请求体键名对齐上游 `BookAnnotations.post`）。 */
export interface AnnotationWriteInput {
  annotationType: string;
  /** 客户端幂等标识（≤64 字符）。带上已有 clientId 重新 POST 即为上游的更新路径。 */
  clientId: string;
  isPrivate: boolean;
  cfi: string;
  chapter: string;
  quoteText: string;
  content: string;
  color: string;
}

/** POST 写入结果（含上游的幂等/冲突/同步标记）。 */
export interface AnnotationWriteResult {
  annotation: AnnotationItem | null;
  created: boolean;
  staleIgnored: boolean;
  conflictProtected: boolean;
  syncEnqueued: boolean;
}

/** DELETE 结果（上游返回 `deleted`）。 */
export interface AnnotationDeleteResult {
  deleted: number;
}

/** 导出结果（`export` 节点：schema/exported_at/annotations）。 */
export interface AnnotationExportResult {
  schema: string;
  exportedAt: string;
  count: number;
  json: string;
}

/** 标注类型的中文标签（仅 UI 展示，不参与请求）。 */
export function annotationTypeLabel(type: string): string {
  switch (type) {
    case ANNOTATION_TYPE_HIGHLIGHT:
      return '高亮';
    case ANNOTATION_TYPE_NOTE:
      return '笔记';
    case ANNOTATION_TYPE_BOOKMARK:
      return '书签';
    case ANNOTATION_TYPE_CHAPTER_COMMENT:
      return '章节批注';
    default:
      return type.length > 0 ? type : '标注';
  }
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

/** 上游布尔字段（JSON true/false）→ boolean；缺失时取 fallback。 */
function asBoolean(value: Object | undefined | null, fallback: boolean): boolean {
  if (value === undefined || value === null) {
    return fallback;
  }
  const text = String(value).toLowerCase();
  return text === 'true' || text === '1' || text === 'yes' || text === 'on';
}

function isMissing(value: Object | undefined | null): boolean {
  return value === undefined || value === null;
}

/** `{err, msg}` 约定：err 为空或 `ok` 视为成功。 */
function isOk(err: string): boolean {
  return err.length === 0 || err === 'ok';
}

function appendQuery(path: string, key: string, value: string): string {
  if (value.length === 0) {
    return path;
  }
  const separator = path.indexOf('?') >= 0 ? '&' : '?';
  return `${path}${separator}${key}=${encodeURIComponent(value)}`;
}

function parseObject(raw: string): Record<string, Object> | null {
  try {
    return JSON.parse(raw) as Record<string, Object>;
  } catch (error) {
    return null;
  }
}

/** 响应体 → 对象；空体（上游 GET 可能返回 `null`）按空对象处理。 */
function envelopeOf(raw: string): Record<string, Object> {
  const parsed = parseObject(raw);
  if (parsed === null) {
    const empty: Record<string, Object> = {};
    return empty;
  }
  return parsed;
}

/** 解析响应并校验 `{err, msg}`；失败时抛出带服务端提示的错误。 */
function ensureOk(raw: string): Record<string, Object> {
  const parsed = envelopeOf(raw);
  const err = asString(parsed['err']);
  if (!isOk(err)) {
    throw new Error(asString(parsed['msg'], err));
  }
  return parsed;
}

function parseAnnotationSource(raw: Record<string, Object>): AnnotationSourceInfo {
  return {
    id: asNumber(raw['id']),
    sourceName: asString(raw['source_name']),
    sourceConnectionId: asString(raw['source_connection_id']),
    sourceAnnotationId: asString(raw['source_annotation_id']),
    sourceRunId: asString(raw['source_run_id']),
    sourcePosition: asString(raw['source_position']),
    sourceRawHash: asString(raw['source_raw_hash']),
    sourceUpdatedAt: asString(raw['source_updated_at']),
    sourceSyncStatus: asString(raw['source_sync_status']),
    sourceSyncedAt: asString(raw['source_synced_at']),
    sourceSyncError: asString(raw['source_sync_error']),
  };
}

function parseAnnotationSources(raw: Object | undefined): AnnotationSourceInfo[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: AnnotationSourceInfo[] = [];
  for (let index = 0; index < list.length; index++) {
    result.push(parseAnnotationSource(list[index]));
  }
  return result;
}

function parseAnnotationItem(raw: Record<string, Object>): AnnotationItem {
  return {
    id: asNumber(raw['id']),
    bookId: asNumber(raw['book_id']),
    clientId: asString(raw['client_id']),
    annotationType: asString(raw['annotation_type']),
    isPrivate: asBoolean(raw['is_private'], true),
    cfi: asString(raw['cfi']),
    chapter: asString(raw['chapter']),
    quoteText: asString(raw['quote_text']),
    content: asString(raw['content']),
    color: asString(raw['color']),
    authorName: asString(raw['author_name']),
    userModifiedAt: asString(raw['user_modified_at']),
    createdAt: asString(raw['created_at']),
    updatedAt: asString(raw['updated_at']),
    canEdit: asBoolean(raw['can_edit'], false),
    sources: parseAnnotationSources(raw['sources']),
  };
}

function parseAnnotationItems(raw: Object | undefined): AnnotationItem[] {
  const list = (raw as Array<Record<string, Object>> | undefined) ?? [];
  const result: AnnotationItem[] = [];
  for (let index = 0; index < list.length; index++) {
    result.push(parseAnnotationItem(list[index]));
  }
  return result;
}

/** 写入请求体（字段名逐一对齐上游读取的键，空串会清空对应字段）。 */
function buildWriteBody(input: AnnotationWriteInput): string {
  const body: Record<string, Object> = {};
  body['annotation_type'] = input.annotationType;
  body['client_id'] = input.clientId;
  body['is_private'] = input.isPrivate;
  body['cfi'] = input.cfi;
  body['chapter'] = input.chapter;
  body['quote_text'] = input.quoteText;
  body['content'] = input.content;
  body['color'] = input.color;
  return JSON.stringify(body);
}

function readWriteResult(parsed: Record<string, Object>): AnnotationWriteResult {
  const node = parsed['annotation'];
  const annotation = isMissing(node) ? null : parseAnnotationItem(node as Record<string, Object>);
  return {
    annotation: annotation,
    created: asBoolean(parsed['created'], false),
    staleIgnored: asBoolean(parsed['stale_ignored'], false),
    conflictProtected: asBoolean(parsed['conflict_protected'], false),
    syncEnqueued: asBoolean(parsed['sync_enqueued'], false),
  };
}

export class AnnotationApi {
  /**
   * GET /api/book/{bookId}/annotations —— 按书列出标注。
   *
   * @param scope `visible`（我与公开，上游默认）/`public`/`mine`
   * @param chapter 非空时按章节过滤（上游对 `chapter` 截断到 500 字符）
   */
  static async listBookAnnotations(bookId: number, scope: string = ANNOTATION_SCOPE_VISIBLE,
    chapter: string = ''): Promise<AnnotationItem[]> {
    let path = `/api/book/${bookId}/annotations`;
    path = appendQuery(path, 'scope', scope);
    path = appendQuery(path, 'chapter', chapter);
    const parsed = ensureOk(await TalebookCoreService.talebookGet(path));
    return parseAnnotationItems(parsed['annotations']);
  }

  /**
   * POST /api/book/{bookId}/annotations —— 新建标注。
   *
   * 上游要求 `annotation_type` 合法且 `client_id` 非空（≤64 字符），否则返回 `params.invalid`。
   */
  static async createAnnotation(bookId: number,
    input: AnnotationWriteInput): Promise<AnnotationWriteResult> {
    const path = `/api/book/${bookId}/annotations`;
    const parsed = ensureOk(await TalebookCoreService.talebookPost(path, buildWriteBody(input)));
    return readWriteResult(parsed);
  }

  /**
   * 更新标注：`PUT /api/book/{bookId}/annotations/{annotationId}`（annotations.py::BookAnnotationItem.put）。
   *
   * 请求体与创建一致（见 `buildWriteBody`），路径末段为标注 id。
   */
  static async updateAnnotation(bookId: number, annotationId: number,
    input: AnnotationWriteInput): Promise<AnnotationWriteResult> {
    const path = `/api/book/${bookId}/annotations/${annotationId}`;
    const parsed = ensureOk(await TalebookCoreService.talebookPut(path, buildWriteBody(input)));
    return readWriteResult(parsed);
  }

  /**
   * DELETE /api/book/{bookId}/annotations/{annotationId} —— 删除标注。
   *
   * 上游仅允许删除本人（reader_id）在该书下的标注，否则返回 `annotation.not_found`。
   */
  static async deleteAnnotation(bookId: number, annotationId: number): Promise<AnnotationDeleteResult> {
    const path = `/api/book/${bookId}/annotations/${annotationId}`;
    const parsed = ensureOk(await TalebookCoreService.talebookDelete(path));
    return { deleted: asNumber(parsed['deleted']) };
  }

  /**
   * GET /api/annotations —— 列出「我的全部标注」。
   *
   * ⚠️ 上游 `AnnotationCollection.get` 不属于 ListHandler 系，**不识别 `start`/`size`**，
   * 只用 `book_id` 与 `source_*` 筛选，并按 (book_id, id) 一次性返回全量。
   * 因此这里的 `start`/`size` 是「窗口截取」语义：`size <= 0` 返回全量（页面据此做本地分页，
   * 避免每页重复整表请求），`size > 0` 时返回 `[start, start + size)` 切片。
   */
  static async listMyAnnotations(start: number = 0, size: number = 0): Promise<AnnotationItem[]> {
    const parsed = ensureOk(await TalebookCoreService.talebookGet('/api/annotations'));
    const all = parseAnnotationItems(parsed['annotations']);
    if (size <= 0) {
      return all;
    }
    const from = start > 0 ? start : 0;
    return all.slice(from, from + size);
  }

  /**
   * GET /api/annotations/export —— 导出我的全部标注。
   *
   * 返回 `export` 节点：`{ schema: 'talebook.annotations.v2', exported_at, annotations }`；
   * 这里同时给出 `count` 与序列化后的 JSON 文本，供 UI 展示或落地。
   */
  static async exportAnnotations(): Promise<AnnotationExportResult> {
    const parsed = ensureOk(await TalebookCoreService.talebookGet('/api/annotations/export'));
    const node = parsed['export'];
    if (isMissing(node)) {
      throw new Error('导出响应缺少 export 字段');
    }
    const exportNode = node as Record<string, Object>;
    const annotations = parseAnnotationItems(exportNode['annotations']);
    return {
      schema: asString(exportNode['schema']),
      exportedAt: asString(exportNode['exported_at']),
      count: annotations.length,
      json: JSON.stringify(exportNode),
    };
  }
}
