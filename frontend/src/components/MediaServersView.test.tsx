import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MediaServersView } from './MediaServersView'
import type { AppConfig, MediaGroup, MediaStatus } from '../types'

vi.mock('../api/client', () => ({
  api: {
    getConfig: vi.fn(),
    saveConfig: vi.fn(),
    mediaGroups: vi.fn(),
    mediaStatus: vi.fn(),
    listLists: vi.fn(),
    plexRescan: vi.fn().mockResolvedValue({ dvrs: 1 }),
  },
}))
import { api } from '../api/client'

const CONFIG: AppConfig = {
  refreshHour: 4, refreshMinute: 0, proxyStreams: false, proxyPort: 9001,
  httpPort: 7777, publicBaseUrl: 'http://gw:7777', useHttps: false,
  visibleGroups: [], dummyEpgEnabled: true, dummyEpgBlockMinutes: 120,
  dummyEpgHoursBack: 12, dummyEpgHoursAhead: 48,
  plexM3uEnabled: false, plexHdhrEnabled: false, plexTunerCount: 4,
}
const GROUPS: MediaGroup[] = [
  { name: 'Nederland', channels: 20 },
  { name: 'Sport', channels: 8 },
]
const STATUS: MediaStatus = { channels: 28, realEpg: 25, dummyEpg: 3 }

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(api.getConfig).mockResolvedValue(CONFIG)
  vi.mocked(api.mediaGroups).mockResolvedValue(GROUPS)
  vi.mocked(api.mediaStatus).mockResolvedValue(STATUS)
  vi.mocked(api.saveConfig).mockResolvedValue(CONFIG)
  vi.mocked(api.listLists).mockResolvedValue([
    { id: 4, name: 'Living room', enabled: true },
    { id: 6, name: 'PLEX', enabled: true },
  ] as never)
})

describe('MediaServersView', () => {
  it('picks the Plex bouquet and resets the group filter', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({ ...CONFIG, visibleGroups: ['Sport'] })
    render(<MediaServersView />)
    const sel = await screen.findByLabelText(/Bouquet for Plex/)
    await screen.findByRole('option', { name: 'PLEX' })
    await userEvent.selectOptions(sel, '6')
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    await waitFor(() =>
      expect(api.saveConfig).toHaveBeenCalledWith(
        expect.objectContaining({ plexListId: 6, visibleGroups: [] }),
      ),
    )
  })

  it('lists the groups and the filter status', async () => {
    render(<MediaServersView />)
    expect(await screen.findByLabelText(/Nederland/)).toBeInTheDocument()
    expect(screen.getByLabelText(/Sport/)).toBeInTheDocument()
    // status line reflects mediaStatus
    expect(await screen.findByText(/28 channels/)).toBeInTheDocument()
  })

  it('narrows the filter to one group and saves it', async () => {
    render(<MediaServersView />)
    // start from "all" (empty filter, everything checked); uncheck Nederland
    const nl = await screen.findByLabelText(/Nederland/)
    expect(nl).toBeChecked()
    await userEvent.click(nl)
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    await waitFor(() =>
      expect(api.saveConfig).toHaveBeenCalledWith(
        expect.objectContaining({ visibleGroups: ['Sport'] }),
      ),
    )
  })

  it('enables the tuners and persists their flags', async () => {
    render(<MediaServersView />)
    await userEvent.click(await screen.findByLabelText(/Enable M3U \+ XMLTV tuner/))
    await userEvent.click(screen.getByLabelText(/Enable HDHomeRun tuner/))
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    await waitFor(() =>
      expect(api.saveConfig).toHaveBeenCalledWith(
        expect.objectContaining({ plexM3uEnabled: true, plexHdhrEnabled: true }),
      ),
    )
  })

  it('shows copyable tuner URLs built from the base URL', async () => {
    render(<MediaServersView />)
    // discover.json + playlist.m3u + epg.xml derived from publicBaseUrl
    expect(await screen.findByText('http://gw:7777/discover.json')).toBeInTheDocument()
    expect(screen.getByText('http://gw:7777/plex/playlist.m3u')).toBeInTheDocument()
    expect(screen.getAllByText('http://gw:7777/plex/epg.xml').length).toBeGreaterThan(0)
  })

  it('copies a URL to the clipboard', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
    render(<MediaServersView />)
    await screen.findByText('http://gw:7777/discover.json')
    const copyButtons = screen.getAllByRole('button', { name: 'Copy' })
    await userEvent.click(copyButtons[0])
    expect(writeText).toHaveBeenCalledWith('http://gw:7777/discover.json')
  })
})
