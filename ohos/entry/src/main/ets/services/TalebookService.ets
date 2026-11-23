import entry from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookshelfRefresh } from '../utils/BookshelfRefresh';
import { parseApiEnvelopeTask, parseJsonArrayTask } from './TalebookJsonParser';
import { TalebookCoreService } from './TalebookCoreService';
import { AccountStore } from './AccountStore';
import { PasswordStore } from './PasswordStore';
import { ServerRegistry, ServerKind } from './ServerProfile';
import { ACTIVE_ACCOUNT_KEY, AccountRecord, DISCARDED_PLAINTEXT_KEYS, identityDirFor,
  LEGACY_PASSWORD_ALIAS, LEGACY_PROFILE_ALIAS, LEGACY_USERNAME_ALIAS, passwordAliasFor,
  profileAliasFor, usernameAliasFor } from '../models/AccountModels';
import { TalebookServiceStore } from './TalebookServiceStore';


export interface ApiEnvelope {
  status: number;
  body: Record<string, Object> | null;
  error: string;
}

/**
 * 自动登录失败原因的 AppStorage 键。
 * 登录页已移除，启动时的自动登录失败只能靠提示告知，由 MainTabs 消费并清空。
 */
export const AUTH_FAILURE_KEY: string = 'authFailureReason';

/** 自动登录结果；失败时带可展示的原因。 */
export interface AuthAttempt {
  ok: boolean;
  reason: string;
}

export interface DownloadRecord {
  bookId: string;
  title: string;
  author?: string;
  coverUrl?: string;
  filePath?: string;
  format?: string;
  downloadTime?: number;
  progress?: ReadingProgress;
}

export interface ReadingProgress {
  lastReadTime?: number;
  chapterName?: string;
  currentPage?: number;
  totalPages?: number;
  progressPercent?: number;
  location?: string;
}

export interface LoginCredentials {
  username: string;
  password: string;
}

export interface ReadingHistoryItem {
  bookId: string;
  title: string;
  author?: string;
  coverUrl?: string;
  filePath?: string;
  format?: string;
  chapterName?: string;
  chapterIndex?: number;
  currentPage?: number;
  totalPages?: number;
  progressPercent?: number;
  location?: string;
  lastReadTime: number;
  /** 累计阅读时长（秒），阅读会话结束时累加。 */
  readSeconds?: number;
}

export interface SoNovelBookPayload {
  sourceId: number;
  sourceName: string;
  url: string;
  bookName: string;
  author: string;
  cover?: string;
  category?: string;
  latestChapter?: string;
  lastUpdateTime?: string;
  status?: string;
  format?: string;
  language?: string;
}

export interface TalebookDownloadPayload {
  bookId: number;
  bookName: string;
  author: string;
  cover: string;
  format: string;
  destPath: string;
}

export type DownloadTaskKind = 'sonovel' | 'talebook';

export type DownloadTaskStatus = 'pending' | 'downloading' | 'completed' | 'failed';

export interface DownloadTask {
  id: string;
  kind: DownloadTaskKind;
  title: string;
  author: string;
  sourceName: string;
  status: DownloadTaskStatus;
  error: string;
  filePath: string;
  format: string;
  bookId: string;
  progress: number;
  message: string;
  createdAt: number;
  updatedAt: number;
  /** 任务所属账号 id；talebook 任务切换账号后不再执行（防止向其他服务器下载）。 */
  accountId?: string;
  payload?: SoNovelBookPayload;
  talebookPayload?: TalebookDownloadPayload;
}

const TAG: string = 'TalebookService';

export class TalebookService {
  private static initialized: boolean = false;
  private static readonly LARGE_JSON_THRESHOLD: number = 32768;

  /** 应用数据根目录（全局偏好所在位置）。 */
  static dataDir(): string {
    return TalebookServiceStore.dataDir_;
  }

  static init(dataDir: string): void {
    if (TalebookService.initialized) {
      return;
    }
    try {
      entry.init(dataDir);
      TalebookServiceStore.dataDir_ = dataDir;
      TalebookService.initialized = true;
    } catch (error) {
      hilog.error(0x0000, TAG, 'init failed: %{public}s', String(error));
    }
  }

  private static parseNative(raw: string): ApiEnvelope {
    return TalebookService.parseEnvelope(raw);
  }

  static failedEnvelope(message: string): ApiEnvelope {
    return { status: 0, body: null, error: message };
  }

