import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

interface CoverCacheEntry {
  name: string;
  mtime: number;
}

/** 封面磁盘缓存：路径哈希 + 简单 LRU 淘汰 */
export class CoverCache {
  private static readonly MAX_FILES: number = 300;
  private static readonly EVICT_BATCH: number = 40;
  private static lastEvictAt: number = 0;

  static cacheDir(context: common.UIAbilityContext): string {
    return `${context.filesDir}/.cache/covers`;
  }

  static pathFor(context: common.UIAbilityContext, url: string): string {
    let hash = 2166136261;
    for (let i = 0; i < url.length; i++) {
      hash ^= url.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    const key = (hash >>> 0).toString(16);
    return `${CoverCache.cacheDir(context)}/${key}.img`;
  }

  static ensureDir(context: common.UIAbilityContext): void {
    const dir = CoverCache.cacheDir(context);
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (_error) {
      try {
        fs.mkdirSync(dir, true);
      } catch (_ignored) {
      }
    }
  }

  static maybeEvict(context: common.UIAbilityContext): void {
    const now = Date.now();
    if (now - CoverCache.lastEvictAt < 60000) {
      return;
    }
    CoverCache.lastEvictAt = now;
    const dir = CoverCache.cacheDir(context);
    try {
      if (!fs.accessSync(dir)) {
        return;
      }
      const names = fs.listFileSync(dir);
      if (names.length <= CoverCache.MAX_FILES) {
        return;
      }
      const entries: CoverCacheEntry[] = [];
      for (let i = 0; i < names.length; i++) {
        const name = names[i];
        if (!name.endsWith('.img')) {
          continue;
        }
        try {
          const st = fs.statSync(`${dir}/${name}`);
          const entry: CoverCacheEntry = { name: name, mtime: Number(st.mtime) };
          entries.push(entry);
        } catch (_error) {
        }
      }
      entries.sort((a: CoverCacheEntry, b: CoverCacheEntry) => a.mtime - b.mtime);
      const removeCount = Math.min(CoverCache.EVICT_BATCH,
        entries.length - CoverCache.MAX_FILES + CoverCache.EVICT_BATCH);
      for (let i = 0; i < removeCount && i < entries.length; i++) {
        try {
          fs.unlinkSync(`${dir}/${entries[i].name}`);
        } catch (_error) {
        }
      }
    } catch (_error) {
    }
  }
}
