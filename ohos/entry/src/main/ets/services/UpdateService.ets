import { bundleManager } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { StorageKeys } from '../common/Constants';
import { TalebookService } from './TalebookService';
import { ErrorFormat } from '../utils/ErrorFormat';

/** 应用自身的 GitHub 仓库：更新检查的唯一数据源。 */
export const UPDATE_REPO_OWNER: string = 'zhonxinya';
export const UPDATE_REPO_NAME: string = 'mybooks_ohos';

/** GitHub 最新 release 接口（latest = 最新一个非草稿、非预发布的 release）。 */
const RELEASE_API_URL: string =
  `https://api.github.com/repos/${UPDATE_REPO_OWNER}/${UPDATE_REPO_NAME}/releases/latest`;
/** GitHub API 强制要求 User-Agent，缺失会直接返回 403。 */
const USER_AGENT: string = 'mybooks_ohos-harmony';
const ACCEPT_HEADER: string = 'application/vnd.github+json';

const CONNECT_TIMEOUT_MS: number = 15000;
const READ_TIMEOUT_MS: number = 20000;

/** 检查结果缓存有效期：期间内复用缓存，避免频繁打 GitHub API 触发匿名限流。 */
const CACHE_TTL_MS: number = 6 * 60 * 60 * 1000;
/** 启动提示里的升级内容摘要上限（完整内容在更新页展示）。 */
const SUMMARY_MAX_CHARS: number = 240;

/** 从 GitHub release 中解析出的必要信息。 */
export interface ReleaseInfo {
  /** 原始 tag，如 v1.2.0 */
  tag: string;
  /** 去掉 v 前缀的版本号，如 1.2.0 */
  version: string;
  /** 升级内容（Markdown 原文） */
  body: string;
  /** 发布页地址 */
  htmlUrl: string;
  /** 发布时间（ISO8601） */
  publishedAt: string;
  /** HAP 附件名，无附件时空串 */
  hapName: string;
  /** HAP 附件下载地址，无附件时空串 */
  hapUrl: string;
  /** HAP 附件字节数，0 表示未知 */
  hapSize: number;
}

/** 一次更新检查的结果；失败同样返回对象，由调用方决定展示方式。 */
export interface UpdateCheckResult {
  ok: boolean;
  error: string;
  /** 本地 versionName */
  currentVersion: string;
  release: ReleaseInfo | null;
  /** release 版本高于本地版本 */
  hasUpdate: boolean;
}

/**
 * 客户端自更新检查：从 GitHub 拉取最新 release，与本地 versionName 比较。
 *
 * 设计要点：
 * - 走系统网络栈（`@kit.NetworkKit`），与 SoNovel 一致，不依赖 native libcurl 的 CA 信任库；
 * - 检查结果缓存在偏好里，启动静默检查与设置页提示共用同一份数据，不重复请求；
 * - 「忽略此版本」「已提示」均按 tag 记录，新版本仍会重新提示。
 */
export class UpdateService {
  /** 本地应用版本号（versionName）；读取失败返回空串。 */
  static currentVersion(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (_error) {
      return '';
    }
  }

  /** 去掉 tag/版本号的 v 前缀。 */
  static normalizeVersion(text: string): string {
    let value: string = text.trim();
    if (value.length > 0 && (value.charAt(0) === 'v' || value.charAt(0) === 'V')) {
      value = value.substring(1);
    }
    return value;
  }

  /** 语义化版本比较：left 更新返回 1，相同返回 0，更旧返回 -1。 */
  static compareVersions(left: string, right: string): number {
    const a: number[] = UpdateService.versionParts(left);
    const b: number[] = UpdateService.versionParts(right);
    const length: number = Math.max(a.length, b.length);
    for (let i = 0; i < length; i++) {
      const x: number = i < a.length ? a[i] : 0;
      const y: number = i < b.length ? b[i] : 0;
      if (x > y) {
        return 1;
      }
      if (x < y) {
        return -1;
      }
    }
    return 0;
  }

  /** 远端 tag 是否比本地版本更新。 */
  static isNewerTag(tag: string, currentVersion: string): boolean {
    if (tag.trim().length === 0 || currentVersion.trim().length === 0) {
      return false;
    }
    return UpdateService.compareVersions(tag, currentVersion) > 0;
  }

  /**
   * 检查更新。
   * @param force true 时忽略缓存必发请求（用户主动点「检查更新」）；
   *              false 时命中缓存直接返回，且请求失败时静默回退到缓存（启动检查不打扰用户）。
   */
  static async check(force: boolean = false): Promise<UpdateCheckResult> {
    const current: string = UpdateService.currentVersion();
    if (!force && UpdateService.cacheIsFresh()) {
      const cached: UpdateCheckResult | null = UpdateService.cachedResult();
      if (cached !== null) {
        UpdateService.publishHint();
        return cached;
      }
    }
    try {
      const release: ReleaseInfo = await UpdateService.fetchLatestRelease();
      UpdateService.saveCache(release);
      UpdateService.publishHint();
      return UpdateService.buildResult(true, '', current, release);
    } catch (error) {
      if (!force) {
        const cached: UpdateCheckResult | null = UpdateService.cachedResult();
        if (cached !== null) {
          UpdateService.publishHint();
          return cached;
        }
      }
      return UpdateService.buildResult(false, ErrorFormat.message(error as Object), current, null);
    }
  }