  static parseEnvelope(raw: string): ApiEnvelope {
    const parsed = JSON.parse(raw) as Record<string, Object>;
    let body: Record<string, Object> | null = null;
    if (parsed['body'] !== null && parsed['body'] !== undefined) {
      if (typeof parsed['body'] === 'string') {
        body = JSON.parse(parsed['body'] as string) as Record<string, Object>;
      } else {
        body = parsed['body'] as Record<string, Object>;
      }
    }
    const envelope: ApiEnvelope = {
      status: Number(parsed['status'] ?? 0),
      body: body,
      error: String(parsed['error'] ?? ''),
    };
    if (envelope.error.length === 0) {
      envelope.error = TalebookService.apiMessage(envelope);
    }
    return envelope;
  }

  static parseEnvelopeAsync(raw: string): Promise<ApiEnvelope> {
    if (raw.length < TalebookService.LARGE_JSON_THRESHOLD) {
      return Promise.resolve(TalebookService.parseEnvelope(raw));
    }
    return taskpool.execute(parseApiEnvelopeTask, raw)
      .then((result: Object): ApiEnvelope => {
        const envelope = result as ApiEnvelope;
        if (envelope.error.length === 0) {
          envelope.error = TalebookService.apiMessage(envelope);
        }
        return envelope;
      })
      .catch((_error: Object) => TalebookService.parseEnvelope(raw));
  }

  static warmLocalCaches(): Promise<void> {
    if (TalebookServiceStore.localCacheWarmPromise !== null) {
      return TalebookServiceStore.localCacheWarmPromise;
    }
    TalebookServiceStore.localCacheWarmPromise = TalebookService.warmLocalCachesInternal();
    return TalebookServiceStore.localCacheWarmPromise;
  }

  private static async warmLocalCachesInternal(): Promise<void> {
    if (TalebookServiceStore.downloadsCache === null) {
      const downloadsRaw: string = entry.getDownloads();
      try {
        if (downloadsRaw.length >= TalebookService.LARGE_JSON_THRESHOLD) {
          const parsed: Array<Object> =
            await (taskpool.execute(parseJsonArrayTask, downloadsRaw) as Promise<Array<Object>>);
          TalebookServiceStore.downloadsCache = parsed as DownloadRecord[];
        } else if (downloadsRaw.length > 0) {
          TalebookServiceStore.downloadsCache = JSON.parse(downloadsRaw) as DownloadRecord[];
        } else {
          TalebookServiceStore.downloadsCache = [];
        }
      } catch (_error) {
        TalebookServiceStore.downloadsCache = downloadsRaw.length > 0
          ? JSON.parse(downloadsRaw) as DownloadRecord[]
          : [];
      }
    }
    if (TalebookServiceStore.historyCache === null) {
      const historyRaw: string = entry.getReadingHistory();
      try {
        if (historyRaw.length >= TalebookService.LARGE_JSON_THRESHOLD) {
          const parsed: Array<Object> =
            await (taskpool.execute(parseJsonArrayTask, historyRaw) as Promise<Array<Object>>);
          TalebookServiceStore.historyCache = parsed as ReadingHistoryItem[];
        } else if (historyRaw.length > 0) {
          TalebookServiceStore.historyCache = JSON.parse(historyRaw) as ReadingHistoryItem[];
        } else {
          TalebookServiceStore.historyCache = [];
        }
      } catch (_error) {
        TalebookServiceStore.historyCache = historyRaw.length > 0
          ? JSON.parse(historyRaw) as ReadingHistoryItem[]
          : [];
      }
    }
  }

  /** 预热 DNS/TCP/TLS，后续请求复用连接 */
  static warmConnection(): Promise<void> {
    const url = TalebookServiceStore.secureGet('talebook_url');
    if (url.length === 0) {
      return Promise.resolve();
    }
    return entry.apiWarmConnectionAsync()
      .then((_raw: string) => undefined)
      .catch((_error: Object) => undefined);
  }

  static apiMessage(envelope: ApiEnvelope): string {
    if (envelope.body === null) {
      return '';
    }
    const err = String(envelope.body['err'] ?? '');
    if (err.length > 0 && err !== 'ok') {
      return err;
    }
    const msg = String(envelope.body['msg'] ?? '');
    if (msg.length > 0 && msg !== 'ok') {
      return msg;
    }
    return '';
  }

  static isApiSuccess(envelope: ApiEnvelope): boolean {
    if (envelope.status < 200 || envelope.status >= 300) {
      return false;
    }
    if (envelope.error.length > 0) {
      return false;
    }
    if (envelope.body === null) {
      return true;
    }
    const err = String(envelope.body['err'] ?? 'ok');
    return err === 'ok';
  }

