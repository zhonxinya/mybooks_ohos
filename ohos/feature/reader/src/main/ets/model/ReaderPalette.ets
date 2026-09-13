import { ReaderTheme } from './ReaderTypes';

/**
 * 阅读器配色。
 *
 * 取色与 entry 既有阅读器（`theme/ReaderThemeColors`）一致，保证两套阅读器观感统一；
 * 但配色归本模块所有，模块不反向依赖 entry。
 */
export class ReaderPalette {
  static pageBackground(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#1A1A2E';
    }
    if (theme === ReaderTheme.EYE) {
      return '#C7EDCC';
    }
    return '#F5F0E8';
  }

  static textColor(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#E0E0E0';
    }
    if (theme === ReaderTheme.EYE) {
      return '#3C3C3C';
    }
    return '#3E3A39';
  }

  static hintColor(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#9A9A9A';
    }
    if (theme === ReaderTheme.EYE) {
      return '#6A7A6A';
    }
    return '#99182431';
  }

  static barBackground(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#2A2A2A';
    }
    if (theme === ReaderTheme.EYE) {
      return '#B8DDBB';
    }
    return '#F3E9D6';
  }

  static panelBackground(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#333333';
    }
    if (theme === ReaderTheme.EYE) {
      return '#A8D0AB';
    }
    return '#EDE3CF';
  }

  static dividerColor(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#444444';
    }
    if (theme === ReaderTheme.EYE) {
      return '#A8C9AB';
    }
    return '#33182431';
  }

  /** 面板分组卡片底色（与面板底色形成层次）。 */
  static sectionBackground(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#333333';
    }
    if (theme === ReaderTheme.EYE) {
      return '#A8D0AB';
    }
    return '#EDE3CF';
  }

  /** 胶囊控件未选中底色。 */
  static chipIdleBackground(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#3A3A3A';
    }
    if (theme === ReaderTheme.EYE) {
      return '#B0D4B3';
    }
    return '#E8DCC8';
  }

  /** 目录/设置面板里选中项的底色。 */
  static selectedBackground(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#3A3A3A';
    }
    if (theme === ReaderTheme.EYE) {
      return '#C5E8C8';
    }
    return '#E6F2FF';
  }

  /** 插图底色：图片未铺满容器时露出的背景，比正文底色略深一点以区分图区。 */
  static imageBackground(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#242438';
    }
    if (theme === ReaderTheme.EYE) {
      return '#BCE3C1';
    }
    return '#EAE3D6';
  }

  static accentColor(): string {
    return '#007DFF';
  }
}
