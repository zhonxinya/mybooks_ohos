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
}
