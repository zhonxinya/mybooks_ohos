import { ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';

/**
 * 页脚电量指示：小电池图形 + 百分比。
 *
 * 只用模块内的调色板与 ArkUI 基础图形（不依赖系统 symbol，避免符号缺失时空白）；
 * 电量值由父组件读取 `batteryInfo.batterySOC` 后传入，`level < 0` 表示未知、整块不渲染。
 */
@Component
export struct ReaderBattery {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  /** 电量百分比 0~100；负数表示未知 */
  @Prop level: number = -1;
  @Prop charging: boolean = false;

  build() {
    if (this.level >= 0) {
      Row({ space: 4 }) {
        Row() {
          // 内填充：宽度随电量变化（电池槽 16x9，内边距 1）
          Column()
            .width(this.fillWidth())
            .height(5)
            .borderRadius(1)
            .backgroundColor(this.lowPower() ? '#E84026' : ReaderPalette.accentColor());
        }
        .width(16)
        .height(9)
        .padding(1)
        .borderRadius(2)
        .border({ width: 1, color: ReaderPalette.hintColor(this.theme) })
        .alignItems(VerticalAlign.Center);

        // 电极
        Column()
          .width(1.5)
          .height(4)
          .borderRadius(1)
          .backgroundColor(ReaderPalette.hintColor(this.theme));

        Text(this.charging ? `${this.level}%+` : `${this.level}%`)
          .fontSize(10)
          .fontColor(this.lowPower() ? '#E84026' : ReaderPalette.hintColor(this.theme));
      }
      .alignItems(VerticalAlign.Center);
    }
  }

  private fillWidth(): number {
    const ratio = Math.min(100, Math.max(0, this.level)) / 100;
    // 电池槽内可用宽度：16 - 2*1(内边距) - 2*1(边框) = 12
    return Math.max(1, Math.round(ratio * 12));
  }

  private lowPower(): boolean {
    return this.level >= 0 && this.level <= 20;
  }
}
