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
    listSources: vi.fn().mockResolvedValue([
      { id: 7, name: 'ProvA', kind: 'xtream', url: 'http://a', enabled: true, contentTypes: ['live'] },
      { id: 8, name: 'ProvB', kind: 'm3u', url: 'http://b', enabled: true, contentTypes: ['live'] },
    ]),
    getMirrorCredentials: vi.fn().mockResolvedValue([]),
    saveMirrorCredentials: vi.fn().mockResolvedValue([]),
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

describe('SettingsView — mirror bouquets', () => {
  const MIRROR: CustomList = {
    id: 3, name: 'Kids', outputUsername: 'kids', outputPassword: 'k', enabled: true, mirrorOfListId: 1,
  }
  beforeEach(() => {
    // clearAllMocks keeps implementations: restore the defaults per test
    vi.mocked(api.saveList).mockResolvedValue({} as CustomList)
    vi.mocked(api.saveMirrorCredentials).mockResolvedValue([])
    vi.mocked(api.getMirrorCredentials).mockResolvedValue([])
  })

  it('offers only lists that are no mirror and not the list itself as master', async () => {
    render(<SettingsView lists={[...LISTS, MIRROR]} onListsChanged={() => {}} />)
    const mirrorOf = await screen.findByLabelText('Mirror of')
    const values = [...(mirrorOf as HTMLSelectElement).options].map((o) => o.value)
    // list 1 is being edited, list 3 is a mirror itself
    expect(values).toEqual(['0', '2'])
    // no account table for a normal list
    expect(screen.queryByLabelText('Username for ProvA')).toBeNull()
  })

  it('shows a credential table per source once a master is chosen and saves the list first, then the credentials', async () => {
    const order: string[] = []
    vi.mocked(api.saveList).mockImplementation(async () => {
      order.push('list')
      return {} as CustomList
    })
    vi.mocked(api.saveMirrorCredentials).mockImplementation(async () => {
      order.push('credentials')
      return []
    })
    const onChanged = vi.fn()
    render(<SettingsView lists={LISTS} onListsChanged={onChanged} />)
    await screen.findByLabelText('Name')
    await userEvent.selectOptions(screen.getByLabelText('Select list'), '2')
    await userEvent.selectOptions(screen.getByLabelText('Mirror of'), '1')
    const user = await screen.findByLabelText('Username for ProvA')
    expect(user).toHaveAttribute('placeholder', '(same as the source)')
    expect(screen.getByLabelText('Server URL for ProvB')).toBeInTheDocument()
    expect(
      screen.getByText(/Only for another account at the same provider/),
    ).toBeInTheDocument()
    await userEvent.type(user, 'u2')
    await userEvent.type(screen.getByLabelText('Password for ProvA'), 'p2')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveMirrorCredentials).toHaveBeenCalled())
    expect(api.saveList).toHaveBeenCalledWith(expect.objectContaining({ id: 2, mirrorOfListId: 1 }))
    // only sources with a value are sent; ProvB keeps the source's own account
    expect(api.saveMirrorCredentials).toHaveBeenCalledWith(2, [
      { sourceId: 7, url: '', username: 'u2', password: 'p2' },
    ])
    expect(order).toEqual(['list', 'credentials'])
    expect(onChanged).toHaveBeenCalled()
  })

  it('does not store credentials when saving the list fails', async () => {
    vi.mocked(api.saveList).mockRejectedValueOnce(new Error('400 empty the bouquet first'))
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    await screen.findByLabelText('Name')
    await userEvent.selectOptions(screen.getByLabelText('Mirror of'), '2')
    await userEvent.type(await screen.findByLabelText('Username for ProvA'), 'u2')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    expect(await screen.findByText('Refused by the server: empty the bouquet first')).toBeInTheDocument()
    expect(api.saveMirrorCredentials).not.toHaveBeenCalled()
  })

  it('loads the stored credentials of an existing mirror', async () => {
    vi.mocked(api.getMirrorCredentials).mockResolvedValue([
      { sourceId: 8, url: 'http://b2', username: 'x', password: 'y' },
    ])
    render(<SettingsView lists={[MIRROR, ...LISTS]} onListsChanged={() => {}} />)
    expect(await screen.findByLabelText('Mirror of')).toHaveValue('1')
    await waitFor(() => expect(screen.getByLabelText('Server URL for ProvB')).toHaveValue('http://b2'))
    expect(api.getMirrorCredentials).toHaveBeenCalledWith(3)
    expect(screen.getByLabelText('Username for ProvB')).toHaveValue('x')
    expect(screen.getByLabelText('Username for ProvA')).toHaveValue('')
  })

  it('a new mirror list is created first, then its credentials go to the new id', async () => {
    vi.mocked(api.saveList).mockResolvedValueOnce({
      id: 9, name: 'New', outputUsername: '', outputPassword: '', enabled: true, mirrorOfListId: 1,
    })
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    await screen.findByLabelText('Name')
    await userEvent.selectOptions(screen.getByLabelText('Select list'), 'new')
    await userEvent.type(screen.getByLabelText('Name'), 'New')
    await userEvent.selectOptions(screen.getByLabelText('Mirror of'), '1')
    await userEvent.type(await screen.findByLabelText('Server URL for ProvB'), 'http://b2')
    await userEvent.click(screen.getByRole('button', { name: 'Add list' }))
    await waitFor(() =>
      expect(api.saveMirrorCredentials).toHaveBeenCalledWith(9, [
        { sourceId: 8, url: 'http://b2', username: '' },
      ]),
    )
    expect(api.saveList).toHaveBeenCalledWith(expect.objectContaining({ name: 'New', mirrorOfListId: 1 }))
  })

  it('saving a mirror without touching its accounts never replaces them', async () => {
    vi.mocked(api.getMirrorCredentials).mockResolvedValue([
      { sourceId: 8, url: 'http://b2', username: 'x', password: '', hasPassword: true },
    ])
    render(<SettingsView lists={[MIRROR, ...LISTS]} onListsChanged={() => {}} />)
    await waitFor(() => expect(screen.getByLabelText('Server URL for ProvB')).toHaveValue('http://b2'))
    await userEvent.type(screen.getByLabelText('Name'), '2')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveList).toHaveBeenCalled())
    expect(api.saveMirrorCredentials).not.toHaveBeenCalled()
  })

  it('shows an error and never saves the accounts when loading them failed', async () => {
    vi.mocked(api.getMirrorCredentials).mockRejectedValue(new Error('500 db busy'))
    render(<SettingsView lists={[MIRROR, ...LISTS]} onListsChanged={() => {}} />)
    expect(await screen.findByText(/Could not load the provider accounts: 500 db busy/)).toBeInTheDocument()
    expect(screen.queryByLabelText('Username for ProvA')).toBeNull()
    await userEvent.type(screen.getByLabelText('Name'), '2')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveList).toHaveBeenCalled())
    expect(api.saveMirrorCredentials).not.toHaveBeenCalled()
  })

  it('keeps Save disabled while the accounts are loading', async () => {
    let resolve: (v: never[]) => void = () => {}
    vi.mocked(api.getMirrorCredentials).mockReturnValue(new Promise((r) => { resolve = r }))
    render(<SettingsView lists={[MIRROR, ...LISTS]} onListsChanged={() => {}} />)
    await userEvent.type(await screen.findByLabelText('Name'), '2')
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled()
    resolve([])
    await waitFor(() => expect(screen.getByRole('button', { name: 'Save' })).not.toBeDisabled())
  })

  it('a stored mirror password is write-only: "(unchanged)", omitted unless typed in or cleared', async () => {
    vi.mocked(api.getMirrorCredentials).mockResolvedValue([
      { sourceId: 7, url: '', username: 'a', password: '', hasPassword: true },
      { sourceId: 8, url: '', username: '', password: '', hasPassword: true },
    ])
    render(<SettingsView lists={[MIRROR, ...LISTS]} onListsChanged={() => {}} />)
    const pwA = await screen.findByLabelText('Password for ProvA')
    await waitFor(() => expect(pwA).toHaveAttribute('placeholder', '(unchanged)'))
    // edit ProvA's username only; clear ProvB's password explicitly
    await userEvent.type(screen.getByLabelText('Username for ProvA'), '2')
    await userEvent.click(screen.getByRole('button', { name: 'Clear password for ProvB' }))
    expect(screen.getByText('Will be removed on save')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveMirrorCredentials).toHaveBeenCalled())
    // ProvA keeps its stored password (no key); ProvB is now empty -> dropped
    expect(api.saveMirrorCredentials).toHaveBeenCalledWith(3, [{ sourceId: 7, url: '', username: 'a2' }])
  })

  it('a cleared password on a row that keeps a username sends clearPassword; undo keeps it', async () => {
    vi.mocked(api.getMirrorCredentials).mockResolvedValue([
      { sourceId: 7, url: '', username: 'a', password: '', hasPassword: true },
    ])
    render(<SettingsView lists={[MIRROR, ...LISTS]} onListsChanged={() => {}} />)
    await screen.findByLabelText('Password for ProvA')
    await userEvent.click(screen.getByRole('button', { name: 'Clear password for ProvA' }))
    await userEvent.click(screen.getByRole('button', { name: 'Undo removal of Password for ProvA' }))
    expect(screen.queryByText('Will be removed on save')).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: 'Clear password for ProvA' }))
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveMirrorCredentials).toHaveBeenCalled())
    expect(api.saveMirrorCredentials).toHaveBeenCalledWith(3, [
      { sourceId: 7, url: '', username: 'a', clearPassword: true },
    ])
  })

  it('a typed-then-deleted mirror password counts as untouched', async () => {
    vi.mocked(api.getMirrorCredentials).mockResolvedValue([
      { sourceId: 7, url: '', username: 'a', password: '', hasPassword: true },
    ])
    render(<SettingsView lists={[MIRROR, ...LISTS]} onListsChanged={() => {}} />)
    const pw = await screen.findByLabelText('Password for ProvA')
    await userEvent.type(screen.getByLabelText('Username for ProvA'), '2')
    await userEvent.type(pw, 'x')
    await userEvent.clear(pw)
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveMirrorCredentials).toHaveBeenCalled())
    expect(api.saveMirrorCredentials).toHaveBeenCalledWith(3, [{ sourceId: 7, url: '', username: 'a2' }])
  })

  it('after saving only the accounts the editor reloads the stored rows and is clean again', async () => {
    vi.mocked(api.getMirrorCredentials).mockResolvedValueOnce([
      { sourceId: 7, url: '', username: 'a', password: '', hasPassword: false },
    ])
    render(<SettingsView lists={[MIRROR, ...LISTS]} onListsChanged={() => {}} />)
    const pw = await screen.findByLabelText('Password for ProvA')
    await userEvent.type(pw, 'secret')
    // the backend now has the password stored
    vi.mocked(api.getMirrorCredentials).mockResolvedValue([
      { sourceId: 7, url: '', username: 'a', password: '', hasPassword: true },
    ])
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.getMirrorCredentials).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(screen.getByLabelText('Password for ProvA')).toHaveValue(''))
    expect(screen.getByLabelText('Password for ProvA')).toHaveAttribute('placeholder', '(unchanged)')
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled() // not dirty anymore
  })

  it('a list that others mirror cannot become a mirror itself', async () => {
    render(<SettingsView lists={[...LISTS, MIRROR]} onListsChanged={() => {}} />)
    expect(await screen.findByLabelText('Mirror of')).toBeDisabled()
    expect(screen.getByText(/Mirrored by “Kids”/)).toBeInTheDocument()
  })
})

