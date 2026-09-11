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


/**
 * Local book import result code
 *
 * @since 2025/2/12
 */
export enum LocalBookImportResult {
  // Local book import successful
  LOCAL_BOOK_IMPORT_SUCCESS = 0,

  // Failed to import local book -- No file in the corresponding directory
  LOCAL_BOOK_IMPORT_FILE_NOT_EXIST = 1,

  // Local book import failed -- file size exceeds the threshold
  LOCAL_BOOK_IMPORT_FILE_EXCEED_THRESHOLD = 2,

  // Local book import failed -- system exception
  LOCAL_BOOK_IMPORT_FILE_SYSTEM_ERROR = 3,

  // Local book import failed -- Invalid file format
  LOCAL_BOOK_IMPORT_FILE_NOT_SUPPORT_TYPE = 4,

  // Local book import failed -- file size is too small
  LOCAL_BOOK_IMPORT_FILE_EXCEPTION = 5
}

export class BookParserInfo {
  private coverPath: string = '';
  private bookLanguage: string = '';
  private bookName: string = '';
  private bookId: string = '';
  private bookSourceType: number = -1;
  private localHash: string = '';
  private filePath: string = '';

  constructor() {
  }

  public setCoverPath(value: string): BookParserInfo {
    this.coverPath = value;
    return this;
  }

  public getCoverPath(): string {
    return this.coverPath;
  }

  public setFilePath(filePath: string): BookParserInfo {
    this.filePath = filePath;
    return this;
  }

  public setLocalHash(value: string): BookParserInfo {
    this.localHash = value;
    return this;
  }

  public getLocalHash(): string {
    return this.localHash;
  }

  public setBookLanguage(value: string): BookParserInfo {
    this.bookLanguage = value;
    return this;
  }

  public getBookLanguage(): string {
    return this.bookLanguage;
  }

  public setBookName(value: string): BookParserInfo {
    this.bookName = value;
    return this;
  }

  public getBookName(): string {
    return this.bookName;
  }

  public setBookId(value: string): BookParserInfo {
    this.bookId = value;
    return this;
  }

  public getBookId(): string {
    return this.bookId;
  }

  public setBookSourceType(value: number): BookParserInfo {
    this.bookSourceType = value;
    return this;
  }

  public getBookSourceType(): number {
    return this.bookSourceType;
  }

  public getFilePath(): string {
    return this.filePath;
  }
}
