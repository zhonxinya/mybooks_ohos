import { IconCircleButton } from './IconCircleButton';

@Component
export struct SearchBar {
  placeholder: string = '';
  @Link keyword: string;
  onSearch?: () => void;

  build() {
    Row({ space: 8 }) {
      TextInput({ placeholder: this.placeholder, text: this.keyword })
        .layoutWeight(1)
        .height($r('app.float.button_height_compact'))
        .backgroundColor($r('app.color.card_background'))
        // 圆角写进 border：先 borderRadius 再 border 会重置圆角；与按钮/卡片保持同一档圆角
        .border({
          width: 1,
          color: $r('app.color.divider'),
          radius: $r('app.float.button_radius'),
        })
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.keyword = value;
        })
        .onSubmit(() => {
          if (this.onSearch) {
            this.onSearch();
          }
        });
      IconCircleButton({
        icon: $r('sys.symbol.magnifyingglass'),
        variant: 'primary',
        iconSize: 18,
        onTap: () => {
          if (this.onSearch) {
            this.onSearch();
          }
        },
      });
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 });
  }
}
