import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within, fireEvent, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ListPanel } from './ListPanel'
import type { CustomGroup, CustomItem, CustomList, Source } from '../types'

vi.mock('../api/client', () => ({
  api: {
    saveGroup: vi.fn().mockResolvedValue({}),
    deleteGroup: vi.fn().mockResolvedValue(undefined),
    clearGroupItems: vi.fn().mockResolvedValue({ removed: 0 }),
    dedupeList: vi.fn().mockResolvedValue({ removed: 3 }),
    sortGroup: vi.fn().mockResolvedValue({ sorted: 2 }),
    reorderGroup: vi.fn().mockResolvedValue({ numbered: 2 }),
    saveItem: vi.fn().mockResolvedValue({}),
    deleteItem: vi.fn().mockResolvedValue(undefined),
    groupVariants: vi.fn().mockResolvedValue([]),
    groupProviderVariants: vi.fn().mockResolvedValue([]),
    addItems: vi.fn().mockResolvedValue({ added: 0 }),
    replaceItems: vi.fn().mockResolvedValue({ replaced: 0 }),
    restripGroup: vi.fn().mockResolvedValue([]),
    tvgIds: vi.fn().mockResolvedValue([]),
    downloadExportM3u: vi.fn().mockResolvedValue(undefined),
    downloadExportXmltv: vi.fn().mockResolvedValue(undefined),
  },
}))
import { api } from '../api/client'

const SOURCES: Source[] = [
  { id: 1, name: 'ProviderA', kind: 'xtream', url: '', enabled: true, contentTypes: ['live'] },
  { id: 2, name: 'ProviderB', kind: 'xtream', url: '', enabled: true, contentTypes: ['live'] },
]
const LISTS: CustomList[] = [
  { id: 1, name: 'L', outputUsername: '', outputPassword: '', enabled: true },
]
const GROUPS: CustomGroup[] = [
  { id: 10, listId: 1, name: 'Sport', contentType: 'live', isFavorite: false },
]
const ITEMS: CustomItem[] = [
  {
    id: 100, listId: 1, streamItemId: 5, customGroupId: 10, contentType: 'live',
    displayName: '', channelNumber: 0, streamName: 'NPO 1',
  },
]

function renderPanel(over: Partial<Parameters<typeof ListPanel>[0]> = {}) {
  return render(
    <ListPanel
      lists={LISTS}
      sources={SOURCES}
      activeListId={1}
      onSelectList={() => {}}
      groups={GROUPS}
      items={ITEMS}
      loading={false}
      error={null}
      onRefresh={() => {}}
      {...over}
    />,
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  localStorage.clear() // sort-mode is persisted; isolate tests
})

describe('ListPanel — sources + downloads', () => {
  it('downloads are buttons (no credential-less href) and fetch a token on click', async () => {
    renderPanel()
    const btn = screen.getByTitle('Download playlist as M3U')
    expect(btn.tagName).toBe('BUTTON')
    expect(btn.getAttribute('href')).toBeNull()
    await userEvent.click(btn)
    expect(api.downloadExportM3u).toHaveBeenCalledWith(1)
  })

  it('shows why a download failed', async () => {
    vi.mocked(api.downloadExportXmltv).mockRejectedValueOnce(new Error('503 down'))
    renderPanel()
    await userEvent.click(screen.getByTitle('Download EPG as XMLTV'))
    expect(await screen.findByText('503 down')).toBeInTheDocument()
  })

  it('re-fetches the guide ids when the app sources change', async () => {
    const { rerender } = renderPanel()
    await waitFor(() => expect(api.tvgIds).toHaveBeenCalledTimes(1))
    rerender(
      <ListPanel
        lists={LISTS}
        sources={[...SOURCES, { id: 3, name: 'ProviderC', kind: 'm3u', url: '', enabled: true, contentTypes: ['live'] }]}
        activeListId={1}
        onSelectList={() => {}}
        groups={GROUPS}
        items={ITEMS}
        loading={false}
        error={null}
        onRefresh={() => {}}
      />,
    )
    await waitFor(() => expect(api.tvgIds).toHaveBeenCalledTimes(2))
  })
})