  /** 缓存的检查结果（不发网络请求）；无缓存返回 null。 */
  static cachedResult(): UpdateCheckResult | null {
    const release: ReleaseInfo | null = UpdateService.cachedRelease();
    if (release === null) {
      return null;
    }
    return UpdateService.buildResult(true, '', UpdateService.currentVersion(), release);
  }

  /** 缓存的 release 信息（不发网络请求）；无缓存返回 null。 */
  static cachedRelease(): ReleaseInfo | null {
    return UpdateService.releaseFromCache();
  }

  /** 该 tag 是否已被用户「忽略此版本」。 */
  static isSkipped(tag: string): boolean {
    return tag.length > 0 && tag === UpdateService.skippedTag();
  }

  /**
   * 把「可升级版本号」发布到 AppStorage（空串 = 无提示）。
   * 启动检查是异步的，设置页可能在检查完成前就已构建；经 AppStorage 订阅才能在该场景下依然显示提示。
   */
  static publishHint(): void {
    const release: ReleaseInfo | null = UpdateService.cachedRelease();
    let version: string = '';
    if (release !== null && !UpdateService.isSkipped(release.tag)
      && UpdateService.isNewerTag(release.tag, UpdateService.currentVersion())) {
      version = release.version;
    }
    AppStorage.setOrCreate<string>(StorageKeys.UPDATE_HINT_VERSION, version);
  }

  /** 最近一次成功检查的时间戳（毫秒）；从未检查返回 0。 */
  private static lastCheckedAt(): number {
    const value: number = Number(TalebookService.prefGet(StorageKeys.UPDATE_CHECKED_AT, ''));
    return Number.isFinite(value) && value > 0 ? value : 0;
  }

  /** 用户选择「忽略此版本」的 tag；空串表示未忽略。 */
  static skippedTag(): string {
    return TalebookService.prefGet(StorageKeys.UPDATE_SKIPPED_TAG, '');
  }

  static skipVersion(tag: string): void {
    TalebookService.prefSet(StorageKeys.UPDATE_SKIPPED_TAG, tag.trim());
    UpdateService.publishHint();
  }

  /** 已弹过启动提示的 tag，避免同一版本每次冷启动都打扰用户。 */
  static promptedTag(): string {
    return TalebookService.prefGet(StorageKeys.UPDATE_PROMPTED_TAG, '');
  }

  static markPrompted(tag: string): void {
    TalebookService.prefSet(StorageKeys.UPDATE_PROMPTED_TAG, tag.trim());
  }

