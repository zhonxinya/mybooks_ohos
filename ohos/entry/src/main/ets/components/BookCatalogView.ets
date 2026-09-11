import { BookGridCard } from './BookGridCard';
import { BookListItem, BookListItemData } from './BookListItem';
import { LoadingState } from './LoadingState';
import { BookCatalogDataSource } from './BookCatalogDataSource';

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
    this.dataSource.update(this.items);
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
        }, (item: BookListItemData) => `list-${item.id}`);
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
        .columnEnd(1)

        LazyForEach(this.dataSource, (item: BookListItemData) => {
          GridItem() {
            BookGridCard({
              title: item.title,
              author: item.author ?? '',
              cover: item.cover ?? '',
              format: item.format ?? '',
              subtitle: item.subtitle ?? '',
              onTap: () => this.onItemTap(item),
              onLongPress: () => this.onItemLongPress(item),
            });
          }
        }, (item: BookListItemData) => `grid-${item.id}`);

        if (this.loadingMore) {
          GridItem() {
            LoadingState({ hint: '加载更多...' });
          }
          .columnStart(0)
          .columnEnd(1)
        }
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(12)
      .rowsGap(12)
      .padding({ left: 16, right: 16, bottom: 16 })
      .cachedCount(8)
      .layoutWeight(1)
      .width('100%')
      .onScrollIndex((_first: number, last: number) => {
        if (last >= this.dataSource.totalCount() - 4) {
          this.onLoadMore();
        }
      });
    }
  }
}
