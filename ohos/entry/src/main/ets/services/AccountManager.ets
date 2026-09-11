import {
  ACCOUNT_LEGACY_ID, AccountInput, AccountRecord, accountDisplayName, identityDirFor, isLegacyAccount,
  newAccountId,
} from '../models/AccountModels';
import { AccountStore } from './AccountStore';
import { NotificationService } from './NotificationService';
import { ServerKind, ServerRegistry } from './ServerProfile';
import { TalebookCoreService } from './TalebookCoreService';
import { TalebookService, AuthAttempt } from './TalebookService';

/**
 * 多账号管理：新增/编辑/删除/切换，以及切换时把账号身份下沉到两套 native 模块。
 *
 * 切换账号需要同时处理四件事，缺一即出现「串会话」或「看到上一个账号的数据」：
 * 1. 把 libentry 与 mybooks_core 的身份根都切到该账号目录（凭据/下载/历史/书签 + Cookie）
 * 2. 把该账号的服务端地址、服务端类型、TLS 开关写回既有的扁平键（全部既有代码依赖这些键）
 * 3. 丢弃 ArkTS 侧的内存缓存与会话恢复状态
 * 4. 广播切换事件，由页面重启导航栈重新渲染
 */
export class AccountManager {
  /** 切换事件的 AppStorage 键，供需要在原地刷新的页面监听。 */
  static readonly SWITCH_TICK_KEY: string = 'accountSwitchTick';

  /**
   * 升级迁移：升级前只支持单账号，此处把既有配置落成默认账号。
   * 默认账号的身份根就是 `<filesDir>`，因此不复制、不移动任何文件，历史数据继续可用。
   * 全新安装（未配置过服务器）不做任何事，等用户在配置页新增第一个账号。
   */
  static ensureMigrated(): void {
    if (AccountStore.count() > 0) {
      return;
    }
    const url = TalebookService.secureGet('talebook_url');
    if (url.length === 0) {
      return;
    }
    const credentials = TalebookService.getLoginCredentials();
    const record: AccountRecord = {
      id: ACCOUNT_LEGACY_ID,
      name: '',
      serverKind: TalebookService.prefGet(ServerRegistry.PREF_KEY, ServerKind.MYBOOKS),
      url: url,
      username: credentials.username,
      allowInsecureSsl: TalebookService.prefGet('allow_insecure_ssl', 'false') === 'true',
      createdAt: Date.now(),
    };
    AccountStore.saveAll([record]);
    AccountStore.setActiveId(ACCOUNT_LEGACY_ID);
  }

  /**
   * 启动时按「当前账号」记录重新下发一次身份。
   *
   * 账号记录是账号配置的权威来源，重新下发可自愈历史失败（例如身份根目录未建成功时
   * 地址/用户名/开关没写进去，重启后请求打到空地址），使应用始终与当前账号一致。
   * 幂等：重复下发同一账号无副作用。
   */
  static ensureActiveIdentity(): void {
    const active = AccountStore.active();
    if (active === null) {
      return;
    }
    AccountManager.applyIdentity(active);
  }

  static list(): AccountRecord[] {
    return AccountStore.list();
  }

  static active(): AccountRecord | null {
    return AccountStore.active();
  }

  static activeId(): string {
    return AccountStore.activeId();
  }

  /** 当前账号展示名（无账号时返回空串）。 */
  static activeDisplayName(): string {
    const record = AccountStore.active();
    return record === null ? '' : accountDisplayName(record);
  }

  static displayNameOf(record: AccountRecord): string {
    return accountDisplayName(record);
  }

  /**
   * 当前账号的本地书籍目录。
   *
   * 必须按账号隔离：不同账号可能都存在同一 bookId 的同一格式，共目录会互相覆盖。
   * 默认（历史）账号沿用既有 `<filesDir>/books`，使升级前已下载的文件继续可用。
   */
  static booksDir(filesDir: string): string {
    const id = AccountStore.activeId();
    return isLegacyAccount(id) ? `${filesDir}/books` : `${filesDir}/accounts/${id}/books`;
  }

  /** 新增账号（可指向新服务器）。密码单独写 Asset Store，不进列表 JSON。 */
  static add(input: AccountInput): AccountRecord {
    const record: AccountRecord = {
      id: newAccountId(),
      name: input.name.trim(),
      serverKind: input.serverKind,
      url: input.url.trim(),
      username: input.username.trim(),
      allowInsecureSsl: input.allowInsecureSsl,
      createdAt: Date.now(),
    };
    const records = AccountStore.list();
    records.push(record);
    AccountStore.saveAll(records);
    AccountStore.setPassword(record.id, input.password);
    return record;
  }

  /** 编辑账号；密码留空表示保持原密码不变。 */
  static update(id: string, input: AccountInput): boolean {
    const records = AccountStore.list();
    let target: AccountRecord | null = null;
    for (let i = 0; i < records.length; i++) {
      if (records[i].id === id) {
        target = records[i];
        break;
      }
    }
    if (target === null) {
      return false;
    }
    target.name = input.name.trim();
    target.serverKind = input.serverKind;
    target.url = input.url.trim();
    target.username = input.username.trim();
    target.allowInsecureSsl = input.allowInsecureSsl;
    AccountStore.saveAll(records);
    if (input.password.length > 0) {
      AccountStore.setPassword(id, input.password);
    }
    return true;
  }

