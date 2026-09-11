/**
 * talebook 目录扫描 / 导入设置 REST 封装（强类型）。
 *
 * 端点来源（逐条核对上游 handler，勿凭印象改动）：
 * - docs/talebook/webserver/handlers/scan.py::routes()
 *
 * 上游语义备忘：
 * - `GET /api/admin/scan/list` **不是** ListHandler 系，自带 `num` / `page`（1 起始）/ `sort` / `desc` / `filter`；
 *   `num <= 0` 表示不分页。`sort` 仅支持 id|path|name|create_time|update_time。
 * - `POST /api/admin/scan/delete` / `import/run` 的 `hashlist` 既接受字符串数组，
 *   也接受字面量 `"all"`（字符串），因此拆成两个方法，避免 ArkTS 联合类型穿参。
 * - `POST /api/admin/scan/mark` 上游是空实现占位（仅回 `{err:'ok'}`）。
 * - `import_mode` 取值 index|copy|move（webserver/services/scan.py）。
 * - `POST /api/admin/import/settings` 用 `settings` 包裹结果，失败时 err 为 `params.path`。
 */
import { TalebookCoreService } from './TalebookCoreService';
import { ApiMessageResult } from './TalebookApi';

/** 扫描记录筛选（上游 `filter` 参数）。 */
export const SCAN_FILTER_ALL: string = 'all';
export const SCAN_FILTER_TODO: string = 'todo';
export const SCAN_FILTER_DONE: string = 'done';
export const SCAN_FILTER_FAILED: string = 'failed';

/** 扫描记录排序字段（上游 sort 白名单，其余回退 create_time）。 */
export const SCAN_SORT_ID: string = 'id';
export const SCAN_SORT_PATH: string = 'path';
export const SCAN_SORT_NAME: string = 'name';
export const SCAN_SORT_CREATE_TIME: string = 'create_time';
export const SCAN_SORT_UPDATE_TIME: string = 'update_time';

/** 导入模式（webserver/services/scan.py）。 */
export const IMPORT_MODE_INDEX: string = 'index';
export const IMPORT_MODE_COPY: string = 'copy';
export const IMPORT_MODE_MOVE: string = 'move';

/** 扫描/导入状态统计（ScanFile 状态 → 数量，键由上游 Scanner.count 给出）。 */
export interface AdminScanStatusCounts {
  total?: number;
  new?: number;
  drop?: number;
  exist?: number;
  ready?: number;
  queued?: number;
  importing?: number;
  imported?: number;
  indexed?: number;
  delete_failed?: number;
  failed?: number;
}

/** 全局摘要（Scanner.summary）：done = exist+imported+indexed。 */
export interface AdminScanSummary {
  total?: number;
  done?: number;
  todo?: number;
  failed?: number;
}

/** 自动监控状态（ScanService.get_watch_status）。 */
export interface AdminWatchStatus {
  state?: string;
  queued?: number;
  running?: number;
  failed?: number;
  last_scan_at?: string;
  message?: string;
}

/** 导入目录预检结果（scan.py::check_import_directory）。 */
export interface AdminImportDirectoryCheck {
  path?: string;
  allowed_roots?: string[];
  exists?: boolean;
  is_dir?: boolean;
  is_symlink?: boolean;
  readable?: boolean;
  writable?: boolean;
  in_allowed_roots?: boolean;
  file_count?: number;
  supported_file_count?: number;
  truncated?: boolean;
  checked_at?: string;
  status?: string;
  msg?: string;
}

/** 目录浏览条目（GET /api/admin/import/directory/list）。 */
export interface AdminDirectoryEntry {
  name?: string;
  path?: string;
  readable?: boolean;
  writable?: boolean;
  is_symlink?: boolean;
  in_allowed_roots?: boolean;
}

export interface AdminImportSettings {
  scan_upload_path?: string;
  import_mode?: string;
  auto_watch_enabled?: boolean;
  allowed_roots?: string[];
  directory_check?: AdminImportDirectoryCheck;
  watch_status?: AdminWatchStatus;
}

export interface AdminScanItem {
  id?: number;
  path?: string;
  hash?: string;
  title?: string;
  author?: string;
  publisher?: string;
  tags?: string;
  status?: string;
  book_id?: number;
  data?: Record<string, Object>;
  create_time?: string;
  update_time?: string;
}

export interface AdminScanListResponse extends ApiMessageResult {
  items?: AdminScanItem[];
  total?: number;
  summary?: AdminScanSummary;
  scan_dir?: string;
  import_mode?: string;
  auto_watch_enabled?: boolean;
  watch_status?: AdminWatchStatus;
}

export interface AdminScanRunResponse extends ApiMessageResult {
  total?: number;
  directory_check?: AdminImportDirectoryCheck;
}

export interface AdminScanStatusResponse extends ApiMessageResult {
  status?: AdminScanStatusCounts;
  summary?: AdminScanSummary;
}

export interface AdminScanDeleteResponse extends ApiMessageResult {
  count?: number;
}

export interface AdminImportSettingsResponse extends ApiMessageResult {
  settings?: AdminImportSettings;
  directory_check?: AdminImportDirectoryCheck;
}

export interface AdminImportDirectoryCheckResponse extends ApiMessageResult {
  directory?: AdminImportDirectoryCheck;
}

export interface AdminImportDirectoryListResponse extends ApiMessageResult {
  path?: string;
  parent?: string;
  allowed_roots?: string[];
  items?: AdminDirectoryEntry[];
}

export interface AdminImportWatchStatusResponse extends ApiMessageResult {
  watch_status?: AdminWatchStatus;
}

