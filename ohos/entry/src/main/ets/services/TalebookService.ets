import entry from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookshelfRefresh } from '../utils/BookshelfRefresh';
import { parseApiEnvelopeTask, parseJsonArrayTask } from './TalebookJsonParser';
import { TalebookCoreService } from './TalebookCoreService';
import { PasswordStore } from './PasswordStore';
import { ServerRegistry, ServerKind } from './ServerProfile';
import { ACTIVE_ACCOUNT_KEY, identityDirFor, LEGACY_PASSWORD_ALIAS, passwordAliasFor } from '../models/AccountModels';

export interface ApiEnvelope {
  status: number;
  body: Record<string, Object> | null;
  error: string;
}

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
}

export interface SoNovelBookPayload {
  sourceId: number;
  sourceName: string;
  url: string;
  bookName: string;
  author: string;
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
  private static downloadsCache: DownloadRecord[] | null = null;
  private static historyCache: ReadingHistoryItem[] | null = null;
  private static imageLoadTasks: Map<string, Promise<ApiEnvelope>> = new Map();
  private static localCacheWarmPromise: Promise<void> | null = null;
  private static readonly LARGE_JSON_THRESHOLD: number = 32768;
  /** 由 Asset Store Kit 加密保存的密码类键，不再写入明文 JSON。 */
  private static readonly PASSWORD_KEYS: string[] = ['talebook_password'];
  private static passwordMigrated: boolean = false;
  /** 应用数据根目录（全局根）；账号身份根在该目录下的 accounts/<id>。 */
  private static dataDir_: string = '';

  /** 应用数据根目录（全局偏好所在位置）。 */
  static dataDir(): string {
    return TalebookService.dataDir_;
  }

  static init(dataDir: string): void {
    if (TalebookService.initialized) {
      return;
    }
    try {
      entry.init(dataDir);
      TalebookService.dataDir_ = dataDir;
      TalebookService.initialized = true;
    } catch (error) {
      hilog.error(0x0000, TAG, 'init failed: %{public}s', String(error));
    }
  }

  private static parseNative(raw: string): ApiEnvelope {
    return TalebookService.parseEnvelope(raw);
  }

  private static failedEnvelope(message: string): ApiEnvelope {
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
    if (TalebookService.localCacheWarmPromise !== null) {
      return TalebookService.localCacheWarmPromise;
    }
    TalebookService.localCacheWarmPromise = TalebookService.warmLocalCachesInternal();
    return TalebookService.localCacheWarmPromise;
  }

  private static async warmLocalCachesInternal(): Promise<void> {
    if (TalebookService.downloadsCache === null) {
      const downloadsRaw: string = entry.getDownloads();
      try {
        if (downloadsRaw.length >= TalebookService.LARGE_JSON_THRESHOLD) {
          const parsed: Array<Object> =
            await (taskpool.execute(parseJsonArrayTask, downloadsRaw) as Promise<Array<Object>>);
          TalebookService.downloadsCache = parsed as DownloadRecord[];
        } else if (downloadsRaw.length > 0) {
          TalebookService.downloadsCache = JSON.parse(downloadsRaw) as DownloadRecord[];
        } else {
          TalebookService.downloadsCache = [];
        }
      } catch (_error) {
        TalebookService.downloadsCache = downloadsRaw.length > 0
          ? JSON.parse(downloadsRaw) as DownloadRecord[]
          : [];
      }
    }
    if (TalebookService.historyCache === null) {
      const historyRaw: string = entry.getReadingHistory();
      try {
        if (historyRaw.length >= TalebookService.LARGE_JSON_THRESHOLD) {
          const parsed: Array<Object> =
            await (taskpool.execute(parseJsonArrayTask, historyRaw) as Promise<Array<Object>>);
          TalebookService.historyCache = parsed as ReadingHistoryItem[];
        } else if (historyRaw.length > 0) {
          TalebookService.historyCache = JSON.parse(historyRaw) as ReadingHistoryItem[];
        } else {
          TalebookService.historyCache = [];
        }
      } catch (_error) {
        TalebookService.historyCache = historyRaw.length > 0
          ? JSON.parse(historyRaw) as ReadingHistoryItem[]
          : [];
      }
    }
  }