  /**
   * 删除账号。最后一个账号不允许删除（否则应用无可用配置）。
   * 若删的是当前账号，则把当前账号切到剩余列表的第一项并立即应用其身份。
   * 说明：账号目录保留在磁盘上（不删用户数据），因此重新添加同服务器账号不会复用旧数据。
   */
  static remove(id: string): boolean {
    if (AccountStore.count() <= 1) {
      return false;
    }
    const wasActive = AccountStore.isActive(id);
    if (!AccountStore.remove(id)) {
      return false;
    }
    const remaining = AccountStore.list();
    if (remaining.length === 0) {
      return true;
    }
    if (wasActive) {
      AccountStore.setActiveId(remaining[0].id);
      AccountManager.applyIdentity(remaining[0]);
      // 与切换一致：丢弃被删账号的内存缓存与会话状态，否则书架仍显示已删账号的数据
      TalebookService.invalidateLocalCaches();
      TalebookService.invalidateSession();
      AccountManager.notifySwitched();
    }
    return true;
  }

  /**
   * 把账号身份应用到两套 native 模块与既有扁平配置键。
   * 幂等：重复应用同一账号无副作用（native 侧同目录会短路）。
   */
  static applyIdentity(record: AccountRecord): void {
    // 空地址不覆盖已有配置：否则会把可用配置清空，之后所有请求都会报「未配置服务器地址」
    if (record.url.length === 0) {
      return;
    }
    const dir = identityDirFor(TalebookService.dataDir(), record.id);
    // 1) 身份根：libentry 的凭据/下载/历史/书签 + Cookie；mybooks_core 的数据库 + Cookie
    TalebookService.setIdentityDir(dir);
    TalebookCoreService.setIdentityDir(dir);
    // 2) 扁平键：所有既有代码（TalebookApi / BookUploadService / 各页面）都依赖这些键
    TalebookService.secureSet('talebook_url', record.url);
    TalebookService.secureSet('talebook_username', record.username);
    TalebookService.prefSet(ServerRegistry.PREF_KEY, record.serverKind);
    ServerRegistry.setKind(ServerRegistry.parse(record.serverKind));
    TalebookService.setBaseUrl('talebook', record.url);
    TalebookCoreService.syncBaseUrl('talebook', record.url);
    // TLS 开关经 prefSet 会同步到 mybooks_core
    TalebookService.prefSet('allow_insecure_ssl', record.allowInsecureSsl ? 'true' : 'false');
    // 再统一套用一次本地配置：把 talebook 与 SoNovel（全局）地址同时推给两套 native，
    // 避免只走 mybooks_core 的页面（书单/插件等）拿到空地址
    TalebookService.applyLocalConfig();
  }

  /**
   * 切换到指定账号：应用身份、丢弃旧账号缓存、广播事件，并自动登录。
   * 返回是否登录成功（凭据缺失或服务器不可达时为 false，此时调用方仍应完成 UI 重载）。
   */
  static async activate(id: string): Promise<AuthAttempt> {
    const record = AccountStore.find(id);
    if (record === null) {
      const missing: AuthAttempt = { ok: false, reason: '账号不存在' };
      return missing;
    }
    AccountStore.setActiveId(id);
    AccountManager.applyIdentity(record);
    // 丢弃上一账号的内存缓存，否则书架/历史仍显示旧账号数据
    TalebookService.invalidateLocalCaches();
    TalebookService.invalidateSession();
    // 未读消息属账号级数据，切换后刷新一次，避免沿用上一账号的角标
    NotificationService.refreshUnreadCount();
    AccountManager.notifySwitched();
    // 返回失败原因，便于调用方跳转登录页并向用户说明
    return TalebookService.tryAutoLogin();
  }

  /** 广播账号切换，供 AppStorage 监听方原地刷新（主要靠调用方重启导航栈重渲染）。 */
  static notifySwitched(): void {
    AppStorage.setOrCreate(AccountManager.SWITCH_TICK_KEY, Date.now());
  }

  /**
   * 用当前生效的配置回写「当前账号」记录，保持账号列表与实际配置一致。
   *
   * 背景：登录页允许直接改服务器地址与用户名、TLS 开关，这些会写到既有扁平键上；
   * 若不回写，账号列表会显示过期的地址/用户名。密码不在此处理（只存 Asset Store）。
   */
  static syncActiveFromConfig(): void {
    const active = AccountStore.active();
    if (active === null) {
      return;
    }
    const url = TalebookService.secureGet('talebook_url');
    const credentials = TalebookService.getLoginCredentials();
    const allowInsecureSsl = TalebookService.prefGet('allow_insecure_ssl', 'false') === 'true';
    const serverKind = TalebookService.prefGet(ServerRegistry.PREF_KEY, active.serverKind);
    // 地址为空时保留账号里已保存的地址，避免把可用配置写成空值
    const nextUrl = url.length > 0 ? url : active.url;
    if (active.url === nextUrl && active.username === credentials.username &&
      active.allowInsecureSsl === allowInsecureSsl && active.serverKind === serverKind) {
      return;
    }
    const input: AccountInput = {
      name: active.name,
      serverKind: serverKind,
      url: nextUrl,
      username: credentials.username,
      // 空密码表示保持原有密码不变
      password: '',
      allowInsecureSsl: allowInsecureSsl,
    };
    AccountManager.update(active.id, input);
  }
}
