import { TalebookCoreService } from './TalebookCoreService';

/**
 * mybooks 专有：作者 / 出版商元数据维护（仅 MyBooksProfile 支持 AUTHOR_META_EDIT）。
 *
 * 端点对照（上游 `docs/mybooks/webserver/handlers/`，已核对源码）：
 * - `GET  /api/author/info?name=<作者名>`  → `{err, author|null}`（admin.py `AuthorInfo`，非管理员亦可读）
 * - `POST /api/author/bio`                 body `{name, bio}` → `{err, msg, author}`（admin.py `AdminAuthorBio`，需管理员；bio > 4096 字拒绝）
 * - `POST /api/author_avatar`              multipart 文件字段 `avatar_data` + 表单字段 `author` → `{err, msg}`（static_files.py `AuthorAvatarUploadHandler`，需管理员；仅 jpeg/png/webp）
 * - `POST /api/author/<作者名>/update`     → 302 重定向到 `/author/<作者名>`（meta.py `AuthorBooksUpdate`，最多处理 40 本）
 * - `POST /api/publisher/<出版商名>/update`→ 302 重定向到 `/publisher/<出版商名>`（meta.py `PubBooksUpdate`，最多处理 40 本）
 * - `GET  /get/author/avatar/<作者名>`     → 头像图片（static_files.py `AuthorAvatarHandler`，按作者名哈希查找，缺失时回退默认图）
 *
 * 后两个 update 端点不做 JSON 应答，因此统一走容错解析（见 `parseEnvelopeOrEmpty`）。
 */

/** 服务端 `{err, msg}` 约定：`err` 缺失或为 `'ok'` 视为成功。 */
export interface AuthorMetaResult {
  err?: string;
  msg?: string;
}

/** 作者记录（对应服务端 `Authors` 模型 / `to_dict()`）。 */
export interface AuthorMetaRecord {
  id: number;
  name: string;
  authorId: number;
  sort: string;
  bio: string;
  region: string;
  avatar: string;
  createTime: string;
}

export interface AuthorInfoResult extends AuthorMetaResult {
  author: AuthorMetaRecord | null;
}

export interface AuthorBioResult extends AuthorMetaResult {
  author: AuthorMetaRecord | null;
}

/** `/api/author/info`、`/api/author/bio` 的原始应答（`author` 缺失或为 `null` 表示无记录）。 */
interface AuthorRawEnvelope {
  err?: string;
  msg?: string;
  author?: Object | null;
}

/** 头像上传支持的扩展名（服务端仅接受 image/jpeg、image/png、image/webp）。 */
export const AUTHOR_AVATAR_SUFFIXES: string[] = ['.jpg', '.jpeg', '.png', '.webp'];

/** 简介长度上限（服务端 `len(bio) > 4096` 时返回「简介内容过长」）。 */
export const AUTHOR_BIO_MAX_LENGTH: number = 4096;

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

/** 解析 `author` 字段；缺失或 `null` 返回 null。 */
function parseAuthor(raw: Object | null | undefined): AuthorMetaRecord | null {
  if (raw === undefined || raw === null) {
    return null;
  }
  const obj = raw as Record<string, Object>;
  const record: AuthorMetaRecord = {
    id: asNumber(obj['id']),
    name: asString(obj['name']),
    authorId: asNumber(obj['author_id']),
    sort: asString(obj['sort']),
    bio: asString(obj['bio']),
    region: asString(obj['region']),
    avatar: asString(obj['avatar']),
    createTime: asString(obj['create_time']),
  };
  return record;
}

/**
 * 容错解析：`/api/author/<name>/update` 与 `/api/publisher/<name>/update` 在批量更新后会
 * 302 重定向到作者/出版商页面，跟随重定向后拿到的是 HTML 而不是 JSON；重定向体也可能为空。
 * 与 `TalebookApi.parseJsonOrOk` 保持同一处理思路：非 JSON 一律按「无 err 字段」处理，
 * 避免把正常的重定向应答误报成失败（真正的服务端错误会以 HTTP >= 400 抛异常）。
 */
function parseEnvelopeOrEmpty(raw: string): AuthorRawEnvelope {
  const trimmed = raw.trim();
  if (trimmed.length === 0 || trimmed.charAt(0) !== '{') {
    return {} as AuthorRawEnvelope;
  }
  try {
    return JSON.parse(trimmed) as AuthorRawEnvelope;
  } catch (_error) {
    return {} as AuthorRawEnvelope;
  }
}

