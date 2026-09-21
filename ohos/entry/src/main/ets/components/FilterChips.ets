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

  @Builder
  emptyTrailing() {
  }

  build() {
    Row({ space: 8 }) {
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
      Blank().layoutWeight(1);
      this.trailing();
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 });
  }
}
