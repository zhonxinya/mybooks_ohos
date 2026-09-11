import { BookListItemData } from '../components/BookListItem';
import { TalebookService } from '../services/TalebookService';

export function mapTalebookBook(book: Record<string, Object>): BookListItemData {
  const format = String(book['format'] ?? book['type'] ?? '');
  const pubdate = String(book['pubdate'] ?? book['timestamp'] ?? '');
  let subtitle = '';
  if (pubdate.length > 0 && pubdate !== '0') {
    const parsed = Number(pubdate);
    if (!Number.isNaN(parsed) && parsed > 0) {
      subtitle = new Date(parsed * (parsed < 1e12 ? 1000 : 1)).toLocaleDateString();
    }
  }
  return {
    id: String(book['id'] ?? book['title'] ?? ''),
    title: String(book['title'] ?? '未知'),
    author: String(book['author'] ?? ''),
    cover: TalebookService.resolveCoverUrl(String(book['cover'] ?? book['cover_url'] ?? book['img'] ?? '')),
    format: format,
    subtitle: subtitle,
  };
}
