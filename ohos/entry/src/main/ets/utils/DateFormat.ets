export class DateFormat {
  static lastReadLabel(timestamp?: number): string {
    if (timestamp === undefined || timestamp <= 0) {
      return '';
    }
    const diff = Date.now() - timestamp;
    const days = Math.floor(diff / 86400000);
    if (days <= 0) {
      return '今天读过';
    }
    if (days === 1) {
      return '昨天读过';
    }
    if (days < 7) {
      return `${days}天前`;
    }
    return new Date(timestamp).toLocaleDateString();
  }

  static formatDateTime(timestamp?: number): string {
    if (timestamp === undefined || timestamp <= 0) {
      return '';
    }
    return new Date(timestamp).toLocaleString();
  }
}
