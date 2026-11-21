/**
 * TalebookService 本地持久化域（拆分自 TalebookService.ets，800 行门禁）：
 * 密钥/偏好读写、下载与阅读记录、书签、凭据与 profile、图片缓存与封面/导航缓存。
 * 门面 TalebookService 保留同名薄委托与登录会话逻辑，外部调用面不变。
 */
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
import type { ApiEnvelope, DownloadRecord, LoginCredentials, ReadingHistoryItem } from './TalebookService';
import { TalebookService } from './TalebookService'; // 跨域调用门面（调用期求值，加载期无环）

const TAG: string = 'TalebookService';

export class TalebookServiceStore {
  static downloadsCache: DownloadRecord[] | null = null;
  static historyCache: ReadingHistoryItem[] | null = null;
  static imageLoadTasks: Map<string, Promise<ApiEnvelope>> = new Map();
  static localCacheWarmPromise: Promise<void> | null = null;
  /** 由 Asset Store Kit 加密保存的密码类键，不再写入明文 JSON。 */
  static readonly PASSWORD_KEYS: string[] = ['talebook_password'];
  /** 应用数据根目录（全局根）；账号身份根在该目录下的 accounts/<id>。 */
  static dataDir_: string = '';
  /** 最近一次自动登录失败原因（空串 = 无失败）；登录页已移除，该值仅用于提示。 */
  static authFailure_: string = '';
  static sessionRestorePromise: Promise<boolean> | null = null;
  static coverBaseUrl: string | null = null;
  /** 会话校验通过结果的复用窗口：进页高频，逐页 whoami 会把每次进页都串行卡在一个网络往返之后。 */
  static sessionOk: boolean = false;
  static sessionCheckedAt: number = 0;
  static readonly SESSION_RECHECK_TTL_MS: number = 60000;
  static navCacheEnvelope: ApiEnvelope | null = null;
  static navCacheAt: number = 0;
  static siteInfoCacheEnvelope: ApiEnvelope | null = null;
  static siteInfoCacheAt: number = 0;
  static readonly NAV_CACHE_TTL_MS: number = 60000;

  static secureGet(key: string): string {
    if (TalebookServiceStore.isAssetKey(key)) {
      return PasswordStore.get(TalebookServiceStore.activeAliasFor(key));
    }
    if (TalebookServiceStore.isGlobalSecureKey(key)) {
      return entry.secureGetGlobal(key);
    }
    return entry.secureGet(key);
  }

  static secureSet(key: string, value: string): void {
    if (TalebookServiceStore.isAssetKey(key)) {
      PasswordStore.set(TalebookServiceStore.activeAliasFor(key), value);
      // 明文通道里可能还留着同一个键（升级前写入的），一并擦除，避免旧值继续可读
      if (key !== 'talebook_password') {
        entry.secureSet(key, '');
      }
      return;
    }
    if (key === 'talebook_url') {
      // cover 拼接记忆的是旧地址：改地址后必须作废，否则新封面仍按旧 base 拼
      TalebookServiceStore.coverBaseUrl = null;
    }
    if (TalebookServiceStore.isGlobalSecureKey(key)) {
      entry.secureSetGlobal(key, value);
      return;
    }
    entry.secureSet(key, value);
  }

  /**
   * 必须进系统关键资产存储（Asset Store）的键：密码、用户名、用户资料。
   *
   * 用户资料里含 `podcast_token`（播客订阅凭据），用户名属账号身份信息，
   * 三者都不允许明文落盘，因此统一走 Asset Store，只有连接受限的服务端地址等
   * 非敏感配置才留在 native 的明文 JSON 里。
   */
  private static isAssetKey(key: string): boolean {
    return TalebookServiceStore.PASSWORD_KEYS.indexOf(key) >= 0
      || key === 'talebook_username' || key === 'talebook_user_profile';
  }

