export interface ApiEnvelopeData {
  status: number;
  body: Record<string, Object> | null;
  error: string;
}

@Concurrent
export function parseApiEnvelopeTask(raw: string): ApiEnvelopeData {
  const parsed = JSON.parse(raw) as Record<string, Object>;
  let body: Record<string, Object> | null = null;
  if (parsed['body'] !== null && parsed['body'] !== undefined) {
    if (typeof parsed['body'] === 'string') {
      body = JSON.parse(parsed['body'] as string) as Record<string, Object>;
    } else {
      body = parsed['body'] as Record<string, Object>;
    }
  }
  let error = String(parsed['error'] ?? '');
  if (error.length === 0 && body !== null) {
    const err = String(body['err'] ?? '');
    if (err.length > 0 && err !== 'ok') {
      error = err;
    } else {
      const msg = String(body['msg'] ?? '');
      if (msg.length > 0 && msg !== 'ok') {
        error = msg;
      }
    }
  }
  return {
    status: Number(parsed['status'] ?? 0),
    body: body,
    error: error,
  };
}

@Concurrent
export function parseJsonArrayTask(raw: string): Array<Object> {
  if (raw.length === 0) {
    return [];
  }
  return JSON.parse(raw) as Array<Object>;
}
