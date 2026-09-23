export class DateFormat {
  /** 书架/历史等「最近阅读」文案：相对日 + 具体时分。 */
  static lastReadLabel(timestamp?: number): string {
    if (timestamp === undefined || timestamp <= 0) {
      return '';
    }
    const clock = DateFormat.formatClock(timestamp);
    const diff = Date.now() - timestamp;
    const days = Math.floor(diff / 86400000);
    if (days <= 0) {
      return `今天 ${clock}`;
    }
    if (days === 1) {
      return `昨天 ${clock}`;
    }
    if (days < 7) {
      return `${days}天前 ${clock}`;
    }
    const d = new Date(timestamp);
    const month = d.getMonth() + 1;
    const day = d.getDate();
    return `${month}/${day} ${clock}`;
  }

  static formatClock(timestamp: number): string {
    const d = new Date(timestamp);
    const h = d.getHours();
    const m = d.getMinutes();
    const hh = h < 10 ? `0${h}` : `${h}`;
    const mm = m < 10 ? `0${m}` : `${m}`;
    return `${hh}:${mm}`;
  }

  static formatDateTime(timestamp?: number): string {
    if (timestamp === undefined || timestamp <= 0) {
      return '';
    }
    return new Date(timestamp).toLocaleString();
  }
}
