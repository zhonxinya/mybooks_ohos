// 独立阅读器模块对外出口：宿主只需依赖这些符号
export { ReaderView } from './src/main/ets/ui/ReaderView';
export {
  BookEngine,
  READER_FLIP_COVER,
  READER_FLIP_DEFAULT,
  READER_FLIP_NONE,
  READER_FLIP_OPTIONS,
  READER_FLIP_PREF_KEY,
  READER_FLIP_SCROLL,
  READER_FLIP_SLIDE,
  READER_MODE_AUTO,
  READER_MODE_BUILTIN,
  READER_MODE_PREF_KEY,
  ReaderCallbacks,
  ReaderCatalogItem,
  ReaderChapter,
  ReaderFlip,
  ReaderFormats,
  ReaderLocation,
  ReaderLocations,
  ReaderOpenOptions,
  ReaderSettings,
  ReaderTheme,
} from './src/main/ets/model/ReaderTypes';
export { ReaderPalette } from './src/main/ets/model/ReaderPalette';
