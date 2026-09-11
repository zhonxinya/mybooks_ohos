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

import { picker } from '@kit.CoreFileKit';
import { WindowAbility } from '../entryability/WindowAbility';
import { LocalBookImporter } from '../common/LocalBookImporter';
import { readerCore } from '@kit.ReaderKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookUtils } from '../utils/BookUtils';
import { common } from '@kit.AbilityKit';

const TAG: string = 'IndexPage';

@Entry
@Component
struct Index {
  private filePath: string = '';
  @State bookName: string = '';
  /**
   * Page data information, used here to get the reading progress of the book
   */
  @StorageLink('currentData') currentData: readerCore.PageDataInfo | null = null;
  /**
   * System font scaled density is changed? If it has changed, the reader needs to be restarted.
   */
  @StorageLink('isDensityChange') isDensityChange: boolean = false;

  async aboutToAppear() {
    hilog.info(0x0000, TAG, 'aboutToAppear');
    WindowAbility.getInstance().toggleWindowSystemBar(['status', 'navigation'], this.getUIContext().getHostContext());
  }

  onPageShow(): void {
    WindowAbility.getInstance().toggleWindowSystemBar(['status', 'navigation'], this.getUIContext().getHostContext());
    if (this.isDensityChange) {
      // Restart the reader page.
      this.jumper();
      AppStorage.setOrCreate('isDensityChange', false);
    }
  }

  private async loadBook() {
    try {
      // Initialize the file selector.
      let documentSelectOptions = new picker.DocumentSelectOptions();
      // Set file type selection.
      documentSelectOptions.fileSuffixFilters = ['.epub', '.txt', '.mobi', '.azw', '.azw3'];
      let documentPicker = new picker.DocumentViewPicker();
      let documentSelectResult = await documentPicker.select(documentSelectOptions);
      if (!documentSelectResult || documentSelectResult.length <= 0) {
        hilog.error(0x0000, TAG, 'loadBook failed');
        return;
      }
      // Obtain the book file path.
      let srcFile: string = decodeURI(documentSelectResult[0]);
      hilog.info(0x0000, TAG, 'loadBook decodeURI succeeded. ' + srcFile);
      let importer = new LocalBookImporter();
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let bookParserInfo = await importer.importLocalBookToCache(srcFile,
        BookUtils.getBookFileLocalBookPath(context.filesDir));
      this.filePath = bookParserInfo.getFilePath();
      this.bookName = bookParserInfo.getBookName();
      hilog.info(0x0000, TAG, 'loadBook bookParserInfo parse succeeded,dest path is: ' + this.filePath);
      this.getUIContext()
        .getPromptAction()
        .showToast({ message: $r('app.string.import_successful_tips'), duration: 2000 });
      this.currentData = null;
    } catch (error) {
      hilog.error(0x0000, TAG, `loadBook failed , Code: ${error.code}, message: ${error.message}`);
    }
  }

  build() {
    RelativeContainer() {
      Column() {
        Text($r('app.string.EntryAbility_label'))
          .fontSize(30)
          .fontColor(Color.Black)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 100 })
          .height(56)
          .alignSelf(ItemAlign.Start)

        Text($r('app.string.book_name'))
          .fontSize(14)
          .fontColor($r('app.color.black_60_opacity'))
          .alignSelf(ItemAlign.Start)
          .margin({ top: 28, left: 16 })
          .visibility(this.bookName ? Visibility.Visible : Visibility.Hidden)

        Text(this.bookName)
          .fontSize(16)
          .fontColor($r('app.color.black_90_opacity'))
          .backgroundColor(Color.White)
          .borderRadius(16)
          .width('100%')
          .height(56)
          .margin({ top: 8 })
          .padding({ left: 16 })
          .visibility(this.bookName ? Visibility.Visible : Visibility.Hidden)
      }
      .alignRules({
        top: { anchor: '__container__', align: VerticalAlign.Top },
        start: { anchor: '__container__', align: HorizontalAlign.Start }
      })

      Column() {
        Button($r('app.string.import_book'))
          .width('100%')
          .height(40)
          .backgroundColor($r('app.color.blue'))
          .onClick(async () => {
            this.loadBook();
          })
        Button(this.currentData ? $r('app.string.continue_reading') : $r('app.string.go_to_reader'))
          .width('100%')
          .height(40)
          .margin({
            top: 12,
            bottom: 44
          })
          .fontColor(this.currentData ? Color.White : $r('app.color.blue'))
          .backgroundColor(this.currentData ? $r('app.color.blue') : $r('app.color.black_5_opacity'))
          .onClick(async () => {
            if (!this.filePath) {
              await this.loadBook();
            }
            this.jumper();
          })
      }.alignRules({
        bottom: { anchor: '__container__', align: VerticalAlign.Bottom },
        start: { anchor: '__container__', align: HorizontalAlign.Start }
      })
    }
    .height('100%')
    .width('100%')
    .backgroundColor($r('app.color.page_background'))
    .padding({ left: 16, right: 16 })
  }

  private jumper() {
    if (!this.filePath) {
      return;
    }
    AppStorage.setOrCreate('filePath', this.filePath);
    this.getUIContext().getRouter().pushUrl({
      url: "pages/Reader", params: {
        filePath: this.filePath,
        resourceIndex: this.currentData?.resourceIndex,
        domPos: this.currentData?.startDomPos || ''
      }
    }).catch(() => {
      hilog.error(0x0000, TAG, 'pushUrl failed');
    })
  }

  /**
   * Remove the page transition animation to speed up the page access speed of the reader
   */
  pageTransition() {
    PageTransitionEnter({ duration: 0, curve: Curve.Sharp });
    PageTransitionExit({ duration: 0, curve: Curve.Sharp });
  }
}
