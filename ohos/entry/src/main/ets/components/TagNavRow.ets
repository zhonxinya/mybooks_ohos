import { ChipButton } from './ChipButton';

export interface TagNavItem {
  name: string;
  count: number;
}

@Component
export struct TagNavSection {
  legend: string = '';
  tags: TagNavItem[] = [];
  onTagTap: (name: string) => void = () => {};

  build() {
    if (this.tags.length === 0) {
      Column();
    } else {
      Column({ space: 8 }) {
        Text(this.legend)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .padding({ left: 16, right: 16 });

        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.tags, (tag: TagNavItem) => {
              ChipButton({
                label: `${tag.name} (${tag.count})`,
                onTap: () => this.onTagTap(tag.name),
              });
            }, (tag: TagNavItem) => `${this.legend}-${tag.name}`);
          }
          .padding({ left: 16, right: 16, bottom: 4 });
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%');
      }
      .width('100%')
      .margin({ bottom: 12 });
    }
  }
}