export interface AdminImportStatusResponse extends ApiMessageResult {
  status?: AdminScanStatusCounts;
  summary?: AdminScanSummary;
}

export interface AdminImportRunResponse extends ApiMessageResult {
  import_mode?: string;
  delete_after?: boolean;
}

/** scan/delete 与 import/run 的请求体（hashlist 支持数组或 "all"）。 */
interface AdminHashListPayload {
  hashlist: Object;
}

interface AdminImportRunPayload {
  hashlist: Object;
  delete_after: boolean;
  import_mode: string;
}

interface AdminImportSettingsPayload {
  scan_upload_path: string;
  import_mode: string;
  auto_watch_enabled: boolean;
}

interface AdminPathPayload {
  path: string;
}

export class AdminScanApi {
  /**
   * 扫描记录列表（GET /api/admin/scan/list）。
   * @param page 1 起始页码；@param num 每页条数（<=0 表示不分页，由服务端置空）。
   */
  static async listScans(page: number, num: number, filter: string, sort: string,
    desc: boolean): Promise<AdminScanListResponse> {
    const query = `?num=${num}&page=${page > 0 ? page : 1}`
      + `&sort=${encodeURIComponent(sort)}`
      + `&desc=${desc ? 'true' : 'false'}`
      + `&filter=${encodeURIComponent(filter)}`;
    const raw = await TalebookCoreService.talebookGet(`/api/admin/scan/list${query}`);
    return JSON.parse(raw) as AdminScanListResponse;
  }

  /** 启动一次扫描（POST /api/admin/scan/run，无请求体）。 */
  static async runScan(): Promise<AdminScanRunResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/scan/run', '{}');
    return JSON.parse(raw) as AdminScanRunResponse;
  }

  /** 最近一次扫描的状态统计（GET /api/admin/scan/status）。 */
  static async getScanStatus(): Promise<AdminScanStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/scan/status');
    return JSON.parse(raw) as AdminScanStatusResponse;
  }

  /** 按 hash 删除扫描记录（POST /api/admin/scan/delete）。 */
  static async deleteScans(hashes: string[]): Promise<AdminScanDeleteResponse> {
    const payload: AdminHashListPayload = { hashlist: hashes };
    const raw = await TalebookCoreService.talebookPost('/api/admin/scan/delete',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminScanDeleteResponse;
  }

  /** 清空全部扫描记录（POST /api/admin/scan/delete，hashlist="all"）。 */
  static async deleteAllScans(): Promise<AdminScanDeleteResponse> {
    const payload: AdminHashListPayload = { hashlist: 'all' };
    const raw = await TalebookCoreService.talebookPost('/api/admin/scan/delete',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminScanDeleteResponse;
  }

  /** 标记（POST /api/admin/scan/mark；上游为空实现占位）。 */
  static async markScans(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/scan/mark', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** 读取导入设置（GET /api/admin/import/settings）。 */
  static async getImportSettings(): Promise<AdminImportSettingsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/import/settings');
    return JSON.parse(raw) as AdminImportSettingsResponse;
  }

  /** 保存导入设置（POST /api/admin/import/settings）。 */
  static async saveImportSettings(scanPath: string, importMode: string,
    autoWatchEnabled: boolean): Promise<AdminImportSettingsResponse> {
    const payload: AdminImportSettingsPayload = {
      scan_upload_path: scanPath,
      import_mode: importMode,
      auto_watch_enabled: autoWatchEnabled,
    };
    const raw = await TalebookCoreService.talebookPost('/api/admin/import/settings',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminImportSettingsResponse;
  }

  /** 校验导入目录（POST /api/admin/import/directory/check）。 */
  static async checkImportDirectory(path: string): Promise<AdminImportDirectoryCheckResponse> {
    const payload: AdminPathPayload = { path: path };
    const raw = await TalebookCoreService.talebookPost('/api/admin/import/directory/check',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminImportDirectoryCheckResponse;
  }

  /** 浏览导入目录下的子目录（GET /api/admin/import/directory/list）。 */
  static async listImportDirectories(path: string): Promise<AdminImportDirectoryListResponse> {
    const raw = await TalebookCoreService.talebookGet(
      `/api/admin/import/directory/list?path=${encodeURIComponent(path)}`);
    return JSON.parse(raw) as AdminImportDirectoryListResponse;
  }

  /** 自动监控状态（GET /api/admin/import/watch/status）。 */
  static async getWatchStatus(): Promise<AdminImportWatchStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/import/watch/status');
    return JSON.parse(raw) as AdminImportWatchStatusResponse;
  }

  /** 导入指定 hash 的扫描记录（POST /api/admin/import/run）。 */
  static async runImport(hashes: string[], deleteAfter: boolean,
    importMode: string): Promise<AdminImportRunResponse> {
    const payload: AdminImportRunPayload = {
      hashlist: hashes,
      delete_after: deleteAfter,
      import_mode: importMode,
    };
    const raw = await TalebookCoreService.talebookPost('/api/admin/import/run',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminImportRunResponse;
  }

  /** 导入全部待导入记录（POST /api/admin/import/run，hashlist="all"）。 */
  static async runImportAll(deleteAfter: boolean, importMode: string):
    Promise<AdminImportRunResponse> {
    const payload: AdminImportRunPayload = {
      hashlist: 'all',
      delete_after: deleteAfter,
      import_mode: importMode,
    };
    const raw = await TalebookCoreService.talebookPost('/api/admin/import/run',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminImportRunResponse;
  }

  /** 最近一次导入的状态统计（GET /api/admin/import/status）。 */
  static async getImportStatus(): Promise<AdminImportStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/import/status');
    return JSON.parse(raw) as AdminImportStatusResponse;
  }
}