  /** 预热 DNS/TCP/TLS，后续请求复用连接 */
  static warmConnection(): Promise<void> {
    const url = TalebookService.secureGet('talebook_url');
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

  static setBaseUrl(service: string, url: string): void {
    entry.setBaseUrl(service, url);
  }

  /** 切换本模块（libentry）的账号身份根：凭据/下载记录/历史/书签 + Cookie。 */
  static setIdentityDir(dir: string): void {
    entry.setIdentityDir(dir);
  }

  static ensureTalebookConfigured(): boolean {
    const url = TalebookService.secureGet('talebook_url');
    if (url.length === 0) {
      return false;
    }
    TalebookService.setBaseUrl('talebook', url);
    // 同步到 mybooks_core 模块（书单/书评等新 API 走此通道）
    TalebookCoreService.syncBaseUrl('talebook', url);
    return true;
  }

  static secureGet(key: string): string {
    if (TalebookService.PASSWORD_KEYS.indexOf(key) >= 0) {
      return TalebookService.readPassword();
    }
    if (TalebookService.isGlobalSecureKey(key)) {
      return entry.secureGetGlobal(key);
    }
    return entry.secureGet(key);
  }

  static secureSet(key: string, value: string): void {
    if (TalebookService.PASSWORD_KEYS.indexOf(key) >= 0) {
      PasswordStore.set(TalebookService.activePasswordAlias(), value);
      return;
    }
    if (TalebookService.isGlobalSecureKey(key)) {
      entry.secureSetGlobal(key, value);
      return;
    }
    entry.secureSet(key, value);
  }

  /**
   * 全局（不随账号）凭据键前缀：SoNovel 是独立第三方服务，其地址不随账号切换。
   * 升级前的单账号安装其身份根就是全局根，因此历史值无需迁移即可被读到。
   */
  private static isGlobalSecureKey(key: string): boolean {
    return key.startsWith('sonovel_');
  }

  /** 当前账号对应的密码别名；默认（历史）账号沿用旧别名以复用已保存的密码。 */
  private static activePasswordAlias(): string {
    return passwordAliasFor(entry.prefGet(ACTIVE_ACCOUNT_KEY));
  }

  /**
   * 读取当前账号的密码（始终来自 Asset Store）。
   * 旧版把密码明文存在 secure JSON 中，且键名与默认账号别名相同，故仅对默认账号做一次迁移。
   * 新账号可能有不同的密码，不能回退到默认账号的明文，否则会串账号。
   */
  private static readPassword(): string {
    const alias: string = TalebookService.activePasswordAlias();
    const secret: string = PasswordStore.get(alias);
    if (secret.length > 0) {
      return secret;
    }
    if (alias !== LEGACY_PASSWORD_ALIAS || TalebookService.passwordMigrated) {
      return '';
    }
    TalebookService.passwordMigrated = true;
    const legacy: string = entry.secureGet(LEGACY_PASSWORD_ALIAS);
    if (legacy.length > 0) {
      PasswordStore.set(alias, legacy);
      entry.secureSet(LEGACY_PASSWORD_ALIAS, '');
    }
    return legacy;
  }

  static prefGet(key: string, defaultValue: string = ''): string {
    const value: string = entry.prefGet(key);
    return value.length > 0 ? value : defaultValue;
  }

  static prefSet(key: string, value: string): void {
    entry.prefSet(key, value);
    if (key === 'allow_insecure_ssl') {
      TalebookCoreService.setSslVerify(value === 'true');
    }
  }

  static prefSetBatch(values: Record<string, string>): void {
    entry.prefSetBatch(JSON.stringify(values));
    const allowInsecure = values['allow_insecure_ssl'];
    if (allowInsecure !== undefined) {
      TalebookCoreService.setSslVerify(allowInsecure === 'true');
    }
  }

  static getDownloads(): DownloadRecord[] {
    if (TalebookService.downloadsCache !== null) {
      return TalebookService.downloadsCache;
    }
    TalebookService.downloadsCache = JSON.parse(entry.getDownloads()) as DownloadRecord[];
    return TalebookService.downloadsCache;
  }

  static saveDownloads(records: DownloadRecord[], notify: boolean = true, persist: boolean = true): void {
    TalebookService.downloadsCache = records;
    if (persist) {
      entry.saveDownloads(JSON.stringify(records));
    }
    if (notify) {
      BookshelfRefresh.notify();
    }
  }

  static getReadingHistory(): ReadingHistoryItem[] {
    if (TalebookService.historyCache !== null) {
      return TalebookService.historyCache;
    }
    TalebookService.historyCache = JSON.parse(entry.getReadingHistory()) as ReadingHistoryItem[];
    return TalebookService.historyCache;
  }

  static saveReadingHistory(records: ReadingHistoryItem[]): void {
    entry.saveReadingHistory(JSON.stringify(records));
    TalebookService.historyCache = records;
  }

  static replaceReadingHistory(records: ReadingHistoryItem[], persist: boolean = true): void {
    TalebookService.historyCache = records;
    if (persist) {
      entry.saveReadingHistory(JSON.stringify(records));
    }
  }

  /** 将内存中的下载/历史缓存落盘（不触发书架刷新） */
  static persistLocalCaches(): void {
    if (TalebookService.downloadsCache !== null) {
      entry.saveDownloads(JSON.stringify(TalebookService.downloadsCache));
    }
    if (TalebookService.historyCache !== null) {
      entry.saveReadingHistory(JSON.stringify(TalebookService.historyCache));
    }
  }

  static invalidateLocalCaches(): void {
    TalebookService.downloadsCache = null;
    TalebookService.historyCache = null;
    // 允许下一次 warmLocalCaches() 按新账号重新预热
    TalebookService.localCacheWarmPromise = null;
  }

  static getBookmarks(): Record<string, Object>[] {
    return JSON.parse(entry.getBookmarks()) as Record<string, Object>[];
  }

  static saveBookmarks(records: Record<string, Object>[]): void {
    entry.saveBookmarks(JSON.stringify(records));
  }

  static getLoginCredentials(): LoginCredentials {
    return {
      username: TalebookService.secureGet('talebook_username'),
      password: TalebookService.secureGet('talebook_password'),
    };
  }

  static saveLoginCredentials(username: string, password: string): void {
    TalebookService.secureSet('talebook_username', username);
    TalebookService.secureSet('talebook_password', password);
  }

  static saveUserProfile(user: Record<string, Object>): void {
    TalebookService.secureSet('talebook_user_profile', JSON.stringify(user));
  }

  static getSavedUserProfile(): Record<string, Object> | null {
    const raw = TalebookService.secureGet('talebook_user_profile');
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as Record<string, Object>;
    } catch (_error) {
      return null;
    }
  }

