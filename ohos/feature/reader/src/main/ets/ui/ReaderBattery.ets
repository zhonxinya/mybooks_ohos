import { batteryInfo } from '@kit.BasicServicesKit';
import { ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';

/** 电量轮询间隔：系统无电量变化订阅，分钟级足够。 */
const BATTERY_REFRESH_MS: number = 60000;

/**
 * 页脚电量指示：小电池图形 + 百分比。
 *
 * 自管轮询与 @State，避免父阅读器因电量刷新整树重建。
 * 只用模块内的调色板与 ArkUI 基础图形（不依赖系统 symbol，避免符号缺失时空白）；
 * `level < 0` 表示未知、整块不渲染。
 */
@Component
export struct ReaderBattery {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @State private level: number = -1;
  @State private charging: boolean = false;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.timerId = setInterval(() => {
      this.refresh();
    }, BATTERY_REFRESH_MS);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private refresh(): void {
    try {
      this.level = batteryInfo.batterySOC;
      this.charging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ||
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
    } catch (_error) {
      this.level = -1;
    }
  }

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
