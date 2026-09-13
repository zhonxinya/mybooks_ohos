import { ReaderCatalogItem, ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { LazyDataSource } from './LazyDataSource';

/**
 * 目录面板（底部半屏）。
 * 组件在 `if (showCatalog)` 中按需创建，故用普通成员接收参数而非 @Prop（避免深拷贝）。
 * 目录用 LazyForEach：数千章的书也只建可见行。
 */
@Component
export struct ReaderCatalogSheet {
  catalog: LazyDataSource<ReaderCatalogItem> = new LazyDataSource<ReaderCatalogItem>();
  currentIndex: number = 0;
  theme: ReaderTheme = ReaderTheme.LIGHT;
  onSelect: (index: number) => void = () => {};
  onClose: () => void = () => {};

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => this.onClose());
      Column() {
        this.header();
        List({ initialIndex: this.currentIndex }) {
          LazyForEach(this.catalog, (item: ReaderCatalogItem) => {
            ListItem() {
              Text(item.title)
                .fontSize(15)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor(item.index === this.currentIndex ?
                  ReaderPalette.accentColor() : ReaderPalette.textColor(this.theme))
                .width('100%')
                .padding({ left: 20, right: 20, top: 14, bottom: 14 })
            }
            .onClick(() => this.onSelect(item.index));
          }, (item: ReaderCatalogItem) => `${item.index}_${item.title}`)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .cachedCount(6);
      }
      .width('100%')
      .height('62%')
      .backgroundColor(ReaderPalette.panelBackground(this.theme))
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  header() {
    Row() {
      Text('目录')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(ReaderPalette.textColor(this.theme))
        .layoutWeight(1);
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(20)
        .fontColor([ReaderPalette.hintColor(this.theme)])
        .onClick(() => this.onClose());
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 10 })
    .border({ width: { bottom: 0.5 }, color: ReaderPalette.dividerColor(this.theme) });
  }
}