  /**
   * 服务端是否明确回复「未登录」。
   *
   * 上游 `BaseHandler.auth`（mybooks/talebook 同一套）在会话失效时返回
   * `{"err":"user.need_login","msg":"请先登录"}`。客户端本地存有凭据不代表服务端会话仍有效
   * （服务端重启会换掉 secure cookie 签名密钥，本地 `cookies.txt` 随即失效），
   * 因此需要按**服务端实际回复**判定，而不是只看 `hasAuthCredentials()`。
   */
  static isLoginRequiredResult(err?: string, msg?: string): boolean {
    if (err === 'user.need_login') {
      return true;
    }
    return msg !== undefined && msg.indexOf('请先登录') >= 0;
  }

  static setBaseUrl(service: string, url: string): void {
    entry.setBaseUrl(service, url);
  }

  /** 切换本模块（libentry）的账号身份根：凭据/下载记录/历史/书签 + Cookie。 */
  static setIdentityDir(dir: string): void {
    entry.setIdentityDir(dir);
  }

  static ensureTalebookConfigured(): boolean {
    const url = TalebookServiceStore.secureGet('talebook_url');
    if (url.length === 0) {
      return false;
    }
    TalebookService.setBaseUrl('talebook', url);
    // 同步到 mybooks_core 模块（书单/书评等新 API 走此通道）
    TalebookCoreService.syncBaseUrl('talebook', url);
    return true;
  }


  static isLoggedInEnvelope(envelope: ApiEnvelope): boolean {
    if (!TalebookService.isApiSuccess(envelope) || envelope.body === null) {
      return false;
    }
    const user = (envelope.body['user'] as Record<string, Object> | undefined) ?? envelope.body;
    if (user['is_login'] !== undefined) {
      return TalebookServiceStore.isLoggedInUser(user);
    }
    return true;
  }

  /**
   * resolveCoverUrl 用的服务器根地址记忆：AuthImage 逐图、BookMapper 逐本都会调
   * resolveCoverUrl，逐次同步 NAPI 读 secure 是纯浪费；值随账号身份根/改地址变化，
   * 由 applyLocalConfig 与 secureSet('talebook_url') 作废。
   */

  static invalidateSession(): void {
    TalebookServiceStore.sessionRestorePromise = null;
    // 切换/保存账号后会话必须重新校验，不能复用上一个账号的通过结果
    TalebookServiceStore.sessionOk = false;
    TalebookServiceStore.sessionCheckedAt = 0;
    TalebookService.invalidateNavCache();
  }

  static invalidateNavCache(): void {
    TalebookServiceStore.navCacheEnvelope = null;
    TalebookServiceStore.navCacheAt = 0;
    TalebookServiceStore.siteInfoCacheEnvelope = null;
    TalebookServiceStore.siteInfoCacheAt = 0;
  }

  static getBookNavCachedAsync(): Promise<ApiEnvelope> {
    const now = Date.now();
    if (TalebookServiceStore.navCacheEnvelope !== null &&
      now - TalebookServiceStore.navCacheAt < TalebookServiceStore.NAV_CACHE_TTL_MS) {
      return Promise.resolve(TalebookServiceStore.navCacheEnvelope);
    }
    return TalebookService.getBookNavAsync().then((envelope: ApiEnvelope) => {
      TalebookServiceStore.navCacheEnvelope = envelope;
      TalebookServiceStore.navCacheAt = Date.now();
      return envelope;
    });
  }

  static getUserInfoCachedAsync(): Promise<ApiEnvelope> {
    const now = Date.now();
    if (TalebookServiceStore.siteInfoCacheEnvelope !== null &&
      now - TalebookServiceStore.siteInfoCacheAt < TalebookServiceStore.NAV_CACHE_TTL_MS) {
      return Promise.resolve(TalebookServiceStore.siteInfoCacheEnvelope);
    }
    return TalebookService.getUserInfoAsync().then((envelope: ApiEnvelope) => {
      TalebookServiceStore.siteInfoCacheEnvelope = envelope;
      TalebookServiceStore.siteInfoCacheAt = Date.now();
      return envelope;
    });
  }

  /**
   * 当前登录账号是否为管理员（`/api/user/info` 的 `is_admin`）。
   *
   * 复用 `getUserInfoCachedAsync` 的缓存，不额外发请求；未登录或取不到时按非管理员处理。
   * 用于收拢「仅管理员可见」的入口（如书单置顶，服务端 `BookListStickyHandler` 为 `@is_admin`）。
   */
  static isCurrentUserAdminAsync(): Promise<boolean> {
    return TalebookService.getUserInfoCachedAsync().then((envelope: ApiEnvelope): boolean => {
      const body: Record<string, Object> | null = envelope.body;
      if (body === null) {
        return false;
      }
      // 服务端两种封装都存在：user/info 直接给字段，部分端点嵌在 user 对象里
      const user: Record<string, Object> =
        (body['user'] as Record<string, Object> | undefined) ?? body;
      const flag: Object | undefined = user['is_admin'];
      return flag === true || String(flag) === '1' || String(flag) === 'true' ||
        String(user['role'] ?? '') === 'admin';
    });
  }

