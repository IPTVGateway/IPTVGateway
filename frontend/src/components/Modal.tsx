import { useEffect, useRef, type ReactNode } from 'react'
import { useT } from '../i18n'

interface Props {
  title: string
  onClose: () => void
  children: ReactNode
  /** Optional footer (e.g. action buttons), rendered below the body. */
  footer?: ReactNode
  /** Wider dialog (tables). */
  wide?: boolean
}

/** Lightweight modal: click the backdrop or press Escape to close. */
export function Modal({ title, onClose, children, footer, wide }: Props) {
  const t = useT()
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])
  // close only on a click that STARTED on the backdrop: selecting text in an input
  // and releasing the mouse outside the dialog must not close it
  const downOnBackdrop = useRef(false)

  return (
    <div
      className="modal-backdrop"
      onMouseDown={(e) => {
        downOnBackdrop.current = e.target === e.currentTarget
      }}
      onClick={(e) => {
        if (downOnBackdrop.current && e.target === e.currentTarget) onClose()
        downOnBackdrop.current = false
      }}
    >
      <div className={wide ? 'modal modal-wide' : 'modal'} role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}>
        <header className="modal-head">
          <h3>{title}</h3>
          <button className="modal-close" onClick={onClose} aria-label={t('Close')}>
            ×
          </button>
        </header>
        <div className="modal-body">{children}</div>
        {footer && <footer className="modal-foot">{footer}</footer>}
      </div>
    </div>
  )
}
