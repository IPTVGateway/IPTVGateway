import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QualityProbeModal, probeHints, formatResolution } from './QualityProbeModal'
import type { CustomItem, ProbeResult, StreamVariant } from '../types'

vi.mock('../api/client', () => ({
  api: {
    streamVariants: vi.fn(),
    probeStream: vi.fn(),
    replaceItems: vi.fn().mockResolvedValue({ replaced: 1 }),
  },
}))
import { api } from '../api/client'

const V = (streamId: number, name: string, quality: string, isSelf = false): StreamVariant => ({
  streamId, sourceId: 2, name, quality, tvgId: 'npo1.nl', groupTitle: 'NL', isSelf,
  matchedBy: isSelf ? 'self' : 'name', onList: false,
})

const R = (streamId: number, over: Partial<ProbeResult> = {}): ProbeResult => ({
  streamId, ok: true, error: '', container: 'mpegts', videoCodec: 'H.264', profile: 'High 4.0',
  width: 1920, height: 1080, fps: 25, interlaced: true, bitDepth: 8,
  audio: [{ codec: 'AAC', language: 'dut' }], bitrateKbps: 9800, mediaSeconds: 12,
  wallSeconds: 8, realtime: 1.5, firstByteMs: 600, redirects: 1, bytes: 1, ...over,
})

const SOURCES = [{ id: 2, name: 'ProviderB', kind: 'xtream', url: '', enabled: true, contentTypes: ['live'] }] as never

describe('QualityProbeModal', () => {
  beforeEach(() => {
    vi.mocked(api.streamVariants).mockResolvedValue([
      V(1, 'NL | NPO 1 4K+', '4K+'),
      V(2, 'NL | NPO 1 UHD', 'UHD'),
      V(3, 'NL | NPO 1 ʀᴀᴡ', 'RAW', true),
    ])
    vi.mocked(api.probeStream).mockImplementation(async (id: number) =>
      id === 1
        ? R(1, { videoCodec: 'HEVC', width: 3840, height: 2160, interlaced: false, bitrateKbps: 7100 })
        : id === 2
          ? R(2, { ok: false, error: 'HTTP 404' })
          : R(3),
    )
    vi.mocked(api.replaceItems).mockClear()
    vi.mocked(api.probeStream).mockClear()
  })

  it('measures every variant one by one and fills the table', async () => {
    render(<QualityProbeModal streamId={3} title="NPO 1" sources={SOURCES} onClose={() => {}} />)
    expect(await screen.findByText('NL | NPO 1 4K+')).toBeInTheDocument()
    await waitFor(() => expect(api.probeStream).toHaveBeenCalledTimes(3))
    // strictly sequential, in table order
    expect(vi.mocked(api.probeStream).mock.calls.map((c) => c[0])).toEqual([1, 2, 3])
    expect(await screen.findByText('3840×2160p')).toBeInTheDocument()
    expect(screen.getByText('1920×1080i')).toBeInTheDocument()
    expect(screen.getByText(/possibly upscaled/)).toBeInTheDocument()
    expect(screen.getByText(/HTTP 404/)).toBeInTheDocument()
    expect(screen.getByText('9.8 Mbps')).toBeInTheDocument()
    // no "use this" outside a list
    expect(screen.queryByText('Use this')).toBeNull()
  })

  it('swaps the list item to the chosen variant', async () => {
    const item: CustomItem = {
      id: 100, listId: 1, streamItemId: 3, customGroupId: 10, contentType: 'live',
      channelNumber: 1, streamName: 'NL | NPO 1 ʀᴀᴡ', streamSourceId: 2,
    }
    const onReplaced = vi.fn()
    const onClose = vi.fn()
    render(
      <QualityProbeModal
        streamId={3} title="NPO 1" sources={SOURCES} listId={1} item={item}
        onReplaced={onReplaced} onClose={onClose}
      />,
    )
    const buttons = await screen.findAllByText('Use this')
    expect(buttons).toHaveLength(2) // not on the current (RAW) row
    await userEvent.click(buttons[0])
    await waitFor(() =>
      expect(api.replaceItems).toHaveBeenCalledWith(1, [{ itemId: 100, streamId: 1 }]),
    )
    expect(onReplaced).toHaveBeenCalled()
    expect(onClose).toHaveBeenCalled()
  })
})

describe('probe helpers', () => {
  it('flags upscales, buffering and slow starts', () => {
    expect(probeHints(R(1, { height: 2160, bitrateKbps: 6000 }))).toContain('possibly upscaled')
    expect(probeHints(R(1, { height: 2160, bitrateKbps: 25000 }))).not.toContain('possibly upscaled')
    expect(probeHints(R(1, { realtime: 0.8 }))).toContain('slower than real time')
    expect(probeHints(R(1, { firstByteMs: 4000 }))).toContain('slow start')
    expect(probeHints(R(1))).toEqual([])
    expect(formatResolution(R(1, { bitDepth: 10, interlaced: false }))).toBe('1920×1080p 10-bit')
  })
})
