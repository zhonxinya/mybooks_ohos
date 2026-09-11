/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { WindowAbility } from '../entryability/WindowAbility';
import { display } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FontFileInfo } from '../common/FontFileInfo';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { ReadPageComponent, readerCore, bookParser } from '@kit.ReaderKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { BookUtils } from '../utils/BookUtils';

interface paramType {
  filePath: string;
  resourceIndex: number;
  domPos: string;
}

const TAG: string = 'ReaderPage';

@Entry
@Component
struct Reader {
  @StorageLink('windowWidth') windowWidth: number = 0;
  @StorageLink('windowHeight') windowHeight: number = 0;
  @StorageLink('colorMode') @Watch('onColorModeChange') colorMode: ConfigurationConstant.ColorMode =
    ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  /**
   * Display dialog box
   */
  @State showModalBanner: boolean = false;
  /**
   * Menu bar type index, 0 : catalog list, 1 : setting, 1 : close dialog
   */
  @State currentIndex: number = -1;
  @State catalogItemList: bookParser.CatalogItem[] = [];
  private currentData: readerCore.PageDataInfo | null = null;
  private defaultHandler: bookParser.BookParserHandler | null = null;
  private readerComponentController: readerCore.ReaderComponentController = new readerCore.ReaderComponentController();
  @State bookCover: PixelMap | null = null;
  @State bookTitle: string = '';
  @State author: string = '';
  @State fontSize: string = '18';
  @State lineHeight: string = '';
  private fontList: Array<FontFileInfo> =
    [new FontFileInfo(BookUtils.getString(this.getUIContext().getHostContext(), 'system_font'),
      ''),
      new FontFileInfo(BookUtils.getString(this.getUIContext().getHostContext(), 'source_han_serif_font'),
        'fonts/SourceHanSerifCN-VF.ttf')];
  @State selectFontPath: string = '';
  @State themeList: string[] = [
    'white',
    'yellow',
    'pink',
    'green',
    'dark',
    'whiteSky',
    'darkSky'
  ];
  private THEME_BUTTON_BACKGROUND: Record<string, Resource> = {
    'white': $r('app.color.ic_white_theme_button_background'),
    'yellow': $r('app.color.ic_yellow_theme_button_background'),
    'pink': $r('app.color.ic_pink_theme_button_background'),
    'green': $r('app.color.ic_green_theme_button_background'),
    'dark': $r('app.color.ic_dark_theme_button_background'),
    'whiteSky': $r('app.color.ic_white_theme_button_background'),
    'darkSky': $r('app.color.ic_dark_theme_button_background')
  }
  private THEME_PAGE_COLOR: Record<string, string> = {
    'white': '#FFFFFF',
    'yellow': '#BD9063',
    'pink': '#FFE4E5',
    'green': '#C5E7CE',
    'dark': '#202224',
    'whiteSky': '#FFFFFF',
    'darkSky': '#202224'
  }
  private themeBorderColor: Record<number, Resource> = {
    0: $r('app.color.ic_border_select_white'),
    1: $r('app.color.ic_border_select_yellow'),
    2: $r('app.color.ic_border_select_pink'),
    3: $r('app.color.ic_border_select_green'),
    4: $r('app.color.ic_border_select_white'),
    5: $r('app.color.ic_border_select_white'),
    6: $r('app.color.ic_border_select_white')
  }
  @State themeSelectIndex: number = 0;
  private readerSetting: readerCore.ReaderSetting = {
    fontName: 'system',
    fontPath: '',
    fontSize: Number.parseInt(this.fontSize),
    fontColor: '#000000',
    fontWeight: 400,
    lineHeight: 1.9,
    nightMode: false,
    themeColor: 'rgba(248, 249, 250, 1)',
    themeBgImg: '',
    flipMode: '0',
    scaledDensity: this.getDefaultScaledDensity(),
    viewPortWidth: this.windowWidth,
    viewPortHeight: this.windowHeight
  };
  private screenDensityCallBack: Callback<number> | null = null;
  @State isLoading: boolean = true;

