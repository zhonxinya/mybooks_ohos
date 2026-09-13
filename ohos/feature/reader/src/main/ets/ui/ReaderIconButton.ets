/**
 * 圆形图标按钮（控制面板专用）。
 *
 * 与 entry 的 `IconCircleButton` 同形制，但只依赖模块内的字符串色，保持 `feature/reader` 自包含
 * （模块不能反向 import 宿主组件/资源）。
 */
@Component
export struct ReaderIconButton {
  icon: Resource = $r('sys.symbol.circle');
  @Prop iconSize: number = 20;
  @Prop buttonSize: number = 40;
  @Prop iconColor: string = '#3E3A39';
  @Prop buttonBackground: string = '#00000000';
  @Prop pressedBackground: string = '#1A000000';
  onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      SymbolGlyph(this.icon)
        .fontSize(this.iconSize)
        .fontColor([this.iconColor]);
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .backgroundColor(this.buttonBackground)
    .stateStyles({
      pressed: {
        .backgroundColor(this.pressedBackground)
      },
    })
    .onClick(() => this.onTap());
  }
}
