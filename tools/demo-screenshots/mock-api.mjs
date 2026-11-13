// Demo backend for README screenshots: serves frontend/dist + a fake /api with
// FICTIONAL data only (no real providers, URLs or credentials).
import http from 'node:http'
import { readFileSync, existsSync } from 'node:fs'
import { join, extname } from 'node:path'

const DIST = process.argv[2]
const PORT = 7790
const now = Date.now()
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d+Z$/, '.000Z')

const sources = [
  { id: 1, name: 'Provider A', kind: 'xtream', url: 'http://provider-a.example', username: 'demo', password: '••••••',
    enabled: true, contentTypes: ['live', 'movie', 'series'], stripPrefixes: ['NL'], stripSuffixes: ['HD', 'ʀᴀᴡ'],
    lastRefreshUtc: iso(now - 3 * 3600e3), accountStatus: 'Active', expiresUtc: iso(now + 200 * 86400e3), maxConnections: 2 },
  { id: 2, name: 'Provider B', kind: 'xtream', url: 'http://provider-b.example', username: 'demo', password: '••••••',
    enabled: true, contentTypes: ['live'], stripPrefixes: ['NL'], lastRefreshUtc: iso(now - 3 * 3600e3),
    accountStatus: 'Active', expiresUtc: iso(now + 90 * 86400e3), maxConnections: 1 },
  { id: 3, name: 'Free-to-air M3U', kind: 'm3u', url: 'http://playlist.example/fta.m3u', enabled: true,
    contentTypes: ['live', 'radio'], lastRefreshUtc: iso(now - 3 * 3600e3) },
]

const groupsA = {
  'NL | GENERAL': ['NPO 1', 'NPO 2', 'NPO 3', 'RTL 4', 'RTL 5', 'SBS 6', 'RTL 7', 'Veronica', 'Net5', 'RTL 8', 'SBS 9', 'RTL Z'],
  'NL | SPORT': ['ESPN', 'ESPN 2', 'ESPN 3', 'ESPN 4', 'Ziggo Sport', 'Ziggo Sport 2', 'Eurosport 1', 'Eurosport 2'],
  'NL | DOCUMENTARY': ['Discovery', 'National Geographic', 'Nat Geo Wild', 'History', 'Animal Planet', 'BBC First'],
  'NL | MOVIES': ['Film1 Premiere', 'Film1 Action', 'Film1 Drama', 'Film1 Family'],
  'NL | KIDS': ['Nickelodeon', 'Disney Channel', 'Cartoon Network', 'Baby TV'],
  'UK | GENERAL': ['BBC One', 'BBC Two', 'ITV 1', 'Channel 4', 'Channel 5'],
}
const quals = ['HD', 'FHD', 'ʀᴀᴡ', '4K']
const categories = []
const streams = []
let sid = 1000
let cid = 1
for (const src of [1, 2]) {
  for (const [g, names] of Object.entries(groupsA)) {
    const c = { id: cid++, sourceId: src, upstreamId: String(cid), contentType: 'live', name: g, isNew: src === 2 && g.startsWith('UK') }
    categories.push(c)
    for (const n of names) {
      const qs = src === 1 ? quals.slice(0, g.includes('GENERAL') || g.includes('SPORT') ? 4 : 2) : ['HD']
      for (const q of qs) {
        streams.push({
          id: sid++, sourceId: src, contentType: 'live', name: `NL | ${n} ${q}`.replace('NL | ', g.slice(0, 5)),
          groupTitle: g, tvgId: n.toLowerCase().replace(/[^a-z0-9]+/g, '') + '.nl', categoryId: c.upstreamId,
          archiveDays: src === 2 && !g.includes('KIDS') ? 3 : q === 'ʀᴀᴡ' ? 2 : 0,
          isNew: src === 2 && g.startsWith('UK'),
        })
      }
    }
  }
}
const radioCat = { id: cid++, sourceId: 3, upstreamId: 'r1', contentType: 'radio', name: 'Radio', isNew: false }
categories.push(radioCat)
for (const n of ['NPO Radio 1', 'NPO Radio 2', 'Radio 538', 'Qmusic', 'Sky Radio'])
  streams.push({ id: sid++, sourceId: 3, contentType: 'radio', name: n, groupTitle: 'Radio', tvgId: '', categoryId: 'r1', isNew: false })

