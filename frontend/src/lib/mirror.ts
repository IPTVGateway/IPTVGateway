import type { CustomList } from '../types'

/** True when the list mirrors another list (it has no channels of its own). */
export function isMirror(l: CustomList | null | undefined): boolean {
  return (l?.mirrorOfListId ?? 0) > 0
}

/** The master a mirror list points at (undefined for a normal list or an unknown id). */
export function mirrorMaster(l: CustomList | null | undefined, lists: CustomList[]): CustomList | undefined {
  if (!isMirror(l)) return undefined
  return lists.find((m) => m.id === l!.mirrorOfListId)
}
