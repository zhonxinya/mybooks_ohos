import { PageScaffold, LoadingState, EmptyState, IconCircleButton, PrimaryButton } from '../components';
import { ThemeApi, ThemeItem } from '../services/ThemeApi';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';

/** 「默认主题」伪条目键（对齐上游 theme.vue 的 `__default__`：激活时提交空 name 以恢复默认外观）。 */
const THEME_DEFAULT_KEY: string = '__default__';

function themeLabel(theme: ThemeItem): string {
  return theme.displayName.length > 0 ? theme.displayName : theme.name;
}

function themeMeta(theme: ThemeItem): string {
  const bits: string[] = [];
  if (theme.version.length > 0) {
    bits.push(`v${theme.version}`);
  }
  if (theme.author.length > 0) {
    bits.push(theme.author);
  }
  return bits.join(' · ');
}

function activeFromList(themes: ThemeItem[]): string {
  for (let index = 0; index < themes.length; index++) {
    if (themes[index].active) {
      return themes[index].name;
    }
  }
  return '';
}

/**
 * 服务端主题管理（talebook 专有）。
 *
 * 端点：GET /api/themes（列表）、GET /api/themes/active（当前激活）、
 * POST /api/themes/activate（激活，管理员；空 name = 恢复默认主题）。
 */
@Entry
@Component
struct ThemesPage {
  @State themes: ThemeItem[] = [];
  /** 当前激活主题的 name；空串表示服务端未激活任何主题（默认外观）。 */
  @State activeName: string = '';
  @State loading: boolean = true;
  @State loadError: string = '';
  /** 正在激活的条目标识（非空即视为忙）。 */
  @State busyName: string = '';

  aboutToAppear(): void {
    if (!ServerRegistry.supports(ServerFeature.THEMES)) {
      // 当前服务端无主题接口，不发起必然失败的请求
      this.loadError = `${ServerRegistry.profile().displayName} 不支持主题管理`;
      this.loading = false;
      return;
    }
    void this.load();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private async load(): Promise<void> {
    this.loading = this.themes.length === 0;
    this.loadError = '';
    try {
      if (!TalebookService.ensureTalebookConfigured()) {
        this.loadError = '请先配置服务器地址';
        return;
      }
      const active = await ThemeApi.getActiveTheme();
      const list = await ThemeApi.listThemes();
      this.themes = list;
      this.activeName = active !== null ? active.name : activeFromList(list);
    } catch (error) {
      this.loadError = `加载失败：${error}`;
    } finally {
      this.loading = false;
    }
  }

  /** 激活后会写入服务端配置并可能触发服务重启，回拉失败时保留本地激活标记。 */
  private async refreshQuiet(): Promise<void> {
    try {
      const active = await ThemeApi.getActiveTheme();
      const list = await ThemeApi.listThemes();
      this.themes = list;
      this.activeName = active !== null ? active.name : activeFromList(list);
    } catch (_error) {
      // 服务端重启窗口内回拉失败：忽略，保留本地结果
    }
  }

  private confirmActivate(name: string, label: string): void {
    if (this.busyName.length > 0 || this.activeName === name) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '切换主题',
      message: name.length === 0
        ? '确定恢复默认主题吗？该操作会写入服务端配置，可能触发服务重启。'
        : `确定激活「${label}」吗？该操作会写入服务端配置，可能触发服务重启。`,
      primaryButton: {
        value: '确定',
        action: () => {
          void this.activate(name);
        },
      },
      secondaryButton: { value: '取消', action: () => {} },
    });
  }

  private async activate(name: string): Promise<void> {
    if (this.busyName.length > 0) {
      return;
    }
    this.busyName = name.length > 0 ? name : THEME_DEFAULT_KEY;
    try {
      const result = await ThemeApi.activateTheme(name);
      this.toast(result.message.length > 0 ? result.message : '已激活');
      this.activeName = result.theme !== null ? result.theme.name : name;
      await this.refreshQuiet();
    } catch (error) {
      this.toast(`激活失败：${error}`);
    } finally {
      this.busyName = '';
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '主题',
        showBack: true,
        action: () => {
          this.refreshAction();
        },
        content: () => {
          this.themesBody();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  refreshAction() {
    IconCircleButton({
      icon: $r('sys.symbol.arrow_clockwise'),
      variant: 'ghost',
      iconSize: 20,
      buttonSize: 40,
      onTap: () => {
        if (this.busyName.length === 0) {
          void this.load();
        }
      },
    });
  }

  @Builder
  themeCard(name: string, label: string, meta: string, description: string, isActive: boolean) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.paintpalette'))
          .fontSize(20)
          .fontColor([$r('app.color.brand_primary')]);
        Text(label)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        if (isActive) {
          Text('当前')
            .fontSize(11)
            .fontColor($r('app.color.on_brand'))
            .backgroundColor($r('app.color.brand_primary'))
            .borderRadius($r('app.float.badge_radius'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 });
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      if (meta.length > 0) {
        Text(meta)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }

      if (description.length > 0) {
        Text(description)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
      }

      Row() {
        if (isActive) {
          Text('当前主题')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'));
        } else {
          PrimaryButton({
            label: this.busyName === name ? '激活中…' : '激活',
            fullWidth: false,
            buttonEnabled: this.busyName.length === 0,
            onTap: () => this.confirmActivate(name, label),
          });
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.End);
    }
    .width('100%')
    .padding($r('app.float.card_padding'))
    .borderRadius($r('app.float.card_radius'))
    .backgroundColor($r('app.color.card_background'))
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  themesBody() {
    if (this.loading) {
      LoadingState({});
    } else if (this.loadError.length > 0) {
      EmptyState({ message: this.loadError });
    } else {
      Scroll() {
        Column({ space: 12 }) {
          this.themeCard(THEME_DEFAULT_KEY, '默认主题', '', '恢复服务端默认外观', this.activeName.length === 0);
          ForEach(this.themes, (item: ThemeItem) => {
            this.themeCard(item.name, themeLabel(item), themeMeta(item), item.description,
              this.activeName === item.name);
          }, (item: ThemeItem) => item.name);
        }
        .width('100%')
        .padding({
          left: $r('app.float.page_padding'),
          right: $r('app.float.page_padding'),
          top: 8,
          bottom: $r('app.float.page_padding'),
        });
      }
      .layoutWeight(1)
      .width('100%');
    }
  }
}
