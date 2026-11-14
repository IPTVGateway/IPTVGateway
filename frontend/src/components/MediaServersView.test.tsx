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
    plexSetup: vi.fn(),
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
  it('sets the gateway up in Plex and lists the steps', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({
      ...CONFIG, plexHdhrEnabled: true, plexServerUrl: 'http://plex:32400', plexToken: '', hasPlexToken: true,
    })
    vi.mocked(api.plexSetup).mockResolvedValue({
      dvr: '7', channels: 28,
      steps: ['Plex setup: tuner registered', 'Plex setup: 28 channels mapped to the guide'],
    })
    render(<MediaServersView />)
    await userEvent.click(await screen.findByRole('button', { name: /Set up in Plex/ }))
    expect(api.plexSetup).toHaveBeenCalled()
    expect(await screen.findByText('Plex setup: 28 channels mapped to the guide')).toBeInTheDocument()
  })

  it('keeps "Set up in Plex" disabled while the HDHomeRun tuner is off', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({
      ...CONFIG, plexServerUrl: 'http://plex:32400', plexToken: '', hasPlexToken: true,
    })
    render(<MediaServersView />)
    expect(await screen.findByRole('button', { name: /Set up in Plex/ })).toBeDisabled()
  })

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

  it('never sends the write-only Plex token back unless it was typed in or cleared', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({ ...CONFIG, plexToken: '', hasPlexToken: true })
    render(<MediaServersView />)
    const token = await screen.findByLabelText(/Plex token/)
    expect(token).toHaveAttribute('placeholder', '(unchanged)')
    expect(token).toHaveValue('')
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    await waitFor(() => expect(api.saveConfig).toHaveBeenCalled())
    expect(vi.mocked(api.saveConfig).mock.calls[0][0]).not.toHaveProperty('plexToken')
    // typing sends it
    await userEvent.type(token, 'newtok')
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    await waitFor(() => expect(api.saveConfig).toHaveBeenCalledTimes(2))
    expect(vi.mocked(api.saveConfig).mock.calls[1][0]).toMatchObject({ plexToken: 'newtok' })
  })

  it('clears the stored Plex token explicitly', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({ ...CONFIG, plexToken: '', hasPlexToken: true })
    render(<MediaServersView />)
    await userEvent.click(await screen.findByRole('button', { name: 'clear' }))
    expect(screen.getByText('Will be removed on save')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    await waitFor(() => expect(api.saveConfig).toHaveBeenCalled())
    const body = vi.mocked(api.saveConfig).mock.calls[0][0]
    expect(body).toMatchObject({ clearPlexToken: true })
    expect(body).not.toHaveProperty('plexToken')
  })

  it('typing a token and deleting it again keeps the stored one', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({ ...CONFIG, plexToken: '', hasPlexToken: true })
    render(<MediaServersView />)
    const token = await screen.findByLabelText(/Plex token/)
    await userEvent.type(token, 'x')
    await userEvent.clear(token)
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    await waitFor(() => expect(api.saveConfig).toHaveBeenCalled())
    const body = vi.mocked(api.saveConfig).mock.calls[0][0]
    expect(body).not.toHaveProperty('plexToken')
    expect(body).not.toHaveProperty('clearPlexToken')
  })

  it('the Plex buttons follow the SAVED token: an unsaved one needs a save first', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({
      ...CONFIG, plexHdhrEnabled: true, plexServerUrl: 'http://plex:32400', plexToken: '', hasPlexToken: false,
    })
    vi.mocked(api.saveConfig).mockResolvedValue({
      ...CONFIG, plexHdhrEnabled: true, plexServerUrl: 'http://plex:32400', plexToken: '', hasPlexToken: true,
    })
    render(<MediaServersView />)
    const rescan = await screen.findByRole('button', { name: 'Rescan Plex' })
    expect(rescan).toBeDisabled() // nothing stored
    await userEvent.type(screen.getByLabelText(/Plex token/), 'newtok')
    expect(rescan).toBeDisabled() // typed but not saved
    expect(screen.getByText(/save first/)).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Rescan Plex' })).not.toBeDisabled())
    expect(screen.getByRole('button', { name: /Set up in Plex/ })).not.toBeDisabled()
    expect(screen.queryByText(/save first/)).toBeNull()
  })

  it('a pending token clear disables the Plex buttons until saved', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({
      ...CONFIG, plexHdhrEnabled: true, plexServerUrl: 'http://plex:32400', plexToken: '', hasPlexToken: true,
    })
    render(<MediaServersView />)
    const rescan = await screen.findByRole('button', { name: 'Rescan Plex' })
    expect(rescan).not.toBeDisabled()
    await userEvent.click(screen.getByRole('button', { name: 'clear' }))
    expect(rescan).toBeDisabled()
    await userEvent.click(screen.getByRole('button', { name: 'undo' }))
    expect(rescan).not.toBeDisabled()
  })
})
