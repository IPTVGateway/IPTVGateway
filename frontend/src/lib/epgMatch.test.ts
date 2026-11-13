import { describe, it, expect } from 'vitest'
import { normalizeName, nameScore, suggestTvgId } from './epgMatch'

describe('epgMatch', () => {
  it('normalizes away quality tags, decoration and diacritics', () => {
    expect(normalizeName('NPO 1 HD')).toEqual(['npo', '1'])
    expect(normalizeName('┃NL┃ NPO 1 ⏺ʳᵉᶜ')).toContain('npo')
    expect(normalizeName('Téléfoot 4K')).toEqual(['telefoot'])
  })

  it('scores the same channel high and a different number low', () => {
    expect(nameScore('NPO 1', 'NPO 1 HD')).toBe(1)
    // a differing channel number drops below the default threshold
    expect(nameScore('NPO 1', 'NPO 2')).toBeLessThan(0.6)
  })

  const guide = [
    { tvgId: 'npo1.nl', name: 'NPO 1 HD' },
    { tvgId: 'npo2.nl', name: 'NPO 2 HD' },
    { tvgId: 'espn.nl', name: 'ESPN' },
  ]

  it('suggests the matching guide id for a channel name', () => {
    const s = suggestTvgId('NPO 1', guide)
    expect(s?.tvgId).toBe('npo1.nl')
  })

  it('does not confuse adjacent channel numbers', () => {
    // "NPO 2" must map to npo2, never npo1
    expect(suggestTvgId('NPO 2 FHD', guide)?.tvgId).toBe('npo2.nl')
  })

  it('returns null when nothing matches well enough', () => {
    expect(suggestTvgId('Some Obscure Local Channel', guide)).toBeNull()
  })
})
