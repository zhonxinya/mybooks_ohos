import { ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { ReaderPage } from '../engine/PageLayout';
import { LazyDataSource } from './LazyDataSource';

const PARAGRAPH_SPACING: number = 12;

/**
 * 单页视图（分页阅读器用）。
 *
 * 页码与位移都走 `@Prop`：翻页拖拽时父组件每帧改 `offsetX`，子组件必须能可靠重建，
 * 而 `@Builder` 按值传参的刷新语义不适合这种高频更新。
 * `pages` 用普通成员按引用传递，避免每帧深拷贝页面文本。
 */
@Component
export struct ReaderPageView {
  pages: LazyDataSource<ReaderPage> = new LazyDataSource<ReaderPage>();
  @Prop pageIndex: number = 0;
  @Prop offsetX: number = 0;
  @Prop layerOrder: number = 0;
  @Prop fontSize: number = 18;
  @Prop lineHeight: number = 1.6;
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @Prop horizontalSpace: number = 22;
  @Prop topSpace: number = 44;
  @Prop bottomSpace: number = 32;

  build() {
    Column({ space: PARAGRAPH_SPACING }) {
      ForEach(this.pageTexts(), (text: string, index: number) => {
        Text(text)
          .fontSize(this.fontSize)
          .lineHeight(this.lineHeight * this.fontSize)
          .fontColor(ReaderPalette.textColor(this.theme))
          .width('100%');
      }, (text: string, index: number) => `${this.pageIndex}_${index}`);
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: this.horizontalSpace,
      right: this.horizontalSpace,
      top: this.topSpace,
      bottom: this.bottomSpace,
    })
    .translate({ x: this.offsetX })
    .zIndex(this.layerOrder)
    .backgroundColor(ReaderPalette.pageBackground(this.theme))
    .clip(true);
  }

  private pageTexts(): string[] {
    const page: ReaderPage | undefined = this.pages.getData(this.pageIndex);
    return page === undefined ? [] : page.texts;
  }
}