describe('SettingsView — readable server errors', () => {
  it('shows a 413 on import readably', async () => {
    vi.mocked(api.importSettings).mockRejectedValueOnce(new Error('413 Request Entity Too Large'))
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    const input = document.querySelector('input[type="file"]') as HTMLInputElement
    const json = JSON.stringify({ sources: [], lists: [] })
    const file = new File([json], 'big.json', { type: 'application/json' })
    Object.defineProperty(file, 'text', { value: () => Promise.resolve(json) }) // jsdom
    await userEvent.upload(input, file)
    await userEvent.click(await screen.findByRole('button', { name: 'Replace everything' }))
    expect(await screen.findByText(/at most 64 MB per request/)).toBeInTheDocument()
  })

  it('refuses an import file over 64 MB before uploading it', async () => {
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    const input = document.querySelector('input[type="file"]') as HTMLInputElement
    const file = new File(['{}'], 'huge.json', { type: 'application/json' })
    Object.defineProperty(file, 'size', { value: 65 * 1024 * 1024 })
    await userEvent.upload(input, file)
    expect(await screen.findByText(/at most 64 MB per request/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Replace everything' })).toBeNull()
    expect(api.importSettings).not.toHaveBeenCalled()
  })

  it('shows a 400 of a settings save readably', async () => {
    vi.mocked(api.saveConfig).mockRejectedValueOnce(new Error('400 this allowedHosts change would lock out the current host'))
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    await userEvent.click(await screen.findByRole('button', { name: /Save settings/ }))
    expect(
      await screen.findByText('Refused by the server: this allowedHosts change would lock out the current host'),
    ).toBeInTheDocument()
  })

  it('the media-clients hint says empty = local network only', async () => {
    render(<SettingsView lists={LISTS} onListsChanged={() => {}} />)
    expect(await screen.findByText(/Empty = only devices on your local network\./)).toBeInTheDocument()
    expect(screen.queryByText(/Empty = every client/)).toBeNull()
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
