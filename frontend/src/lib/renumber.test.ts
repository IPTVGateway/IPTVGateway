import { describe, it, expect } from 'vitest'
import { planBouquetNumbers } from './ordering'

const ids = (from: number, n: number) => Array.from({ length: n }, (_, i) => from + i)

describe('planBouquetNumbers', () => {
  it('starts every group on a fresh hundred, big groups on a thousand', () => {
    const { numbers, blocks } = planBouquetNumbers([
      { groupId: 1, itemIds: ids(1, 12) },     // 100..111
      { groupId: 2, itemIds: [] },             // skipped
      { groupId: 3, itemIds: ids(100, 99) },   // fits a hundred: 200..298
      { groupId: 4, itemIds: ids(300, 150) },  // > 99 -> next thousand: 1000..1149
      { groupId: 5, itemIds: ids(500, 3) },    // next hundred after 1149: 1200..1202
    ])
    expect(blocks).toEqual([
      { groupId: 1, first: 100, last: 111, count: 12 },
      { groupId: 3, first: 200, last: 298, count: 99 },
      { groupId: 4, first: 1000, last: 1149, count: 150 },
      { groupId: 5, first: 1200, last: 1202, count: 3 },
    ])
    expect(numbers[0]).toEqual({ itemId: 1, channelNumber: 100 })
    expect(numbers).toHaveLength(12 + 99 + 150 + 3)
    expect(new Set(numbers.map((n) => n.channelNumber)).size).toBe(numbers.length) // unique
  })

  it('a first big group starts at 1000', () => {
    expect(planBouquetNumbers([{ groupId: 1, itemIds: ids(1, 100) }]).blocks[0].first).toBe(1000)
  })
})