const lists = [
  { id: 1, name: 'Living room', outputUsername: 'living', outputPassword: '••••••', enabled: true },
  { id: 2, name: 'Plex', outputUsername: 'plex', outputPassword: '••••••', enabled: true },
]
const groups = [
  { id: 11, listId: 1, name: 'Nederland', contentType: 'live', isFavorite: true, sortOrder: 1 },
  { id: 12, listId: 1, name: 'Sport', contentType: 'live', isFavorite: false, sortOrder: 2 },
  { id: 13, listId: 1, name: 'Documentaries', contentType: 'live', isFavorite: false, sortOrder: 3 },
  { id: 14, listId: 1, name: 'Movies', contentType: 'live', isFavorite: false, sortOrder: 4 },
]
const pick = (grp, src, q) => streams.filter((s) => s.groupTitle === grp && s.sourceId === src && s.name.endsWith(' ' + q))
const items = []
let iid = 1
const addGroup = (gid, base, list) => list.forEach((s, i) => {
  const clean = s.name.replace(/^NL \| /, '').replace(/ (HD|FHD|ʀᴀᴡ|4K)$/, '')
  items.push({ id: iid++, listId: 1, streamItemId: s.id, customGroupId: gid, contentType: 'live', displayName: clean,
    channelNumber: base + i, streamName: s.name, streamTvgId: s.tvgId, streamSourceId: s.sourceId, streamArchiveDays: s.archiveDays })
})
addGroup(11, 100, pick('NL | GENERAL', 2, 'HD'))
addGroup(12, 200, pick('NL | SPORT', 1, 'FHD'))
addGroup(13, 300, pick('NL | DOCUMENTARY', 2, 'HD'))
addGroup(14, 400, pick('NL | MOVIES', 1, 'HD'))

const titles = ['News', 'Weather', 'Talk show', 'Documentary', 'Quiz', 'Drama series', 'Live football', 'Film', 'Late news', 'Cooking']
function epgFor(tvg, seed = 0) {
  const out = []
  const start = Math.floor((now - 3 * 3600e3) / 1800e3) * 1800e3
  let t = start, k = seed
  while (t < now + 9 * 3600e3) {
    const len = [30, 60, 90, 45, 120][k % 5] * 60e3
    out.push({ channelTvgId: tvg, startUtc: iso(t), stopUtc: iso(t + len), title: titles[k % titles.length],
      description: 'Example programme description.', category: '' })
    t += len; k += 3
  }
  return out
}

const config = {
  refreshHour: 3, refreshMinute: 0, epgMaxDays: 7, proxyStreams: false, proxyPort: 7778, streamFailover: false,
  plexM3uEnabled: false, plexHdhrEnabled: true, plexHdhrProxy: false, plexTunerCount: 2, plexListId: 2,
  plexServerUrl: 'http://192.168.1.10:32400', plexToken: '', visibleGroups: [], publicBaseUrl: 'http://192.168.1.50:7777',
  dummyEpgEnabled: true, dummyEpgBlockMinutes: 60, dummyEpgHoursBack: 6, dummyEpgHoursAhead: 48,
  nameShowGroup: false, nameShowNumber: false, nameShowSource: false, idSortPrefix: true,
  httpPort: 7777, useHttps: false, plexDeviceId: '1A2B3C4D',
}

const variantsOf = (id) => {
  const s = streams.find((x) => x.id === id)
  if (!s) return []
  const base = s.name.replace(/ (HD|FHD|ʀᴀᴡ|4K)$/, '')
  return streams.filter((x) => x.name.replace(/ (HD|FHD|ʀᴀᴡ|4K)$/, '') === base && x.groupTitle === s.groupTitle)
    .map((x) => ({ streamId: x.id, sourceId: x.sourceId, name: x.name, quality: x.name.split(' ').pop(), tvgId: x.tvgId,
      groupTitle: x.groupTitle, isSelf: x.id === id, matchedBy: x.id === id ? 'self' : 'name', onList: items.some((i) => i.streamItemId === x.id) }))
}
const probe = (id) => {
  const s = streams.find((x) => x.id === id)
  const q = s?.name.split(' ').pop()
  const m = {
    '4K': { videoCodec: 'HEVC', profile: 'Main 10', width: 3840, height: 2160, fps: 50, interlaced: false, bitDepth: 10, bitrateKbps: 15800 },
    'ʀᴀᴡ': { videoCodec: 'H.264', profile: 'High 4.0', width: 1920, height: 1080, fps: 25, interlaced: true, bitDepth: 8, bitrateKbps: 9400 },
    FHD: { videoCodec: 'H.264', profile: 'High 4.2', width: 1920, height: 1080, fps: 50, interlaced: false, bitDepth: 8, bitrateKbps: 7900 },
    HD: { videoCodec: 'H.264', profile: 'Main 3.1', width: 1280, height: 720, fps: 50, interlaced: false, bitDepth: 8, bitrateKbps: 3100 },
  }[q] ?? {}
  return { streamId: id, ok: true, error: '', container: 'mpegts', audio: [{ codec: 'AAC', language: 'dut' }, { codec: 'AC-3', language: 'eng' }],
    mediaSeconds: 10.2, wallSeconds: 8, realtime: 1.3, firstByteMs: 420, redirects: 1, bytes: 9e6, ...m }
}

