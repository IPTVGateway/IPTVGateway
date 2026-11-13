import { useState, type FormEvent } from 'react'
import { api, adminAuth, UnauthorizedError } from '../api/client'
import { useT } from '../i18n'

/**
 * Simple password gate for the admin UI. The password is validated by trying an
 * authenticated /api/health; on success the parent is told we're in. The actual
 * secret lives in the backend config.json (set by whoever runs the service).
 */
export function LoginGate({ onAuthed }: { onAuthed: () => void }) {
  const t = useT()
  const [pw, setPw] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    adminAuth.set(pw)
    try {
      await api.health() // 200 = correct, 401 = wrong password
      onAuthed() // success: the password stays in adminAuth for subsequent /api calls
    } catch (err) {
      // Never leave an UNVALIDATED password in storage (it would be sent on every
      // later /api call and survive a reload). The typed value is still in `pw`
      // state, so a retry isn't lost either way.
      adminAuth.clear()
      if (err instanceof UnauthorizedError)
        setError(t('Incorrect password'))
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
        {error && <p className="error">{error}</p>}
        <button type="submit" disabled={busy || !pw}>
          {busy ? t('Checking…') : t('Log in')}
        </button>
      </form>
    </div>
  )
}
