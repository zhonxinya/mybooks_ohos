/**
 * talebook 服务端维护 REST 封装（强类型）。
 *
 * 端点来源（逐条核对上游 handler，勿凭印象改动）：
 * - docs/talebook/webserver/handlers/admin.py::routes()
 *   （/api/admin/update、/api/admin/ssl、/api/admin/testdb、/api/admin/migratedb、/api/admin/book/kindleconvert）
 * - docs/talebook/webserver/handlers/audiobook.py::routes()
 *   （/api/admin/audio-stats、/api/admin/podcast-audits）
 *
 * 上游语义备忘：
 * - `POST /api/admin/update` 是同步触发一次 GitHub release 检查；`GET` 只读缓存状态。
 * - `POST /api/admin/testdb` / `POST /api/admin/migratedb` 使用 Tornado `get_argument`，
 *   参数必须走 query 或 `application/x-www-form-urlencoded`，**不是** JSON 体；
 *   `migratedb` 的 `force` 取 `"1"` 才表示强制。目标库非空时返回
 *   `{err:'db.target_has_data', count}`，需再次确认后带 force 重试。
 * - `POST /api/admin/ssl` 是 multipart，字段固定 `ssl_crt` 与 `ssl_key`。
 * - `PATCH /api/admin/podcast-audits` 只支持 `action` 为 freeze / unfreeze；
 *   响应含 `frozen` / `frozen_reason`，可直接回显结果。
 * - `GET /api/admin/trash/size` 返回 `{sizes:{trash,upload}}`（字节，服务端带缓存）；
 *   `POST /api/admin/trash/clear` 清空 Calibre 回收站与上传目录，失败时 `err='error'` 且 `msg` 为原因。
 */
import { TalebookCoreService } from './TalebookCoreService';
import { ApiMessageResult } from './TalebookApi';

/** 更新检查状态（UpdateChecker.get_status）。 */
export interface AdminUpdateStatus {
  current_version?: string;
  latest_version?: string;
  has_update?: boolean;
  latest_release_url?: string;
  latest_release_name?: string;
  latest_release_body?: string;
  check_error?: string;
  last_check_time?: number;
}

/** 一/三方有声书统计（AudiobookAdminStats）。 */
export interface AdminAudioStats {
  first_party?: AdminFirstPartyAudioStats;
  podcast_estimated?: AdminPodcastEstimatedStats;
  jobs?: AdminAudioJobStats;
}

export interface AdminFirstPartyAudioStats {
  listened_ms?: number;
  sessions?: number;
}

export interface AdminPodcastEstimatedStats {
  requests?: number;
  bytes?: number;
}

export interface AdminAudioJobStats {
  total?: number;
  failed?: number;
}

/** 播客访问审计日志（PodcastAudit.get）。 */
export interface AdminPodcastAuditLog {
  id?: number;
  subscription_id?: number;
  book_id?: number;
  chapter_id?: number;
  kind?: string;
  method?: string;
  status?: number;
  range_start?: number;
  range_end?: number;
  bytes_sent?: number;
  ip?: string;
  user_agent?: string;
  protected?: boolean;
  created_at?: string;
}

/** Kindle 格式批量转换进度（BatchConvertService.status）。 */
export interface AdminKindleConvertStatus {
  total?: number;
  skip?: number;
  done?: number;
  fail?: number;
  running?: boolean;
}

export interface AdminUpdateStatusResponse extends ApiMessageResult {
  status?: AdminUpdateStatus;
}

export interface AdminAudioStatsResponse extends ApiMessageResult {
  first_party?: AdminFirstPartyAudioStats;
  podcast_estimated?: AdminPodcastEstimatedStats;
  jobs?: AdminAudioJobStats;
}

export interface AdminPodcastAuditsResponse extends ApiMessageResult {
  logs?: AdminPodcastAuditLog[];
}

export interface AdminKindleConvertStatusResponse extends ApiMessageResult {
  status?: AdminKindleConvertStatus;
}

export interface AdminMigrateDbResponse extends ApiMessageResult {
  count?: number;
  need_restart?: boolean;
}

/** 回收站 / 上传目录占用（AdminTrashSize → TrashManager.get_trash_sizes）。 */
export interface AdminTrashSizes {
  trash?: number;
  upload?: number;
}

export interface AdminTrashSizeResponse extends ApiMessageResult {
  sizes?: AdminTrashSizes;
}

/** podcast-audits PATCH 请求体（action=freeze|unfreeze）。 */
interface AdminPodcastFreezePayload {
  action: string;
  subscription_id: number;
  reason?: string;
}

/** podcast-audits PATCH 响应（回显冻结结果）。 */
export interface AdminPodcastFreezeResponse extends ApiMessageResult {
  subscription_id?: number;
  frozen?: boolean;
  frozen_reason?: string;
}

/** Kindle 转换请求体（idlist 为空数组时上游转换为全部书籍）。 */
interface AdminKindleConvertPayload {
  idlist: number[];
}

export const PODCAST_ACTION_FREEZE: string = 'freeze';
export const PODCAST_ACTION_UNFREEZE: string = 'unfreeze';

