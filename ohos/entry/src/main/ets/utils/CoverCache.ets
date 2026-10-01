import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { taskpool } from '@kit.ArkTS';

interface CoverCacheEntry {
  name: string;
  mtime: number;
}

/** 淘汰任务：在 taskpool 里跑同步 FS，避免卡 UI。 */
@Concurrent
function evictCoverFiles(dir: string, maxFiles: number, evictBatch: number): void {
  try {
    if (!fs.accessSync(dir)) {
      return;
    }
    const names = fs.listFileSync(dir);
    if (names.length <= maxFiles) {
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
    const removeCount = Math.min(evictBatch, entries.length - maxFiles + evictBatch);
    for (let i = 0; i < removeCount && i < entries.length; i++) {
      try {
        fs.unlinkSync(`${dir}/${entries[i].name}`);
      } catch (_error) {
      }
    }
  } catch (_error) {
  }
}

/** 封面磁盘缓存：路径哈希 + 简单 LRU 淘汰 */
export class CoverCache {
  private static readonly MAX_FILES: number = 300;
  private static readonly EVICT_BATCH: number = 40;
  /** 淘汰最短间隔：避免滚动加载封面时频繁扫盘。 */
  private static readonly EVICT_INTERVAL_MS: number = 120000;
  private static lastEvictAt: number = 0;
  private static evictRunning: boolean = false;
  /** 目录就绪标记：目录只会被本进程的淘汰任务删文件、不会删目录，确认一次即可复用。 */
  private static dirReady: boolean = false;
  /** 已确认落盘的封面路径：滚动回看时免去逐张 accessSync；淘汰前整体作废。 */
  private static presentPaths: Set<string> = new Set();

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
    if (CoverCache.dirReady) {
      return;
    }
    const dir = CoverCache.cacheDir(context);
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      CoverCache.dirReady = true;
    } catch (_error) {
      try {
        fs.mkdirSync(dir, true);
        CoverCache.dirReady = true;
      } catch (_ignored) {
      }
    }
  }

  /**
   * 是否已确认落盘：先查内存命中集合，未命中才做一次 accessSync（结果回填集合）。
   * 淘汰任务删文件前会整体清空集合，因此不会把已删文件误判为存在。
   */
  static isPresent(path: string): boolean {
    if (CoverCache.presentPaths.has(path)) {
      return true;
    }
    try {
      if (fs.accessSync(path)) {
        CoverCache.presentPaths.add(path);
        return true;
      }
    } catch (_error) {
    }
    return false;
  }

  /** 下载成功落盘后登记，后续滚动回看直接走内存命中。 */
  static markPresent(path: string): void {
    CoverCache.presentPaths.add(path);
  }

  static maybeEvict(context: common.UIAbilityContext): void {
    const now = Date.now();
    if (CoverCache.evictRunning || now - CoverCache.lastEvictAt < CoverCache.EVICT_INTERVAL_MS) {
      return;
    }
    CoverCache.lastEvictAt = now;
    CoverCache.evictRunning = true;
    // 淘汰即将删文件：先作废内存命中集合，避免把已删文件误判为已缓存
    CoverCache.presentPaths.clear();
    const dir = CoverCache.cacheDir(context);
    const maxFiles = CoverCache.MAX_FILES;
    const batch = CoverCache.EVICT_BATCH;
    void taskpool.execute(evictCoverFiles, dir, maxFiles, batch).finally(() => {
      CoverCache.evictRunning = false;
    });
  }
}
