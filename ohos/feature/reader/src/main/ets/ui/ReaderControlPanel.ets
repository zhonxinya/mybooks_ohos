import {
  READER_PANEL_ALOUD,
  READER_PANEL_APPEARANCE,
  READER_PANEL_BOOKMARKS,
  READER_PANEL_SETTINGS,
  READER_PANEL_TOC,
  READER_THEME_LABELS,
  ReaderBookmark,
  ReaderCatalogItem,
  ReaderFontOption,
  ReaderTheme,
  ReaderTtsState,
  ReaderTtsVoice,
} from '../model/ReaderTypes';
import { ReaderPalette } from '../model/ReaderPalette';
import { LazyDataSource } from './LazyDataSource';
import {
  ReaderChip,
  ReaderPanelButton,
  ReaderPanelSection,
  ReaderSegmentedControl,
  ReaderSelectRow,
  ReaderSliderBlock,
  ReaderSwitchRow,
} from './ReaderPanelWidgets';

/**
 * 阅读控制面板（**两套阅读器共用**）。
 *
 * 面板本身不依赖 ReaderKit、也不依赖宿主组件：
 * - 目录用模块的 `ReaderCatalogItem`，选中回传下标，由宿主映射回自己的目录项；
 * - 书签用模块的 `ReaderBookmark`，宿主用 `id` 反查完整对象；
 * - 翻页方式由宿主给定 `flipLabels/flipValues` + `@Link flipValue`（ReaderKit 是「仿真/滚动」，
 *   内置阅读器是「覆盖/滑动/无动画/滚动」）；
 * - 字体区块在 `fontOptions` 为空时隐藏；朗读/书签页由 `showAloud/showBookmarks` 控制。
 */
@Component
export struct ReaderControlPanel {
  /** 当前标签页：toc / appearance / settings / bookmarks / aloud。 */
  @Prop sheetOnly: string = READER_PANEL_TOC;

  // ---- 目录 ----
  @Prop catalogItems: ReaderCatalogItem[] = [];
  @Prop currentCatalogIndex: number = 0;

  // ---- 书签 ----
  @Prop bookmarks: ReaderBookmark[] = [];
  @Prop showBookmarks: boolean = false;

  // ---- 界面：文字/主题/翻页 ----
  @Link fontSize: number;
  @Link lineHeight: number;
  @Link theme: ReaderTheme;
  @Prop fontOptions: ReaderFontOption[] = [];
  @Prop selectedFontId: string = '';
  @Prop fontDownloading: boolean = false;
  @Prop flipLabels: string[] = [];
  @Prop flipValues: string[] = [];
  @Link flipValue: string;

  // ---- 设置 ----
  @Link keepScreenOn: boolean;
  /**
   * 单手模式（点击左右两侧均为下一页，后退靠滑动）。
   * 目前只有内置阅读器支持，`showOneHandMode=false` 时隐藏该行（ReaderKit 阅读器就不显示）。
   */
  @Prop showOneHandMode: boolean = false;
  @Prop oneHandMode: boolean = false;
  onOneHandModeChange: (enabled: boolean) => void = (_enabled: boolean) => {};
  /**
   * 是否把「阅读行为（常亮）」放进「界面」页。
   * ReaderKit 阅读器底部有独立的「设置」入口，用不到；内置阅读器只有「界面」一个入口，
   * 打开它才能触达常亮开关。
   */
  @Prop behaviorInAppearance: boolean = false;

  // ---- 朗读（宿主不启用时 showAloud=false）----
  @Prop showAloud: boolean = false;
  @Prop ttsState: ReaderTtsState = 'idle';
  @Prop ttsChapterTitle: string = '';
  @Link ttsSpeed: number;
  @Prop ttsChunkIndex: number = 0;
  @Prop ttsChunkTotal: number = 0;
  @Prop ttsVoices: ReaderTtsVoice[] = [];
  @Prop ttsPerson: number = 0;
  @Prop ttsVoiceLoading: boolean = false;