function api(path, q, method) {
  const p = path.replace(/^\/api/, '')
  let m
  if (p === '/health') return { status: 'ok', version: '1.2.26', hasApp: true }
  if (p === '/sources') return sources
  if (p === '/refresh/status') return sources.map((s) => ({ sourceId: s.id, running: false, startedUtc: s.lastRefreshUtc,
    finishedUtc: s.lastRefreshUtc, streams: streams.filter((x) => x.sourceId === s.id).length,
    categories: categories.filter((c) => c.sourceId === s.id).length, programmes: 1840, error: '' }))
  if (p === '/languages') return []
  if (p === '/catalog/categories') return categories.filter((c) => (!q.get('sourceId') || c.sourceId === +q.get('sourceId')) && (!q.get('type') || c.contentType === q.get('type')))
  const filt = () => streams.filter((s) =>
    (!q.get('sourceId') || s.sourceId === +q.get('sourceId')) && (!q.get('type') || s.contentType === q.get('type')) &&
    (!q.get('category') || s.categoryId === q.get('category')) && (!q.get('onlyNew') || s.isNew) &&
    (!q.get('search') || s.name.toLowerCase().includes(q.get('search').toLowerCase())))
  if (p === '/catalog/streams/count') return { count: filt().length }
  if (p === '/catalog/streams') { const off = +(q.get('offset') || 0); return filt().slice(off, off + +(q.get('limit') || 200)) }
  if ((m = p.match(/^\/catalog\/streams\/(\d+)\/variants$/))) return variantsOf(+m[1])
  if ((m = p.match(/^\/catalog\/streams\/(\d+)\/probe$/))) return probe(+m[1])
  if ((m = p.match(/^\/sources\/(\d+)\/prefixes$/))) return [{ prefix: 'NL |', count: 412 }, { prefix: 'UK |', count: 96 }, { prefix: 'DE |', count: 88 }]
  if (p === '/tvg-ids') return [...new Set(streams.map((s) => s.tvgId).filter(Boolean))].map((t) => ({ tvgId: t, name: t }))
  if (p === '/lists') return lists
  if ((m = p.match(/^\/lists\/(\d+)\/groups$/))) return groups.filter((g) => g.listId === +m[1])
  if ((m = p.match(/^\/lists\/(\d+)\/items$/))) return items.filter((i) => i.listId === +m[1])
  if ((m = p.match(/^\/lists\/(\d+)\/epg$/))) return items.filter((i) => i.listId === +m[1]).flatMap((i, k) => epgFor(i.streamTvgId, k))
  if (p === '/epg') return epgFor(q.get('tvgId') || 'x', 2)
  if (p === '/config') return config
  if (p === '/media/groups') return groups.map((g) => ({ name: g.name, channels: items.filter((i) => i.customGroupId === g.id).length }))
  if (p === '/media/status') return { channels: items.length, realEpg: items.length - 3, dummyEpg: 3 }
  if (p === '/plex/status') return { pending: false, enabled: true, configured: true }
  return method === 'GET' ? [] : {}
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' }
http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x')
  if (u.pathname.startsWith('/api/')) {
    const body = JSON.stringify(api(u.pathname, u.searchParams, req.method))
    res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(body); return
  }
  let f = join(DIST, u.pathname === '/' ? 'index.html' : u.pathname)
  if (!existsSync(f)) f = join(DIST, 'index.html')
  res.writeHead(200, { 'Content-Type': MIME[extname(f)] || 'application/octet-stream' })
  res.end(readFileSync(f))
}).listen(PORT, '127.0.0.1', () => console.log('mock on ' + PORT))
