import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { SettingsView } from './SettingsView'
import type { AppConfig, CustomList } from '../types'

vi.mock('../api/client', () => ({
  api: {
    getConfig: vi.fn(),
    saveConfig: vi.fn(),
    saveList: vi.fn().mockResolvedValue({}),
    deleteList: vi.fn().mockResolvedValue(undefined),
    exportSettings: vi.fn().mockResolvedValue({ version: 1, sources: [], lists: [] }),
    importSettings: vi.fn().mockResolvedValue({ sources: 2, lists: 1, groups: 3 }),
    plexRescan: vi.fn().mockResolvedValue({ dvrs: 1 }),
  },
}))
import { api } from '../api/client'

const CONFIG: AppConfig = {
  refreshHour: 4, refreshMinute: 0, proxyStreams: false, proxyPort: 9001,
  httpPort: 9000, publicBaseUrl: 'http://x', useHttps: false,
}
const LISTS: CustomList[] = [
  { id: 1, name: 'Box', outputUsername: 'iptv', outputPassword: 'iptv', enabled: true },
  { id: 2, name: 'Default', outputUsername: '', outputPassword: '', enabled: true },
]

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(api.getConfig).mockResolvedValue(CONFIG)
  vi.mocked(api.saveConfig).mockResolvedValue({ ...CONFIG, proxyStreams: true })
})

describe('SettingsView — service settings', () => {
  it('loads the config and saves edited settings', async () => {
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    // proxy checkbox reflects config (off)
    const proxy = await screen.findByLabelText(/Relay streams through this server/)
    expect(proxy).not.toBeChecked()
    await userEvent.click(proxy)
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    // only what the user changed is sent, so this form can't undo a change made
    // elsewhere meanwhile (e.g. the proxy toggled from the header)
    await waitFor(() => expect(api.saveConfig).toHaveBeenCalledWith({ proxyStreams: true }))
  })

  it('lets the proxy port be cleared and retyped (no snap to 1), clamped on save', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({ ...CONFIG, proxyStreams: true })
    vi.mocked(api.saveConfig).mockResolvedValue({ ...CONFIG, proxyStreams: true, proxyPort: 7778 })
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    const port = (await screen.findByLabelText('Proxy port')) as HTMLInputElement
    await userEvent.clear(port)
    expect(port.value).toBe('') // stays empty while editing
    await userEvent.type(port, '7778')
    expect(port.value).toBe('7778') // not "17778"
    await userEvent.click(screen.getByRole('button', { name: /Save settings/ }))
    await waitFor(() => expect(api.saveConfig).toHaveBeenCalledWith({ proxyPort: 7778 }))
  })

  it('a cleared proxy port falls back to the last valid value on blur', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({ ...CONFIG, proxyStreams: true })
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    const port = (await screen.findByLabelText('Proxy port')) as HTMLInputElement
    await userEvent.clear(port)
    await userEvent.tab()
    expect(port.value).toBe('9001')
  })
})