  /** 把对外的键名映射为「当前账号」在 Asset Store 中的别名。 */
  private static activeAliasFor(key: string): string {
    const id: string = entry.prefGet(ACTIVE_ACCOUNT_KEY);
    if (key === 'talebook_password') {
      return passwordAliasFor(id);
    }
    if (key === 'talebook_username') {
      return usernameAliasFor(id);
    }
    return profileAliasFor(id);
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
   * 凭据明文存储迁移：把历史版本写在 native 明文 JSON 里的密码/用户名/用户资料
   * 搬进 Asset Store，并立刻从明文通道删除。
   *
   * 旧版只是「读到密码时才迁移」，若用户升级后一直能自动登录（读到的是 Asset Store 里的值），
   * 明文副本就会长期留在 secure 目录里。这里在启动时无条件清一次。
   *
   * 明文里还残留密码时，说明 Asset Store 里多半没有值，需要先搬再删，避免登录失败。
   */
  static migratePlaintextSecrets(): void {
    const alias: string = TalebookServiceStore.activePasswordAlias();
    const plaintextPassword: string = entry.secureGet(LEGACY_PASSWORD_ALIAS);
    const plaintextUsername: string = entry.secureGet(LEGACY_USERNAME_ALIAS);
    const plaintextProfile: string = entry.secureGet(LEGACY_PROFILE_ALIAS);
    if (plaintextPassword.length > 0) {
      PasswordStore.ensure(alias, plaintextPassword);
    }
    if (plaintextUsername.length > 0) {
      PasswordStore.ensure(TalebookServiceStore.activeAliasFor('talebook_username'), plaintextUsername);
    }
    if (plaintextProfile.length > 0) {
      PasswordStore.ensure(TalebookServiceStore.activeAliasFor('talebook_user_profile'), plaintextProfile);
    }
    // 现有账号各自的旧别名（多账号升级路径）
    const records: AccountRecord[] = AccountStore.list();
    for (let i = 0; i < records.length; i++) {
      const id: string = records[i].id;
      const legacyUser: string = entry.secureGet(`account_${id}_username`);
      if (legacyUser.length > 0) {
        PasswordStore.ensure(usernameAliasFor(id), legacyUser);
      }
      const legacyProfile: string = entry.secureGet(`account_${id}_profile`);
      if (legacyProfile.length > 0) {
        PasswordStore.ensure(profileAliasFor(id), legacyProfile);
      }
      const recordUser: string = records[i].username;
      if (recordUser.length > 0) {
        PasswordStore.ensure(usernameAliasFor(id), recordUser);
      }
    }
    for (let i = 0; i < DISCARDED_PLAINTEXT_KEYS.length; i++) {
      entry.secureSet(DISCARDED_PLAINTEXT_KEYS[i], '');
    }
    // 仅记录「是否还存在明文」与键数量，绝不输出任何凭据内容
    let remaining: number = 0;
    for (let i = 0; i < DISCARDED_PLAINTEXT_KEYS.length; i++) {
      if (entry.secureGet(DISCARDED_PLAINTEXT_KEYS[i]).length > 0) {
        remaining++;
      }
    }
    // 明文清空后，自动登录仍要能从 Asset Store 取到密码/用户名（只记存在与否）
    const pwdInStore: number = PasswordStore.get(alias).length > 0 ? 1 : 0;
    const userInStore: number =
      PasswordStore.get(TalebookServiceStore.activeAliasFor('talebook_username')).length > 0 ? 1 : 0;
    const profileInStore: number =
      PasswordStore.get(TalebookServiceStore.activeAliasFor('talebook_user_profile')).length > 0 ? 1 : 0;
    hilog.info(0x0000, TAG,
      'plaintext secret migration done: had=%{public}d/%{public}d/%{public}d residual=%{public}d '
        + 'assetStore=%{public}d/%{public}d/%{public}d accounts=%{public}d',
      plaintextPassword.length > 0 ? 1 : 0, plaintextUsername.length > 0 ? 1 : 0,
      plaintextProfile.length > 0 ? 1 : 0, remaining, pwdInStore, userInStore, profileInStore,
      records.length);
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
    if (key === 'http_perf_log') {
      TalebookCoreService.setHttpMetrics(value === 'true');
    }
  }

  static prefSetBatch(values: Record<string, string>): void {
    entry.prefSetBatch(JSON.stringify(values));
    const allowInsecure = values['allow_insecure_ssl'];
    if (allowInsecure !== undefined) {
      TalebookCoreService.setSslVerify(allowInsecure === 'true');
    }
    const perfLog = values['http_perf_log'];
    if (perfLog !== undefined) {
      TalebookCoreService.setHttpMetrics(perfLog === 'true');
    }
  }

  static getDownloads(): DownloadRecord[] {
    if (TalebookServiceStore.downloadsCache !== null) {
      return TalebookServiceStore.downloadsCache;
    }
    TalebookServiceStore.downloadsCache = JSON.parse(entry.getDownloads()) as DownloadRecord[];
    return TalebookServiceStore.downloadsCache;
  }

  static saveDownloads(records: DownloadRecord[], notify: boolean = true, persist: boolean = true): void {
    TalebookServiceStore.downloadsCache = records;
    if (persist) {
      entry.saveDownloads(JSON.stringify(records));
    }
    if (notify) {
      BookshelfRefresh.notify();
    }
  }

  static getReadingHistory(): ReadingHistoryItem[] {
    if (TalebookServiceStore.historyCache !== null) {
      return TalebookServiceStore.historyCache;
    }
    TalebookServiceStore.historyCache = JSON.parse(entry.getReadingHistory()) as ReadingHistoryItem[];
    return TalebookServiceStore.historyCache;
  }

  static saveReadingHistory(records: ReadingHistoryItem[]): void {
    entry.saveReadingHistory(JSON.stringify(records));
    TalebookServiceStore.historyCache = records;
  }

  static replaceReadingHistory(records: ReadingHistoryItem[], persist: boolean = true): void {
    TalebookServiceStore.historyCache = records;
    if (persist) {
      entry.saveReadingHistory(JSON.stringify(records));
    }
  }

  /** 将内存中的下载/历史缓存落盘（不触发书架刷新） */
  static persistLocalCaches(): void {
    if (TalebookServiceStore.downloadsCache !== null) {
      entry.saveDownloads(JSON.stringify(TalebookServiceStore.downloadsCache));
    }
    if (TalebookServiceStore.historyCache !== null) {
      entry.saveReadingHistory(JSON.stringify(TalebookServiceStore.historyCache));
    }
  }

  static invalidateLocalCaches(): void {
    TalebookServiceStore.downloadsCache = null;
    TalebookServiceStore.historyCache = null;
    // 允许下一次 TalebookService.warmLocalCaches() 按新账号重新预热
    TalebookServiceStore.localCacheWarmPromise = null;
  }

  static getBookmarks(): Record<string, Object>[] {
    return JSON.parse(entry.getBookmarks()) as Record<string, Object>[];
  }

  static saveBookmarks(records: Record<string, Object>[]): void {
    entry.saveBookmarks(JSON.stringify(records));
  }

  static getLoginCredentials(): LoginCredentials {
    return {
      username: TalebookServiceStore.secureGet('talebook_username'),
      password: TalebookServiceStore.secureGet('talebook_password'),
    };
  }

  static saveLoginCredentials(username: string, password: string): void {
    TalebookServiceStore.secureSet('talebook_username', username);
    TalebookServiceStore.secureSet('talebook_password', password);
  }

  /**
   * 记录/响应里的 `is_login` 是否表示「已登录」。
   *
   * 服务端现在给布尔，但历史上有过 0/1 与字符串写法，故按真值判断（对外来数据宽容）。
   * 判定口径统一走这里，避免各处 `Boolean(...)` 与 `=== true` 各写一套。
   */
  static isLoggedInUser(record: Record<string, Object>): boolean {
    const raw: Object | undefined = record['is_login'];
    if (raw === undefined || raw === null) {
      return false;
    }
    if (typeof raw === 'boolean') {
      return raw;
    }
    const text: string = String(raw);
    return text === '1' || text === 'true';
  }

  static saveUserProfile(user: Record<string, Object>): void {
    // 登录前（匿名/访客）的 user/info 响应同样带 `is_login:false`，也满足 isUserProfile 的
    // 字段存在性检查；一旦把它缓存成资料，「个人中心」会按未登录渲染且**不再刷新**。
    if (user['is_login'] !== undefined && !TalebookServiceStore.isLoggedInUser(user)) {
      return;
    }
    TalebookServiceStore.secureSet('talebook_user_profile', JSON.stringify(user));
  }

  /**
   * 判断响应体/缓存是否真的是用户资料。
   *
   * 上游 `POST /api/user/sign_in` 只返回 `{err:'ok',msg:'ok'}`，不含用户对象；
   * 若把它当资料保存，「个人中心」会读到非用户对象而恒显示「未登录」（且隐藏登录后菜单）。
   */
  private static isUserProfile(record: Record<string, Object>): boolean {
    return record['is_login'] !== undefined || record['username'] !== undefined
      || record['nickname'] !== undefined || record['avatar'] !== undefined;
  }

  static getSavedUserProfile(): Record<string, Object> | null {
    const raw = TalebookServiceStore.secureGet('talebook_user_profile');
    if (raw.length === 0) {
      return null;
    }
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(raw) as Record<string, Object>;
    } catch (_error) {
      return null;
    }
    if (!TalebookServiceStore.isUserProfile(parsed)) {
      // 历史版本曾把 sign_in 响应误存为资料：丢弃，避免「个人中心」永久停在未登录态
      TalebookServiceStore.secureSet('talebook_user_profile', '');
      return null;
    }
    return parsed;
  }

