import { BookListItemData } from './BookListItem';

export class BookCatalogDataSource implements IDataSource {
  private items: BookListItemData[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): BookListItemData {
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

  update(items: BookListItemData[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }

  /**
   * 把外部数组同步进列表。
   * 前缀内容没变、只是变长时走追加；完全一致则不动；其余情况整表重载。
   */
  sync(items: BookListItemData[]): void {
    const prev: BookListItemData[] = this.items;
    if (items.length === prev.length && BookCatalogDataSource.samePrefix(prev, items, prev.length)) {
      return;
    }
    if (items.length > prev.length && BookCatalogDataSource.samePrefix(prev, items, prev.length)) {
      this.append(items.slice(prev.length));
      return;
    }
    this.update(items);
  }

  /** 追加分页数据，避免整表 onDataReloaded */
  append(items: BookListItemData[]): void {
    if (items.length === 0) {
      return;
    }
    const start = this.items.length;
    this.items = this.items.concat(items);
    this.listeners.forEach((listener: DataChangeListener) => {
      for (let i = 0; i < items.length; i++) {
        listener.onDataAdd(start + i);
      }
    });
  }

  /** 前缀每一项的展示字段都相同才算「只是追加」。角标、副标题变化会落到整表重载。 */
  private static samePrefix(prev: BookListItemData[], next: BookListItemData[], count: number): boolean {
    for (let i = 0; i < count; i++) {
      if (BookCatalogDataSource.fingerprint(prev[i]) !== BookCatalogDataSource.fingerprint(next[i])) {
        return false;
      }
    }
    return true;
  }

  private static fingerprint(item: BookListItemData): string {
    return `${item.id}\u0001${item.title}\u0001${item.author ?? ''}\u0001${item.cover ?? ''}\u0001` +
      `${item.subtitle ?? ''}\u0001${item.format ?? ''}\u0001${item.badge ?? ''}`;
  }
}