  /** 字节数转可读大小（MB，保留 1 位小数）；0 或非法值返回空串。 */
  static formatSize(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return '';
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  /** ISO8601 发布时间 → yyyy-MM-dd；无法识别返回空串。 */
  static formatDate(iso: string): string {
    if (iso.length < 10) {
      return '';
    }
    const date: string = iso.substring(0, 10);
    return /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : '';
  }

  /** 把 Markdown 升级内容压成纯文本摘要（启动提示用；更新页展示原文）。 */
  static summarize(body: string): string {
    let text: string = body.replace(/\r\n/g, '\n');
    // 「Full Changelog」行只是链接，摘要里去掉
    text = text.replace(/^[ \t]*\*\*Full Changelog\*\*:.*$/gm, '');
    // Markdown 链接 → 文字
    text = text.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
    text = text.replace(/\*\*/g, '');
    text = text.replace(/^[ \t]*#{1,6}[ \t]*/gm, '');
    text = text.replace(/^[ \t]*[-*][ \t]+/gm, '· ');
    text = text.replace(/\n{2,}/g, '\n');
    text = text.trim();
    if (text.length <= SUMMARY_MAX_CHARS) {
      return text;
    }
    return `${text.substring(0, SUMMARY_MAX_CHARS)}…`;
  }

  private static versionParts(text: string): number[] {
    const parts: number[] = [];
    const segments: string[] = UpdateService.normalizeVersion(text).split('.');
    for (let i = 0; i < segments.length; i++) {
      const segment: string = segments[i];
      parts.push(/^\d+$/.test(segment) ? Number(segment) : 0);
    }
    return parts;
  }

  private static buildResult(
    ok: boolean,
    error: string,
    currentVersion: string,
    release: ReleaseInfo | null,
  ): UpdateCheckResult {
    const hasUpdate: boolean =
      ok && release !== null && UpdateService.isNewerTag(release.tag, currentVersion);
    const result: UpdateCheckResult = {
      ok: ok,
      error: error,
      currentVersion: currentVersion,
      release: release,
      hasUpdate: hasUpdate,
    };
    return result;
  }

  private static readString(record: Record<string, Object>, key: string): string {
    const value: Object | undefined = record[key];
    if (value === undefined || value === null) {
      return '';
    }
    return typeof value === 'string' ? value : String(value);
  }

  private static readNumber(record: Record<string, Object>, key: string): number {
    const value: Object | undefined = record[key];
    if (value === undefined || value === null) {
      return 0;
    }
    const parsed: number = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  /** 从 GitHub release 响应体中解析出客户端需要的字段。 */
  private static parseRelease(root: Record<string, Object>): ReleaseInfo {
    const tag: string = UpdateService.readString(root, 'tag_name');
    let hapName: string = '';
    let hapUrl: string = '';
    let hapSize: number = 0;
    const assets: Object[] | undefined = root['assets'] as Object[] | undefined;
    if (assets !== undefined && assets !== null) {
      for (let i = 0; i < assets.length; i++) {
        const asset: Record<string, Object> = assets[i] as Record<string, Object>;
        const name: string = UpdateService.readString(asset, 'name');
        if (name.toLowerCase().endsWith('.hap')) {
          hapName = name;
          hapUrl = UpdateService.readString(asset, 'browser_download_url');
          hapSize = UpdateService.readNumber(asset, 'size');
          break;
        }
      }
    }
    const release: ReleaseInfo = {
      tag: tag,
      version: UpdateService.normalizeVersion(tag),
      body: UpdateService.readString(root, 'body'),
      htmlUrl: UpdateService.readString(root, 'html_url'),
      publishedAt: UpdateService.readString(root, 'published_at'),
      hapName: hapName,
      hapUrl: hapUrl,
      hapSize: hapSize,
    };
    return release;
  }

  /** 拉取 GitHub 最新 release；网络或接口异常时抛出 Error。 */
  private static async fetchLatestRelease(): Promise<ReleaseInfo> {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(RELEASE_API_URL, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': ACCEPT_HEADER,
          'User-Agent': USER_AGENT,
          'X-GitHub-Api-Version': '2022-11-28',
        },
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING,
        usingProtocol: http.HttpProtocol.HTTP1_1,
      });
      const status: number = response.responseCode;
      if (status < 200 || status >= 300) {
        throw new Error(UpdateService.httpErrorMessage(status));
      }
      const raw: string = typeof response.result === 'string' ? response.result : '';
      if (raw.length === 0) {
        throw new Error('GitHub 返回空响应');
      }
      let root: Record<string, Object>;
      try {
        root = JSON.parse(raw) as Record<string, Object>;
      } catch (_error) {
        throw new Error('GitHub 响应解析失败');
      }
      if (UpdateService.readString(root, 'tag_name').length === 0) {
        throw new Error('GitHub 响应缺少版本标签');
      }
      return UpdateService.parseRelease(root);
    } finally {
      httpRequest.destroy();
    }
  }

  private static httpErrorMessage(status: number): string {
    if (status === 403 || status === 429) {
      return 'GitHub 访问过于频繁，请稍后再试';
    }
    if (status === 404) {
      return '未找到 GitHub 发布页';
    }
    return `检查更新失败（HTTP ${status}）`;
  }

  private static cacheIsFresh(): boolean {
    const value: number = UpdateService.lastCheckedAt();
    if (value <= 0) {
      return false;
    }
    return Date.now() - value < CACHE_TTL_MS;
  }

  private static saveCache(release: ReleaseInfo): void {
    const record: Record<string, Object> = {
      'tag': release.tag,
      'version': release.version,
      'body': release.body,
      'htmlUrl': release.htmlUrl,
      'publishedAt': release.publishedAt,
      'hapName': release.hapName,
      'hapUrl': release.hapUrl,
      'hapSize': release.hapSize,
    };
    TalebookService.prefSet(StorageKeys.UPDATE_RELEASE_CACHE, JSON.stringify(record));
    TalebookService.prefSet(StorageKeys.UPDATE_CHECKED_AT, `${Date.now()}`);
  }

  private static releaseFromCache(): ReleaseInfo | null {
    const text: string = TalebookService.prefGet(StorageKeys.UPDATE_RELEASE_CACHE, '');
    if (text.length === 0) {
      return null;
    }
    let record: Record<string, Object>;
    try {
      record = JSON.parse(text) as Record<string, Object>;
    } catch (_error) {
      return null;
    }
    const tag: string = UpdateService.readString(record, 'tag');
    if (tag.length === 0) {
      return null;
    }
    const release: ReleaseInfo = {
      tag: tag,
      version: UpdateService.readString(record, 'version'),
      body: UpdateService.readString(record, 'body'),
      htmlUrl: UpdateService.readString(record, 'htmlUrl'),
      publishedAt: UpdateService.readString(record, 'publishedAt'),
      hapName: UpdateService.readString(record, 'hapName'),
      hapUrl: UpdateService.readString(record, 'hapUrl'),
      hapSize: UpdateService.readNumber(record, 'hapSize'),
    };
    return release;
  }
}