  static saveUserProfileFromEnvelope(envelope: ApiEnvelope): void {
    if (!TalebookService.isApiSuccess(envelope) || envelope.body === null) {
      return;
    }
    const user = (envelope.body['user'] as Record<string, Object> | undefined) ?? envelope.body;
    // 非用户资料（如登录响应的 {err,msg}）不得写入，否则会覆盖真实资料
    if (!TalebookServiceStore.isUserProfile(user)) {
      return;
    }
    TalebookServiceStore.saveUserProfile(user);
  }

  static refreshUserProfile(): void {
    const envelope = TalebookService.parseEnvelope(entry.apiGetUserInfo());
    if (!TalebookService.isApiSuccess(envelope) || envelope.body === null) {
      return;
    }
    const user = (envelope.body['user'] as Record<string, Object> | undefined) ?? envelope.body;
    if (!TalebookServiceStore.isUserProfile(user)) {
      return;
    }
    TalebookServiceStore.saveUserProfile(user);
  }

  static applyLocalConfig(): void {
    // 本地配置（身份根/服务器地址/TLS）可能刚被改动：作废会话通过结果，
    // 让下一次 ensureAuthenticated 重新按新配置校验，而不是复用旧窗口
    TalebookServiceStore.sessionOk = false;
    TalebookServiceStore.sessionCheckedAt = 0;
    // 切账号后 talebook_url 随身份根变化且不经过 secureSet，cover 拼接记忆一并作废
    TalebookServiceStore.coverBaseUrl = null;
    // 先恢复当前账号的身份根：凭据/下载记录/历史/书签与其 Cookie 都随账号隔离
    const identityDir = identityDirFor(TalebookServiceStore.dataDir_, entry.prefGet(ACTIVE_ACCOUNT_KEY));
    TalebookService.setIdentityDir(identityDir);
    TalebookCoreService.setIdentityDir(identityDir);
    // 再恢复服务端类型，后续端点/分页/能力判定均依赖它
    const kind = TalebookServiceStore.prefGet(ServerRegistry.PREF_KEY, ServerKind.MYBOOKS);
    ServerRegistry.setKind(ServerRegistry.parse(kind));
    const url = TalebookServiceStore.secureGet('talebook_url');
    if (url.length > 0) {
      TalebookService.setBaseUrl('talebook', url);
      TalebookCoreService.syncBaseUrl('talebook', url);
    }
    const sonovelUrl = TalebookServiceStore.secureGet('sonovel_url');
    if (sonovelUrl.length > 0) {
      TalebookCoreService.syncBaseUrl('sonovel', sonovelUrl);
    }
    const allowInsecure = TalebookServiceStore.prefGet('allow_insecure_ssl', 'false');
    TalebookServiceStore.prefSet('allow_insecure_ssl', allowInsecure);
  }

