import { useT } from '../i18n'

/** "⟲ 3d": the provider keeps an archive of this channel (catch-up / timeshift). */
export function ArchiveBadge({ days }: { days?: number }) {
  const t = useT()
  if (!days || days <= 0) return null
  return (
    <span
      className="badge archive"
      title={t('Catch-up: replay the past {n} days on boxes that support it').replace('{n}', String(days))}
    >
      ⟲ {days}d
    </span>
  )
}
