import { AuthImage } from './AuthImage';
import { IconCircleButton } from './IconCircleButton';
import { BookListCoverBook, BookListSummary, booklistColorHex } from '../models/BookListModels';

const MAX_COVERS: number = 12;

/** 书单卡片，对齐 Web 端 components/BookListCard.vue：色条边框 + 名称/描述 + 属主 + 统计 + 封面墙。 */
@Component
export struct BookListCardItem {
  item: BookListSummary = {
    id: 0, name: '', description: '', color: 'marine', isPublic: true, isSticky: false,
    viewCount: 0, likeCount: 0, bookCount: 0, owner: null, isOwner: false,
    likedByMe: false, coverBooks: [],
  };
  showManage: boolean = false;
  showRecommendBadge: boolean = false;
  onItemTap?: () => void;
  onLikeTap?: () => void;
  onManageTap?: () => void;

  private accentColor(): string {
    return booklistColorHex(this.item.color);
  }

  @Builder
  ownerAvatar() {
    if (this.item.owner !== null && this.item.owner.avatar.length > 0) {
      Column() {
        AuthImage({
          url: this.item.owner.avatar,
          imageWidth: 26,
          imageHeight: 26,
        });
      }
      .borderRadius(13)
      .clip(true);
    } else {
      SymbolGlyph($r('sys.symbol.person'))
        .fontSize(24)
        .fontColor([$r('app.color.text_tertiary')]);
    }
  }

  build() {
    Column() {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Row({ space: 4 }) {
              Text(this.item.name)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              if (!this.item.isPublic) {
                SymbolGlyph($r('sys.symbol.lock'))
                  .fontSize(13)
                  .fontColor([$r('app.color.text_tertiary')]);
              }
            }
            .alignItems(VerticalAlign.Center);
            Text(this.item.description.length > 0 ? this.item.description : '暂无简介')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .lineHeight(17);
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);

          if (this.showManage) {
            IconCircleButton({
              icon: $r('sys.symbol.ellipsis_circle'),
              variant: 'soft',
              iconSize: 16,
              buttonSize: 28,
              onTap: () => {
                if (this.onManageTap) {
                  this.onManageTap();
                }
              },
            });
          } else {
            Row({ space: 4 }) {
              this.ownerAvatar();
              if (this.item.owner !== null) {
                Text(this.item.owner.username)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 72 });
              }
            }
            .alignItems(VerticalAlign.Center);
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top);

        Row({ space: 14 }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.book'))
              .fontSize(12)
              .fontColor([$r('app.color.text_tertiary')]);
            Text(`${this.item.bookCount}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'));
          }
          .alignItems(VerticalAlign.Center);
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.eye'))
              .fontSize(12)
              .fontColor([$r('app.color.text_tertiary')]);
            Text(`${this.item.viewCount}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'));
          }
          .alignItems(VerticalAlign.Center);
          Row({ space: 4 }) {
            SymbolGlyph(this.item.likedByMe ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(12)
              .fontColor([this.item.likedByMe ? $r('app.color.error') : $r('app.color.text_tertiary')]);
            Text(`${this.item.likeCount}`)
              .fontSize(12)
              .fontColor(this.item.likedByMe ? $r('app.color.error') : $r('app.color.text_secondary'));
          }
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            if (this.onLikeTap) {
              this.onLikeTap();
            }
          });
          Blank().layoutWeight(1);
          if (this.item.isSticky && this.showRecommendBadge) {
            Text('推荐')
              .fontSize(10)
              .fontColor(Color.White)
              .backgroundColor('#EF6C00')
              .borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 });
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
      }
      .width('100%');

      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(0.5)
        .margin({ top: 4 });

      if (this.item.coverBooks.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.item.coverBooks.slice(0, MAX_COVERS), (cover: BookListCoverBook) => {
            AuthImage({
              url: cover.thumb.length > 0 ? cover.thumb : cover.img,
              imageWidth: 46,
              imageHeight: 63,
            })
              .margin({ right: 6, top: 8 });
          }, (cover: BookListCoverBook) => `${cover.bookId}`);
        }
        .width('100%');
      } else {
        Text('书单暂无书籍')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 10 });
      }
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .border({
      width: { left: 4 },
      color: { left: this.accentColor() },
    })
    .alignItems(HorizontalAlign.Start)
    .stateStyles({
      pressed: {
        .backgroundColor($r('app.color.surface_pressed'))
      },
    })
    .onClick(() => {
      if (this.onItemTap) {
        this.onItemTap();
      }
    });
  }
}