  static hasAuthCredentials(): boolean {
    const url = TalebookServiceStore.secureGet('talebook_url');
    const creds = TalebookServiceStore.getLoginCredentials();
    return url.length > 0 && creds.username.length > 0 && creds.password.length > 0;
  }

  /**
   * 应用 SoNovel 服务地址。
   *
   * SoNovel 是全局第三方服务（不随书库账号切换），因此只写全局键与两套 native 的 sonovel 通道；
   * 缺任一处都会导致搜索仍走旧地址（`secureGet('sonovel_url')` 是 `sonovel_` 前缀的全局键）。
   */
  static applySonovelUrl(url: string): void {
    TalebookService.setBaseUrl('sonovel', url);
    TalebookServiceStore.secureSet('sonovel_url', url);
    TalebookCoreService.syncBaseUrl('sonovel', url);
  }
  static fetchImageCache(url: string, destPath: string): ApiEnvelope {
    return TalebookService.parseEnvelope(entry.fetchImageCache(url, destPath));
  }

  static fetchImageCacheAsync(url: string, destPath: string): Promise<ApiEnvelope> {
    const existing = TalebookServiceStore.imageLoadTasks.get(destPath);
    if (existing !== undefined) {
      return existing;
    }
    const task: Promise<ApiEnvelope> = entry.fetchImageCacheAsync(url, destPath).then((raw: string) => {
      TalebookServiceStore.imageLoadTasks.delete(destPath);
      return TalebookService.parseEnvelopeAsync(raw);
    }).catch((error: Object): ApiEnvelope => {
      TalebookServiceStore.imageLoadTasks.delete(destPath);
      return TalebookService.failedEnvelope(`${error}`);
    });
    TalebookServiceStore.imageLoadTasks.set(destPath, task);
    return task;
  }

