import { TalebookService } from '../services/TalebookService';

const PREF_KEY: string = 'book_list_mode';
const LEGACY_KEY: string = 'bookshelf_list_mode';

export class BookViewMode {
  static isListMode(): boolean {
    const value = TalebookService.prefGet(PREF_KEY, '');
    if (value.length > 0) {
      return value === 'true';
    }
    return TalebookService.prefGet(LEGACY_KEY, 'false') === 'true';
  }

  static setListMode(isListMode: boolean): void {
    const text = isListMode ? 'true' : 'false';
    TalebookService.prefSet(PREF_KEY, text);
    TalebookService.prefSet(LEGACY_KEY, text);
  }
}