  static saveUserProfileFromEnvelope(envelope: ApiEnvelope): void {
    if (!TalebookService.isApiSuccess(envelope) || envelope.body === null) {
      return;
    }
    const user = (envelope.body['user'] as Record<string, Object> | undefined) ?? envelope.body;
    TalebookService.saveUserProfile(user);
  }

  static refreshUserProfile(): void {
    const envelope = TalebookService.parseEnvelope(entry.apiGetUserInfo());
    if (!TalebookService.isApiSuccess(envelope) || envelope.body === null) {
      return;
    }
    const user = (envelope.body['user'] as Record<string, Object> | undefined) ?? envelope.body;
    TalebookService.saveUserProfile(user);
  }

  static applyLocalConfig(): void {
    // 先恢复当前账号的身份根：凭据/下载记录/历史/书签与其 Cookie 都随账号隔离
    const identityDir = identityDirFor(TalebookService.dataDir_, entry.prefGet(ACTIVE_ACCOUNT_KEY));
    TalebookService.setIdentityDir(identityDir);
    TalebookCoreService.setIdentityDir(identityDir);
    // 再恢复服务端类型，后续端点/分页/能力判定均依赖它
    const kind = TalebookService.prefGet(ServerRegistry.PREF_KEY, ServerKind.MYBOOKS);
    ServerRegistry.setKind(ServerRegistry.parse(kind));
    const url = TalebookService.secureGet('talebook_url');
    if (url.length > 0) {
      TalebookService.setBaseUrl('talebook', url);
      TalebookCoreService.syncBaseUrl('talebook', url);
    }
    const sonovelUrl = TalebookService.secureGet('sonovel_url');
    if (sonovelUrl.length > 0) {
      TalebookCoreService.syncBaseUrl('sonovel', sonovelUrl);
    }
    const allowInsecure = TalebookService.prefGet('allow_insecure_ssl', 'false');
    TalebookService.prefSet('allow_insecure_ssl', allowInsecure);
  }

  static hasAuthCredentials(): boolean {
    const url = TalebookService.secureGet('talebook_url');
    const creds = TalebookService.getLoginCredentials();
    return url.length > 0 && creds.username.length > 0 && creds.password.length > 0;
  }

  static isLoggedInEnvelope(envelope: ApiEnvelope): boolean {
    if (!TalebookService.isApiSuccess(envelope) || envelope.body === null) {
      return false;
    }
    const user = (envelope.body['user'] as Record<string, Object> | undefined) ?? envelope.body;
    if (user['is_login'] !== undefined) {
      return Boolean(user['is_login']);
    }
    return true;
  }

