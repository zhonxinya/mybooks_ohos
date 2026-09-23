import { PrimaryButton, SecondaryButton } from '../components';
import { BookReviewItem } from '../models/BookReviewModels';

/**
 * 书籍详情「写书评 / 修改评价」面板。
 * 从 BookDetailPage 竖切出来，避免详情页因评价态变化整页重建评价以外的区域。
 */
@Component
export struct BookDetailReviewSheet {
  @Link reviewStars: number;
  @Link reviewComment: string;
  @Prop ownReview: BookReviewItem | null = null;
  @Prop submittingReview: boolean = false;
  onSubmit: () => void = () => {};
  onDelete: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text('评分')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'));
        this.reviewStarsRow(this.reviewStars, 26);
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
      Row({ space: 6 }) {
        ForEach([1, 2, 3, 4, 5], (index: number) => {
          Column() {
            SymbolGlyph(index <= this.reviewStars ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
              .fontSize(30)
              .fontColor([index <= this.reviewStars ? $r('app.color.brand_primary') : $r('app.color.divider')]);
          }
          .onClick(() => {
            this.reviewStars = index;
          });
        }, (index: number) => `pick-${index}-${this.reviewStars}`);
      }
      .width('100%')
      .justifyContent(FlexAlign.Center);
      TextArea({ text: this.reviewComment, placeholder: '写下你的评价（可选）' })
        .width('100%')
        .height(100)
        .onChange((value: string) => {
          this.reviewComment = value;
        });
      Row({ space: 12 }) {
        if (this.ownReview !== null) {
          SecondaryButton({
            label: '删除我的评价',
            fullWidth: false,
            onTap: () => this.onDelete(),
          })
            .layoutWeight(1);
        }
        PrimaryButton({
          label: '提交评价',
          fullWidth: false,
          buttonEnabled: !this.submittingReview,
          onTap: () => this.onSubmit(),
        })
          .layoutWeight(1);
      }
      .width('100%');
    }
    .width('100%')
    .padding($r('app.float.page_padding'));
  }

  @Builder
  reviewStarsRow(stars: number, size: number) {
    Row({ space: 2 }) {
      ForEach([1, 2, 3, 4, 5], (index: number) => {
        SymbolGlyph(index <= stars ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
          .fontSize(size)
          .fontColor([index <= stars ? $r('app.color.brand_primary') : $r('app.color.divider')]);
      }, (index: number) => `star-${index}-${stars}-${size}`);
    }
  }
}
