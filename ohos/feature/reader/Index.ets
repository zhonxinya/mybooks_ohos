// 独立阅读器模块对外出口：宿主只需依赖这些符号
export { ReaderView } from './src/main/ets/ui/ReaderView';
export { ReaderControlPanel } from './src/main/ets/ui/ReaderControlPanel';
export { ReaderChrome } from './src/main/ets/ui/ReaderChrome';
export { ReaderIconButton } from './src/main/ets/ui/ReaderIconButton';
export { ReaderOverlayBar } from './src/main/ets/ui/ReaderOverlayBar';
export {
  ReaderChip,
  ReaderPanelButton,
  ReaderPanelSection,
  ReaderSegmentedControl,
  ReaderSelectRow,
  ReaderSliderBlock,
  ReaderSwitchRow,
} from './src/main/ets/ui/ReaderPanelWidgets';
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
  READER_PANEL_ALOUD,
  READER_PANEL_APPEARANCE,
  READER_PANEL_BOOKMARKS,
  READER_PANEL_SETTINGS,
  READER_PANEL_TOC,
  READER_THEME_LABELS,
  READKIT_FLIP_LABELS,
  READKIT_FLIP_VALUES,
  ReaderBlock,
  ReaderBlockKind,
  ReaderBookmark,
  ReaderCallbacks,
  ReaderCatalogItem,
  ReaderChapter,
  ReaderFlip,
  ReaderFontOption,
  ReaderFormats,
  ReaderLocation,
  ReaderLocations,
  ReaderOpenOptions,
  ReaderSettings,
  ReaderTheme,
  ReaderTtsState,
  ReaderTtsVoice,
} from './src/main/ets/model/ReaderTypes';
export { ReaderPalette } from './src/main/ets/model/ReaderPalette';
