import { ChipButton } from './ChipButton';

export interface FilterChipItem {
  label: string;
  value: number;
}

@Component
export struct FilterChips {
  items: FilterChipItem[] = [];
  @Link selected: number;
  onChange?: (value: number) => void;
  /** 尾部插槽（如书架页的排序下拉）；不传时与原先完全一致。 */
  @BuilderParam trailing: () => void = this.emptyTrailing;
  /** 横向滚动模式：放进横向 Scroll 时置 true，去掉 100% 宽度与 Blank 占位，让内容自然撑开、尾部可达。 */
  scrollable: boolean = false;

  @Builder
  emptyTrailing() {
  }

  @Builder
  chipItems() {
    ForEach(this.items, (item: FilterChipItem) => {
      ChipButton({
        label: item.label,
        selected: this.selected === item.value,
        onTap: () => {
          this.selected = item.value;
          if (this.onChange) {
            this.onChange(item.value);
          }
        },
      });
    }, (item: FilterChipItem) => `${item.value}`);
  }

  build() {
    if (this.scrollable) {
      Row({ space: 8 }) {
        this.chipItems();
        this.trailing();
      }
      .padding({ left: 16, right: 16, bottom: 8 });
    } else {
      Row({ space: 8 }) {
        this.chipItems();
        Blank().layoutWeight(1);
        this.trailing();
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 });
    }
  }
}
