import { useT } from '../i18n'

/**
 * A write-only secret as edited in a form. The backend never returns a stored
 * secret (only `hasPassword` / `hasPlexToken`), so the edit is one of:
 * - keep:  nothing typed (or typed and deleted again) -> omitted, the backend keeps it
 * - set:   a non-blank value typed in -> sent
 * - clear: the explicit "clear" control -> `clear…: true`, the backend removes it
 */
export interface SecretEdit {
  value: string
  clear: boolean
}

export const SECRET_KEEP: SecretEdit = { value: '', clear: false }

/** The typed value to send, or undefined when nothing (non-blank) was typed in. */
export function secretValue(e: SecretEdit): string | undefined {
  const v = e.value.trim()
  return !e.clear && v !== '' ? v : undefined
}

/** The edit differs from "keep the stored value" (typed in, or a clear pending). */
export function secretEdited(e: SecretEdit): boolean {
  return e.clear || e.value.trim() !== ''
}

/**
 * The POST fields for one secret: `{ [key]: value }` when typed in,
 * `{ [clearKey]: true }` when a clear is pending, else nothing (= keep).
 */
export function secretPayload(e: SecretEdit, key: string, clearKey: string): Record<string, unknown> {
  if (e.clear) return { [clearKey]: true }
  const v = secretValue(e)
  return v !== undefined ? { [key]: v } : {}
}

interface Props {
  edit: SecretEdit
  onChange: (e: SecretEdit) => void
  /** the backend has a stored value (enables "clear" and the "(unchanged)" hint) */
  hasStored: boolean
  /** input type: 'password' masks it */
  type?: 'password' | 'text'
  ariaLabel?: string
  /** placeholder when nothing is stored */
  placeholder?: string
  /** tooltip of the clear control */
  clearTitle: string
  /** accessible name of the clear control (defaults to its text) */
  clearAriaLabel?: string
}

/** Input for a write-only secret, with an explicit "clear" and an undo while pending. */
export function SecretField({
  edit,
  onChange,
  hasStored,
  type = 'password',
  ariaLabel,
  placeholder,
  clearTitle,
  clearAriaLabel,
}: Props) {
  const t = useT()
  if (edit.clear) {
    return (
      <span className="secret-field secret-pending">
        <span className="secret-pending-text" role="status">
          {t('Will be removed on save')}
        </span>
        <button
          type="button"
          className="secret-clear"
          // explicit name: inside a <label> the button would otherwise take the label's text
          aria-label={ariaLabel ? t('Undo removal of {field}').replace('{field}', ariaLabel) : t('undo')}
          onClick={() => onChange(SECRET_KEEP)}
        >
          {t('undo')}
        </button>
      </span>
    )
  }
  return (
    <span className="secret-field">
      <input
        type={type}
        aria-label={ariaLabel}
        value={edit.value}
        placeholder={hasStored && edit.value === '' ? t('(unchanged)') : placeholder}
        onChange={(e) => onChange({ value: e.target.value, clear: false })}
      />
      {hasStored && (
        <button
          type="button"
          className="secret-clear"
          title={clearTitle}
          aria-label={clearAriaLabel ?? t('clear')}
          onClick={() => onChange({ value: '', clear: true })}
        >
          {t('clear')}
        </button>
      )}
    </span>
  )
}
