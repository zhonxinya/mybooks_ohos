import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SecureStore as SecureStoreOhos } from './SecureStore';
import { SecureStoreAndroid } from './SecureStoreAndroid';
import { PlatformTarget } from '../common/PlatformTarget';

/**
 * 执行一次写入：按运行平台分派到底层安全存储。
 *
 * 不用「返回实现对象再调方法」的写法，是因为 ArkTS 禁止 `typeof X` 类型查询
 * （arkts-no-type-query），无法把两个纯静态类统一成一个接口类型。
 * 直接在函数内分派既避开该限制，也少一层间接。
 */

const TAG: string = 'PasswordStore';

/** 鸿蒙：Asset Store（系统关键资产存储）。 */
function putOhos(context: common.UIAbilityContext, key: Uint8Array, value: Uint8Array): void {
  SecureStoreOhos.put(context, key, value);
}

function getOhos(context: common.UIAbilityContext, key: Uint8Array): Uint8Array | null {
  return SecureStoreOhos.get(context, key);
}

function deleteOhos(context: common.UIAbilityContext, key: Uint8Array): void {
  SecureStoreOhos.delete(context, key);
}

/** Android：AES-256-GCM 密文 + 原生密钥文件（见 `SecureStoreAndroid`）。 */
function putAndroid(context: common.UIAbilityContext, key: Uint8Array, value: Uint8Array): void {
  SecureStoreAndroid.put(context, key, value);
}

function getAndroid(context: common.UIAbilityContext, key: Uint8Array): Uint8Array | null {
  return SecureStoreAndroid.get(context, key);
}

function deleteAndroid(context: common.UIAbilityContext, key: Uint8Array): void {
  SecureStoreAndroid.delete(context, key);
}

/**
 * 保存密码类敏感数据。
 *
 * 抽象层：`SecureStore` 按平台分派底层实现（鸿蒙 Asset Store / Android 加密落盘），
 * 本类只负责进程内缓存与统一契约，因此调用方无需感知平台差异。
 *
 * 来源: https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-asset
 */
export class PasswordStore {
  /**
   * 进程内一级缓存：底层存储（Asset Store 同步 IPC / 文件读盘）在 UI 线程上是毫秒级开销。
   * 封面地址解析 / 凭据判断等路径会高频读取（每次解析封面都会读一次 talebook_url），
   * 命中缓存后完全不再进系统服务。
   *
   * 失效策略：所有写入都经本类，`set`/`remove` 同步更新缓存；键在底层存储中的值
   * 不会被其他进程改写（同一应用的账号切换也走这里），因此缓存不会变脏。
   */
  private static cache: Map<string, string> = new Map<string, string>();

  /**
   * 应用上下文。
   *
   * Android 端的 preferences 必须凭 context 定位沙箱路径，而本类的调用方
   * （`AccountStore` / `TalebookService`）都在静态方法里拿不到组件 `this`，
   * 故由 `EntryAbility.onCreate` 调 `PasswordStore.initContext` 注入一次。
   * 未初始化时 Android 端读写会失败（鸿蒙端不依赖它）。
   */
  private static context: common.UIAbilityContext | null = null;

  /** 由 `EntryAbility` 在应用启动时调用一次。 */
  static initContext(context: common.UIAbilityContext): void {
    PasswordStore.context = context;
  }

  private static stringToArray(str: string): Uint8Array {
    const textEncoder: util.TextEncoder = new util.TextEncoder();
    return textEncoder.encodeInto(str);
  }

  private static arrayToString(arr: Uint8Array): string {
    const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return textDecoder.decodeToString(arr, { stream: false });
  }

  /** 写入密码，别名已存在时覆盖；密码为空则删除该条目。 */
  static set(alias: string, secret: string): void {
    if (secret.length === 0) {
      PasswordStore.remove(alias);
      return;
    }
    try {
      const context = PasswordStore.context;
      if (context === null) {
        return;
      }
      const store = PlatformTarget.isAndroid() ? putAndroid : putOhos;
      store(context, PasswordStore.stringToArray(alias), PasswordStore.stringToArray(secret));
      PasswordStore.cache.set(alias, secret);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'set failed, code: %{public}d, message: %{public}s', err.code, err.message);
    }
  }

  /** 读取密码，条目不存在时返回空字符串。 */
  static get(alias: string): string {
    const cached: string | undefined = PasswordStore.cache.get(alias);
    if (cached !== undefined) {
      return cached;
    }
    try {
      const context = PasswordStore.context;
      if (context === null) {
        return '';
      }
      const reader = PlatformTarget.isAndroid() ? getAndroid : getOhos;
      const raw: Uint8Array | null = reader(context, PasswordStore.stringToArray(alias));
      if (raw === null) {
        PasswordStore.cache.set(alias, '');
        return '';
      }
      const value: string = PasswordStore.arrayToString(raw);
      PasswordStore.cache.set(alias, value);
      return value;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'get failed, code: %{public}d, message: %{public}s', err.code, err.message);
      // 读取失败不缓存，下次重试（与旧实现对 NOT_FOUND 的处理区分开）
      return '';
    }
  }

  /** 删除条目（账号被删除时需同步清理其密码）。 */
  static remove(alias: string): void {
    try {
      const context = PasswordStore.context;
      if (context === null) {
        return;
      }
      const remover = PlatformTarget.isAndroid() ? deleteAndroid : deleteOhos;
      remover(context, PasswordStore.stringToArray(alias));
      PasswordStore.cache.set(alias, '');
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'remove failed, code: %{public}d, message: %{public}s', err.code, err.message);
    }
  }

  /**
   * 确保别名在底层存储中存在（用于把历史上明文保存的凭据迁移过来）。
   * 已存在时不覆盖：底层存储中的值更可信，避免明文旧值倒灌。
   * 返回是否已就绪（含此前已存在的情况）。
   */
  static ensure(alias: string, secret: string): boolean {
    if (secret.length === 0 || PasswordStore.get(alias).length > 0) {
      return true;
    }
    PasswordStore.set(alias, secret);
    return PasswordStore.get(alias).length > 0;
  }
}
