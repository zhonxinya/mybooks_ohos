import { batteryInfo, deviceInfo } from '@kit.BasicServicesKit';
import entry from 'libentry.so';
import { ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';

/** 电量轮询间隔：系统无电量变化订阅，分钟级足够。 */
const BATTERY_REFRESH_MS: number = 60000;

/**
 * 电量能力是否可用（模块级缓存，探测一次）。
 * 鸿蒙端调 `batteryInfo` 抛异常说明平台不支持；这里探测一次后不再轮询，
 * 既避免每分钟刷异常日志，也让页脚干脆不渲染电量块。
 * （安卓端不走 batteryInfo，也不落此标记，见 refreshAndroid。）
 */
let batteryUnavailable: boolean = false;

/** 安卓分支返回的电池状态。 */
interface BatteryAndroidInfo {
  level: number;
  charging: boolean;
}

/**
 * 平台判定与 entry 的 PlatformTarget 同依据（osFullName 含 android）；
 * reader 是独立 HAR、不能反向依赖 entry，故在此本地实现。
 */
function isAndroidPlatform(): boolean {
  const osName: string = deviceInfo.osFullName ?? '';
  return osName.toLowerCase().indexOf('android') >= 0;
}

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
    if (batteryUnavailable) {
      return;
    }
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
    if (batteryUnavailable) {
      return;
    }
    if (isAndroidPlatform()) {
      this.refreshAndroid();
      return;
    }
    try {
      this.level = batteryInfo.batterySOC;
      this.charging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ||
        batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.FULL;
    } catch (_error) {
      // 平台不支持电量查询：标记后停止轮询，页脚不显示电量
      batteryUnavailable = true;
      this.level = -1;
      if (this.timerId >= 0) {
        clearInterval(this.timerId);
        this.timerId = -1;
      }
    }
  }

  /**
   * 安卓分支：ArkUI-X 的 Android SDK 没有 batteryinfo 插件，
   * 改经 libentry 原生桥读 BatteryManager（BatteryReader，见 android-overlay）。
   * 拿到空串（理论上不该出现）时本轮留空但**不置 batteryUnavailable**——
   * 桥就绪后下一轮轮询自愈，避免一次抖动永久关掉电量显示。
   */
  private refreshAndroid(): void {
    const json: string = entry.apiGetBatteryInfo() as string;
    if (json.length === 0) {
      this.level = -1;
      this.charging = false;
      return;
    }
    try {
      const info = JSON.parse(json) as BatteryAndroidInfo;
      this.level = info.level;
      this.charging = info.charging;
    } catch (_error) {
      this.level = -1;
      this.charging = false;
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