  static ensureAuthenticated(): Promise<boolean> {
    // 每轮会话校验前重置失败原因，避免把上一轮（或切换账号时）的旧原因当成启动结果
    TalebookServiceStore.authFailure_ = '';
    if (TalebookServiceStore.sessionRestorePromise !== null) {
      return TalebookServiceStore.sessionRestorePromise;
    }
    // 刚校验通过的复用窗口内直接返回：60+ 页面的 aboutToAppear 都会进来，逐页 whoami
    // 会把每次进页都串行卡在一个网络往返之后。失败不缓存，仍逐页重试（保住过期/断网时的恢复语义）
    if (TalebookServiceStore.sessionOk &&
      Date.now() - TalebookServiceStore.sessionCheckedAt < TalebookServiceStore.SESSION_RECHECK_TTL_MS) {
      return Promise.resolve(true);
    }
    // 先套用本地配置（身份根 + 两套模块的 base URL + TLS），
    // 否则新账号/未登录场景下两模块地址为空，请求会以 curl 的 malformed URL 报错
    TalebookServiceStore.applyLocalConfig();
    const url = TalebookServiceStore.secureGet('talebook_url');
    if (url.length === 0) {
      return Promise.resolve(false);
    }
    TalebookServiceStore.sessionRestorePromise = TalebookService.restoreSessionAsync()
      .then((ok: boolean): boolean => {
        TalebookServiceStore.sessionOk = ok;
        TalebookServiceStore.sessionCheckedAt = Date.now();
        return ok;
      })
      .finally((): void => {
        TalebookServiceStore.sessionRestorePromise = null;
      });
    return TalebookServiceStore.sessionRestorePromise;
  }

  static restoreSessionIfNeeded(): Promise<void> {
    return TalebookService.ensureAuthenticated().then(() => undefined);
  }

  static async restoreSessionAsync(): Promise<boolean> {
    const attempt = await TalebookService.tryAutoLogin();
    return attempt.ok;
  }

  /** 从登录响应中提取可展示的原因：优先服务端 `msg`（中文提示），其次 `err` 错误码。 */
  static authReason(envelope: ApiEnvelope): string {
    if (envelope.body !== null) {
      const msg = String(envelope.body['msg'] ?? '');
      if (msg.length > 0 && msg !== 'ok') {
        return msg;
      }
    }
    return envelope.error.length > 0 ? envelope.error : '登录失败';
  }

  /**
   * 用已保存的凭据尝试自动登录（不弹 UI）。
   * 失败时返回具体原因，由调用方决定如何展示（跳账号配置页 / 启动提示）。
   */
  static async tryAutoLogin(): Promise<AuthAttempt> {
    const attempt = await TalebookService.autoLoginInternal();
    // 记录本轮结果：登录页已移除，失败原因只在此汇总，由启动流程或账号页取走展示
    TalebookServiceStore.authFailure_ = attempt.ok ? '' : attempt.reason;
    return attempt;
  }

  /** 取走最近一次自动登录失败原因（读取后清空），供启动提示只报一次。 */
  static consumeAuthFailure(): string {
    const reason: string = TalebookServiceStore.authFailure_;
    TalebookServiceStore.authFailure_ = '';
    return reason;
  }

  private static async autoLoginInternal(): Promise<AuthAttempt> {
    TalebookServiceStore.applyLocalConfig();
    const url = TalebookServiceStore.secureGet('talebook_url');
    if (url.length === 0) {
      const noUrl: AuthAttempt = { ok: false, reason: '未配置服务器地址' };
      return noUrl;
    }
    const info = await TalebookService.getUserInfoAsync();
    if (TalebookService.isLoggedInEnvelope(info)) {
      TalebookServiceStore.saveUserProfileFromEnvelope(info);
      const already: AuthAttempt = { ok: true, reason: '' };
      return already;
    }
    const creds = TalebookServiceStore.getLoginCredentials();
    if (creds.username.length === 0 || creds.password.length === 0) {
      const noCreds: AuthAttempt = {
        ok: false,
        reason: '该账号未保存密码，请手动登录一次（之后切换即可自动登录）',
      };
      return noCreds;
    }
    const login = await TalebookService.signInAsync(creds.username, creds.password);
    if (TalebookService.isApiSuccess(login)) {
      const success: AuthAttempt = { ok: true, reason: '' };
      return success;
    }
    const failed: AuthAttempt = { ok: false, reason: TalebookService.authReason(login) };
    return failed;
  }

