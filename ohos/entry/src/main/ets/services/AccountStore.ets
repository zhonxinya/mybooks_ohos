import {
  ACCOUNTS_KEY, ACTIVE_ACCOUNT_KEY, AccountRecord, parseAccountsJson,
  passwordAliasFor, stringifyAccounts,
} from '../models/AccountModels';
import { PasswordStore } from './PasswordStore';
import { TalebookService } from './TalebookService';

/**
 * 账号清单与凭据的持久化入口。
 *
 * - 清单与当前账号 id 存全局偏好（preferences.json，不随账号变）
 * - 密码逐个存 Asset Store，别名为 `account_<id>_password`；默认账号沿用旧别名 `talebook_password`
 *   以便升级后继续复用已保存的密码
 */
export class AccountStore {
  /** 全部账号，保持保存顺序。 */
  static list(): AccountRecord[] {
    return parseAccountsJson(TalebookService.prefGet(ACCOUNTS_KEY, '[]'));
  }

  static saveAll(records: AccountRecord[]): void {
    TalebookService.prefSet(ACCOUNTS_KEY, stringifyAccounts(records));
  }

  /** 当前账号 id；未选择时为全局根对应的默认账号（含首次未配置的空值）。 */
  static activeId(): string {
    return TalebookService.prefGet(ACTIVE_ACCOUNT_KEY, '');
  }

  static setActiveId(id: string): void {
    TalebookService.prefSet(ACTIVE_ACCOUNT_KEY, id);
  }

  static find(id: string): AccountRecord | null {
    const records = AccountStore.list();
    for (let i = 0; i < records.length; i++) {
      if (records[i].id === id) {
        return records[i];
      }
    }
    return null;
  }

  static active(): AccountRecord | null {
    return AccountStore.find(AccountStore.activeId());
  }

  static count(): number {
    return AccountStore.list().length;
  }

  /** 密码读写（按账号别名走 Asset Store，不落明文）。 */
  static getPassword(id: string): string {
    return PasswordStore.get(passwordAliasFor(id));
  }

  static setPassword(id: string, password: string): void {
    PasswordStore.set(passwordAliasFor(id), password);
  }

  static removePassword(id: string): void {
    PasswordStore.remove(passwordAliasFor(id));
  }

  /** 删除账号记录（保持至少一个账号由调用方决定；返回是否删除成功）。 */
  static remove(id: string): boolean {
    const records = AccountStore.list();
    const remaining: AccountRecord[] = [];
    for (let i = 0; i < records.length; i++) {
      if (records[i].id !== id) {
        remaining.push(records[i]);
      }
    }
    if (remaining.length === records.length) {
      return false;
    }
    AccountStore.saveAll(remaining);
    AccountStore.removePassword(id);
    return true;
  }

  /** 该账号是否就是当前账号。 */
  static isActive(id: string): boolean {
    return AccountStore.activeId() === id;
  }
}
