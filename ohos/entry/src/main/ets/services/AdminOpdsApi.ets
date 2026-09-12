/**
 * talebook OPDS 源浏览 / 导入 REST 封装（强类型）。
 *
 * 端点来源（逐条核对上游 handler，勿凭印象改动）：
 * - docs/talebook/webserver/handlers/admin.py::routes()（opds/browse、opds/import*）
 * - docs/talebook/webserver/handlers/admin_opds_sources.py::routes()（opds/sources）
 *
 * 上游语义备忘：
 * - `POST /api/admin/opds/browse` 优先读 `url`，兼容旧 `host`/`port`/`path` 三字段。
 *   返回的 items 既有目录（type=folder，带 path）也有书籍（type=book，带 acquisition_link）。
 * - `POST /api/admin/opds/import` 是异步任务：立即返回 `{err:'ok', async:true}`，
 *   进度需轮询 `GET /api/admin/opds/import/status`（全局单例计数）。
 * - `POST /api/admin/opds/import/retry` 接受 `id` 或 `hash` 之一（ScanFile.FAILED 记录）。
 * - OPDS 源的增/改/删（`POST/PUT/DELETE /api/admin/opds/sources`，见 admin_opds_sources.py）：
 *   `POST` 必填 name+url（url 必须以 http(s) 开头、名称不可重复）；`PUT` 以 `id` 定位，
 *   仅更新请求中出现的字段，`active` 可单独切换；`DELETE` 以 JSON 体的 `id` 定位。
 */
import { TalebookCoreService } from './TalebookCoreService';
import { ApiMessageResult } from './TalebookApi';

/** OPDS 源配置（AdminOpdsSources.get）。 */
export interface AdminOpdsSource {
  id?: number;
  name?: string;
  url?: string;
  description?: string;
  active?: boolean;
  create_time?: string;
  update_time?: string;
}

/** 浏览结果条目（opds_import.py::parse_opds_navigation / _extract_navigation_links）。 */
export interface AdminOpdsBrowseItem {
  type?: string;
  id?: string;
  title?: string;
  author?: string;
  href?: string;
  cover_link?: string;
  summary?: string;
  path?: string;
}

/** 失败记录（AdminOPDSImportFailedList）。 */
export interface AdminOpdsFailedItem {
  id?: number;
  title?: string;
  author?: string;
  path?: string;
  hash?: string;
  status?: string;
  error?: Object;
  update_time?: string;
}

/** OPDS 导入计数（AdminOPDSImportStatus）。 */
export interface AdminOpdsImportCounts {
  total?: number;
  done?: number;
  skip?: number;
  fail?: number;
}

/** 传给导入接口的书籍描述。 */
export interface AdminOpdsImportBook {
  title?: string;
  author?: string;
  href?: string;
  acquisition_link?: string;
}

export interface AdminOpdsSourcesResponse extends ApiMessageResult {
  items?: AdminOpdsSource[];
  count?: number;
}

export interface AdminOpdsBrowseResponse extends ApiMessageResult {
  items?: AdminOpdsBrowseItem[];
  current_path?: string;
}

export interface AdminOpdsImportStatusResponse extends ApiMessageResult {
  status?: AdminOpdsImportCounts;
}

export interface AdminOpdsFailedResponse extends ApiMessageResult {
  items?: AdminOpdsFailedItem[];
  count?: number;
}

/** 新建/更新 OPDS 源的返回（AdminOpdsSources.post 带新建 id）。 */
export interface AdminOpdsSourceWriteResponse extends ApiMessageResult {
  id?: number;
}

// ---- 请求载荷 ----

interface AdminOpdsBrowsePayload {
  url: string;
}

interface AdminOpdsImportPayload {
  opds_url: string;
  books: AdminOpdsImportBook[];
  delete_after: boolean;
}

interface AdminOpdsRetryByIdPayload {
  id: number;
}

interface AdminOpdsRetryByHashPayload {
  hash: string;
}

/** 新建 OPDS 源载荷（name/url 必填）。 */
interface AdminOpdsSourceCreatePayload {
  name: string;
  url: string;
  description: string;
}

/** 更新 OPDS 源载荷：以 id 定位，其余字段省略则不修改。 */
export interface AdminOpdsSourceUpdatePayload {
  id: number;
  name?: string;
  url?: string;
  description?: string;
  active?: boolean;
}

interface AdminOpdsSourceDeletePayload {
  id: number;
}

