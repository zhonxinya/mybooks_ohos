export interface EditBookRequest {
  title?: string;
  authors?: string[];
  tags?: string[];
  publisher?: string;
  isbn?: string;
  series?: string;
  rating?: number;
}

export interface ReferBook {
  cover_url?: string;
  source: string;
  website?: string;
  title?: string;
  author_sort?: string;
  authors?: string[];
  comments?: string;
  isbn?: string;
  isbn13?: string;
  publisher?: string;
  language?: string;
  identifiers?: Record<string, Object>;
  tags?: string[];
  series?: string;
  pubdate?: string;
  pubyear?: string;
  provider_key?: string;
  provider_value?: string;
  rating?: number;
}

export interface AudioFileInfo {
  filename: string;
  url: string;
  size: number;
}

export interface AudioInfoResponse {
  err?: string;
  status?: string;
  msg?: string;
  count?: number;
  total_files?: number;
  is_paid?: boolean;
  audios?: AudioFileInfo[];
}
export interface AudioConversionProgress {
  status?: string;
  percent?: number;
  message?: string;
  converted_chapters?: number;
  total_chapters?: number;
  current_chapter?: Record<string, Object>;
  error_message?: string;
}

export interface AudioConversionResponse {
  err?: string;
  msg?: string;
  data?: AudioConversionProgress;
  task_id?: string;
}

export interface AudioCollectionResponse {
  err?: string;
  msg?: string;
  message?: string;
  download_url?: string;
}

export interface AudioPurchaseResponse {
  err?: string;
  msg?: string;
  notes?: string;
}