  aboutToAppear(): void {
    hilog.info(0x0000, TAG, 'aboutToAppear');
    this.registerScreenDensityChange();
    this.registerListener();
    WindowAbility.getInstance().toggleWindowSystemBar([], this.getUIContext().getHostContext());
    let param = this.getUIContext().getRouter().getParams() as paramType;
    let filePath = param.filePath;
    let resourceIndex = param.resourceIndex;
    let domPos = param.domPos;
    this.startPlay(filePath, resourceIndex, domPos).catch(() => {
      hilog.error(0x0000, TAG, `aboutToAppear startPlay failed`);
    });
  }

  getDefaultScaledDensity() {
    try {
      return display.getDefaultDisplaySync().scaledDensity > 0 ? display.getDefaultDisplaySync().scaledDensity : 1;
    } catch (error) {
      hilog.error(0x0000, TAG, `getDefaultScaledDensity failed, error code: ${error.code}, message: ${error.message}.`);
    }
    return 1;
  }

  /**
   * The color mode of the system changed
   */
  onColorModeChange() {
    hilog.info(0x0000, TAG, 'onConfigurationUpdate colorMode changed.');
    if (this.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      this.readerSetting.nightMode = true;
      this.readerSetting.fontColor = '#ffffff';
      this.readerSetting.themeColor = '#202224';
    } else {
      this.readerSetting.nightMode = false;
      this.readerSetting.fontColor = '#000000';
      this.readerSetting.themeColor = '#FFFFFF';
    }
    try {
      this.readerComponentController.setPageConfig(this.readerSetting);
    } catch (error) {
      hilog.error(0x0000, TAG,
        `onColorModeChange setPageConfig failed, error code: ${error.code}, message: ${error.message}.`);
    }
  }

  /**
   * Register the screen density change callback.
   */
  registerScreenDensityChange() {
    this.screenDensityCallBack = () => {
      try {
        let displaySync = display.getDefaultDisplaySync();
        let scaledDensity = displaySync.scaledDensity;
        if (scaledDensity !== this.readerSetting.scaledDensity) {
          AppStorage.setOrCreate('isDensityChange', true);
          this.getUIContext().getRouter().back();
        }
      } catch (error) {
        hilog.error(0x0000, TAG,
          `registerScreenDensityChange getDefaultDisplaySync failed, error code: ${error.code}, message: ${error.message}.`);
      }
    }
    display.on('change', this.screenDensityCallBack);
  }

