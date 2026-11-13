// Theme preference: 'system' | 'light' | 'dark', persisted in a COOKIE
// (the user asked for cookies, not localStorage). For 'system' we follow the
// OS color-scheme media query and react live to changes.

export type ThemePref = 'system' | 'light' | 'dark'

const COOKIE = 'iptvplay_theme'
const ONE_YEAR = 60 * 60 * 24 * 365

function isPref(v: string): v is ThemePref {
  return v === 'system' || v === 'light' || v === 'dark'
}

/** Read the stored theme preference from the cookie. Defaults to 'system'. */
export function readTheme(): ThemePref {
  const match = document.cookie
    .split(';')
    .map((c) => c.trim())
    .find((c) => c.startsWith(`${COOKIE}=`))
  if (match) {
    const val = decodeURIComponent(match.slice(COOKIE.length + 1))
    if (isPref(val)) return val
  }
  return 'system'
}

/** Persist the theme preference in a 1-year cookie. */
export function writeTheme(pref: ThemePref): void {
  document.cookie = `${COOKIE}=${encodeURIComponent(pref)}; path=/; max-age=${ONE_YEAR}; SameSite=Lax`
}

/**
 * Apply the preference to <html data-theme="…">. The CSS resolves 'system'
 * via a prefers-color-scheme media query, so we set the raw preference here.
 */
export function applyTheme(pref: ThemePref): void {
  document.documentElement.dataset.theme = pref
}

/**
 * Wire up the theme: apply the stored (or given) preference and, while the
 * preference is 'system', keep reacting to OS color-scheme changes (only needed
 * to trigger any JS observers — CSS already handles the visuals). Returns a
 * disposer that removes the media-query listener.
 */
export function initTheme(pref: ThemePref): () => void {
  applyTheme(pref)
  const mql = window.matchMedia('(prefers-color-scheme: dark)')
  const onChange = () => {
    // Re-apply so the data-theme attribute stays in sync; CSS does the rest.
    if (document.documentElement.dataset.theme === 'system') applyTheme('system')
  }
  // addEventListener is supported in all modern browsers; guard for older Safari.
  if (typeof mql.addEventListener === 'function') mql.addEventListener('change', onChange)
  return () => {
    if (typeof mql.removeEventListener === 'function') mql.removeEventListener('change', onChange)
  }
}