  private static sessionRestorePromise: Promise<boolean> | null = null;
  private static navCacheEnvelope: ApiEnvelope | null = null;
  private static navCacheAt: number = 0;
  private static siteInfoCacheEnvelope: ApiEnvelope | null = null;
  private static siteInfoCacheAt: number = 0;
  private static readonly NAV_CACHE_TTL_MS: number = 60000;

  static invalidateSession(): void {
    TalebookService.sessionRestorePromise = null;
    TalebookService.invalidateNavCache();
  }

  static invalidateNavCache(): void {
    TalebookService.navCacheEnvelope = null;
    TalebookService.navCacheAt = 0;
    TalebookService.siteInfoCacheEnvelope = null;
    TalebookService.siteInfoCacheAt = 0;
  }

  static getBookNavCachedAsync(): Promise<ApiEnvelope> {
    const now = Date.now();
    if (TalebookService.navCacheEnvelope !== null &&
      now - TalebookService.navCacheAt < TalebookService.NAV_CACHE_TTL_MS) {
      return Promise.resolve(TalebookService.navCacheEnvelope);
    }
    return TalebookService.getBookNavAsync().then((envelope: ApiEnvelope) => {
      TalebookService.navCacheEnvelope = envelope;
      TalebookService.navCacheAt = Date.now();
      return envelope;
    });
  }

  static getUserInfoCachedAsync(): Promise<ApiEnvelope> {
    const now = Date.now();
    if (TalebookService.siteInfoCacheEnvelope !== null &&
      now - TalebookService.siteInfoCacheAt < TalebookService.NAV_CACHE_TTL_MS) {
      return Promise.resolve(TalebookService.siteInfoCacheEnvelope);
    }
    return TalebookService.getUserInfoAsync().then((envelope: ApiEnvelope) => {
      TalebookService.siteInfoCacheEnvelope = envelope;
      TalebookService.siteInfoCacheAt = Date.now();
      return envelope;
    });
  }

  static ensureAuthenticated(): Promise<boolean> {
    if (TalebookService.sessionRestorePromise !== null) {
      return TalebookService.sessionRestorePromise;
    }
    // 先套用本地配置（身份根 + 两套模块的 base URL + TLS），
    // 否则新账号/未登录场景下两模块地址为空，请求会以 curl 的 malformed URL 报错
    TalebookService.applyLocalConfig();
    const url = TalebookService.secureGet('talebook_url');
    if (url.length === 0) {
      return Promise.resolve(false);
    }
    TalebookService.sessionRestorePromise = TalebookService.restoreSessionAsync().finally(() => {
      TalebookService.sessionRestorePromise = null;
    });
    return TalebookService.sessionRestorePromise;
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
   * 失败时返回具体原因，由调用方决定是否跳转登录页并把原因展示给用户。
   */
  static async tryAutoLogin(): Promise<AuthAttempt> {
    TalebookService.applyLocalConfig();
    const url = TalebookService.secureGet('talebook_url');
    if (url.length === 0) {
      const noUrl: AuthAttempt = { ok: false, reason: '未配置服务器地址' };
      return noUrl;
    }
    const info = await TalebookService.getUserInfoAsync();
    if (TalebookService.isLoggedInEnvelope(info)) {
      TalebookService.saveUserProfileFromEnvelope(info);
      const already: AuthAttempt = { ok: true, reason: '' };
      return already;
    }
    const creds = TalebookService.getLoginCredentials();
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
    const url = TalebookService.secureGet('talebook_url');
    if (url.length === 0) {
      return false;
    }
    TalebookService.setBaseUrl('talebook', url);
    const allowInsecure = TalebookService.prefGet('allow_insecure_ssl', 'false');
    TalebookService.prefSet('allow_insecure_ssl', allowInsecure);
    if (TalebookService.isApiSuccess(TalebookService.getUserInfo())) {
      TalebookService.refreshUserProfile();
      return true;
    }
    const creds = TalebookService.getLoginCredentials();
    if (creds.username.length === 0 || creds.password.length === 0) {
      return false;
    }
    return TalebookService.isApiSuccess(TalebookService.signIn(creds.username, creds.password));
  }

  static signIn(username: string, password: string): ApiEnvelope {
    try {
      const envelope = TalebookService.parseNative(entry.apiSignIn(username, password));
      TalebookService.saveUserProfileFromEnvelope(envelope);
      return envelope;
    } catch (error) {
      return TalebookService.failedEnvelope(`${error}`);
    }
  }

  static signInAsync(username: string, password: string): Promise<ApiEnvelope> {
    return entry.apiSignInAsync(username, password).then((raw: string) => {
      return TalebookService.parseEnvelopeAsync(raw).then((envelope: ApiEnvelope) => {
        TalebookService.saveUserProfileFromEnvelope(envelope);
        return envelope;
      });
    }).catch((error: Object) => TalebookService.failedEnvelope(`${error}`));
  }

  static signOut(): ApiEnvelope {
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

  /** 元数据列表（GET /api/{meta}，服务端不分页；meta 键按 ServerProfile 归一化）。 */
  static getMetaListAsync(type: string, page: number = 1, limit: number = 20): Promise<ApiEnvelope> {
    return TalebookService.getServerBookListAsync(
      `/api/${ServerRegistry.resolveMetaType(type)}`, page, limit);
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

  static fetchImageCache(url: string, destPath: string): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.fetchImageCache(url, destPath));
  }

  static fetchImageCacheAsync(url: string, destPath: string): Promise<ApiEnvelope> {
    const existing = TalebookService.imageLoadTasks.get(destPath);
    if (existing !== undefined) {
      return existing;
    }
    const task: Promise<ApiEnvelope> = entry.fetchImageCacheAsync(url, destPath).then((raw: string) => {
      TalebookService.imageLoadTasks.delete(destPath);
      return TalebookService.parseEnvelopeAsync(raw);
    }).catch((error: Object): ApiEnvelope => {
      TalebookService.imageLoadTasks.delete(destPath);
      return TalebookService.failedEnvelope(`${error}`);
    });
    TalebookService.imageLoadTasks.set(destPath, task);
    return task;
  }

  static resolveCoverUrl(cover: string): string {
    if (cover.length === 0) {
      return '';
    }
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return cover;
    }
    const base = TalebookService.secureGet('talebook_url');
    if (base.length === 0) {
      return cover;
    }
    return base + (cover.startsWith('/') ? cover : `/${cover}`);
  }

