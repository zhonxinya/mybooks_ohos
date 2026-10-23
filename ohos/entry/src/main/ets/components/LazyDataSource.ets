/** 通用 IDataSource 实现：配合 LazyForEach 按需创建列表项，避免长列表全量构建。 */
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

  /** 整表替换并通知重载（数量/顺序均可变化）。 */
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
}
