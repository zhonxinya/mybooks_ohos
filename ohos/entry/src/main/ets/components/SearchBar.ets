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
        .borderRadius(20)
        .backgroundColor($r('app.color.card_background'))
        .border({
          width: 1,
          color: $r('app.color.divider'),
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