  /**
   * Resource request callback. Font files and theme background images can be stored in the resources/rawfile directory or app sandbox path.
   */
  private resourceRequest: bookParser.CallbackRes<string, ArrayBuffer> = (filePath: string): ArrayBuffer => {
    hilog.info(0x0000, TAG,
      'resourceRequest : filePath = ' + filePath + ', this.selectFontPath = ' + this.selectFontPath);
    if (filePath.length === 0) {
      return new ArrayBuffer(0);
    }
    let resourcePath = filePath;
    if (this.isFont(filePath)) {
      resourcePath = this.selectFontPath;
    }
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let value: Uint8Array = context.resourceManager.getRawFileContentSync(resourcePath);
      hilog.info(0x0000, TAG, 'resourceRequest : get other resource succeeded ');
      return value.buffer as ArrayBuffer;
    } catch (error) {
      let code = (error as BusinessError).code;
      let message = (error as BusinessError).message;
      hilog.error(0x0000, TAG,
        `resourceRequest : get resource failed, error code: ${code}, message: ${message}.`);
    }
    // Obtain data from the sandbox path.
    return this.loadFileFromPath(resourcePath);
  }

  private registerListener(): void {
    this.readerComponentController.on('resourceRequest', this.resourceRequest);
    this.readerComponentController.on('pageShow', (data: readerCore.PageDataInfo): void => {
      hilog.info(0x0000, TAG, 'pageshow: data is: ' + JSON.stringify(data));
      this.currentData = data;
      // Save the page data.
      AppStorage.setOrCreate('currentData', this.currentData);
      if (data.state === readerCore.PageState.PAGE_ON_SHOW) {
        this.isLoading = false;
      }
    });
    WindowAbility.getInstance().onWindowSizeChange(() => {
      if (this.readerSetting.viewPortWidth != this.windowWidth ||
        this.readerSetting.viewPortHeight != this.windowHeight) {
        hilog.info(0x0000, TAG, 'onWindowSizeChange is changed, update page config');
        // When the window size changes, update the current page viewport size.
        this.readerSetting.viewPortWidth = this.windowWidth;
        this.readerSetting.viewPortHeight = this.windowHeight;
        try {
          this.readerComponentController.setPageConfig(this.readerSetting);
        } catch (error) {
          hilog.error(0x0000, TAG,
            `onWindowSizeChange failed, Code: ${error.code}, message: ${error.message}`);
        }
      }
    });
  }

  /**
   * @throws
   */
  private async startPlay(path: string, resourceIndex: number, domPos: string) {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let initPromise: Promise<void> = this.readerComponentController.init(context);
      let defaultHandler: Promise<bookParser.BookParserHandler> = bookParser.getDefaultHandler(path);
      let result: [bookParser.BookParserHandler, void] = await Promise.all([defaultHandler, initPromise]);
      this.defaultHandler = result[0];
      this.readerComponentController.registerBookParser(this.defaultHandler);
      this.onColorModeChange();
      this.readerComponentController.startPlay(resourceIndex || 0, domPos);
    } catch (error) {
      hilog.error(0x0000, TAG, `startPlay failed, Code: ${error.code}, message: ${error.message}`);
    }
  }

  private async getBookInfo() {
    try {
      let bookInfo: bookParser.BookInfo | undefined = this.defaultHandler?.getBookInfo();
      if (bookInfo) {
        this.bookTitle = bookInfo.bookTitle || '';
        this.author = bookInfo?.bookCreator || '';
        // SpineIndex is not required for obtaining the book cover.
        let buffer = this.defaultHandler?.getResourceContent(-1, bookInfo.bookCoverImage);
        let imageSource: image.ImageSource = image.createImageSource(buffer);
        this.bookCover = await imageSource.createPixelMap();
        imageSource.release();
      }
      hilog.info(0x0000, TAG, 'getBookInfo bookInfo is: ' + JSON.stringify(bookInfo));
    } catch (error) {
      hilog.error(0x0000, TAG, `getBookInfo failed, Code: ${error.code}, message: ${error.message}`);
    }
  }

  aboutToDisappear(): void {
    try {
      display.off('change', this.screenDensityCallBack);
    } catch (error) {
      hilog.error(0x0000, TAG, `aboutToDisappear display.off failed, Code: ${error.code}, message: ${error.message}`);
    }
    this.readerComponentController.off('pageShow');
    this.readerComponentController.off('resourceRequest');
    this.readerComponentController.releaseBook();
  }

  @Builder
  private buildCatalogItemList() {
    Column() {
      Row() {
        Stack() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontColor([$r('app.color.ohos_id_color_primary_light')])
            .width(18)
            .fontSize(18)
            .fontWeight(600)
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            .effectStrategy(SymbolEffectStrategy.NONE)
        }
        .borderRadius('50%')
        .backgroundColor("#0d777777")
        .align(Alignment.Center)
        .width(40)
        .height(40)
        .margin({ top: 8, left: 16, right: 16 })
        .onClick(() => {
          this.closeModal();
        })
      }
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.End)

      Row() {
        Stack({ alignContent: Alignment.Top }) {
          Image(this.bookCover)
            .draggable(false)
            .width(42)
            .aspectRatio(3 / 4)
            .borderRadius(2)
            .zIndex(1)
            .alt($r('app.media.default_cover'))
            .backgroundColor($r('sys.color.ohos_id_color_background'))

          Image($r('app.media.spines'))
            .draggable(false)
            .aspectRatio(3 / 4)
            .width(42)
            .borderRadius(2)
            .zIndex(2)
            .position({ x: 0, y: 0 })

          Image($r('app.media.cover_shadow'))
            .draggable(false)
            .width(42)
            .opacity(0.7)
            .aspectRatio(3)
            .position({ x: 0, y: 42 / 3 / 4 - 42 / 9 })
            .zIndex(0)
        }
        .width(42)
        .shadow({ radius: 18, color: "#4D000000" })
        .borderRadius(2)
        .aspectRatio(3 / 4)
        .visibility(this.bookTitle ? Visibility.Visible : Visibility.None)

        Text(this.bookTitle)
          .fontSize($r('sys.float.ohos_id_text_size_body1'))
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .maxLines(1)
          .margin({ right: 12, left: 12 })
          .fontWeight(FontWeight.Bold)
          .flexShrink(1)
          .fontColor("#E6000000")
          .height(40)
          .visibility(this.bookTitle ? Visibility.Visible : Visibility.None)
      }
      .padding({
        left: 16,
        right: 16
      })
      .width('100%')
      .margin({ bottom: 20 })
      .alignSelf(ItemAlign.Start)

      List() {
        ForEach(this.catalogItemList, (item: bookParser.CatalogItem) => {
          ListItem() {
            Column() {
              Row() {
                Row() {
                  Text(' · ')
                    .fontSize(14)
                    .fontColor($r('app.color.black_90_opacity'))
                  Text(item.catalogName)
                    .fontSize(14)
                    .fontColor($r('app.color.black_90_opacity'))
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .padding({ top: 8, bottom: 8 })
                    .maxLines(2)
                    .layoutWeight(1)
                }
              }
              .width('100%')
              .height(48)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)

              Divider()
            }
            .padding({
              left: item.catalogLevel ? item.catalogLevel * 26 : 16,
              right: 16,
              top: 6,
              bottom: 6
            })
            .onClick(async () => {
              this.jumpToCatalogItem(item);
            })
          }
        })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
    }
    .borderRadius({ topRight: 32, topLeft: 32 })
    .visibility(this.currentIndex === 0 ? Visibility.Visible : Visibility.None)
    .backgroundColor(Color.White)
    .zIndex(3)
  }

  @Builder
  private buildSetting() {
    Column() {
      GridRow({
        columns: {
          xs: 4,
          sm: 4,
          md: 9,
          lg: 12
        },
        gutter: { x: 8, y: 8 },
        breakpoints: { value: ['0vp', '520vp', '840vp'] },
        direction: GridRowDirection.Row
      }) {
        ForEach(this.fontList, (data: FontFileInfo, index) => {
          GridCol({
            span: {
              xs: 1,
              sm: 2,
              md: 3,
              lg: 4
            },
            offset: 0,
            order: 0
          }) {
            Column() {
              Text(data.getAlias())
                .fontSize(14)
                .borderRadius(12)
                .borderWidth(1.5)
                .width('100%')
                .height(48)
                .fontColor(this.selectFontPath !== data.getPath() ? Color.Black :
                  Color.Red)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.selectFontPath !== data.getPath() ? $r('app.color.ic_bg_grey') :
                  $r('app.color.ic_bg_font_selected'))
                .borderColor(this.selectFontPath !== data.getPath() ? $r('app.color.color_transparent') :
                  $r('app.color.ic_border_select_white'))
            }
            .width('100%')
            .onClick(() => {
              this.selectFontPath = data.getPath();
              this.readerSetting.fontName = index === 0 ? 'system' : data.getAlias();
              this.readerSetting.fontPath = data.getPath();
              try {
                this.readerComponentController.setPageConfig(this.readerSetting);
              } catch (error) {
                hilog.error(0x0000, TAG, `setFont failed, Code: ${error.code}, message: ${error.message}`);
              }
              hilog.info(0x0000, TAG, 'getAlias: = ' + data.getAlias() + " , getPath = " + data.getPath());
            })
            .id(TAG + '_Stack_' + data.getAlias())
            .onAppear(() => {
              focusControl.requestFocus(TAG + '_Stack_' + data.getAlias());
            })
          }
        });
      }.margin({ top: 24, left: 16, right: 16 })

      Text()
        .width('92%')
        .height(1)
        .margin({ left: 16, top: 12, right: 16 })
        .backgroundColor($r('app.color.ic_bg_grey'))

      Row({ space: 20 }) {
        Radio({
          value: 'flipMode', group: 'radioGroup'
        })
          .height(20)
          .width(20)
          .checked(true)
          .radioStyle({
            checkedBackgroundColor: Color.Red,
          })
          .onClick(() => {
            this.readerSetting.flipMode = '0';
            try {
              this.readerComponentController.setPageConfig(this.readerSetting);
            } catch (error) {
              hilog.error(0x0000, TAG, `setflipMode failed, Code: ${error.code}, message: ${error.message}`);
            }
          })
        Text($r('app.string.emulation_page'))
          .fontSize(16)
          .lineHeight(21)

        Radio({
          value: 'flipMode', group: 'radioGroup'
        })
          .height(20)
          .width(20)
          .checked(false)
          .radioStyle({
            checkedBackgroundColor: Color.Red,
          })
          .onClick(() => {
            this.readerSetting.flipMode = '1';
            try {
              this.readerComponentController.setPageConfig(this.readerSetting);
            } catch (error) {
              hilog.error(0x0000, TAG, `setflipMode failed, Code: ${error.code}, message: ${error.message}`);
            }
          })
        Text($r('app.string.transversal_slip_page'))
          .fontSize(16)
          .lineHeight(21)
      }
      .margin({ left: 16, top: 16, right: 16 })

      Text()
        .width('92%')
        .height(1)
        .margin({ left: 16, top: 12, right: 16 })
        .backgroundColor($r('app.color.ic_bg_grey'))

      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.themeList, (item: string, index: number) => {
            Stack() {
              Row()
                .width('100%')
                .height(40)
                .borderWidth(this.themeSelectIndex !== index ? 1 : 2)
                .borderColor(this.themeSelectIndex !== index ? $r('app.color.ic_border_unselect') :
                  this.themeBorderColor[this.themeSelectIndex])
                .backgroundImage(this.getBackgroundImage(item))
                .backgroundColor(this.THEME_BUTTON_BACKGROUND[item.toString()])
                .backgroundImagePosition(Alignment.BottomEnd)
                .backgroundImageSize(ImageSize.Cover)
                .borderRadius(20)
                .id(TAG + '_Row_' + index)
            }
            .width(`calc((100% - ${(this.themeList.length - 1) * 12}vp) / ${this.themeList.length})`)
            .constraintSize({
              minWidth: 60
            })
            .borderRadius(30)
            .borderStyle(BorderStyle.Solid)
            .onClick(() => {
              this.themeSelectIndex = index;
              this.readerSetting.themeColor = this.THEME_PAGE_COLOR[item];
              this.readerSetting.nightMode = false;
              if (index === 5) {
                this.readerSetting.themeBgImg = 'white_sky_first.jpg';
                this.readerSetting.fontColor = '#000000';
              } else if (index === 6) {
                this.readerSetting.themeBgImg = 'dark_sky_first.jpg';
                this.readerSetting.fontColor = '#ffffff';
                this.readerSetting.nightMode = true;
              } else if (index == 4) {
                this.readerSetting.themeBgImg = '';
                this.readerSetting.nightMode = true;
                this.readerSetting.fontColor = '#ffffff';
              } else {
                this.readerSetting.themeBgImg = '';
                this.readerSetting.fontColor = '#000000';
              }
              try {
                this.readerSetting.scaledDensity = display.getDefaultDisplaySync().scaledDensity;
                this.readerComponentController.setPageConfig(this.readerSetting);
              } catch (error) {
                hilog.error(0x0000, TAG, `setTheme failed, Code: ${error.code}, message: ${error.message}`);
              }
            })
            .id(TAG + '_Stack_' + index)
            .onAppear(() => {
              focusControl.requestFocus(TAG + '_Stack_' + index);
            })
          })
        }
        .constraintSize({
          minWidth: '100%'
        })
        .id(TAG + '_Row_1')
        .padding({
          left: 12,
          right: 12,
          top: 12,
          bottom: 12
        })
      }
      .margin({ top: 8 })
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      Text()
        .width('92%')
        .height(1)
        .margin({ left: 16, top: 12, right: 16 })
        .backgroundColor($r('app.color.ic_bg_grey'))

      TextInput({ placeholder: $r('app.string.font_size_placeholder'), text: this.fontSize })
        .margin({
          left: 16,
          top: 10,
          right: 16,
          bottom: 10
        })
        .backgroundColor($r('app.color.ic_text_input_bg'))
        .placeholderColor("#666666")
        .type(InputType.Number)
        .fontSize(16)
        .onChange((value: string) => {
          this.fontSize = value;
        })

      TextInput({ placeholder: $r('app.string.line_height_placeholder'), text: this.lineHeight })
        .margin({ left: 16, right: 16, bottom: 10 })
        .backgroundColor($r('app.color.ic_text_input_bg'))
        .placeholderColor("#666666")
        .type(InputType.NUMBER_DECIMAL)
        .fontSize(16)
        .onChange((value: string) => {
          this.lineHeight = value;
        })

      Button($r('app.string.update_font_size_and_line_height'))
        .onClick(() => {
          hilog.info(0x0000, TAG,
            'click : update page setting, fontSize = ' + this.fontSize + ' ,lineHeight = ' + this.lineHeight);
          if (!isNaN(Number.parseInt(this.fontSize))) {
            this.readerSetting.fontSize = Number.parseInt(this.fontSize);
          }
          if (!isNaN(Number.parseInt(this.lineHeight))) {
            this.readerSetting.lineHeight = Number.parseInt(this.lineHeight);
          }
          try {
            this.readerComponentController.setPageConfig(this.readerSetting);
          } catch (error) {
            hilog.error(0x0000, TAG,
              `set fontSize or lineHeight failed, Code: ${error.code}, message: ${error.message}`);
          }
        })
        .fontSize(16)
        .width('92%')
        .fontColor(Color.Red)
        .backgroundColor($r('app.color.ic_text_input_bg'))
        .padding({ top: 10, bottom: 10 })
        .margin({ left: 16, right: 16, bottom: 30 })

    }.visibility(this.currentIndex === 1 ? Visibility.Visible : Visibility.None)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Color.White)
    .zIndex(3)
  }

  build() {
    Stack() {
      ReadPageComponent({
        controller: this.readerComponentController,
        readerCallback: (err: BusinessError, data: readerCore.ReaderComponentController) => {
          this.readerComponentController = data;
          if (err) {
            hilog.error(0x0000, TAG, `ReadPageComponent init failed, Code: ${err.code}, message: ${err.message}`);
          }
        }
      }).zIndex(1)
      // menu bar
      Column() {
        Column() {
          Column() {
            // catalog list view
            this.buildCatalogItemList()
            // setting view
            this.buildSetting()
          }
          .padding({ bottom: !this.bookCover && !this.bookTitle ? 56 : 100 })
          .backgroundColor(Color.White)
          .borderRadius({
            topRight: this.currentIndex === 0 ? 32 : 0,
            topLeft: this.currentIndex === 0 ? 32 : 0
          })
        }
        .visibility(this.currentIndex < 0 ? Visibility.None : Visibility.Visible)
        .width('100%')
        .height(this.currentIndex === 0 ? 'calc(100%  - 80vp - 56vp)' : '60%')
        .justifyContent(FlexAlign.End)
        .onClick(() => {
          this.showModalBanner = true;
        })

        Row() {
          Text($r('app.string.catalog_list'))
            .width('50%')
            .height('100%')
            .onClick(() => {
              this.jumpToCatalogList();
            })
            .textAlign(TextAlign.Center)
            .fontColor(this.currentIndex === 0 ? Color.Red : Color.Black)
          Text($r('app.string.setting'))
            .width('50%')
            .height('100%')
            .onClick(() => {
              this.jumpToSetting();
            })
            .textAlign(TextAlign.Center)
            .fontColor(this.currentIndex === 1 ? Color.Red : Color.Black)
        }
        .width('100%')
        .height(80)
        .backgroundColor(Color.White)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.currentIndex == 0 ? '#0d626262' : Color.Transparent)
      .zIndex(this.showModalBanner ? 2 : 0)
      .justifyContent(FlexAlign.End)
      .onClick(() => {
        this.closeModal();
      })

      Row() {
        Text('加载中...')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Color.White)
      .zIndex(3)
      .visibility(this.isLoading ? Visibility.Visible : Visibility.None)
    }.width('100%').height('100%').onClick(() => {
      this.showModal();
    })
  }

  /**
   * show menu bar
   */
  private showModal() {
    this.showModalBanner = true;
  }

  /**
   * close menu bar
   */
  private closeModal() {
    this.showModalBanner = false;
    this.currentIndex = -1;
  }

  private jumpToCatalogList() {
    this.currentIndex = 0;
    try {
      this.catalogItemList = this.defaultHandler?.getCatalogList() || [];
    } catch (error) {
      hilog.error(0x0000, TAG, `getCatalogList failed, Code: ${error.code}, message: ${error.message}`);
    }
    this.getBookInfo();
    hilog.info(0x0000, TAG, 'catalog list length: ' + this.catalogItemList.length);
  }

  private jumpToSetting() {
    this.currentIndex = 1;
  }

  private async jumpToCatalogItem(catalogItem: bookParser.CatalogItem) {
    const domPos = await this.getDomPos(catalogItem);
    const resourceIndex = this.getResourceItemByCatalog(catalogItem).index;
    this.readerComponentController.startPlay(resourceIndex, domPos).catch(() => {
      hilog.error(0x0000, TAG, `startPlay failed`);
    });
    this.closeModal();
  }

  private async getDomPos(catalogItem: bookParser.CatalogItem): Promise<string> {
    try {
      const domPos: string = this.defaultHandler?.getDomPosByCatalogHref(catalogItem.href || '') || '';
      return domPos;
    } catch (error) {
      hilog.error(0x0000, TAG, `getDomPos failed, Code: ${error.code}, message: ${error.message}`);
    }
    return Promise.reject();
  }

  private getResourceItemByCatalog(catalogItem: bookParser.CatalogItem): bookParser.SpineItem {
    let resourceFile = catalogItem.resourceFile || '';
    try {
      let spineList: bookParser.SpineItem[] = this.defaultHandler?.getSpineList() || [];
      let resourceItemArr = spineList.filter(item => item.href === resourceFile);
      if (resourceItemArr.length > 0) {
        hilog.info(0x0000, TAG, 'getResourceItemByCatalog get resource ', resourceItemArr[0]);
        let resourceItem = resourceItemArr[0];
        return resourceItem;
      } else if (spineList.length > 0) {
        hilog.info(0x0000, TAG, 'getResourceItemByCatalog get resource in resourceList', spineList[0]);
        return spineList[0];
      }
    } catch (error) {
      hilog.error(0x0000, TAG, `getSpineList failed, Code: ${error.code}, message: ${error.message}`);
    }
    hilog.info(0x0000, TAG, 'getResourceItemByCatalog get resource in escape');
    return {
      idRef: '',
      index: 0,
      href: '',
      properties: ''
    };
  }

  getBackgroundImage(themeType: string): Resource | string {
    if (themeType === 'whiteSky') {
      return $r('app.media.white_sky_icon');
    } else if (themeType === 'darkSky') {
      return $r('app.media.dark_sky_icon');
    }
    return '';
  }

  private isFont(filePath: string): boolean {
    let options = [".ttf", ".woff2", ".otf"];
    let path = filePath.toLowerCase();
    let result = path.indexOf(options[0]) != -1 || path.indexOf(options[1]) != -1 || path.indexOf(options[2]) != -1;
    hilog.info(0x0000, TAG, 'isFont = ' + result);
    return result;
  }

  private loadFileFromPath(filePath: string): ArrayBuffer {
    try {
      let stats = fs.statSync(filePath);
      let file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      let buffer = new ArrayBuffer(stats.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      return buffer;
    } catch (error) {
      hilog.error(0x0000, TAG, `loadFileFromPath failed, Code: ${error.code}, message: ${error.message}`);
      return new ArrayBuffer(0);
    }
  }

  /**
   * Remove the page transition animation to speed up the page access speed of the reader
   */
  pageTransition() {
    PageTransitionEnter({ duration: 0, curve: Curve.Sharp });
    PageTransitionExit({ duration: 0, curve: Curve.Sharp });
  }
}