import { ReaderTheme } from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';

/** 当前时间的 `HH:mm`（24 小时制）。 */
function clockText(): string {
  const now = new Date();
  const hour = now.getHours();
  const minute = now.getMinutes();
  return `${hour < 10 ? '0' : ''}${hour}:${minute < 10 ? '0' : ''}${minute}`;
}

/**
 * 阅读区顶部时间（屏幕右上角、与章节名齐平）。
 *
 * 只在文本变化时重建自身；定时器对齐到分钟边界，一分钟一次，
 * 不做逐秒刷新（阅读时秒级变化无意义且会持续触发重建）。
 */
@Component
export struct ReaderClock {
  @Prop theme: ReaderTheme = ReaderTheme.LIGHT;
  @State private timeText: string = clockText();
  private timerId: number = -1;

  aboutToAppear(): void {
    this.scheduleTick();
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  build() {
    Text(this.timeText)
      .fontSize(12)
      .fontColor(ReaderPalette.hintColor(this.theme))
      .maxLines(1);
  }

  /** 下一次整分钟时刷新，之后每分钟一次（不累积漂移）。 */
  private scheduleTick(): void {
    const delay = 60000 - (Date.now() % 60000);
    this.timerId = setTimeout(() => {
      this.timeText = clockText();
      this.scheduleTick();
    }, delay);
  }
}
