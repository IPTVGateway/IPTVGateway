import type { AccessBlock } from '../lib/errors'
import { useT } from '../i18n'

/**
 * Full-page notice when the admin API refuses this browser with a 403: no admin
 * password is set and the client is not on the local network, or the address
 * (Host) used to open the app is not allowed (DNS-rebinding guard).
 */
export function AccessBlocked({ block }: { block: AccessBlock }) {
  const t = useT()
  return (
    <div className="access-blocked" role="alert">
      <h1>{t('IPTV Gateway')}</h1>
      <h2>{t('The admin API refused this browser')}</h2>
      <p className="access-blocked-msg">{block.message}</p>
      <p>{t('What you can do:')}</p>
      <ul>
        <li>{t('Set an admin password (adminPassword in config.json, or the ADMIN_PASSWORD environment variable) and sign in with it.')}</li>
        <li>{t('Or open the app via a local-network address of the server, e.g. http://192.168.1.10:7777.')}</li>
        {block.kind !== 'lan' && (
          <li>
            {block.host
              ? t('Or add the host “{host}” to allowedHosts in config.json.').replace(
                  '{host}',
                  block.host,
                )
              : t('Or add this host name to allowedHosts in config.json.')}
          </li>
        )}
      </ul>
      <button type="button" onClick={() => window.location.reload()}>
        {t('Try again')}
      </button>
    </div>
  )
}
