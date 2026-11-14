import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { isBlank, useDebounced } from './useDebounced'

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

const tick = (ms: number) => act(() => vi.advanceTimersByTime(ms))

describe('useDebounced', () => {
  it('returns the initial value immediately', () => {
    const { result } = renderHook(() => useDebounced('a', 300))
    expect(result.current).toBe('a')
  })

  it('only updates after the delay of quiet', () => {
    const { result, rerender } = renderHook(({ v }) => useDebounced(v, 300), {
      initialProps: { v: 'a' },
    })
    rerender({ v: 'b' })
    expect(result.current).toBe('a') // not yet
    tick(299)
    expect(result.current).toBe('a')
    tick(1)
    expect(result.current).toBe('b') // after 300ms
  })

  it('resets the timer on rapid changes (debounce)', () => {
    const { result, rerender } = renderHook(({ v }) => useDebounced(v, 300), {
      initialProps: { v: 'a' },
    })
    rerender({ v: 'b' })
    tick(200)
    rerender({ v: 'c' }) // resets the window
    tick(200)
    expect(result.current).toBe('a') // still within the reset window
    tick(100)
    expect(result.current).toBe('c') // settles on the latest
  })

  it('a reset value applies at once and the old value never comes back', () => {
    const { result, rerender } = renderHook(({ v }) => useDebounced(v, 300, isBlank), {
      initialProps: { v: 'old' },
    })
    rerender({ v: '' }) // cleared: follows immediately
    expect(result.current).toBe('')
    rerender({ v: 'n' }) // typed again within the window
    expect(result.current).toBe('') // never 'old'
    tick(300)
    expect(result.current).toBe('n')
  })
})
