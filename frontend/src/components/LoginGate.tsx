import { useEffect, useState, type FormEvent } from 'react'
import { api, adminAuth, TooManyRequestsError, UnauthorizedError } from '../api/client'
import { useT } from '../i18n'

/**
 * Simple password gate for the admin UI. The password is validated by trying an
 * authenticated endpoint (/api/config — /api/health is open and would accept any
 * password); on success the parent is told we're in. The actual
 * secret lives in the backend config.json (set by whoever runs the service).
 */
const MS_PER_SECOND = 1000

export function LoginGate({
  onAuthed,
  lockedForSec = 0,
}: {
  onAuthed: () => void
  /** The backend already refused us with 429 (too many failed logins): seconds left. */
  lockedForSec?: number
}) {
  const t = useT()
  const [pw, setPw] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // seconds left of a failed-login lockout (0 = not locked); counts down each second
  const [lockLeft, setLockLeft] = useState(lockedForSec)
  useEffect(() => setLockLeft(lockedForSec), [lockedForSec])
  const locked = lockLeft > 0
  useEffect(() => {
    if (!locked) return
    const timer = setInterval(() => setLockLeft((n) => Math.max(0, n - 1)), MS_PER_SECOND)
    return () => clearInterval(timer)
  }, [locked])

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (locked) return // every request is refused (429) until the lockout ends
    setBusy(true)
    setError(null)
    adminAuth.set(pw)
    try {
      await api.getConfig() // 200 = correct, 401 = wrong password
      onAuthed() // success: the password stays in adminAuth for subsequent /api calls
    } catch (err) {
      // Never leave an UNVALIDATED password in storage (it would be sent on every
      // later /api call and survive a reload). The typed value is still in `pw`
      // state, so a retry isn't lost either way.
      adminAuth.clear()
      if (err instanceof UnauthorizedError)
        setError(t('Incorrect password'))
      else if (err instanceof TooManyRequestsError)
        setLockLeft(err.retryAfterSec)
      else
        setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="login-gate">
      <form className="login-card" onSubmit={submit}>
        <h1>{t('IPTV Gateway')}</h1>
        <p className="muted">{t('Admin access is password-protected.')}</p>
        <input
          type="password"
          autoFocus
          placeholder={t('Password')}
          value={pw}
          onChange={(e) => setPw(e.target.value)}
        />
        {locked ? (
          <p className="error" role="alert">
            {t('Too many failed logins. Try again in {n} s.').replace('{n}', String(lockLeft))}
          </p>
        ) : (
          error && <p className="error">{error}</p>
        )}
        <button type="submit" disabled={busy || !pw || locked}>
          {busy ? t('Checking…') : t('Log in')}
        </button>
      </form>
    </div>
  )
}
