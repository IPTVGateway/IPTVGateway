import { describe, it, expect, beforeEach } from 'vitest'
import { readTheme, writeTheme, applyTheme } from './theme'

beforeEach(() => {
  // clear our cookie + reset the attribute
  document.cookie = 'iptvplay_theme=; max-age=0; path=/'
  delete document.documentElement.dataset.theme
})

describe('theme', () => {
  it('defaults to "system" when no cookie is set', () => {
    expect(readTheme()).toBe('system')
  })

  it('persists and reads back a preference via cookie', () => {
    writeTheme('dark')
    expect(document.cookie).toContain('iptvplay_theme=dark')
    expect(readTheme()).toBe('dark')
  })

  it('round-trips light', () => {
    writeTheme('light')
    expect(readTheme()).toBe('light')
  })

  it('ignores an invalid cookie value and falls back to system', () => {
    document.cookie = 'iptvplay_theme=purple; path=/'
    expect(readTheme()).toBe('system')
  })

  it('applyTheme sets the data-theme attribute on <html>', () => {
    applyTheme('dark')
    expect(document.documentElement.dataset.theme).toBe('dark')
    applyTheme('light')
    expect(document.documentElement.dataset.theme).toBe('light')
  })
})
