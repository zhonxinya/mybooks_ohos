import { ReaderTheme } from '../models/ReaderTheme';

export class ReaderThemeColors {
  static overlay(theme: ReaderTheme): string {
    return theme === ReaderTheme.DARK ? '#99000000' : '#66000000';
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

  static panelSectionBg(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#333333';
    }
    if (theme === ReaderTheme.EYE) {
      return '#A8D0AB';
    }
    return '#EDE3CF';
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

  static textHint(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#9A9A9A';
    }
    if (theme === ReaderTheme.EYE) {
      return '#6A7A6A';
    }
    return '#99182431';
  }

  static divider(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#444444';
    }
    if (theme === ReaderTheme.EYE) {
      return '#A8C9AB';
    }
    return '#33182431';
  }

  static chipIdleBg(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#3A3A3A';
    }
    if (theme === ReaderTheme.EYE) {
      return '#B0D4B3';
    }
    return '#E8DCC8';
  }

  static chipSelectedBg(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#1A007DFF';
    }
    if (theme === ReaderTheme.EYE) {
      return '#C5E8C8';
    }
    return '#E6F2FF';
  }

  static quickActionBg(theme: ReaderTheme): string {
    return ReaderThemeColors.chipIdleBg(theme);
  }

  static rowHighlight(theme: ReaderTheme): string {
    return '#1A007DFF';
  }

  static pageBackground(theme: ReaderTheme): string {
    if (theme === ReaderTheme.DARK) {
      return '#1A1A2E';
    }
    if (theme === ReaderTheme.EYE) {
      return '#C7EDCC';
    }
    return '#F5F0E8';
  }

  static pageThemeColor(theme: ReaderTheme): string {
    return ReaderThemeColors.pageBackground(theme);
  }

  static pageFontColor(theme: ReaderTheme): string {
    return ReaderThemeColors.textColor(theme);
  }

  static nightMode(theme: ReaderTheme): boolean {
    return theme === ReaderTheme.DARK;
  }
}
