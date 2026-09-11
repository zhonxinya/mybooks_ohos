import { ConfigurationConstant } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';

export class AppTheme {
  static readonly pagePadding: number = 16;
  static readonly cardPadding: number = 12;
  static readonly cardRadius: number = 12;
  static readonly coverRadius: number = 8;

  static applyThemeMode(context: common.UIAbilityContext, mode: string): void {
    const appContext = context.getApplicationContext();
    if (mode === 'light') {
      appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      return;
    }
    if (mode === 'dark') {
      appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      return;
    }
    appContext.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
  }

  static themeModeLabel(mode: string): string {
    if (mode === 'light') {
      return '浅色';
    }
    if (mode === 'dark') {
      return '深色';
    }
    return '跟随系统';
  }

  static nextThemeMode(mode: string): string {
    if (mode === 'system') {
      return 'light';
    }
    if (mode === 'light') {
      return 'dark';
    }
    return 'system';
  }
}
