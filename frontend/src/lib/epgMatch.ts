// Fuzzy match a channel name to a known EPG guide id (tvg-id). Used by the bouquet's
// "suggest EPG ids" action to propose a tvg-id override for channels that don't yet
// resolve to a guide entry. Pure + tested so the heuristic can be tuned safely.

// Quality/format/decoration tokens that shouldn't influence the match — "NPO 1 HD"
// and "NPO 1" are the same channel; "┃NL┃" decoration is already stripped as non-alnum.
const NOISE = new Set([
  'hd', 'uhd', 'fhd', 'sd', 'qhd', '4k', '8k', 'h265', 'hevc', 'h264',
  'fps', '50fps', '60fps', 'tv', 'channel', 'kanaal', 'rec',
])

/** Lowercase, strip diacritics, split on non-alphanumerics, drop noise tokens. */
export function normalizeName(s: string): string[] {
  return s
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '') // strip combining diacritics (after NFKD)
    .replace(/[^a-z0-9]+/g, ' ') // bars, pipes, punctuation → space
    .split(' ')
    .filter((t) => t.length > 0 && !NOISE.has(t))
}

/** Token-overlap score in 0..1 (intersection / larger token set). */
export function nameScore(a: string, b: string): number {
  const ta = new Set(normalizeName(a))
  const tb = new Set(normalizeName(b))
  if (ta.size === 0 || tb.size === 0) return 0
  let inter = 0
  for (const t of ta) if (tb.has(t)) inter++
  return inter / Math.max(ta.size, tb.size)
}

export interface TvgGuide {
  tvgId: string
  name: string
}

export interface TvgSuggestion {
  tvgId: string
  name: string
  score: number
}

/**
 * Best guide-id match for a channel name, or null below the threshold. Matches the
 * channel name against each guide entry's sample name (and, as a weaker signal, the
 * tvg-id itself for ids like "npo1.nl"). A differing channel NUMBER lowers the score,
 * so "NPO 1" won't be matched to "NPO 2" at the default threshold.
 */
export function suggestTvgId(
  channelName: string,
  known: TvgGuide[],
  threshold = 0.6,
): TvgSuggestion | null {
  let best: TvgSuggestion | null = null
  for (const k of known) {
    const s = Math.max(nameScore(channelName, k.name), nameScore(channelName, k.tvgId))
    if (s >= threshold && (best === null || s > best.score))
      best = { tvgId: k.tvgId, name: k.name, score: s }
  }
  return best
}
