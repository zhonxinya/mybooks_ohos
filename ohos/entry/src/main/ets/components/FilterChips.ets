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
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 });
  }
}
