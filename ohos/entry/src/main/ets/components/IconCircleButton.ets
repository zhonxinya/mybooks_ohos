export type IconCircleVariant = 'ghost' | 'soft' | 'primary' | 'surface';

@Component
export struct IconCircleButton {
  icon: Resource = $r('sys.symbol.circle');
  variant: IconCircleVariant = 'ghost';
  iconSize: number = 20;
  buttonSize: number = 40;
  iconColor?: ResourceColor;
  buttonBackground?: ResourceColor;
  onTap?: () => void;

  private resolvedBackground(): ResourceColor {
    if (this.buttonBackground !== undefined) {
      return this.buttonBackground;
    }
    if (this.variant === 'primary') {
      return $r('app.color.brand_primary');
    }
    if (this.variant === 'soft') {
      return $r('app.color.brand_primary_light');
    }
    if (this.variant === 'surface') {
      return $r('app.color.card_background');
    }
    return Color.Transparent;
  }

  private resolvedPressedBackground(): ResourceColor {
    if (this.buttonBackground !== undefined) {
      return $r('app.color.surface_pressed');
    }
    if (this.variant === 'primary') {
      return $r('app.color.brand_primary_pressed');
    }
    if (this.variant === 'soft') {
      return $r('app.color.brand_primary_light_pressed');
    }
    return $r('app.color.surface_pressed');
  }

  private resolvedIconColor(): ResourceColor {
    if (this.iconColor !== undefined) {
      return this.iconColor;
    }
    if (this.variant === 'primary') {
      return $r('app.color.on_brand');
    }
    if (this.variant === 'soft') {
      return $r('app.color.brand_primary');
    }
    return $r('app.color.text_primary');
  }

  build() {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      SymbolGlyph(this.icon)
        .fontSize(this.iconSize)
        .fontColor([this.resolvedIconColor()]);
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .backgroundColor(this.resolvedBackground())
    .shadow(this.variant === 'surface' ? {
      radius: 8,
      color: '#14000000',
      offsetX: 0,
      offsetY: 2,
    } : {
      radius: 0,
      color: Color.Transparent,
      offsetX: 0,
      offsetY: 0,
    })
    .stateStyles({
      pressed: {
        .backgroundColor(this.resolvedPressedBackground())
      },
    })
    .onClick(() => {
      if (this.onTap) {
        this.onTap();
      }
    });
  }
}