/** 判断应答是否成功（`err` 缺失或为 `'ok'`）。 */
export function isAuthorMetaOk(rsp: AuthorMetaResult): boolean {
  return rsp.err === undefined || rsp.err === 'ok';
}

/** 取服务端提示文案（优先 `msg`，回退 `err`，最后用 fallback）。 */
export function authorMetaMessage(rsp: AuthorMetaResult, fallback: string): string {
  if (rsp.msg !== undefined && rsp.msg.length > 0) {
    return rsp.msg;
  }
  if (rsp.err !== undefined && rsp.err.length > 0 && rsp.err !== 'ok') {
    return rsp.err;
  }
  return fallback;
}

/** 作者 / 出版商元数据维护（mybooks 专有）。 */
export class AuthorMetaApi {
  /** 作者信息（`GET /api/author/info?name=…`）；服务端无记录时 `author` 为 null。 */
  static async getAuthorInfo(name: string): Promise<AuthorInfoResult> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/author/info?name=${encodeURIComponent(name)}`);
    const envelope = parseEnvelopeOrEmpty(raw) as AuthorRawEnvelope;
    const result: AuthorInfoResult = {
      err: envelope.err,
      msg: envelope.msg,
      author: parseAuthor(envelope.author),
    };
    return result;
  }

  /** 保存作者简介（`POST /api/author/bio`，需管理员；无记录时服务端会自动创建）。 */
  static async saveAuthorBio(name: string, bio: string): Promise<AuthorBioResult> {
    const body: Record<string, Object> = { 'name': name, 'bio': bio };
    const raw = await TalebookCoreService.talebookPost('/api/author/bio', JSON.stringify(body));
    const envelope = parseEnvelopeOrEmpty(raw) as AuthorRawEnvelope;
    const result: AuthorBioResult = {
      err: envelope.err,
      msg: envelope.msg,
      author: parseAuthor(envelope.author),
    };
    return result;
  }

  /**
   * 上传作者头像（`POST /api/author_avatar`，multipart，需管理员）。
   * 文件字段名 `avatar_data`；附加表单字段 `author`（服务端对该字段做 `unquote`，故此处编码）。
   */
  static async uploadAuthorAvatar(author: string, localPath: string, fileName: string):
    Promise<AuthorMetaResult> {
    const fields: Record<string, Object> = { 'author': encodeURIComponent(author) };
    const raw = await TalebookCoreService.talebookUploadFile(
      '/api/author_avatar', localPath, 'avatar_data', fileName, JSON.stringify(fields));
    const envelope = parseEnvelopeOrEmpty(raw) as AuthorRawEnvelope;
    const result: AuthorMetaResult = { err: envelope.err, msg: envelope.msg };
    return result;
  }

  /** 更新该作者名下书籍元数据（`POST /api/author/<作者名>/update`，服务端最多处理 40 本）。 */
  static async updateAuthorBooks(name: string): Promise<AuthorMetaResult> {
    const raw = await TalebookCoreService.talebookPost(
      `/api/author/${encodeURIComponent(name)}/update`, '{}');
    const envelope = parseEnvelopeOrEmpty(raw) as AuthorRawEnvelope;
    const result: AuthorMetaResult = { err: envelope.err, msg: envelope.msg };
    return result;
  }

  /**
   * 更新该出版商名下书籍元数据（`POST /api/publisher/<出版商名>/update`）。
   * 注意：服务端在出版商名为空时会改为刷新「所有未填写出版商」的书籍，调用方需自行把关。
   */
  static async updatePublisherBooks(name: string): Promise<AuthorMetaResult> {
    const raw = await TalebookCoreService.talebookPost(
      `/api/publisher/${encodeURIComponent(name)}/update`, '{}');
    const envelope = parseEnvelopeOrEmpty(raw) as AuthorRawEnvelope;
    const result: AuthorMetaResult = { err: envelope.err, msg: envelope.msg };
    return result;
  }

  /**
   * 作者头像相对地址（`GET /get/author/avatar/<作者名>`）。
   * `cacheBust` 传时间戳可在上传后强制刷新（服务端响应 `Cache-Control: max-age=86400`）。
   */
  static authorAvatarPath(name: string, cacheBust: string = ''): string {
    const path = `/get/author/avatar/${encodeURIComponent(name)}`;
    return cacheBust.length > 0 ? `${path}?t=${cacheBust}` : path;
  }
}
