import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { EpgView } from './EpgView'
import type { CustomGroup, CustomItem, CustomList, EpgProgramme } from '../types'

vi.mock('../api/client', () => ({
  api: {
    listEpg: vi.fn(),
    listItems: vi.fn().mockResolvedValue([]),
    listGroups: vi.fn().mockResolvedValue([]),
    streams: vi.fn().mockResolvedValue([]),
    epg: vi.fn().mockResolvedValue([]),
    refreshEpg: vi.fn().mockResolvedValue({ started: true }),
  },
}))
import { api } from '../api/client'

const LISTS: CustomList[] = [
  { id: 1, name: 'Box', outputUsername: '', outputPassword: '', enabled: true },
]

const now = Date.now()
const PROGS: EpgProgramme[] = [
  {
    channelTvgId: 'npo1',
    startUtc: new Date(now - 10 * 60_000).toISOString(),
    stopUtc: new Date(now + 50 * 60_000).toISOString(),
    title: 'The News',
    description: 'Daily news',
    category: '',
  },
]

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(api.listEpg).mockResolvedValue(PROGS)
})

describe('EpgView', () => {
  it('defaults to the Own-list view and renders the curated guide grid', async () => {
    render(<EpgView lists={LISTS} activeListId={1} />)
    // Own list is the default mode → curated EPG fetched for the active list
    await waitFor(() => expect(api.listEpg).toHaveBeenCalledWith(1))
    expect(await screen.findByText('npo1')).toBeInTheDocument() // channel lane label
    expect(screen.getByText('The News')).toBeInTheDocument() // programme block
  })

  it('marks the currently-airing programme as live (NOW)', async () => {
    render(<EpgView lists={LISTS} activeListId={1} />)
    await screen.findByText('The News')
    expect(document.querySelector('.epg-prog-block.now')).toBeTruthy()
    expect(document.querySelector('.epg-now-line')).toBeTruthy()
  })

  it('triggers a server-side EPG re-fetch via Update EPG', async () => {
    render(<EpgView lists={LISTS} activeListId={1} />)
    await screen.findByText('The News')
    await userEvent.click(screen.getByRole('button', { name: /Update EPG/ }))
    await waitFor(() => expect(api.refreshEpg).toHaveBeenCalled())
  })

  it('switches to the Source view (per-channel) on demand', async () => {
    render(<EpgView lists={LISTS} activeListId={1} />)
    await screen.findByText('The News')
    await userEvent.click(screen.getByRole('button', { name: 'Source' }))
    await waitFor(() => expect(api.streams).toHaveBeenCalled())
  })

  it('orders the own-list lanes like the bouquet (favorite group first), unmatched lanes last A→Z', async () => {
    const prog = (id: string, title: string): EpgProgramme => ({
      channelTvgId: id,
      startUtc: new Date(now - 10 * 60_000).toISOString(),
      stopUtc: new Date(now + 50 * 60_000).toISOString(),
      title,
      description: '',
      category: '',
    })
    vi.mocked(api.listEpg).mockResolvedValue([
      prog('a.tvg', 'P-A'), prog('z.tvg', 'P-Z'), prog('m.tvg', 'P-M'),
      prog('orphan2', 'P-O2'), prog('Orphan1', 'P-O1'),
    ])
    const groups: CustomGroup[] = [
      { id: 1, listId: 1, name: 'Alpha', contentType: 'live', isFavorite: false },
      { id: 2, listId: 1, name: 'Zulu', contentType: 'live', isFavorite: true },
    ]
    const item = (id: number, gid: number, name: string, tvg: string): CustomItem => ({
      id, listId: 1, streamItemId: id, customGroupId: gid, contentType: 'live',
      displayName: name, channelNumber: 0, streamTvgId: tvg,
    })
    vi.mocked(api.listGroups).mockResolvedValue(groups)
    vi.mocked(api.listItems).mockResolvedValue([
      item(1, 1, 'Ch A', 'a.tvg'), // non-favorite group
      item(2, 2, 'Ch Z', 'z.tvg'), // favorite group → first
      item(3, 0, 'Ch M', 'm.tvg'), // upstream group → after the custom groups
    ])
    render(<EpgView lists={LISTS} activeListId={1} />)
    await screen.findByText('Ch Z')
    await waitFor(() => {
      const order = [...document.querySelectorAll('.epg-prog-block')].map((el) => el.textContent ?? '')
      const idx = (title: string) => order.findIndex((txt) => txt.includes(title))
      expect(idx('P-Z')).toBeLessThan(idx('P-A'))
      expect(idx('P-A')).toBeLessThan(idx('P-M'))
      expect(idx('P-M')).toBeLessThan(idx('P-O1'))
      expect(idx('P-O1')).toBeLessThan(idx('P-O2'))
    })
  })
})