  static upsertDownloadRecord(record: DownloadRecord): void {
    const records = TalebookService.getDownloads();
    const index = records.findIndex((item) => item.bookId === record.bookId);
    if (index >= 0) {
      records[index] = record;
    } else {
      records.unshift(record);
    }
    TalebookService.saveDownloads(records);
    BookshelfRefresh.notify();
  }

  static removeDownloadRecord(bookId: string, deleteFile: boolean = true): void {
    const records = TalebookService.getDownloads();
    const target = records.find((item) => item.bookId === bookId);
    const filtered = records.filter((item) => item.bookId !== bookId);
    TalebookService.saveDownloads(filtered);
    if (deleteFile && target?.filePath !== undefined && target.filePath.length > 0) {
      try {
        if (fs.accessSync(target.filePath)) {
          fs.unlinkSync(target.filePath);
        }
      } catch (_error) {
      }
    }
    TalebookService.removeHistoryItem(bookId, target?.filePath ?? '');
    BookshelfRefresh.notify();
  }

  static removeHistoryItem(bookId: string, filePath: string = ''): void {
    const records = TalebookService.getReadingHistory().filter((item) => {
      if (item.bookId === bookId && bookId.length > 0) {
        return false;
      }
      if (filePath.length > 0 && item.filePath === filePath) {
        return false;
      }
      return true;
    });
    TalebookService.saveReadingHistory(records);
  }

  static upsertHistoryItem(item: ReadingHistoryItem, persist: boolean = true): void {
    const records = TalebookService.getReadingHistory();
    const index = records.findIndex((r) =>
      r.bookId === item.bookId ||
      (item.filePath !== undefined && item.filePath.length > 0 && r.filePath === item.filePath));
    if (index >= 0) {
      records.splice(index, 1);
    }
    records.unshift(item);
    if (records.length > 200) {
      records.length = 200;
    }
    if (persist) {
      TalebookService.saveReadingHistory(records);
    } else {
      TalebookService.historyCache = records;
    }
  }

  static resolveSavedLocation(bookId: string, filePath: string = ''): string {
    const downloads = TalebookService.getDownloads();
    let local = downloads.find((item) => item.bookId === bookId && bookId.length > 0);
    if (local === undefined && filePath.length > 0) {
      local = downloads.find((item) => item.filePath === filePath);
    }
    if (local?.progress?.location !== undefined && local.progress.location.length > 0) {
      return local.progress.location;
    }
    const history = TalebookService.getReadingHistory();
    let item = history.find((entry: ReadingHistoryItem) => entry.bookId === bookId && bookId.length > 0);
    if (item === undefined && filePath.length > 0) {
      item = history.find((entry: ReadingHistoryItem) => entry.filePath === filePath);
    }
    return item?.location ?? '';
  }
}
