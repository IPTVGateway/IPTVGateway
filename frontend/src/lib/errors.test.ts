import { describe, it, expect } from 'vitest'
import { ApiError, accessBlock, describeError, errorDetail, errorStatus } from './errors'

const id = (s: string) => s

describe('errors', () => {
  it('reads the status from an ApiError and from a plain "<status> <text>" Error', () => {
    expect(errorStatus(new ApiError(413, 'too big'))).toBe(413)
    expect(errorStatus(new Error('400 Port 7778 is in use'))).toBe(400)
    expect(errorStatus(new Error('boom'))).toBe(0)
    expect(errorDetail(new Error('400 Port 7778 is in use'))).toBe('Port 7778 is in use')
  })

  it('recognises the LAN and the Host guard of a 403', () => {
    expect(accessBlock(new ApiError(403, 'Without an admin password the admin API only answers the local network'))?.kind).toBe('lan')
    expect(accessBlock(new ApiError(403, 'Host "x.y" is not allowed: …'))).toMatchObject({ kind: 'host', host: 'x.y' })
    expect(accessBlock(new ApiError(500, 'Host "x" is not allowed'))).toBeNull()
  })

  it('describes 413 / 411 / 400 readably', () => {
    expect(describeError(new ApiError(413, 'Request Entity Too Large'), id)).toMatch(/at most 64 MB/)
    expect(describeError(new ApiError(411, 'Length Required'), id)).toMatch(/Content-Length/)
    expect(describeError(new ApiError(400, 'this change would lock out the current host'), id)).toBe(
      'Refused by the server: this change would lock out the current host',
    )
    expect(describeError(new Error('500 boom'), id)).toBe('500 boom')
  })
})
