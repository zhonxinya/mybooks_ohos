/**
 * 固定容量的 LRU。
 * 命中时把键挪到最近使用；超出容量时丢掉最久未用的一项，而不是整表清空。
 */
export class LruCache<K, V> {
  private readonly map: Map<K, V> = new Map<K, V>();
  private readonly order: K[] = [];
  private readonly limit: number;

  constructor(limit: number) {
    this.limit = limit < 1 ? 1 : limit;
  }

  get(key: K): V | undefined {
    const value: V | undefined = this.map.get(key);
    if (value === undefined || !this.map.has(key)) {
      return undefined;
    }
    this.touch(key);
    return value;
  }

  set(key: K, value: V): void {
    const exists: boolean = this.map.has(key);
    this.map.set(key, value);
    if (exists) {
      this.touch(key);
      return;
    }
    this.order.push(key);
    while (this.order.length > this.limit) {
      const oldest: K | undefined = this.order.shift();
      if (oldest !== undefined) {
        this.map.delete(oldest);
      }
    }
  }

  clear(): void {
    this.map.clear();
    this.order.length = 0;
  }

  private touch(key: K): void {
    const index: number = this.order.indexOf(key);
    if (index >= 0) {
      this.order.splice(index, 1);
    }
    this.order.push(key);
  }
}