  static restoreSession(): boolean {
    const url = TalebookServiceStore.secureGet('talebook_url');
    if (url.length === 0) {
      return false;
    }
    TalebookService.setBaseUrl('talebook', url);
    const allowInsecure = TalebookServiceStore.prefGet('allow_insecure_ssl', 'false');
    TalebookServiceStore.prefSet('allow_insecure_ssl', allowInsecure);
    if (TalebookService.isApiSuccess(TalebookService.getUserInfo())) {
      TalebookServiceStore.refreshUserProfile();
      return true;
    }
    const creds = TalebookServiceStore.getLoginCredentials();
    if (creds.username.length === 0 || creds.password.length === 0) {
      return false;
    }
    return TalebookService.isApiSuccess(TalebookService.signIn(creds.username, creds.password));
  }

  static signIn(username: string, password: string): ApiEnvelope {
    try {
      const envelope = TalebookService.parseNative(entry.apiSignIn(username, password));
      if (TalebookService.isApiSuccess(envelope)) {
        // 登录响应不含用户对象，单独拉一次 user/info 写入真实资料
        TalebookServiceStore.refreshUserProfile();
      }
      return envelope;
    } catch (error) {
      return TalebookService.failedEnvelope(`${error}`);
    }
  }

  static signInAsync(username: string, password: string): Promise<ApiEnvelope> {
    return entry.apiSignInAsync(username, password).then((raw: string) => {
      return TalebookService.parseEnvelopeAsync(raw).then((envelope: ApiEnvelope) => {
        return TalebookService.cacheProfileAfterLogin(envelope);
      });
    }).catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  /** 登录成功后缓存真实用户资料（user/info）；失败不影响登录结果本身。 */
  private static cacheProfileAfterLogin(loginEnvelope: ApiEnvelope): Promise<ApiEnvelope> {
    if (!TalebookService.isApiSuccess(loginEnvelope)) {
      return Promise.resolve(loginEnvelope);
    }
    return TalebookService.getUserInfoAsync().then((info: ApiEnvelope) => {
      TalebookServiceStore.saveUserProfileFromEnvelope(info);
      return loginEnvelope;
    });
  }

  static signOut(): ApiEnvelope {
    // 登出后会话不再有效：作废通过结果，下次进页按原语义重新校验（含凭据自动重登）
    TalebookServiceStore.sessionOk = false;
    TalebookServiceStore.sessionCheckedAt = 0;
    return TalebookService.parseEnvelope(entry.apiSignOut());
  }

  static getUserInfo(): ApiEnvelope {
    try {
      return TalebookService.parseNative(entry.apiGetUserInfo());
    } catch (error) {
      return TalebookService.failedEnvelope(`${error}`);
    }
  }

  static getUserInfoAsync(): Promise<ApiEnvelope> {
    return entry.apiGetUserInfoAsync().then((raw: string) => TalebookService.parseEnvelopeAsync(raw))
      .catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  static getIndex(random: number = -1, recent: number = -1): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetIndex(random, recent));
  }

  static searchAsync(name: string, page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return TalebookService.getServerBookListAsync('/api/search', page, limit,
      `name=${encodeURIComponent(name)}`);
  }

  static getRecentAsync(page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return TalebookService.getServerBookListAsync('/api/recent', page, limit);
  }

  static getHotAsync(page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return TalebookService.getServerBookListAsync('/api/hot', page, limit);
  }