export class AdminOpdsApi {
  /** OPDS 源列表（GET /api/admin/opds/sources）。 */
  static async listSources(): Promise<AdminOpdsSourcesResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/opds/sources');
    return JSON.parse(raw) as AdminOpdsSourcesResponse;
  }

  /** 新建 OPDS 源（POST /api/admin/opds/sources）。 */
  static async createSource(name: string, url: string, description: string):
    Promise<AdminOpdsSourceWriteResponse> {
    const payload: AdminOpdsSourceCreatePayload = {
      name: name,
      url: url,
      description: description,
    };
    const raw = await TalebookCoreService.talebookPost('/api/admin/opds/sources',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminOpdsSourceWriteResponse;
  }

  /** 更新 OPDS 源（PUT /api/admin/opds/sources，仅提交需变更的字段）。 */
  static async updateSource(id: number, patch: AdminOpdsSourceUpdatePayload):
    Promise<AdminOpdsSourceWriteResponse> {
    const payload: AdminOpdsSourceUpdatePayload = { id: id };
    if (patch.name !== undefined) {
      payload.name = patch.name;
    }
    if (patch.url !== undefined) {
      payload.url = patch.url;
    }
    if (patch.description !== undefined) {
      payload.description = patch.description;
    }
    if (patch.active !== undefined) {
      payload.active = patch.active;
    }
    const raw = await TalebookCoreService.talebookPut('/api/admin/opds/sources',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminOpdsSourceWriteResponse;
  }

  /** 切换启用状态（PUT /api/admin/opds/sources，仅提交 id+active）。 */
  static async setSourceActive(id: number, active: boolean):
    Promise<AdminOpdsSourceWriteResponse> {
    const patch: AdminOpdsSourceUpdatePayload = { id: id, active: active };
    return AdminOpdsApi.updateSource(id, patch);
  }

  /** 删除 OPDS 源（DELETE /api/admin/opds/sources，id 在 JSON 体内）。 */
  static async deleteSource(id: number): Promise<AdminOpdsSourceWriteResponse> {
    const payload: AdminOpdsSourceDeletePayload = { id: id };
    const raw = await TalebookCoreService.talebookDeleteWithBody('/api/admin/opds/sources',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminOpdsSourceWriteResponse;
  }

  /** 浏览 OPDS 目录（POST /api/admin/opds/browse，传完整 url）。 */
  static async browse(url: string): Promise<AdminOpdsBrowseResponse> {
    const payload: AdminOpdsBrowsePayload = { url: url };
    const raw = await TalebookCoreService.talebookPost('/api/admin/opds/browse',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminOpdsBrowseResponse;
  }

  /** 浏览 OPDS 目录（旧 host/port/path 形式，传给同一端点）。 */
  static async browseHost(host: string, port: string, path: string):
    Promise<AdminOpdsBrowseResponse> {
    const payload: Record<string, Object> = {
      'host': host,
      'port': port,
      'path': path,
    };
    const raw = await TalebookCoreService.talebookPost('/api/admin/opds/browse',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminOpdsBrowseResponse;
  }

  /**
   * 导入选中书籍（POST /api/admin/opds/import，异步）。
   * books 为空数组时服务端导入该 OPDS 目录下的全部书籍。
   */
  static async importBooks(opdsUrl: string, books: AdminOpdsImportBook[],
    deleteAfter: boolean): Promise<ApiMessageResult> {
    const payload: AdminOpdsImportPayload = {
      opds_url: opdsUrl,
      books: books,
      delete_after: deleteAfter,
    };
    const raw = await TalebookCoreService.talebookPost('/api/admin/opds/import',
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** OPDS 导入进度（GET /api/admin/opds/import/status，全局单例计数）。 */
  static async getImportStatus(): Promise<AdminOpdsImportStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/opds/import/status');
    return JSON.parse(raw) as AdminOpdsImportStatusResponse;
  }

  /** OPDS 导入失败记录（GET /api/admin/opds/import/failed）。 */
  static async listFailed(): Promise<AdminOpdsFailedResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/opds/import/failed');
    return JSON.parse(raw) as AdminOpdsFailedResponse;
  }

  /** 按记录 id 重试（POST /api/admin/opds/import/retry）。 */
  static async retryFailedById(itemId: number): Promise<ApiMessageResult> {
    const payload: AdminOpdsRetryByIdPayload = { id: itemId };
    const raw = await TalebookCoreService.talebookPost('/api/admin/opds/import/retry',
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 按 hash 重试（POST /api/admin/opds/import/retry）。 */
  static async retryFailedByHash(hash: string): Promise<ApiMessageResult> {
    const payload: AdminOpdsRetryByHashPayload = { hash: hash };
    const raw = await TalebookCoreService.talebookPost('/api/admin/opds/import/retry',
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }
}
