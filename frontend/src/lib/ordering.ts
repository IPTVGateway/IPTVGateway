import type { CustomGroup, CustomItem } from '../types'

/** Case-insensitive A→Z comparator for plain names. */
export function byNameCI(a: string, b: string): number {
  return a.localeCompare(b, undefined, { sensitivity: 'base' })
}

/**
 * Global ordering rule for groups: favorite groups first, then the operator's
 * manual drag order (sortOrder > 0), then case-insensitive A→Z for any groups not
 * yet manually positioned. Mirrors the backend LoadOutputChannels ordering.
 */
export function compareGroups(a: CustomGroup, b: CustomGroup): number {
  if (a.isFavorite !== b.isFavorite) return a.isFavorite ? -1 : 1
  const ao = a.sortOrder && a.sortOrder > 0 ? a.sortOrder : Number.POSITIVE_INFINITY
  const bo = b.sortOrder && b.sortOrder > 0 ? b.sortOrder : Number.POSITIVE_INFINITY
  if (ao !== bo) return ao - bo
  return byNameCI(a.name, b.name)
}

/**
 * Order channels by channel number ascending. An unset number (0) is treated as
 * "no number" and sinks to the bottom; equal numbers (and unset ones) fall back
 * to case-insensitive A→Z by name.
 */
export function byChannelNumber(
  aNum: number,
  aName: string,
  bNum: number,
  bName: string,
): number {
  const ax = aNum > 0 ? aNum : Number.POSITIVE_INFINITY
  const bx = bNum > 0 ? bNum : Number.POSITIVE_INFINITY
  if (ax !== bx) return ax - bx
  return byNameCI(aName, bName)
}

/**
 * Move `draggedId` to the position of `targetId` within `ids`: dragging UP lands
 * before the target, dragging DOWN lands after it (so dropping on the next row
 * really moves it).
 * Returns a new array; returns the input unchanged if either id is missing or
 * they are the same. Used by drag-and-drop reordering of channels in a group.
 */
export function reorderByDrag(ids: number[], draggedId: number, targetId: number): number[] {
  if (draggedId === targetId) return ids
  const from = ids.indexOf(draggedId)
  if (from < 0 || ids.indexOf(targetId) < 0) return ids
  const down = from < ids.indexOf(targetId)
  const next = ids.slice()
  next.splice(from, 1)
  next.splice(next.indexOf(targetId) + (down ? 1 : 0), 0, draggedId)
  return next
}

export const CONTENT_TYPES = ['live', 'movie', 'series', 'radio'] as const

/** One group's block in a bouquet-wide renumber plan. */
export interface RenumberBlock {
  groupId: number
  first: number
  last: number
  count: number
}

/**
 * Bouquet-wide channel numbering across all groups (in display order, channels
 * already in their display order): every group starts on a fresh round number —
 * the next hundred (100, 200, …), or the next thousand when the group has more
 * than 99 channels (a hundred-block holds x00..x99). Empty groups are skipped.
 */
export function planBouquetNumbers(groups: { groupId: number; itemIds: number[] }[]): {
  numbers: { itemId: number; channelNumber: number }[]
  blocks: RenumberBlock[]
} {
  const numbers: { itemId: number; channelNumber: number }[] = []
  const blocks: RenumberBlock[] = []
  let next = 1 // first free number
  for (const g of groups) {
    const n = g.itemIds.length
    if (n === 0) continue
    const block = n > 99 ? 1000 : 100
    const first = Math.ceil(next / block) * block
    g.itemIds.forEach((itemId, i) => numbers.push({ itemId, channelNumber: first + i }))
    blocks.push({ groupId: g.groupId, first, last: first + n - 1, count: n })
    next = first + n
  }
  return { numbers, blocks }
}

/** The name a bouquet row shows: display name, else the upstream name. */
export function itemDisplayName(it: CustomItem): string {
  return it.displayName?.trim() || it.streamName?.trim() || `#${it.streamItemId}`
}

/**
 * The list's items in the order the bouquet panel shows them: custom groups in
 * `compareGroups` order, then the upstream group (id 0) last; within a group by
 * name A→Z (case-insensitive) or by channel number, like the panel's sort mode.
 * Items of a group that no longer exists come at the very end.
 */
export function bouquetOrder(
  groups: CustomGroup[],
  items: CustomItem[],
  mode: 'name' | 'number' = 'name',
): CustomItem[] {
  const rank = new Map<number, number>()
  ;[...groups].sort(compareGroups).forEach((g, i) => rank.set(g.id, i))
  const upstream = groups.length // the upstream group sits after every custom group
  const groupRank = (id: number) => rank.get(id) ?? (id === 0 ? upstream : upstream + 1)
  const cmp =
    mode === 'number'
      ? (a: CustomItem, b: CustomItem) =>
          byChannelNumber(a.channelNumber, itemDisplayName(a), b.channelNumber, itemDisplayName(b))
      : (a: CustomItem, b: CustomItem) => byNameCI(itemDisplayName(a), itemDisplayName(b))
  return [...items].sort((a, b) => groupRank(a.customGroupId) - groupRank(b.customGroupId) || cmp(a, b))
}
