// Turns database / network errors into clear, actionable messages.
export type AppError = {
  kind: 'network' | 'permission' | 'insufficient' | 'validation' | 'state' | 'confirm' | 'conflict' | 'auth' | 'unknown';
  message: string;
  code?: string;
  detail?: Record<string, unknown> | null;
};

export function toAppError(e: unknown): AppError {
  const err = e as { code?: string; message?: string; details?: string; name?: string } | null;
  const msg = err?.message ?? String(e);
  if (!err || err.name === 'TypeError' || /fetch|network|Failed to fetch|Load failed|NetworkError|timeout|aborted/i.test(msg) && !err.code) {
    return { kind: 'network', message: 'The server could not be reached. Nothing has been confirmed as saved.' };
  }
  let detail: Record<string, unknown> | null = null;
  if (err.details) { try { detail = JSON.parse(err.details); } catch { detail = null; } }
  switch (err.code) {
    case 'CS401': return { kind: 'permission', message: msg, code: err.code, detail };
    case 'CS409': return { kind: 'insufficient', message: msg, code: err.code, detail };
    case 'CS410': return { kind: 'conflict', message: msg, code: err.code, detail };
    case 'CS422': return { kind: 'validation', message: msg, code: err.code, detail };
    case 'CS423': return { kind: 'state', message: msg, code: err.code, detail };
    case 'CS428': return { kind: 'confirm', message: msg, code: err.code, detail };
    case '42501': return { kind: 'permission', message: 'You do not have permission for this action.', code: err.code };
    case '23505': {
      const friendly: [RegExp, string][] = [
        [/stocktakes_one_active/, 'Another stocktake covering this warehouse is already in progress. Finish or cancel it first.'],
        [/barcodes|label_code/, 'That barcode is already in use.'],
        [/sku/, 'That stock code already exists.'],
        [/code/, 'That code already exists.'],
      ];
      return { kind: 'conflict', message: friendly.find(([re]) => re.test(msg))?.[1] ?? 'This record already exists.', code: err.code };
    }
    case '23503': return { kind: 'validation', message: 'This refers to a record that does not exist or is still in use.', code: err.code };
    case '23514': return { kind: 'validation', message: 'A value is not in the required format.', code: err.code };
    case 'PGRST301': case 'PGRST302': return { kind: 'auth', message: 'Your session has expired. Sign in again.', code: err.code };
    default: return { kind: 'unknown', message: msg || 'Unexpected error', code: err.code, detail };
  }
}
