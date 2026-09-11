export class ErrorFormat {
  static message(error: Object | string | undefined | null): string {
    if (error === undefined || error === null) {
      return '未知错误';
    }
    if (typeof error === 'string') {
      if (error.length === 0 || error === '[object Object]') {
        return '未知错误';
      }
      return error;
    }
    if (error instanceof Error) {
      const text = error.message;
      if (text.length === 0 || text === '[object Object]') {
        return '未知错误';
      }
      return text;
    }
    const record = error as Record<string, Object>;
    const msg = record['message'];
    if (typeof msg === 'string' && msg.length > 0) {
      return msg;
    }
    const code = record['code'];
    if (typeof code === 'number') {
      return `错误码 ${code}`;
    }
    if (typeof code === 'string' && code.length > 0) {
      return `错误码 ${code}`;
    }
    return '未知错误';
  }
}
