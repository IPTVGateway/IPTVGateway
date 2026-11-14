// localStorage that never throws: in a private window, with blocked site data or
// a full quota the accessors raise, and a UI preference must not break the page.

import { SORT_BY_NAME, SORT_BY_NUMBER, SORT_MODE_STORAGE_KEY, type SortMode } from './ordering'

/** The stored value, or null when absent or storage is unavailable. */
export function safeGetItem(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

/** Store a value; silently does nothing when storage is unavailable. */
export function safeSetItem(key: string, value: string): void {
  try {
    localStorage.setItem(key, value)
  } catch {
    /* preference not remembered - harmless */
  }
}

/** Remove a value; silently does nothing when storage is unavailable. */
export function safeRemoveItem(key: string): void {
  try {
    localStorage.removeItem(key)
  } catch {
    /* nothing stored that we could remove - harmless */
  }
}

/** Fired on window when the bouquet panel's sort mode changes (same tab). */
export const SORT_MODE_EVENT = 'iptv:sortmode'

/** The bouquet panel's sort mode as stored (A→Z by default). */
export function readSortMode(): SortMode {
  return safeGetItem(SORT_MODE_STORAGE_KEY) === SORT_BY_NUMBER ? SORT_BY_NUMBER : SORT_BY_NAME
}

/** Store the sort mode and tell other views (the EPG lanes follow it). */
export function writeSortMode(mode: SortMode): void {
  safeSetItem(SORT_MODE_STORAGE_KEY, mode)
  window.dispatchEvent(new Event(SORT_MODE_EVENT))
}