  onSelectCatalogIndex: (index: number) => void = (_index: number) => {};
  onSelectBookmark: (bookmarkId: string) => void = (_id: string) => {};
  onRemoveBookmark: (bookmarkId: string) => void = (_id: string) => {};
  onSelectFont: (fontId: string) => void = (_fontId: string) => {};
  /** 字号/行距/主题/翻页变化后：宿主持久化并按需重新排版/定位 */
  onSettingsChanged: (relayout: boolean) => void = (_relayout: boolean) => {};
  onTtsPlay: () => void = () => {};
  onTtsPause: () => void = () => {};
  onTtsStop: () => void = () => {};
  onSelectVoice: (person: number) => void = (_person: number) => {};
  onReloadVoices: () => void = () => {};
  onClose: () => void = () => {};

  private tocScroller: ListScroller = new ListScroller();
  /** 目录用 LazyForEach：数千章的书也只建可见行（面板每次打开都是新实例，构造时灌一次即可）。 */
  private tocSource: LazyDataSource<ReaderCatalogItem> = new LazyDataSource<ReaderCatalogItem>();

  aboutToAppear(): void {
    this.tocSource.update(this.catalogItems);
  }

  build() {
    Column({ space: 8 }) {
      this.panelHeader();
      if (this.sheetOnly === READER_PANEL_TOC) {
        this.tocTab();
      } else if (this.sheetOnly === READER_PANEL_APPEARANCE) {
        this.appearanceTab();
      } else if (this.sheetOnly === READER_PANEL_SETTINGS) {
        this.settingsTab();
      } else if (this.sheetOnly === READER_PANEL_BOOKMARKS) {
        this.bookmarkTab();
      } else if (this.sheetOnly === READER_PANEL_ALOUD) {
        this.aloudTab();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ReaderPalette.barBackground(this.theme))
    .borderRadius({ topLeft: 20, topRight: 20 })
    .clip(true)
    .shadow({ radius: 24, color: '#40000000', offsetX: 0, offsetY: -8 })
    // 圆角必须写进 border：先 borderRadius 再 border 会重置圆角
    .border({
      width: { top: 0.5 },
      color: ReaderPalette.dividerColor(this.theme),
      radius: { topLeft: 20, topRight: 20 },
    })
    .padding({ bottom: 12 })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM]);
  }

  @Builder
  panelHeader() {
    Row() {
      Text(this.sheetTitle())
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(ReaderPalette.textColor(this.theme))
        .layoutWeight(1);
      Text('完成')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ReaderPalette.accentColor())
        .padding({ left: 12, right: 4, top: 6, bottom: 6 })
        .onClick(() => this.onClose());
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 12 });
  }

  @Builder
  tocTab() {
    if (this.catalogItems.length === 0) {
      Column() {
        Text('暂无章节目录')
          .fontSize(14)
          .fontColor(ReaderPalette.hintColor(this.theme));
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center);
    } else {
      List({
        scroller: this.tocScroller,
        initialIndex: this.currentCatalogIndex,
      }) {
        LazyForEach(this.tocSource, (item: ReaderCatalogItem, index: number) => {
          ListItem() {
            ReaderSelectRow({
              theme: this.theme,
              leading: `${index + 1}`,
              title: item.title,
              selected: index === this.currentCatalogIndex,
              showDivider: index < this.catalogItems.length - 1,
              onTap: () => {
                this.onSelectCatalogIndex(index);
                this.onClose();
              },
            });
          }
        }, (item: ReaderCatalogItem) => `${item.index}_${item.title}`);
      }
      .layoutWeight(1)
      .padding({ left: 8, right: 8, bottom: 8 })
      .scrollBar(BarState.Auto)
      .onAppear(() => {
        this.scrollTocToCurrentChapter();
      });
    }
  }

  @Builder
  appearanceTab() {
    Scroll() {
      Column({ space: 12 }) {
        ReaderPanelSection({ theme: this.theme, title: '文字' }) {
          Column({ space: 12 }) {
            if (this.fontOptions.length > 0) {
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Text('字体')
                    .fontSize(14)
                    .fontColor(ReaderPalette.textColor(this.theme))
                    .layoutWeight(1);
                  if (this.fontDownloading) {
                    LoadingProgress()
                      .width(16)
                      .height(16)
                      .color(ReaderPalette.accentColor());
                    Text('下载中…')
                      .fontSize(12)
                      .fontColor(ReaderPalette.hintColor(this.theme));
                  }
                }
                .width('100%');
                Scroll() {
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.fontOptions, (option: ReaderFontOption) => {
                      ReaderChip({
                        theme: this.theme,
                        label: option.name,
                        selected: this.selectedFontId === option.id,
                        onTap: () => {
                          if (this.fontDownloading) {
                            return;
                          }
                          this.onSelectFont(option.id);
                        },
                      })
                        .margin({ right: 8, bottom: 8 });
                    }, (option: ReaderFontOption) => option.id);
                  }
                  .width('100%');
                }
                .width('100%')
                .constraintSize({ maxHeight: 220 })
                .scrollBar(BarState.Auto);
              }
            }
            ReaderSliderBlock({
              theme: this.theme,
              label: `字号: ${this.fontSize.toFixed(0)}`,
              value: this.fontSize,
              min: 12,
              max: 40,
              step: 1,
              onChange: (value: number) => {
                this.fontSize = value;
                this.onSettingsChanged(true);
              },
            });
            ReaderSliderBlock({
              theme: this.theme,
              label: `行距: ${this.lineHeight.toFixed(1)}`,
              value: this.lineHeight,
              min: 1.2,
              max: 3.0,
              step: 0.1,
              onChange: (value: number) => {
                this.lineHeight = value;
                this.onSettingsChanged(true);
              },
            });
          }
        }
        ReaderPanelSection({ theme: this.theme, title: '主题' }) {
          ReaderSegmentedControl({
            theme: this.theme,
            labels: READER_THEME_LABELS,
            selectedIndex: this.theme,
            onSelect: (index: number) => {
              this.theme = index as ReaderTheme;
              this.onSettingsChanged(true);
            },
          });
        }
        if (this.flipValues.length > 0) {
          ReaderPanelSection({ theme: this.theme, title: '翻页' }) {
            ReaderSegmentedControl({
              theme: this.theme,
              labels: this.flipLabels,
              selectedIndex: this.flipIndex(),
              onSelect: (index: number) => {
                if (index >= 0 && index < this.flipValues.length) {
                  this.flipValue = this.flipValues[index];
                  this.onSettingsChanged(true);
                }
              },
            });
          }
        }
        if (this.behaviorInAppearance) {
          this.behaviorSection();
        }
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
    .layoutWeight(1);
  }

  @Builder
  settingsTab() {
    Scroll() {
      Column({ space: 12 }) {
        this.behaviorSection();
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
    .layoutWeight(1);
  }

  /** 阅读行为：两处入口（界面页 / 设置页）共用，避免两份实现。 */
  @Builder
  behaviorSection() {
    ReaderPanelSection({ theme: this.theme, title: '阅读行为' }) {
      ReaderSwitchRow({
        theme: this.theme,
        title: '阅读时常亮',
        subtitle: '阅读页保持屏幕不息屏',
        isOn: this.keepScreenOn,
        onChange: (value: boolean) => {
          this.keepScreenOn = value;
          this.onSettingsChanged(false);
        },
      });
      if (this.showOneHandMode) {
        ReaderSwitchRow({
          theme: this.theme,
          title: '单手模式',
          subtitle: '点击左右两侧均为下一页，上一页靠向右滑动',
          isOn: this.oneHandMode,
          onChange: (value: boolean) => this.onOneHandModeChange(value),
        });
      }
    }
  }

  @Builder
  bookmarkTab() {
    if (this.bookmarks.length === 0) {
      Column() {
        Text('暂无书签')
          .fontSize(14)
          .fontColor(ReaderPalette.hintColor(this.theme));
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center);
    } else {
      List() {
        ForEach(this.bookmarks, (bookmark: ReaderBookmark) => {
          ListItem() {
            Row() {
              Text(bookmark.title)
                .fontSize(15)
                .fontColor(ReaderPalette.textColor(this.theme))
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              ReaderPanelButton({
                theme: this.theme,
                label: '删除',
                tone: 'danger',
                onTap: () => this.onRemoveBookmark(bookmark.id),
              });
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .onClick(() => {
              this.onSelectBookmark(bookmark.id);
              this.onClose();
            });
          }
        }, (bookmark: ReaderBookmark) => bookmark.id);
      }
      .layoutWeight(1)
      .padding({ left: 16, right: 16, bottom: 8 });
    }
  }

  @Builder
  aloudTab() {
    Scroll() {
      Column({ space: 12 }) {
        ReaderPanelSection({ theme: this.theme, title: '朗读状态' }) {
          Text(this.ttsStatusText())
            .fontSize(14)
            .fontColor(ReaderPalette.textColor(this.theme))
            .width('100%');
          if (this.ttsChunkTotal > 0) {
            Progress({ value: this.ttsChunkIndex, total: this.ttsChunkTotal, type: ProgressType.Linear })
              .width('100%')
              .height(4)
              .color(ReaderPalette.accentColor());
          }
        }
        ReaderPanelSection({ theme: this.theme, title: '控制' }) {
          Row({ space: 8 }) {
            ReaderPanelButton({
              theme: this.theme,
              label: this.ttsState === 'paused' ? '继续' : '开始',
              onTap: () => this.onTtsPlay(),
            });
            ReaderPanelButton({
              theme: this.theme,
              label: '暂停',
              onTap: () => this.onTtsPause(),
            });
            ReaderPanelButton({
              theme: this.theme,
              label: '停止',
              tone: 'danger',
              onTap: () => this.onTtsStop(),
            });
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceAround);
        }
        ReaderPanelSection({ theme: this.theme, title: '语速' }) {
          ReaderSliderBlock({
            theme: this.theme,
            label: `语速: ${this.ttsSpeed.toFixed(1)}`,
            value: this.ttsSpeed,
            min: 0.5,
            max: 2.0,
            step: 0.1,
            onChange: (value: number) => {
              this.ttsSpeed = value;
            },
          });
        }
        ReaderPanelSection({ theme: this.theme, title: '发音人' }) {
          if (this.ttsVoices.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.ttsVoices, (voice: ReaderTtsVoice) => {
                ReaderChip({
                  theme: this.theme,
                  label: voice.label,
                  selected: voice.person === this.ttsPerson,
                  onTap: () => this.onSelectVoice(voice.person),
                })
                  .margin({ right: 8, bottom: 8 });
              }, (voice: ReaderTtsVoice) => `voice-${voice.person}`);
            }
            .width('100%');
          } else {
            Text(this.ttsVoiceLoading ? '正在获取音色列表...' : '未获取到可用音色，使用系统默认发音人')
              .fontSize(12)
              .fontColor(ReaderPalette.hintColor(this.theme))
              .width('100%')
              .margin({ bottom: 8 });
          }
          ReaderPanelButton({
            theme: this.theme,
            label: this.ttsVoiceLoading ? '刷新中...' : '刷新音色列表',
            onTap: () => this.onReloadVoices(),
          });
        }
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 16 });
    }
    .layoutWeight(1);
  }

  /** 当前翻页方式在 `flipValues` 中的下标（未知取值回落到 0）。 */
  private flipIndex(): number {
    const index = this.flipValues.indexOf(this.flipValue);
    return index < 0 ? 0 : index;
  }

  private ttsStatusText(): string {
    if (this.ttsState === 'playing') {
      const title = this.ttsChapterTitle.length > 0 ? this.ttsChapterTitle : '当前章节';
      return `正在朗读：${title}${this.ttsProgressText()}`;
    }
    if (this.ttsState === 'paused') {
      return `已暂停，点击继续${this.ttsProgressText()}`;
    }
    return '点击开始朗读当前页，读完自动翻页续读';
  }

  private ttsProgressText(): string {
    if (this.ttsChunkTotal <= 0) {
      return '';
    }
    const current = Math.min(this.ttsChunkIndex + 1, this.ttsChunkTotal);
    const percent = Math.round((this.ttsChunkIndex / this.ttsChunkTotal) * 100);
    return ` · 第 ${current}/${this.ttsChunkTotal} 段（${percent}%）`;
  }

  private scrollTocToCurrentChapter(): void {
    const index = this.currentCatalogIndex;
    if (index <= 0 || this.catalogItems.length === 0) {
      return;
    }
    const maxIndex = this.catalogItems.length - 1;
    const target = index > maxIndex ? maxIndex : index;
    this.tocScroller.scrollToIndex(target, false, ScrollAlign.CENTER);
  }

  private sheetTitle(): string {
    if (this.sheetOnly === READER_PANEL_TOC) {
      return '目录';
    }
    if (this.sheetOnly === READER_PANEL_APPEARANCE) {
      return '界面';
    }
    if (this.sheetOnly === READER_PANEL_SETTINGS) {
      return '设置';
    }
    if (this.sheetOnly === READER_PANEL_BOOKMARKS) {
      return '书签';
    }
    if (this.sheetOnly === READER_PANEL_ALOUD) {
      return '朗读';
    }
    return '阅读';
  }
}
