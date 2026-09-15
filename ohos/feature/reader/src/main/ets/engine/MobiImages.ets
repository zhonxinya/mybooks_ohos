import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookFile } from './BookFile';
import { MobiDoc } from './MobiDoc';

const TAG: string = 'MobiImages';

/**
 * MOBI 图片资源落地：把资源记录按需写成沙箱里的图片文件。
 *
 * MOBI 的插图不放在正文里，而是 `<img recindex="00005">` 指向第 `firstResource + recindex - 1`
 * 条记录（1 起计数）。ArkUI 的 `Image` 只能读文件，因此首次遇到某张图时把它落盘，
 * 之后按路径缓存复用——一本书往往只有几张图，代价远小于开书时全量导出。
 */
export class MobiImages {
  /**
   * 确保第 `recindex` 张图片已落到 `imageDir`，返回其沙箱绝对路径。
   * 记录缺失、越界或不是已知图片格式时返回空串（调用方据此丢掉该图）。
   */
  static ensure(filePath: string, imageDir: string, records: number[],
    firstResource: number, recindex: number): string {
    if (firstResource <= 0 || recindex <= 0) {
      return '';
    }
    const record: number = firstResource + recindex - 1;
    if (record < 0 || record + 1 >= records.length) {
      return '';
    }
    const from: number = records[record];
    const to: number = records[record + 1];
    if (to <= from) {
      return '';
    }
    try {
      const data: Uint8Array = new Uint8Array(BookFile.readRange(filePath, from, to - from));
      const start: number = MobiDoc.imageStart(data);
      const extension: string = MobiDoc.imageExtension(data, start);
      if (extension.length === 0) {
        return '';
      }
      const path: string = BookFile.join(imageDir, `img_${recindex}.${extension}`);
      if (BookFile.exists(path)) {
        return path;
      }
      // 目录按需创建：一本书没有插图时不必留下空目录
      BookFile.ensureDir(imageDir);
      BookFile.writeBytes(path, data.buffer.slice(data.byteOffset + start));
      return path;
    } catch (error) {
      hilog.warn(0x0000, TAG, 'extract image %{public}d failed: %{public}s', recindex, (error as Error).message);
      return '';
    }
  }
}
