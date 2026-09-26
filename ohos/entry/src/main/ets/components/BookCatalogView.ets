import { BookGridCard } from './BookGridCard';
import { BookListItem, BookListItemData } from './BookListItem';
import { LoadingState } from './LoadingState';
import { BookCatalogDataSource } from './BookCatalogDataSource';

/**
 * 网格列数。
 *
 * 列数只用这一处定义：表头/加载项的跨列范围由 `GRID_COLUMNS - 1` 推导，
 * 列模板也由它拼出来。曾在改列数时漏改表头跨列，结果首页那整块推荐区只占前两列宽、被挤到屏幕左侧。
 */
const GRID_COLUMNS: number = 3;
const GRID_COLUMN_GAP: number = 10;
const GRID_ROW_GAP: number = 14;
/** 距末尾还剩几项就预加载下一页：3 列下一屏约 9~12 项，留 6 项做提前量。 */
const LOAD_MORE_THRESHOLD_ITEMS: number = 6;

function buildColumnsTemplate(columns: number): string {
  const parts: string[] = [];
  for (let i = 0; i < columns; i++) {
    parts.push('1fr');
  }
  return parts.join(' ');
}

const GRID_COLUMNS_TEMPLATE: string = buildColumnsTemplate(GRID_COLUMNS);

@Component
export struct BookCatalogView {
  @Prop @Watch('onItemsChanged') items: BookListItemData[] = [];
  @Prop isListMode: boolean = false;
  @Prop loadingMore: boolean = false;
  @BuilderParam header: () => void = this.emptyHeader;
  onItemTap: (item: BookListItemData) => void = () => {};
  onItemLongPress: (item: BookListItemData) => void = () => {};
  onLoadMore: () => void = () => {};
  private scrollController: Scroller = new Scroller();
  private dataSource: BookCatalogDataSource = new BookCatalogDataSource();

  @Builder
  emptyHeader() {
  }

  aboutToAppear(): void {
    this.dataSource.update(this.items);
  }

  onItemsChanged(): void {
    this.dataSource.sync(this.items);
  }

  build() {
    if (this.isListMode) {
      List({ scroller: this.scrollController, space: 8 }) {
        ListItem() {
          this.header();
        }
        LazyForEach(this.dataSource, (item: BookListItemData) => {
          ListItem() {
            BookListItem({
              item: item,
              onTap: () => this.onItemTap(item),
            })
              .gesture(
                LongPressGesture({ repeat: false })
                  .onAction(() => this.onItemLongPress(item)),
              );
          }
          .height($r('app.float.list_item_height'))
          .padding({ left: 16, right: 16 })
          // key 必须包含行内会变化的字段：角标（如「已入库」）是异步补齐的，
          // 只按下标做 key 时 onDataReloaded 会复用旧组件，行内容不刷新
        }, (item: BookListItemData) => `list-${item.id}-${item.badge ?? ''}`);
        if (this.loadingMore) {
          ListItem() {
            LoadingState({ hint: '加载更多...' });
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
      .cachedCount(8)
      .onReachEnd(() => this.onLoadMore());
    } else {
      Grid() {
        GridItem() {
          Column() {
            this.header();
          }
          .width('100%')
          .padding({ left: 0, right: 0 });
        }
        .columnStart(0)
        .columnEnd(GRID_COLUMNS - 1)

        LazyForEach(this.dataSource, (item: BookListItemData) => {
          GridItem() {
            BookGridCard({
              title: item.title,
              author: item.author ?? '',
              cover: item.cover ?? '',
              format: item.format ?? '',
              subtitle: item.subtitle ?? '',
              badge: item.badge ?? '',
              onTap: () => this.onItemTap(item),
              onLongPress: () => this.onItemLongPress(item),
            });
          }
        }, (item: BookListItemData) => `grid-${item.id}-${item.badge ?? ''}`);

        if (this.loadingMore) {
          GridItem() {
            LoadingState({ hint: '加载更多...' });
          }
          .columnStart(0)
          .columnEnd(GRID_COLUMNS - 1)
        }
      }
      .columnsTemplate(GRID_COLUMNS_TEMPLATE)
      .columnsGap(GRID_COLUMN_GAP)
      .rowsGap(GRID_ROW_GAP)
      .padding({ left: 16, right: 16, bottom: 16 })
      .cachedCount(12)
      .layoutWeight(1)
      .width('100%')
      .onScrollIndex((_first: number, last: number) => {
        if (last >= this.dataSource.totalCount() - LOAD_MORE_THRESHOLD_ITEMS) {
          this.onLoadMore();
        }
      });
    }
  }
}
