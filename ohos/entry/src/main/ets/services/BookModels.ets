export interface BookItem {
  id: number;
  title: string;
  authors: string[];
  coverUrl: string;
  rating: number;
  tags: string[];
}

export interface BookDetail {
  id: number;
  title: string;
  authors: string[];
  coverUrl: string;
  comments: string;
  rating: number;
  tags: string[];
  files: BookFileItem[];
  downloadUrl: string;
}

export interface BookFileItem {
  format: string;
  size: number;
}

export interface DownloadRecord {
  bookId: string;
  bookTitle: string;
  filePath: string;
  format: string;
  coverUrl: string;
  author: string;
}

export interface ReadingHistoryItem {
  bookId: string;
  bookTitle: string;
  coverUrl: string;
  author: string;
  progressPercent: number;
  lastReadTime: number;
}

function parseStringList(value: Object | undefined): string[] {
  if (value === undefined || value === null) {
    return [];
  }
  const arr = value as Array<Object>;
  const result: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    result.push(`${arr[i]}`);
  }
  return result;
}

function pickCover(json: Record<string, Object>): string {
  const cover = json['cover_url'] ?? json['img'] ?? json['thumb'];
  return cover !== undefined ? `${cover}` : '';
}

export function parseBookItem(json: Record<string, Object>): BookItem {
  const idRaw = json['id'];
  const id = typeof idRaw === 'number' ? idRaw : parseInt(`${idRaw}`, 10);
  return {
    id: isNaN(id) ? 0 : id,
    title: `${json['title'] ?? ''}`,
    authors: parseStringList(json['authors'] as Object),
    coverUrl: pickCover(json),
    rating: typeof json['rating'] === 'number' ? json['rating'] as number : 0,
    tags: parseStringList(json['tags'] as Object),
  };
}

export function parseBookDetail(json: Record<string, Object>): BookDetail {
  const base = parseBookItem(json);
  const filesRaw = json['files'] as Array<Record<string, Object>> | undefined;
  const files: BookFileItem[] = [];
  if (filesRaw !== undefined) {
    for (let i = 0; i < filesRaw.length; i++) {
      const f = filesRaw[i];
      files.push({
        format: `${f['format'] ?? f['name'] ?? 'epub'}`,
        size: typeof f['size'] === 'number' ? f['size'] as number : 0,
      });
    }
  }
  return {
    id: base.id,
    title: base.title,
    authors: base.authors,
    coverUrl: base.coverUrl,
    comments: `${json['comments'] ?? ''}`,
    rating: base.rating,
    tags: base.tags,
    files: files,
    downloadUrl: `${json['download_url'] ?? ''}`,
  };
}

export function parseDownloadRecord(json: Record<string, Object>): DownloadRecord {
  const metadata = json['metadata'] as Record<string, Object> | undefined;
  let coverUrl = '';
  let author = '';
  if (metadata !== undefined) {
    coverUrl = pickCover(metadata);
    const authors = parseStringList(metadata['authors'] as Object);
    author = authors.length > 0 ? authors.join(', ') : '';
  }
  return {
    bookId: `${json['book_id'] ?? ''}`,
    bookTitle: `${json['book_title'] ?? ''}`,
    filePath: `${json['file_path'] ?? ''}`,
    format: `${json['format'] ?? ''}`,
    coverUrl: coverUrl,
    author: author,
  };
}

export function parseReadingHistoryItem(json: Record<string, Object>): ReadingHistoryItem {
  const progress = json['progress'] as Record<string, Object> | undefined;
  const metadata = json['metadata'] as Record<string, Object> | undefined;
  let coverUrl = '';
  let author = '';
  if (metadata !== undefined) {
    coverUrl = pickCover(metadata);
    const authors = parseStringList(metadata['authors'] as Object);
    author = authors.length > 0 ? authors.join(', ') : '';
  }
  return {
    bookId: `${json['book_id'] ?? ''}`,
    bookTitle: `${json['book_title'] ?? ''}`,
    coverUrl: coverUrl,
    author: author,
    progressPercent: progress !== undefined && typeof progress['progress_percent'] === 'number'
      ? progress['progress_percent'] as number : 0,
    lastReadTime: progress !== undefined && typeof progress['last_read_time'] === 'number'
      ? progress['last_read_time'] as number : 0,
  };
}
