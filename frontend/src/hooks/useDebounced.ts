import { useEffect, useState } from 'react'

/** Default quiet time (ms) before a typed search/filter is applied. */
export const SEARCH_DEBOUNCE_MS = 300

/**
 * Returns a debounced copy of `value` that only updates after `delayMs` of quiet.
 * When `isReset(value)` holds (e.g. a cleared search field) the debounced copy follows
 * at once, so a value typed right after it can never bring back the old one.
 */
export function useDebounced<T>(
  value: T,
  delayMs = SEARCH_DEBOUNCE_MS,
  isReset?: (v: T) => boolean,
): T {
  const [debounced, setDebounced] = useState(value)
  const reset = isReset?.(value) ?? false
  // adjusting state during render (React's documented pattern): no stale frame
  if (reset && !Object.is(debounced, value)) setDebounced(value)
  useEffect(() => {
    if (reset) return
    const t = setTimeout(() => setDebounced(value), delayMs)
    return () => clearTimeout(t)
  }, [value, delayMs, reset])
  return debounced
}

/** `isReset` for text fields: an empty (or blank) value applies immediately. */
export const isBlank = (v: string) => v.trim() === ''
