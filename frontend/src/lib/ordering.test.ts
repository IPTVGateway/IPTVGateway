import { describe, it, expect } from 'vitest'
import { bouquetOrder, byChannelNumber, byNameCI, compareGroups, CONTENT_TYPES, reorderByDrag } from './ordering'
import type { CustomGroup, CustomItem } from '../types'

function grp(name: string, isFavorite = false): CustomGroup {
  return { id: 1, listId: 1, name, contentType: 'live', isFavorite }
}

describe('byNameCI', () => {
  it('sorts case-insensitively', () => {
    expect(byNameCI('apple', 'Banana')).toBeLessThan(0)
    expect(byNameCI('Banana', 'apple')).toBeGreaterThan(0)
  })
  it('treats same letters of different case as equal', () => {
    expect(byNameCI('ABC', 'abc')).toBe(0)
  })
})

describe('compareGroups', () => {
  it('puts favorites first regardless of name', () => {
    expect(compareGroups(grp('Zzz', true), grp('Aaa', false))).toBeLessThan(0)
    expect(compareGroups(grp('Aaa', false), grp('Zzz', true))).toBeGreaterThan(0)
  })
  it('falls back to case-insensitive name when favorite flags match', () => {
    expect(compareGroups(grp('alpha'), grp('Beta'))).toBeLessThan(0)
  })
  it('sorts a mixed list favorites-first then A→Z', () => {
    const sorted = [grp('News'), grp('ZSports', true), grp('ABC'), grp('Movies', true)].sort(
      compareGroups,
    )
    expect(sorted.map((g) => g.name)).toEqual(['Movies', 'ZSports', 'ABC', 'News'])
  })
})

describe('byChannelNumber', () => {
  it('orders by ascending channel number', () => {
    expect(byChannelNumber(1, 'Zebra', 2, 'Alpha')).toBeLessThan(0)
    expect(byChannelNumber(5, 'Alpha', 2, 'Zebra')).toBeGreaterThan(0)
  })
  it('sinks unset numbers (0) to the bottom', () => {
    expect(byChannelNumber(0, 'Alpha', 99, 'Zebra')).toBeGreaterThan(0)
    expect(byChannelNumber(99, 'Zebra', 0, 'Alpha')).toBeLessThan(0)
  })
  it('falls back to case-insensitive name on equal (or both unset) numbers', () => {
    expect(byChannelNumber(3, 'alpha', 3, 'Beta')).toBeLessThan(0)
    expect(byChannelNumber(0, 'alpha', 0, 'Beta')).toBeLessThan(0)
  })
})

describe('reorderByDrag', () => {
  it('moves a later item up to the target position (insert-before)', () => {
    expect(reorderByDrag([1, 2, 3, 4], 4, 2)).toEqual([1, 4, 2, 3])
  })
  it('moves an earlier item down to just after the target', () => {
    expect(reorderByDrag([1, 2, 3, 4], 1, 3)).toEqual([2, 3, 1, 4])
  })
  it('dropping on the next row swaps the two', () => {
    expect(reorderByDrag([1, 2, 3], 1, 2)).toEqual([2, 1, 3])
  })
  it('is a no-op when dragging onto itself or onto a missing id', () => {
    expect(reorderByDrag([1, 2, 3], 2, 2)).toEqual([1, 2, 3])
    expect(reorderByDrag([1, 2, 3], 2, 9)).toEqual([1, 2, 3])
    expect(reorderByDrag([1, 2, 3], 9, 1)).toEqual([1, 2, 3])
  })
})

describe('CONTENT_TYPES', () => {
  it('is the canonical four in order', () => {
    expect(CONTENT_TYPES).toEqual(['live', 'movie', 'series', 'radio'])
  })
})

describe('bouquetOrder', () => {
  const g = (id: number, name: string, isFavorite = false) =>
    ({ id, listId: 1, name, contentType: 'live', isFavorite }) as CustomGroup
  const it_ = (id: number, gid: number, name: string, channelNumber = 0) =>
    ({ id, listId: 1, streamItemId: id, customGroupId: gid, contentType: 'live', displayName: name, channelNumber }) as CustomItem

  it('favorite groups first, then A→Z, upstream group last; channels A→Z case-insensitive', () => {
    const groups = [g(1, 'news'), g(2, 'Sport', true), g(3, 'Kids')]
    const items = [it_(1, 1, 'b'), it_(2, 0, 'Up'), it_(3, 3, 'K'), it_(4, 2, 'zz'), it_(5, 2, 'AA'), it_(6, 1, 'A')]
    expect(bouquetOrder(groups, items).map((i) => i.id)).toEqual([5, 4, 3, 6, 1, 2])
  })

  it('orders channels by number in number mode', () => {
    const items = [it_(1, 1, 'A', 3), it_(2, 1, 'B', 1), it_(3, 1, 'C', 0)]
    expect(bouquetOrder([g(1, 'X')], items, 'number').map((i) => i.id)).toEqual([2, 1, 3])
  })
})