  static search(name: string, page: number = 1, limit: number = 20): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiSearch(name, page, limit));
  }

  static getRecent(page: number = 1, limit: number = 20): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetRecent(page, limit));
  }

  static getHot(page: number = 1, limit: number = 20): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetHot(page, limit));
  }

  static getAllBooks(page: number = 1, limit: number = 20): ApiEnvelope {
    try {
      return TalebookService.parseNative(entry.apiGetAllBooks(page, limit));
    } catch (error) {
      return TalebookService.failedEnvelope(`${error}`);
    }
  }

  /** 全部书籍（端点由当前 ServerProfile 决定：mybooks `/api/all`，talebook `/api/library`）。 */
  static getAllBooksAsync(page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return TalebookService.getServerBookListAsync(ServerRegistry.allBooksPath(), page, limit);
  }

  static getBookNav(): ApiEnvelope {
    try {
      return TalebookService.parseNative(entry.apiGetBookNav());
    } catch (error) {
      return TalebookService.failedEnvelope(`${error}`);
    }
  }

  static getBookNavAsync(): Promise<ApiEnvelope> {
    return entry.apiGetBookNavAsync().then((raw: string) => TalebookService.parseEnvelopeAsync(raw))
      .catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  static getBookDetail(bookId: number): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetBookDetail(bookId));
  }

  static getBookDetailAsync(bookId: number): Promise<ApiEnvelope> {
    return entry.apiGetBookDetailAsync(bookId).then((raw: string) => TalebookService.parseEnvelopeAsync(raw))
      .catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  static deleteBook(bookId: number): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiDeleteBook(bookId));
  }

  static setFavorite(bookId: number, favorite: boolean): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiSetFavorite(bookId, favorite));
  }

  static setFavoriteAsync(bookId: number, favorite: boolean): Promise<ApiEnvelope> {
    return entry.apiSetFavoriteAsync(bookId, favorite).then((raw: string) => TalebookService.parseEnvelopeAsync(raw))
      .catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  static getReadingList(page: number = 1, limit: number = 20): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetReadingList(page, limit));
  }

  static getReadingListAsync(page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return TalebookService.getServerBookListAsync('/api/reading', page, limit);
  }

  static getFavorites(page: number = 1, limit: number = 20): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetFavorites(page, limit));
  }

  static getFavoritesAsync(page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return TalebookService.getServerBookListAsync('/api/favorites', page, limit);
  }

  static getMessages(page: number = 1, limit: number = 20): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetMessages(page, limit));
  }

  static getMessagesAsync(page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return entry.apiGetMessagesAsync(page, limit).then((raw: string) => TalebookService.parseEnvelopeAsync(raw))
      .catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  static getMetaList(type: string, page: number = 1, limit: number = 20): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetMetaList(type, page, limit));
  }

  /**
   * 元数据列表（GET /api/{meta}，服务端不分页；meta 键按 ServerProfile 归一化）。
   * `extraQuery` 用于传 `show=all`：条目过多时服务端按热门度截断，该参数可取全量。
   */
  static getMetaListAsync(type: string, page: number = 1, limit: number = 20,
    extraQuery: string = ''): Promise<ApiEnvelope> {
    return TalebookService.getServerBookListAsync(
      `/api/${ServerRegistry.resolveMetaType(type)}`, page, limit, extraQuery);
  }

  /** 元数据下的书籍（GET /api/{meta}/{name}，start/size 分页）。 */
  static getMetaBooksAsync(type: string, name: string, page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return TalebookService.getServerBookListAsync(
      `/api/${ServerRegistry.resolveMetaType(type)}/${encodeURIComponent(name)}`, page, limit);
  }
  static getAdminBooks(page: number = 1, limit: number = 20): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetAdminBooks(page, limit));
  }

  /** 管理端书籍列表（端点与分页由 ServerProfile 决定）。 */
  static getAdminBooksAsync(page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return TalebookService.getListAsync(ServerRegistry.adminBooksPath(),
      ServerRegistry.adminBooksQuery(page, limit));
  }

  /**
   * 通用服务端列表请求（query 已含分页）。
   * 两端 ListHandler 系只识别 start(偏移)+size(每页)，均通过 `ServerProfile.listQuery` 生成。
   */
  private static async getListAsync(path: string, query: string): Promise<ApiEnvelope> {
    try {
      const raw = await TalebookCoreService.talebookGet(`${path}?${query}`);
      const body = JSON.parse(raw) as Record<string, Object>;
      const envelope: ApiEnvelope = { status: 200, body: body, error: '' };
      envelope.error = TalebookService.apiMessage(envelope);
      return envelope;
    } catch (error) {
      return TalebookService.failedEnvelope(`${error}`);
    }
  }

  /** 通用服务端书籍列表（分页由当前 ServerProfile 决定）。 */
  static getServerBookListAsync(path: string, page: number = 1, limit: number = 20,
    extraQuery: string = ''): Promise<ApiEnvelope> {
    const query = ServerRegistry.listQuery(page, limit);
    return TalebookService.getListAsync(path, extraQuery.length > 0 ? `${query}&${extraQuery}` : query);
  }

  static getAdminUsers(page: number = 1, limit: number = 20): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetAdminUsers(page, limit));
  }

  static soNovelSearch(keyword: string): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiSoNovelSearch(keyword));
  }

  static soNovelFetchBook(payload: SoNovelBookPayload, destPath: string): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiSoNovelFetchBook(JSON.stringify(payload), destPath));
  }

  static downloadBook(bookId: number, format: string, destPath: string): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiDownloadBook(bookId, format, destPath));
  }

  static downloadBookAsync(bookId: number, format: string, destPath: string): Promise<ApiEnvelope> {
    return entry.apiDownloadBookAsync(bookId, format, destPath).then((raw: string) => TalebookService.parseEnvelopeAsync(raw))
      .catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  static downloadAudioFileAsync(bookId: number, filename: string, destPath: string): Promise<ApiEnvelope> {
    return entry.apiDownloadAudioFileAsync(bookId, filename, destPath).then((raw: string) => TalebookService.parseEnvelopeAsync(raw))
      .catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  static editBook(bookId: number, payload: Record<string, Object>): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiEditBook(bookId, JSON.stringify(payload)));
  }

  static editBookAsync(bookId: number, payload: Record<string, Object>): Promise<ApiEnvelope> {
    return entry.apiEditBookAsync(bookId, JSON.stringify(payload)).then((raw: string) => TalebookService.parseEnvelopeAsync(raw))
      .catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  static getBookRefer(bookId: number): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetBookRefer(bookId));
  }

  static getAudioFiles(bookId: number): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiGetAudioFiles(bookId));
  }

  static markMessageRead(messageId: number): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.apiMarkMessageRead(messageId));
  }

  static markMessageReadAsync(messageId: number): Promise<ApiEnvelope> {
    return entry.apiMarkMessageReadAsync(messageId)
      .then((raw: string) => TalebookService.parseEnvelopeAsync(raw))
      .catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  /** 委托 TalebookServiceStore.secureGet（本地持久化域）。 */
  static secureGet(key: string): string {
    return TalebookServiceStore.secureGet(key);
  }
  /** 委托 TalebookServiceStore.secureSet（本地持久化域）。 */
  static secureSet(key: string, value: string): void {
    TalebookServiceStore.secureSet(key, value);
  }
  /** 委托 TalebookServiceStore.migratePlaintextSecrets（本地持久化域）。 */
  static migratePlaintextSecrets(): void {
    TalebookServiceStore.migratePlaintextSecrets();
  }
  /** 委托 TalebookServiceStore.prefGet（本地持久化域）。 */
  static prefGet(key: string, defaultValue: string = ''): string {
    return TalebookServiceStore.prefGet(key, defaultValue);
  }
  /** 委托 TalebookServiceStore.prefSet（本地持久化域）。 */
  static prefSet(key: string, value: string): void {
    TalebookServiceStore.prefSet(key, value);
  }
  /** 委托 TalebookServiceStore.prefSetBatch（本地持久化域）。 */
  static prefSetBatch(values: Record<string, string>): void {
    TalebookServiceStore.prefSetBatch(values);
  }
  /** 委托 TalebookServiceStore.getDownloads（本地持久化域）。 */
  static getDownloads(): DownloadRecord[] {
    return TalebookServiceStore.getDownloads();
  }
  /** 委托 TalebookServiceStore.saveDownloads（本地持久化域）。 */
  static saveDownloads(records: DownloadRecord[], notify: boolean = true, persist: boolean = true): void {
    TalebookServiceStore.saveDownloads(records, notify, persist);
  }
  /** 委托 TalebookServiceStore.getReadingHistory（本地持久化域）。 */
  static getReadingHistory(): ReadingHistoryItem[] {
    return TalebookServiceStore.getReadingHistory();
  }
  /** 委托 TalebookServiceStore.saveReadingHistory（本地持久化域）。 */
  static saveReadingHistory(records: ReadingHistoryItem[]): void {
    TalebookServiceStore.saveReadingHistory(records);
  }
  /** 委托 TalebookServiceStore.replaceReadingHistory（本地持久化域）。 */
  static replaceReadingHistory(records: ReadingHistoryItem[], persist: boolean = true): void {
    TalebookServiceStore.replaceReadingHistory(records, persist);
  }
  /** 委托 TalebookServiceStore.persistLocalCaches（本地持久化域）。 */
  static persistLocalCaches(): void {
    TalebookServiceStore.persistLocalCaches();
  }
  /** 委托 TalebookServiceStore.invalidateLocalCaches（本地持久化域）。 */
  static invalidateLocalCaches(): void {
    TalebookServiceStore.invalidateLocalCaches();
  }
  /** 委托 TalebookServiceStore.getBookmarks（本地持久化域）。 */
  static getBookmarks(): Record<string, Object>[] {
    return TalebookServiceStore.getBookmarks();
  }
  /** 委托 TalebookServiceStore.saveBookmarks（本地持久化域）。 */
  static saveBookmarks(records: Record<string, Object>[]): void {
    TalebookServiceStore.saveBookmarks(records);
  }
  /** 委托 TalebookServiceStore.getLoginCredentials（本地持久化域）。 */
  static getLoginCredentials(): LoginCredentials {
    return TalebookServiceStore.getLoginCredentials();
  }
  /** 委托 TalebookServiceStore.saveLoginCredentials（本地持久化域）。 */
  static saveLoginCredentials(username: string, password: string): void {
    TalebookServiceStore.saveLoginCredentials(username, password);
  }
  /** 委托 TalebookServiceStore.isLoggedInUser（本地持久化域）。 */
  static isLoggedInUser(record: Record<string, Object>): boolean {
    return TalebookServiceStore.isLoggedInUser(record);
  }
  /** 委托 TalebookServiceStore.saveUserProfile（本地持久化域）。 */
  static saveUserProfile(user: Record<string, Object>): void {
    TalebookServiceStore.saveUserProfile(user);
  }
  /** 委托 TalebookServiceStore.getSavedUserProfile（本地持久化域）。 */
  static getSavedUserProfile(): Record<string, Object> | null {
    return TalebookServiceStore.getSavedUserProfile();
  }
  /** 委托 TalebookServiceStore.saveUserProfileFromEnvelope（本地持久化域）。 */
  static saveUserProfileFromEnvelope(envelope: ApiEnvelope): void {
    TalebookServiceStore.saveUserProfileFromEnvelope(envelope);
  }
  /** 委托 TalebookServiceStore.refreshUserProfile（本地持久化域）。 */
  static refreshUserProfile(): void {
    TalebookServiceStore.refreshUserProfile();
  }
  /** 委托 TalebookServiceStore.applyLocalConfig（本地持久化域）。 */
  static applyLocalConfig(): void {
    TalebookServiceStore.applyLocalConfig();
  }
  /** 委托 TalebookServiceStore.hasAuthCredentials（本地持久化域）。 */
  static hasAuthCredentials(): boolean {
    return TalebookServiceStore.hasAuthCredentials();
  }
  /** 委托 TalebookServiceStore.applySonovelUrl（本地持久化域）。 */
  static applySonovelUrl(url: string): void {
    TalebookServiceStore.applySonovelUrl(url);
  }
  /** 委托 TalebookServiceStore.fetchImageCache（本地持久化域）。 */
  static fetchImageCache(url: string, destPath: string): ApiEnvelope {
    return TalebookServiceStore.fetchImageCache(url, destPath);
  }
  /** 委托 TalebookServiceStore.fetchImageCacheAsync（本地持久化域）。 */
  static fetchImageCacheAsync(url: string, destPath: string): Promise<ApiEnvelope> {
    return TalebookServiceStore.fetchImageCacheAsync(url, destPath);
  }
  /** 委托 TalebookServiceStore.resolveCoverUrl（本地持久化域）。 */
  static resolveCoverUrl(cover: string): string {
    return TalebookServiceStore.resolveCoverUrl(cover);
  }
  /** 委托 TalebookServiceStore.upsertDownloadRecord（本地持久化域）。 */
  static upsertDownloadRecord(record: DownloadRecord): void {
    TalebookServiceStore.upsertDownloadRecord(record);
  }
  /** 委托 TalebookServiceStore.syncDownloadMeta（#1638 元数据同步本地书架快照）。 */
  static syncDownloadMeta(bookId: string, title: string, author: string, coverUrl: string): boolean {
    return TalebookServiceStore.syncDownloadMeta(bookId, title, author, coverUrl);
  }
  /**
   * 服务端元数据被远端改动（AI 补全等）后重取 detail 并同步本地书架（#1638）。
   * 书未下载（无本地记录）时静默跳过；不下载任何文件内容。
   */
  static async syncLocalBookMeta(bookId: number): Promise<void> {
    const envelope = await TalebookService.getBookDetailAsync(bookId);
    const body: Record<string, Object> = envelope.body ?? {};
    const book: Record<string, Object> = (body['book'] as Record<string, Object> | undefined) ?? body;
    const title: string = String(book['title'] ?? '');
    const authors: string[] = Array.isArray(book['authors']) ? (book['authors'] as string[]) : [];
    const cover: string = String(book['cover'] ?? '');
    TalebookServiceStore.syncDownloadMeta(`${bookId}`, title, authors.length > 0 ? authors[0] : '', cover);
  }
  /** 委托 TalebookServiceStore.removeDownloadRecord（本地持久化域）。 */
  static removeDownloadRecord(bookId: string, deleteFile: boolean = true): void {
    TalebookServiceStore.removeDownloadRecord(bookId, deleteFile);
  }
  /** 委托 TalebookServiceStore.removeHistoryItem（本地持久化域）。 */
  static removeHistoryItem(bookId: string, filePath: string = ''): void {
    TalebookServiceStore.removeHistoryItem(bookId, filePath);
  }
  /** 委托 TalebookServiceStore.upsertHistoryItem（本地持久化域）。 */
  static upsertHistoryItem(item: ReadingHistoryItem, persist: boolean = true): void {
    TalebookServiceStore.upsertHistoryItem(item, persist);
  }
  /** 委托 TalebookServiceStore.resolveSavedLocation（本地持久化域）。 */
  static resolveSavedLocation(bookId: string, filePath: string = ''): string {
    return TalebookServiceStore.resolveSavedLocation(bookId, filePath);
  }
}

