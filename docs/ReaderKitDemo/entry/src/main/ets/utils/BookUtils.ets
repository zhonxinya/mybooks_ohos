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


enum BOOK_FILE_TYPE {
  UNKNOWN = -1,
  TXT = 1,
  EPUB = 2,
  MOBI = 3,
  AZW = 4,
  AZW3 = 5
}

const EXTENSION_FILE_TXT = 'txt';

const EXTENSION_FILE_EPUB = 'epub';

const EXTENSION_FILE_MOBI = 'mobi';

const EXTENSION_FILE_AZW = 'azw';

const EXTENSION_FILE_AZW3 = 'azw3';


const SUPPORT_EXTENSION_FILE =
  [EXTENSION_FILE_TXT, EXTENSION_FILE_EPUB, EXTENSION_FILE_MOBI, EXTENSION_FILE_AZW, EXTENSION_FILE_AZW3];

const SUPPORT_BOOK_FILE_TYPES =
  [BOOK_FILE_TYPE.TXT, BOOK_FILE_TYPE.EPUB, BOOK_FILE_TYPE.MOBI, BOOK_FILE_TYPE.AZW, BOOK_FILE_TYPE.AZW3];

export class BookUtils {
  /**
   * Convert book types based on suffix
   * @param suffixName - Book file name extension
   * @returns {BOOK_FILE_TYPE}
   */
  public static convertSuffixToSourceType(suffixName: string): number {
    switch (suffixName) {
      case EXTENSION_FILE_TXT:
        return BOOK_FILE_TYPE.TXT;
      case EXTENSION_FILE_EPUB:
        return BOOK_FILE_TYPE.EPUB;
      case EXTENSION_FILE_MOBI:
        return BOOK_FILE_TYPE.MOBI;
      case EXTENSION_FILE_AZW:
        return BOOK_FILE_TYPE.AZW;
      case EXTENSION_FILE_AZW3:
        return BOOK_FILE_TYPE.AZW3;
      default:
        return BOOK_FILE_TYPE.UNKNOWN;
    }
  }

  /**
   * Convert the suffix of a book file based on the book type
   * @param sourceType - {BOOK_FILE_TYPE}
   * @returns Book File Suffix
   */
  public static convertSourceTypeToSuffix(sourceType: number): string {
    switch (sourceType) {
      case BOOK_FILE_TYPE.TXT:
        return EXTENSION_FILE_TXT;
      case BOOK_FILE_TYPE.EPUB:
        return EXTENSION_FILE_EPUB;
      case BOOK_FILE_TYPE.MOBI:
        return EXTENSION_FILE_MOBI;
      case BOOK_FILE_TYPE.AZW:
        return EXTENSION_FILE_AZW;
      case BOOK_FILE_TYPE.AZW3:
        return EXTENSION_FILE_AZW3;
      default:
        return "";
    }
  }

  public static getBookFileBasePath(workPath: string, bookId: string): string {
    return `${workPath}${bookId}/`;
  }

  public static getBookFileLocalBookPath(workPath: string): string {
    return `${workPath}import/`;
  }

  public static isSupportFromSuffix(suffixName: string): boolean {
    return SUPPORT_EXTENSION_FILE.includes(suffixName);
  }

  public static isSupportFromType(bookFileType: number): boolean {
    return SUPPORT_BOOK_FILE_TYPES.includes(bookFileType);
  }

  public static getString(context: Context | undefined, name: string): string {
    try {
      return context?.resourceManager.getStringByNameSync(name) || '';
    } catch (error) {
      console.error(`getStringSync failed, error code: ${error.code}, message: ${error.message}.`);
    }
    return '';
  }
}