export class AdminMaintenanceApi {
  /** 读取更新状态（GET /api/admin/update，只读缓存）。 */
  static async getUpdateStatus(): Promise<AdminUpdateStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/update');
    return JSON.parse(raw) as AdminUpdateStatusResponse;
  }

  /** 触发一次更新检查（POST /api/admin/update，同步请求 GitHub）。 */
  static async checkForUpdates(): Promise<AdminUpdateStatusResponse> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/update', '{}');
    return JSON.parse(raw) as AdminUpdateStatusResponse;
  }

  /**
   * 上传 SSL 证书与私钥（POST /api/admin/ssl，multipart 字段 ssl_crt / ssl_key）。
   * 两个文件必须使用已落到本地路径的副本（BookUploadService.pickStagedFile 结果）。
   */
  static async uploadSsl(crtLocalPath: string, crtFileName: string,
    keyLocalPath: string, keyFileName: string): Promise<ApiMessageResult> {
    const files: Array<Record<string, Object>> = [
      { 'path': crtLocalPath, 'name': crtFileName, 'field': 'ssl_crt' },
      { 'path': keyLocalPath, 'name': keyFileName, 'field': 'ssl_key' },
    ];
    const raw = await TalebookCoreService.talebookUploadFiles('/api/admin/ssl',
      JSON.stringify(files), '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /**
   * 测试数据库连接（POST /api/admin/testdb）。
   * 参数以表单体提交（上游用 `get_argument` 读取）。
   */
  static async testDatabase(userDatabase: string): Promise<ApiMessageResult> {
    const form = `user_database=${encodeURIComponent(userDatabase)}`;
    const raw = await TalebookCoreService.talebookPostForm('/api/admin/testdb', form);
    return JSON.parse(raw) as ApiMessageResult;
  }

  /**
   * 迁移用户数据到新数据库（POST /api/admin/migratedb，危险操作）。
   * 目标库非空时返回 `err='db.target_has_data'` 与 `count`，需 force=true 重试。
   */
  static async migrateDatabase(userDatabase: string, force: boolean):
    Promise<AdminMigrateDbResponse> {
    const form = `user_database=${encodeURIComponent(userDatabase)}&force=${force ? '1' : '0'}`;
    const raw = await TalebookCoreService.talebookPostForm('/api/admin/migratedb', form);
    return JSON.parse(raw) as AdminMigrateDbResponse;
  }

  /** 有声书统计（GET /api/admin/audio-stats）。 */
  static async getAudioStats(): Promise<AdminAudioStatsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/audio-stats');
    return JSON.parse(raw) as AdminAudioStatsResponse;
  }

  /** 播客访问审计日志（GET /api/admin/podcast-audits，最多 500 条）。 */
  static async listPodcastAudits(): Promise<AdminPodcastAuditsResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/podcast-audits');
    return JSON.parse(raw) as AdminPodcastAuditsResponse;
  }

  /** 冻结/解冻播客订阅（PATCH /api/admin/podcast-audits）。 */
  static async setPodcastSubscriptionFrozen(subscriptionId: number, freeze: boolean,
    reason: string): Promise<AdminPodcastFreezeResponse> {
    const payload: AdminPodcastFreezePayload = {
      action: freeze ? PODCAST_ACTION_FREEZE : PODCAST_ACTION_UNFREEZE,
      subscription_id: subscriptionId,
      reason: reason,
    };
    const raw = await TalebookCoreService.talebookPatch('/api/admin/podcast-audits',
      JSON.stringify(payload));
    return JSON.parse(raw) as AdminPodcastFreezeResponse;
  }

  /** 回收站与上传目录占用（GET /api/admin/trash/size）。 */
  static async getTrashSizes(): Promise<AdminTrashSizeResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/trash/size');
    return JSON.parse(raw) as AdminTrashSizeResponse;
  }

  /**
   * 清空 Calibre 回收站与上传目录（POST /api/admin/trash/clear，危险操作）。
   * 服务端对非绝对路径 / 不安全路径会跳过并返回 `err='error'` 与原因。
   */
  static async clearTrash(): Promise<ApiMessageResult> {
    const raw = await TalebookCoreService.talebookPost('/api/admin/trash/clear', '{}');
    return JSON.parse(raw) as ApiMessageResult;
  }

  /** Kindle 格式批量转换进度（GET /api/admin/book/kindleconvert）。 */
  static async getKindleConvertStatus(): Promise<AdminKindleConvertStatusResponse> {
    const raw = await TalebookCoreService.talebookGet('/api/admin/book/kindleconvert');
    return JSON.parse(raw) as AdminKindleConvertStatusResponse;
  }

  /**
   * 启动 Kindle→EPUB 批量转换（POST /api/admin/book/kindleconvert）。
   * `bookIds` 为空数组时上游转换为全部书籍；有任务在跑时返回 `err='task.running'`。
   */
  static async runKindleConvert(bookIds: number[]): Promise<ApiMessageResult> {
    const payload: AdminKindleConvertPayload = { idlist: bookIds };
    const raw = await TalebookCoreService.talebookPost('/api/admin/book/kindleconvert',
      JSON.stringify(payload));
    return JSON.parse(raw) as ApiMessageResult;
  }
}
