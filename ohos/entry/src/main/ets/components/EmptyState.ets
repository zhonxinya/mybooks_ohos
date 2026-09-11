import { PrimaryButton } from './PrimaryButton';

@Component
export struct EmptyState {
  message: string = '';
  detail: string = '';
  actionLabel: string = '';
  onAction?: () => void;

  build() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.book'))
        .fontSize(48)
        .fontColor([$r('app.color.text_tertiary')]);
      Text(this.message)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'));
      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center);
      }
      if (this.actionLabel.length > 0 && this.onAction) {
        PrimaryButton({
          label: this.actionLabel,
          fullWidth: false,
          onTap: () => this.onAction!(),
        });
      }
    }
    .width('100%')
    .padding($r('app.float.page_padding'))
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }
}
