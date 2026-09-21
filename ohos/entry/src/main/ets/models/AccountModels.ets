/**
 * 多账号模型与纯函数工具。
 *
 * 一个账号 = 一个 (服务端, 用户) 组合：可指向不同服务器，也可指向同一服务器的不同用户。
 * 本文件只做数据形状与「账号 → 存储位置」的纯映射，不依赖任何 service，避免循环依赖。
 *
 * 存储划分（与 native 配合）：
 * - 全局根 `<filesDir>`：preferences.json —— 账号列表、当前账号、主题、阅读器、SoNovel
 * - 账号身份根 `<filesDir>/accounts/<id>`：Cookie、凭据、下载记录、阅读历史、书签
 * - 默认（历史）账号的身份根就是 `<filesDir>` 本身，因此既有单账号安装升级后无需迁移文件
 */

/** 全局偏好中账号列表的键。 */
export const ACCOUNTS_KEY: string = 'accounts';
/** 全局偏好中当前账号 id 的键。 */
export const ACTIVE_ACCOUNT_KEY: string = 'active_account_id';
/** 历史（升级前）单账号的固定 id。 */
export const ACCOUNT_LEGACY_ID: string = 'default';
/** 历史密码在 Asset Store 中的别名；默认账号沿用该别名以复用已保存的密码。 */
export const LEGACY_PASSWORD_ALIAS: string = 'talebook_password';
/** 历史用户名在 Asset Store 中的别名（旧版曾明文存于 secure JSON）。 */
export const LEGACY_USERNAME_ALIAS: string = 'talebook_username';
/** 历史用户资料在 Asset Store 中的别名（旧版曾明文存于 secure JSON，含 podcast_token）。 */
export const LEGACY_PROFILE_ALIAS: string = 'talebook_user_profile';

/** 一个已保存的账号。密码不在此结构中，单独存于 Asset Store。 */
export interface AccountRecord {
  id: string;
  /** 展示名，留空时按 `用户名@主机` 生成。 */
  name: string;
  /** ServerKind 的值。 */
  serverKind: string;
  url: string;
  username: string;
  allowInsecureSsl: boolean;
  createdAt: number;
}

/** 新增/编辑账号时的表单输入（含密码）。 */
export interface AccountInput {
  name: string;
  serverKind: string;
  url: string;
  username: string;
  password: string;
  allowInsecureSsl: boolean;
}

function asString(value: Object | undefined | null, fallback: string = ''): string {
  if (value === undefined || value === null) {
    return fallback;
  }
  const text = String(value);
  return text === 'undefined' || text === 'null' ? fallback : text;
}

function asBoolean(value: Object | undefined | null, fallback: boolean = false): boolean {
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value === 'boolean') {
    return value;
  }
  return String(value) === 'true';
}

function asNumber(value: Object | undefined | null, fallback: number = 0): number {
  if (value === undefined || value === null) {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isNaN(parsed) ? fallback : parsed;
}

/** 是否为历史（默认）账号；空 id 也按默认账号处理，供首次启动时回退到全局根。 */
export function isLegacyAccount(id: string): boolean {
  return id.length === 0 || id === ACCOUNT_LEGACY_ID;
}

/** 账号身份根目录：Cookie / 凭据 / 下载记录 / 阅读历史 / 书签都落在此目录下。 */
export function identityDirFor(filesDir: string, id: string): string {
  return isLegacyAccount(id) ? filesDir : `${filesDir}/accounts/${id}`;
}

/** 账号密码在 Asset Store 中的别名。 */
export function passwordAliasFor(id: string): string {
  return isLegacyAccount(id) ? LEGACY_PASSWORD_ALIAS : `account_${id}_password`;
}

/** 账号用户名在 Asset Store 中的别名。 */
export function usernameAliasFor(id: string): string {
  return isLegacyAccount(id) ? LEGACY_USERNAME_ALIAS : `account_${id}_username`;
}

/** 账号用户资料（含 podcast_token 等凭据）在 Asset Store 中的别名。 */
export function profileAliasFor(id: string): string {
  return isLegacyAccount(id) ? LEGACY_PROFILE_ALIAS : `account_${id}_profile`;
}

/** 已迁出明文存储的旧键：迁移到 Asset Store 后须从明文 JSON 中删除。 */
export const DISCARDED_PLAINTEXT_KEYS: string[] = [
  LEGACY_PASSWORD_ALIAS, LEGACY_USERNAME_ALIAS, LEGACY_PROFILE_ALIAS,
  'talebook_username', 'talebook_password', 'talebook_user_profile',
];

/** 从 URL 中取出主机（含端口），用于生成展示名。 */
export function accountHost(url: string): string {
  let host = url.trim();
  const schemeIndex = host.indexOf('://');
  if (schemeIndex >= 0) {
    host = host.substring(schemeIndex + 3);
  }
  const slashIndex = host.indexOf('/');
  if (slashIndex >= 0) {
    host = host.substring(0, slashIndex);
  }
  return host;
}

/** 展示名：优先用户自定义，否则 `用户名@主机`，再否则主机。 */
export function accountDisplayName(record: AccountRecord): string {
  if (record.name.length > 0) {
    return record.name;
  }
  const host = accountHost(record.url);
  if (record.username.length > 0 && host.length > 0) {
    return `${record.username}@${host}`;
  }
  if (host.length > 0) {
    return host;
  }
  return record.username.length > 0 ? record.username : '未命名账号';
}

/** 解析单个账号；id 缺失的记录视为无效（返回 null）。 */
export function parseAccount(raw: Record<string, Object>): AccountRecord | null {
  const id = asString(raw['id']);
  if (id.length === 0) {
    return null;
  }
  const record: AccountRecord = {
    id: id,
    name: asString(raw['name']),
    serverKind: asString(raw['server_kind']),
    url: asString(raw['url']),
    username: asString(raw['username']),
    allowInsecureSsl: asBoolean(raw['allow_insecure_ssl']),
    createdAt: asNumber(raw['created_at']),
  };
  return record;
}

/** 解析账号列表 JSON；非法内容返回空数组。 */
export function parseAccountsJson(json: string): AccountRecord[] {
  const result: AccountRecord[] = [];
  if (json.trim().length === 0) {
    return result;
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(json) as Object;
  } catch (_error) {
    return result;
  }
  if (!Array.isArray(parsed)) {
    return result;
  }
  const list = parsed as Array<Record<string, Object>>;
  for (let i = 0; i < list.length; i++) {
    const record = parseAccount(list[i]);
    if (record !== null) {
      result.push(record);
    }
  }
  return result;
}

/** 账号列表序列化（存全局偏好）。 */
export function stringifyAccounts(records: AccountRecord[]): string {
  const plain: Array<Record<string, Object>> = [];
  for (let i = 0; i < records.length; i++) {
    const record = records[i];
    const item: Record<string, Object> = {
      'id': record.id,
      'name': record.name,
      'server_kind': record.serverKind,
      'url': record.url,
      'username': record.username,
      'allow_insecure_ssl': record.allowInsecureSsl,
      'created_at': record.createdAt,
    };
    plain.push(item);
  }
  return JSON.stringify(plain);
}

/** 生成新的账号 id（时间戳 + 随机后缀，避免同毫秒冲突）。 */
export function newAccountId(): string {
  const suffix = Math.floor(Math.random() * 100000);
  return `acc${Date.now()}${suffix}`;
}
