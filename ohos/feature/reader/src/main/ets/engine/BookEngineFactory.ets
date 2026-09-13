import { BookEngine, ReaderFormats, ReaderOpenOptions } from '../model/ReaderTypes';
import { EpubEngine } from './EpubEngine';
import { TxtEngine } from './TxtEngine';

/** 按格式选择解析引擎；不支持时抛出宿主可直接展示的错误。 */
export class BookEngineFactory {
  static async open(options: ReaderOpenOptions): Promise<BookEngine> {
    const format = ReaderFormats.normalize(options.format);
    if (format === ReaderFormats.EPUB) {
      return EpubEngine.open(options.filePath, options.title, options.cacheDir);
    }
    if (format === ReaderFormats.TXT) {
      return TxtEngine.load(options.filePath, options.title);
    }
    throw new Error(`内置阅读器暂不支持 ${format.toUpperCase()} 格式`);
  }
}