describe('SettingsView — list management', () => {
  it('focuses the first list in the picker and shows its fields', async () => {
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    // the picker selects the first list, whose name fills the editor
    expect(await screen.findByLabelText('Name')).toHaveValue('Box')
    expect(screen.getByLabelText('Select list')).toHaveValue('1')
  })

  it('switches the editor to another list via the dropdown', async () => {
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    await screen.findByLabelText('Name')
    await userEvent.selectOptions(screen.getByLabelText('Select list'), '2')
    expect(screen.getByLabelText('Name')).toHaveValue('Default')
  })

  it('creates a new list via the "New list…" picker option', async () => {
    const onChanged = vi.fn()
    render(<SettingsView lists={LISTS} onListsChanged={onChanged} />)
    await screen.findByLabelText('Name')
    await userEvent.selectOptions(screen.getByLabelText('Select list'), 'new')
    expect(screen.getByLabelText('Name')).toHaveValue('')
    await userEvent.type(screen.getByLabelText('Name'), 'Second')
    await userEvent.click(screen.getByRole('button', { name: 'Add list' }))
    await waitFor(() =>
      expect(api.saveList).toHaveBeenCalledWith(expect.objectContaining({ name: 'Second' })),
    )
    expect(onChanged).toHaveBeenCalled()
  })

  it('shows an error when creating a list fails and keeps the typed values', async () => {
    vi.mocked(api.saveList).mockRejectedValueOnce(new Error('409 name taken'))
    const onChanged = vi.fn()
    render(<SettingsView lists={LISTS} onListsChanged={onChanged} />)
    await screen.findByLabelText('Name')
    await userEvent.selectOptions(screen.getByLabelText('Select list'), 'new')
    await userEvent.type(screen.getByLabelText('Name'), 'Dup')
    await userEvent.click(screen.getByRole('button', { name: 'Add list' }))
    expect(await screen.findByText('409 name taken')).toBeInTheDocument()
    expect(screen.getByLabelText('Name')).toHaveValue('Dup')
    expect(onChanged).not.toHaveBeenCalled()
  })

  it('the list editor restarts from the server values when the list changes underneath', async () => {
    const { rerender } = render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    const name = await screen.findByLabelText('Name')
    await userEvent.type(name, ' local edit')
    // e.g. a settings import replaced the list with the same id
    rerender(
      <SettingsView lists={[{ ...LISTS[0], name: 'Imported' }, LISTS[1]]} onListsChanged={() => {}} />,
    )
    expect(screen.getByLabelText('Name')).toHaveValue('Imported')
  })

  it('deletes the selected list after confirm', async () => {
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    await screen.findByLabelText('Name')
    await userEvent.click(screen.getByRole('button', { name: 'Delete' }))
    await userEvent.click(screen.getByRole('button', { name: 'Confirm delete' }))
    expect(api.deleteList).toHaveBeenCalledWith(1)
  })
})

describe('SettingsView — export / import', () => {
  it('exports the settings bundle to a download', async () => {
    // jsdom has no object-URL API; stub it
    const createUrl = vi.fn().mockReturnValue('blob:x')
    const revokeUrl = vi.fn()
    vi.stubGlobal('URL', { createObjectURL: createUrl, revokeObjectURL: revokeUrl })
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    await userEvent.click(await screen.findByRole('button', { name: /Export to file/ }))
    await waitFor(() => expect(api.exportSettings).toHaveBeenCalled())
    expect(createUrl).toHaveBeenCalled()
    vi.unstubAllGlobals()
  })

  it('imports a chosen file after the replace confirm', async () => {
    const onChanged = vi.fn()
    render(<SettingsView lists={LISTS} onListsChanged={onChanged} />)
    const bundle = { version: 1, sources: [{ name: 'P' }], lists: [{ name: 'L' }] }
    const file = new File([JSON.stringify(bundle)], 'iptv-settings.json', { type: 'application/json' })
    // jsdom's File doesn't implement .text() reliably; stub it (browsers have it)
    Object.defineProperty(file, 'text', { value: () => Promise.resolve(JSON.stringify(bundle)) })
    // the file input is hidden inside the label; grab it from the DOM
    const input = document.querySelector('input[type="file"]') as HTMLInputElement
    await userEvent.upload(input, file)
    // a confirm step appears; commit it
    await userEvent.click(await screen.findByRole('button', { name: 'Replace everything' }))
    await waitFor(() =>
      expect(api.importSettings).toHaveBeenCalledWith(expect.objectContaining({ version: 1 })),
    )
    expect(onChanged).toHaveBeenCalled()
  })

  it('re-fetches the service config after an import', async () => {
    const onImported = vi.fn()
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} onImported={onImported} />)
    await screen.findByLabelText(/Relay streams through this server/)
    expect(api.getConfig).toHaveBeenCalledTimes(1)
    vi.mocked(api.getConfig).mockResolvedValue({ ...CONFIG, proxyStreams: true })
    const bundle = { version: 1, sources: [{ name: 'P' }], lists: [{ name: 'L' }] }
    const file = new File([JSON.stringify(bundle)], 'iptv-settings.json', { type: 'application/json' })
    Object.defineProperty(file, 'text', { value: () => Promise.resolve(JSON.stringify(bundle)) })
    const input = document.querySelector('input[type="file"]') as HTMLInputElement
    await userEvent.upload(input, file)
    await userEvent.click(await screen.findByRole('button', { name: 'Replace everything' }))
    await waitFor(() => expect(onImported).toHaveBeenCalled())
    await waitFor(() => expect(api.getConfig).toHaveBeenCalledTimes(2))
    expect(await screen.findByLabelText(/Relay streams through this server/)).toBeChecked()
  })
})