describe('ListPanel', () => {
  it('shows the upstream channel name as the item label fallback (no override)', () => {
    renderPanel()
    expect(screen.getByPlaceholderText('NPO 1')).toBeInTheDocument()
  })

  it('renames a group via the pencil → Save', async () => {
    renderPanel({ items: [] }) // no item rows → the only "Sport" field is the rename input
    await userEvent.click(screen.getByTitle('Rename'))
    const input = screen.getByDisplayValue('Sport')
    await userEvent.clear(input)
    await userEvent.type(input, 'News')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    expect(api.saveGroup).toHaveBeenCalledWith(1, expect.objectContaining({ id: 10, name: 'News' }))
  })

  it('empties a group in one click (with confirm)', async () => {
    renderPanel()
    await userEvent.click(screen.getByTitle(/Empty group/))
    await userEvent.click(screen.getByRole('button', { name: 'Confirm empty' }))
    expect(api.clearGroupItems).toHaveBeenCalledWith(1, 10)
  })

  it('sorts a group A→Z (renumber) — enabled only with 2+ channels', async () => {
    const twoItems: CustomItem[] = [
      { id: 100, listId: 1, streamItemId: 5, customGroupId: 10, contentType: 'live', displayName: '', channelNumber: 0, streamName: 'NPO 1' },
      { id: 101, listId: 1, streamItemId: 6, customGroupId: 10, contentType: 'live', displayName: '', channelNumber: 0, streamName: 'BBC' },
    ]
    renderPanel({ items: twoItems })
    await userEvent.click(screen.getByTitle(/Sort this group/))
    expect(api.sortGroup).toHaveBeenCalledWith(1, 10)
  })

  it('deletes a group only after confirm', async () => {
    renderPanel()
    await userEvent.click(screen.getByTitle(/Delete group/))
    expect(api.deleteGroup).not.toHaveBeenCalled()
    await userEvent.click(screen.getByRole('button', { name: 'Confirm delete' }))
    expect(api.deleteGroup).toHaveBeenCalledWith(10)
  })

  it('cancelling the group delete keeps the group', async () => {
    renderPanel()
    await userEvent.click(screen.getByTitle(/Delete group/))
    await userEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(api.deleteGroup).not.toHaveBeenCalled()
    expect(screen.queryByRole('button', { name: 'Confirm delete' })).toBeNull()
  })

  it('a pointercancel aborts a channel drag without reordering (no stale drag on the next pointerup)', async () => {
    const twoItems: CustomItem[] = [
      { id: 100, listId: 1, streamItemId: 5, customGroupId: 10, contentType: 'live', displayName: '', channelNumber: 1, streamName: 'Zebra' },
      { id: 101, listId: 1, streamItemId: 6, customGroupId: 10, contentType: 'live', displayName: '', channelNumber: 2, streamName: 'Alpha' },
    ]
    renderPanel({ items: twoItems })
    await userEvent.click(screen.getByRole('button', { name: 'No.' }))
    const grips = screen.getAllByLabelText('Reorder')
    const targetRow = grips[0].closest('li') as HTMLElement
    const orig = (document as unknown as { elementFromPoint?: unknown }).elementFromPoint
    ;(document as unknown as { elementFromPoint: unknown }).elementFromPoint = () => targetRow
    try {
      fireEvent.pointerDown(grips[1], { pointerId: 1 })
      fireEvent.pointerMove(grips[1], { pointerId: 1, clientX: 5, clientY: 5 })
      expect(targetRow.className).toContain('drop-target')
      fireEvent.pointerCancel(grips[1], { pointerId: 1 })
      expect(targetRow.className).not.toContain('drop-target')
      // a later stray pointerup must not apply the cancelled drag
      fireEvent.pointerUp(grips[1], { pointerId: 1 })
    } finally {
      ;(document as unknown as { elementFromPoint: unknown }).elementFromPoint = orig
    }
    expect(api.reorderGroup).not.toHaveBeenCalled()
  })

  it('de-duplicates the list and reports how many were removed', async () => {
    renderPanel()
    await userEvent.click(screen.getByRole('button', { name: 'Dedupe' }))
    expect(api.dedupeList).toHaveBeenCalledWith(1)
    expect(await screen.findByText(/3 duplicates removed/)).toBeInTheDocument()
  })

  it('sorts channels by channel number when "No." is selected (and back by name)', async () => {
    // Zebra has the lower number; name-order would put Alpha first, number-order Zebra first.
    const twoItems: CustomItem[] = [
      { id: 100, listId: 1, streamItemId: 5, customGroupId: 10, contentType: 'live', displayName: '', channelNumber: 1, streamName: 'Zebra' },
      { id: 101, listId: 1, streamItemId: 6, customGroupId: 10, contentType: 'live', displayName: '', channelNumber: 2, streamName: 'Alpha' },
    ]
    renderPanel({ items: twoItems })
    const nums = () => screen.getAllByTitle('Channel number').map((el) => (el as HTMLInputElement).value)

    // default: by name → Alpha(2), Zebra(1)
    expect(nums()).toEqual(['2', '1'])

    // switch to channel-number order → Zebra(1), Alpha(2)
    await userEvent.click(screen.getByRole('button', { name: 'No.' }))
    expect(nums()).toEqual(['1', '2'])
    expect(localStorage.getItem('iptv.list.sortMode')).toBe('number')

    // back to name order
    await userEvent.click(screen.getByRole('button', { name: 'Name' }))
    expect(nums()).toEqual(['2', '1'])
  })

  it('reorders by drag in "Nr" mode and persists channel numbers in the dropped order', async () => {
    const twoItems: CustomItem[] = [
      { id: 100, listId: 1, streamItemId: 5, customGroupId: 10, contentType: 'live', displayName: '', channelNumber: 1, streamName: 'Zebra' },
      { id: 101, listId: 1, streamItemId: 6, customGroupId: 10, contentType: 'live', displayName: '', channelNumber: 2, streamName: 'Alpha' },
    ]
    renderPanel({ items: twoItems })
    // grips only exist in channel-number mode
    await userEvent.click(screen.getByRole('button', { name: 'No.' }))
    const grips = screen.getAllByLabelText('Reorder') // DOM order: row 100 (ch1), row 101 (ch2)
    expect(grips).toHaveLength(2)

    // Reorder uses Pointer Events (works on mouse + touch). The hit-test uses
    // document.elementFromPoint, which jsdom (no layout) returns null for — stub it
    // to the target row so the move resolves to row 100.
    const targetRow = grips[0].closest('li') as HTMLElement
    // jsdom has no layout / may not implement elementFromPoint — assign it directly
    const orig = (document as unknown as { elementFromPoint?: unknown }).elementFromPoint
    ;(document as unknown as { elementFromPoint: unknown }).elementFromPoint = () => targetRow
    try {
      // drag the 2nd channel (id 101) onto the 1st (id 100) → order becomes [101, 100]
      fireEvent.pointerDown(grips[1], { pointerId: 1 })
      fireEvent.pointerMove(grips[1], { pointerId: 1, clientX: 5, clientY: 5 })
      expect(targetRow.className).toContain('drop-target')
      fireEvent.pointerUp(grips[1], { pointerId: 1 })
    } finally {
      ;(document as unknown as { elementFromPoint: unknown }).elementFromPoint = orig
    }

    await waitFor(() =>
      expect(api.reorderGroup).toHaveBeenCalledWith(1, 10, [101, 100]),
    )
  })

  it('shows no drag grips in name mode', () => {
    renderPanel()
    expect(screen.queryByLabelText('Reorder')).toBeNull()
  })

  it('removes a channel from the list via the per-row trash button', async () => {
    renderPanel()
    const row = screen.getByPlaceholderText('NPO 1').closest('li') as HTMLElement
    await userEvent.click(within(row).getByLabelText('Remove channel'))
    expect(api.deleteItem).toHaveBeenCalledWith(100)
  })

  it('collapses and expands a group, hiding/showing its channels', async () => {
    renderPanel()
    expect(screen.getByPlaceholderText('NPO 1')).toBeInTheDocument()
    await userEvent.click(screen.getByTitle('Collapse'))
    expect(screen.queryByPlaceholderText('NPO 1')).toBeNull()
    await userEvent.click(screen.getByTitle('Expand'))
    expect(screen.getByPlaceholderText('NPO 1')).toBeInTheDocument()
  })

  it('creates a new group', async () => {
    renderPanel()
    await userEvent.type(screen.getByPlaceholderText('New group name'), 'Movies')
    await userEvent.click(screen.getByRole('button', { name: 'Add group' }))
    expect(api.saveGroup).toHaveBeenCalledWith(1, expect.objectContaining({ name: 'Movies' }))
  })

  it('duplicates a group at another quality: matched channels added to a new group, unmatched flagged', async () => {
    renderPanel()
    // open the duplicate-variant dialog from the group header
    await userEvent.click(screen.getByTitle(/duplicate this group/))
    // default is "in this group"; switch to a copy
    await userEvent.click(screen.getByRole('button', { name: 'Copy to a new group' }))
    // name is pre-filled "<group> UHD"
    expect(screen.getByDisplayValue('Sport UHD')).toBeInTheDocument()

    // one channel HAS a UHD variant, one does not
    ;(api.groupVariants as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      { itemId: 100, streamId: 5, name: 'NPO 1 HD', quality: 'HD', candidateStreamId: 55, candidateName: 'NPO 1 UHD', matched: true, alreadyInList: false },
      { itemId: 101, streamId: 6, name: 'BBC HD', quality: 'HD', candidateStreamId: 0, candidateName: '', matched: false, alreadyInList: false },
    ])
    await userEvent.click(screen.getByRole('button', { name: 'Find variants' }))

    // review: the matched candidate is shown, the unmatched one is flagged
    expect(await screen.findByText('NPO 1 UHD')).toBeInTheDocument()
    expect(screen.getByText(/no UHD variant found/)).toBeInTheDocument()

    // create: new group + bulk-add only the matched candidate's stream
    ;(api.saveGroup as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      id: 20, listId: 1, name: 'Sport UHD', contentType: 'live', isFavorite: false,
    })
    await userEvent.click(screen.getByRole('button', { name: 'Create group (1)' }))

    expect(api.saveGroup).toHaveBeenCalledWith(1, expect.objectContaining({ name: 'Sport UHD', contentType: 'live' }))
    await waitFor(() => expect(api.addItems).toHaveBeenCalledWith(1, [55], 20))
  })

  it('duplicates a group from another provider: matched channels added from the chosen source', async () => {
    renderPanel()
    await userEvent.click(screen.getByTitle(/duplicate this group/))
    await userEvent.click(screen.getByRole('button', { name: 'Copy to a new group' }))
    // switch to provider mode and pick the replacement source
    await userEvent.click(screen.getByRole('button', { name: 'Provider' }))
    expect(await screen.findByRole('option', { name: 'ProviderA' })).toBeInTheDocument()

    ;(api.groupProviderVariants as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      { itemId: 100, streamId: 5, name: 'NPO 1', quality: '', candidateStreamId: 77, candidateName: 'NPO 1', matched: true, alreadyInList: false },
    ])
    await userEvent.click(screen.getByRole('button', { name: 'Find variants' }))
    expect(api.groupProviderVariants).toHaveBeenCalledWith(1, 10, 1) // first source id

    ;(api.saveGroup as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      id: 30, listId: 1, name: 'Sport ProviderA', contentType: 'live', isFavorite: false,
    })
    await userEvent.click(screen.getByRole('button', { name: 'Create group (1)' }))
    await waitFor(() => expect(api.addItems).toHaveBeenCalledWith(1, [77], 30))
  })

  it('replaces RAW channels by 4K+ IN the group (default), only the ticked matches', async () => {
    renderPanel()
    await userEvent.click(screen.getByTitle(/duplicate this group/))
    // in-place is the default: no new-group name field
    expect(screen.queryByDisplayValue('Sport UHD')).not.toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Target quality'), '4K+')

    ;(api.groupVariants as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      { itemId: 100, streamId: 5, name: 'NL | NPO 1 ʀᴀᴡ', quality: 'RAW', candidateStreamId: 55, candidateName: 'NL | NPO 1 4K+', matched: true, alreadyInList: false },
      { itemId: 101, streamId: 6, name: 'NL | RTL 4 ʀᴀᴡ', quality: 'RAW', candidateStreamId: 66, candidateName: 'NL | RTL 4 4K+', matched: true, alreadyInList: false },
      { itemId: 102, streamId: 7, name: 'NL | BBC NL ʀᴀᴡ', quality: 'RAW', candidateStreamId: 0, candidateName: '', matched: false, alreadyInList: false },
    ])
    await userEvent.click(screen.getByRole('button', { name: 'Find variants' }))
    expect(api.groupVariants).toHaveBeenCalledWith(1, 10, '4K+')
    expect(await screen.findByText('NL | NPO 1 4K+')).toBeInTheDocument()
    expect(screen.getByText(/no 4K\+ variant found/)).toBeInTheDocument()

    // untick RTL 4 -> only NPO 1 is replaced
    await userEvent.click(screen.getByRole('checkbox', { name: /RTL 4/ }))
    ;(api.replaceItems as ReturnType<typeof vi.fn>).mockResolvedValueOnce({ replaced: 1 })
    await userEvent.click(screen.getByRole('button', { name: 'Replace 1 channels' }))
    await waitFor(() =>
      expect(api.replaceItems).toHaveBeenCalledWith(1, [{ itemId: 100, streamId: 55 }]),
    )
    expect(api.saveGroup).not.toHaveBeenCalled()
    expect(api.addItems).not.toHaveBeenCalled()
    expect(await screen.findByText(/Replaced 1 channels in “Sport”/)).toBeInTheDocument()
  })

  it('replaces only the channels of the chosen current quality (RAW -> HD)', async () => {
    renderPanel()
    await userEvent.click(screen.getByTitle(/duplicate this group/))
    await userEvent.selectOptions(screen.getByLabelText('Target quality'), 'HD')
    await userEvent.selectOptions(screen.getByLabelText('Only replace channels with quality'), 'RAW')

    ;(api.groupVariants as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      { itemId: 100, streamId: 5, name: 'NPO 1 RAW', quality: 'RAW', candidateStreamId: 55, candidateName: 'NPO 1 HD', matched: true, alreadyInList: false },
      { itemId: 101, streamId: 6, name: 'RTL 4 UHD', quality: 'UHD', candidateStreamId: 66, candidateName: 'RTL 4 HD', matched: true, alreadyInList: false },
    ])
    await userEvent.click(screen.getByRole('button', { name: 'Find variants' }))
    expect(await screen.findByText('NPO 1 HD')).toBeInTheDocument()
    // the UHD channel is not offered (and so never replaced)
    expect(screen.queryByText('RTL 4 HD')).not.toBeInTheDocument()
    expect(screen.getByText(/1 other channels are left as they are/)).toBeInTheDocument()

    ;(api.replaceItems as ReturnType<typeof vi.fn>).mockResolvedValueOnce({ replaced: 1 })
    await userEvent.click(screen.getByRole('button', { name: 'Replace 1 channels' }))
    await waitFor(() =>
      expect(api.replaceItems).toHaveBeenCalledWith(1, [{ itemId: 100, streamId: 55 }]),
    )
  })

  it('cleans the names of an existing group: preview with extra tokens, then apply', async () => {
    const restrip = api.restripGroup as ReturnType<typeof vi.fn>
    restrip.mockResolvedValueOnce([]) // initial preview (source rules only): nothing
    renderPanel()
    await userEvent.click(screen.getByTitle(/Strip prefixes\/suffixes from the channel names/))
    expect(await screen.findByText(/Nothing to strip/)).toBeInTheDocument()
    expect(restrip).toHaveBeenCalledWith(1, 10, { extraPrefixes: [], extraSuffixes: [], dryRun: true })

    await userEvent.type(screen.getByLabelText('Extra prefixes'), 'NL |')
    await userEvent.type(screen.getByLabelText('Extra suffixes'), '(S); rec')
    restrip.mockResolvedValueOnce([
      { itemId: 100, oldName: 'NL | HISTORY HD (S)', newName: 'HISTORY HD', original: 'NL | HISTORY HD (S)' },
    ])
    await userEvent.click(screen.getByRole('button', { name: 'Preview' }))
    expect(await screen.findByText('HISTORY HD')).toBeInTheDocument()
    expect(restrip).toHaveBeenLastCalledWith(1, 10, {
      extraPrefixes: ['NL |'], extraSuffixes: ['(S)', 'rec'], dryRun: true,
    })

    restrip.mockResolvedValueOnce([
      { itemId: 100, oldName: 'NL | HISTORY HD (S)', newName: 'HISTORY HD', original: 'NL | HISTORY HD (S)' },
    ])
    await userEvent.click(screen.getByRole('button', { name: 'Apply (1)' }))
    await waitFor(() =>
      expect(restrip).toHaveBeenLastCalledWith(1, 10, {
        extraPrefixes: ['NL |'], extraSuffixes: ['(S)', 'rec'], dryRun: false,
      }),
    )
    expect(await screen.findByText(/Cleaned 1 channel names in “Sport”/)).toBeInTheDocument()
  })

  it('shows the original upstream name (with prefix/suffix) under a stripped display name', () => {
    renderPanel({
      items: [
        {
          id: 100, listId: 1, streamItemId: 5, customGroupId: 10, contentType: 'live',
          displayName: 'HISTORY ʀᴀᴡ', channelNumber: 0, streamName: 'NL | HISTORY ʀᴀᴡ (S)',
        },
      ],
    })
    expect(screen.getByDisplayValue('HISTORY ʀᴀᴡ')).toBeInTheDocument()
    expect(screen.getByText('NL | HISTORY ʀᴀᴡ (S)')).toBeInTheDocument()
  })

  it('saves an item edit (display name) via its Save', async () => {
    renderPanel()
    const dn = screen.getByPlaceholderText('NPO 1') // display-name input (placeholder = upstream name)
    await userEvent.type(dn, 'Renamed')
    const row = dn.closest('li') as HTMLElement
    await userEvent.click(within(row).getByRole('button', { name: 'Save' }))
    expect(api.saveItem).toHaveBeenCalledWith(1, expect.objectContaining({ id: 100, displayName: 'Renamed' }))
  })

  it('sets a per-channel tvg-id override and saves it', async () => {
    renderPanel()
    // the channel has no upstream tvg-id, so the picker shows the fallback placeholder
    const tvg = screen.getByPlaceholderText('tvg-id (EPG)')
    await userEvent.type(tvg, 'npo1.nl')
    const row = tvg.closest('li') as HTMLElement
    await userEvent.click(within(row).getByRole('button', { name: 'Save' }))
    expect(api.saveItem).toHaveBeenCalledWith(1, expect.objectContaining({ id: 100, tvgIdOverride: 'npo1.nl' }))
  })

  it('does not carry a pending "Confirm empty" (upstream group) or messages over to another list', async () => {
    const lists: CustomList[] = [
      ...LISTS,
      { id: 2, name: 'L2', outputUsername: 'b', outputPassword: 'b', enabled: true },
    ]
    const upstream: CustomItem[] = [{ ...ITEMS[0], customGroupId: 0 }]
    const { rerender } = renderPanel({ lists, items: upstream })
    await userEvent.click(screen.getByRole('button', { name: 'Dedupe' }))
    expect(await screen.findByText(/3 duplicates removed/)).toBeInTheDocument()
    await userEvent.click(screen.getByTitle('Remove all channels from the upstream group'))
    expect(screen.getByRole('button', { name: 'Confirm empty' })).toBeInTheDocument()
    rerender(
      <ListPanel
        lists={lists}
        sources={SOURCES}
        activeListId={2}
        onSelectList={() => {}}
        groups={[]}
        items={[{ ...upstream[0], id: 200, listId: 2 }]}
        loading={false}
        error={null}
        onRefresh={() => {}}
      />,
    )
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Confirm empty' })).toBeNull())
    expect(screen.queryByText(/3 duplicates removed/)).toBeNull()
    expect(api.clearGroupItems).not.toHaveBeenCalled()
  })

  it('offers every backend quality tier (incl. QHD and 2K) as a variant target', async () => {
    renderPanel()
    await userEvent.click(screen.getByTitle(/duplicate this group/))
    const select = screen.getByLabelText('Target quality') as HTMLSelectElement
    const values = [...select.options].map((o) => o.value)
    expect(values).toEqual(['SD', 'HD', 'FHD', '2K', 'QHD', 'UHD', '4K', '4K+', '8K', '8K+', 'RAW'])
  })
})


describe('ListPanel — mirror bouquet', () => {
  const WITH_MIRROR: CustomList[] = [
    ...LISTS,
    { id: 2, name: 'Kids', outputUsername: 'k', outputPassword: 'k', enabled: true, mirrorOfListId: 1 },
  ]

  it('shows a notice instead of the editor and opens the master', async () => {
    const onSelectList = vi.fn()
    renderPanel({ lists: WITH_MIRROR, activeListId: 2, groups: [], items: [], onSelectList })
    expect(screen.getByText(/This bouquet mirrors “L”/)).toBeInTheDocument()
    // no bouquet editing controls for a mirror
    expect(screen.queryByPlaceholderText('New group name')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Renumber bouquet' })).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: 'Open “L”' }))
    expect(onSelectList).toHaveBeenCalledWith(1)
  })

  it('the master itself keeps the normal editor', () => {
    renderPanel({ lists: WITH_MIRROR, activeListId: 1 })
    expect(screen.queryByText(/This bouquet mirrors/)).toBeNull()
    expect(screen.getByPlaceholderText('New group name')).toBeInTheDocument()
  })
})
