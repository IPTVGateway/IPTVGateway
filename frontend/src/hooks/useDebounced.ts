import { useEffect, useState } from 'react'

/** Default quiet time (ms) before a typed search/filter is applied. */
export const SEARCH_DEBOUNCE_MS = 300

/** Returns a debounced copy of `value` that only updates after `delayMs` of quiet. */
export function useDebounced<T>(value: T, delayMs = SEARCH_DEBOUNCE_MS): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const t = setTimeout(() => setDebounced(value), delayMs)
    return () => clearTimeout(t)
  }, [value, delayMs])
  return debounced
}
