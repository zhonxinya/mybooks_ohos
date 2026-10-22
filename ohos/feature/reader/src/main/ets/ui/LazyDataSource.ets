/**
 * 通用 IDataSource：配合 LazyForEach 只构建可见项。
 *
 * 正文段落与章节目录都用它——超长章节（数千段）与数千章的书都不会在首屏全量建节点。
 */
export class LazyDataSource<T> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** 整表替换并通知重载。 */
  update(items: T[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }

  /** 单条更新：只通知框架指定索引变化，避免整表 reload。 */
  updateAt(index: number, item: T): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    this.items[index] = item;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataChange(index));
  }

  /** 只替换数据但不发通知（调用方自行决定通知粒度）。 */
  replaceAll(items: T[]): void {
    this.items = items;
  }

  /** 清空但不通知。紧接着的 update/append 会负责通知，避免中间闪一帧空列表。 */
  resetQuiet(): void {
    this.items = [];
  }

  /** 只追加新页，已在屏上的页不重建。 */
  append(items: T[]): void {
    if (items.length === 0) {
      return;
    }
    const start: number = this.items.length;
    this.items = this.items.concat(items);
    this.listeners.forEach((listener: DataChangeListener) => {
      for (let i = 0; i < items.length; i++) {
        listener.onDataAdd(start + i);
      }
    });
  }
}
