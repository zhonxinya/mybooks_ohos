import { BookViewMode } from '../utils/BookViewMode';
import { IconCircleButton } from './IconCircleButton';

@Component
export struct BookViewToggleButton {
  @Link isListMode: boolean;

  build() {
    IconCircleButton({
      icon: this.isListMode ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.list_bullet'),
      variant: 'ghost',
      onTap: () => {
        this.isListMode = !this.isListMode;
        BookViewMode.setListMode(this.isListMode);
      },
    });
  }
}