  static resolveCoverUrl(cover: string): string {
    if (cover.length === 0) {
      return '';
    }
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return cover;
    }
    if (TalebookServiceStore.coverBaseUrl === null) {
      TalebookServiceStore.coverBaseUrl = TalebookServiceStore.secureGet('talebook_url');
    }
    const base = TalebookServiceStore.coverBaseUrl;
    if (base.length === 0) {
      return cover;
    }
    return base + (cover.startsWith('/') ? cover : `/${cover}`);
  }

  static upsertDownloadRecord(record: DownloadRecord): void {
    const records = TalebookServiceStore.getDownloads();
    const index = records.findIndex((item) => item.bookId === record.bookId);
    if (index >= 0) {
      records[index] = record;
    } else {
      records.unshift(record);
    }
    TalebookServiceStore.saveDownloads(records);
    BookshelfRefresh.notify();
  }

  static removeDownloadRecord(bookId: string, deleteFile: boolean = true): void {
    const records = TalebookServiceStore.getDownloads();
    const target = records.find((item) => item.bookId === bookId);
    const filtered = records.filter((item) => item.bookId !== bookId);
    TalebookServiceStore.saveDownloads(filtered);
    if (deleteFile && target?.filePath !== undefined && target.filePath.length > 0) {
      try {
        if (fs.accessSync(target.filePath)) {
          fs.unlinkSync(target.filePath);
        }
      } catch (_error) {
      }
    }
    TalebookServiceStore.removeHistoryItem(bookId, target?.filePath ?? '');
    BookshelfRefresh.notify();
  }

  static removeHistoryItem(bookId: string, filePath: string = ''): void {
    const records = TalebookServiceStore.getReadingHistory().filter((item) => {
      if (item.bookId === bookId && bookId.length > 0) {
        return false;
      }
      if (filePath.length > 0 && item.filePath === filePath) {
        return false;
      }
      return true;
    });
    TalebookServiceStore.saveReadingHistory(records);
  }

  static upsertHistoryItem(item: ReadingHistoryItem, persist: boolean = true): void {
    const records = TalebookServiceStore.getReadingHistory();
    const index = records.findIndex((r) =>
      r.bookId === item.bookId ||
      (item.filePath !== undefined && item.filePath.length > 0 && r.filePath === item.filePath));
    if (index >= 0) {
      // 进度条目每次新建，别把累计阅读时长冲掉
      if (item.readSeconds === undefined && records[index].readSeconds !== undefined) {
        item.readSeconds = records[index].readSeconds;
      }
      records.splice(index, 1);
    }
    records.unshift(item);
    if (records.length > 200) {
      records.length = 200;
    }
    if (persist) {
      TalebookServiceStore.saveReadingHistory(records);
    } else {
      TalebookServiceStore.historyCache = records;
    }
  }

  static resolveSavedLocation(bookId: string, filePath: string = ''): string {
    const downloads = TalebookServiceStore.getDownloads();
    let local = downloads.find((item) => item.bookId === bookId && bookId.length > 0);
    if (local === undefined && filePath.length > 0) {
      local = downloads.find((item) => item.filePath === filePath);
    }
    if (local?.progress?.location !== undefined && local.progress.location.length > 0) {
      return local.progress.location;
    }
    const history = TalebookServiceStore.getReadingHistory();
    let item = history.find((entry: ReadingHistoryItem) => entry.bookId === bookId && bookId.length > 0);
    if (item === undefined && filePath.length > 0) {
      item = history.find((entry: ReadingHistoryItem) => entry.filePath === filePath);
    }
    return item?.location ?? '';
  }
}

