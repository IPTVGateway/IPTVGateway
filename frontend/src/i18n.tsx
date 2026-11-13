import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import { api } from './api/client'
import { nl } from './locales/nl'

// ── English-string-as-key i18n ──────────────────────────────────────────────
// Every visible UI string IS its own key: t('Save settings') returns
//   dict['Save settings'] ?? 'Save settings'
// so English needs no dictionary (identity) and the literal English passes
// through unchanged. Crucially, with NO provider (e.g. a component rendered in a
// unit test), useT() returns the identity function — so tests that assert on
// English strings keep working untouched.

export type Dict = Record<string, string>
export interface Language {
  code: string
  name: string
}

/** Built-in languages always available, regardless of the backend. */
const BUILTIN_LANGUAGES: Language[] = [
  { code: 'en', name: 'English' },
  { code: 'nl', name: 'Nederlands' },
]

/** Built-in dictionaries. `en` is identity (empty). */
const BUILTIN_DICTS: Record<string, Dict> = {
  en: {},
  nl,
}

const LOCALE_KEY = 'iptv.locale'

/** Identity translator — used as the no-provider default and for English. */
const identityT = (s: string) => s

// Context A: the translate function (defaults to identity so no provider works).
const TContext = createContext<(s: string) => string>(identityT)

// Context B: locale control. No-provider default is sensible English-only.
interface I18nControl {
  locale: string
  setLocale: (code: string) => void
  languages: Language[]
}
const I18nContext = createContext<I18nControl>({
  locale: 'en',
  setLocale: () => {},
  languages: [{ code: 'en', name: 'English' }],
})

/** Strip the `_name` label key (it's only a human label, not a UI string). */
function stripMeta(d: Dict): Dict {
  if (!d || typeof d !== 'object') return {}
  const { _name, ...rest } = d
  void _name
  return rest
}

function readInitialLocale(): string {
  try {
    return localStorage.getItem(LOCALE_KEY) || 'en'
  } catch {
    return 'en'
  }
}

/** Merge built-in languages with backend folder languages (folder overrides built-in by code). */
function mergeLanguages(folder: Language[]): Language[] {
  const byCode = new Map<string, Language>()
  for (const l of BUILTIN_LANGUAGES) byCode.set(l.code, l)
  for (const l of folder) {
    if (l && l.code) byCode.set(l.code, { code: l.code, name: l.name || l.code })
  }
  return [...byCode.values()]
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<string>(readInitialLocale)
  const [dict, setDict] = useState<Dict>(() => BUILTIN_DICTS[readInitialLocale()] ?? {})
  const [languages, setLanguages] = useState<Language[]>(BUILTIN_LANGUAGES)

  // Discover backend folder languages once on mount; ignore errors (401 etc.).
  useEffect(() => {
    api
      .languages()
      .then((folder) => setLanguages(mergeLanguages(folder ?? [])))
      .catch(() => setLanguages(BUILTIN_LANGUAGES))
  }, [])

  // Load the dictionary for the current locale (built-in synchronously, folder via fetch).
  useEffect(() => {
    let cancelled = false
    if (locale in BUILTIN_DICTS) {
      setDict(BUILTIN_DICTS[locale])
      return
    }
    api
      .language(locale)
      .then((d) => {
        if (!cancelled) setDict(stripMeta(d ?? {}))
      })
      .catch(() => {
        if (!cancelled) setDict({}) // fall back to identity (English passthrough)
      })
    return () => {
      cancelled = true
    }
  }, [locale])

  const setLocale = useCallback((code: string) => {
    setLocaleState(code)
    try {
      localStorage.setItem(LOCALE_KEY, code)
    } catch {
      /* ignore storage errors */
    }
  }, [])

  const t = useCallback((s: string) => dict[s] ?? s, [dict])

  const control = useMemo<I18nControl>(
    () => ({ locale, setLocale, languages }),
    [locale, setLocale, languages],
  )

  return (
    <I18nContext.Provider value={control}>
      <TContext.Provider value={t}>{children}</TContext.Provider>
    </I18nContext.Provider>
  )
}

/** The translate function. With no provider, returns identity (English passthrough). */
export function useT(): (s: string) => string {
  return useContext(TContext)
}

/** Locale control: current locale, a setter, and the available languages. */
export function useI18n(): I18nControl {
  return useContext(I18nContext)
}
