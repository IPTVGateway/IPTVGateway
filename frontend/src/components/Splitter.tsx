import { useEffect, useRef, type MouseEvent as ReactMouseEvent } from 'react'

/** A vertical drag handle between workbench columns. Reports horizontal movement
 *  (delta px) while dragging so the parent can resize the adjacent column. */
export function Splitter({ onDrag }: { onDrag: (dx: number) => void }) {
  // track a teardown for an in-progress drag so unmounting mid-drag can't leak
  // the window listeners (or fire onDrag into an unmounted tree)
  const cleanupRef = useRef<(() => void) | null>(null)
  useEffect(() => () => cleanupRef.current?.(), [])

  function onMouseDown(e: ReactMouseEvent) {
    e.preventDefault()
    let last = e.clientX
    function move(ev: globalThis.MouseEvent) {
      const dx = ev.clientX - last
      last = ev.clientX
      onDrag(dx)
    }
    function up() {
      window.removeEventListener('mousemove', move)
      window.removeEventListener('mouseup', up)
      document.body.style.cursor = ''
      document.body.style.userSelect = ''
      cleanupRef.current = null
    }
    cleanupRef.current = up
    window.addEventListener('mousemove', move)
    window.addEventListener('mouseup', up)
    document.body.style.cursor = 'col-resize'
    document.body.style.userSelect = 'none'
  }

  return <div className="col-splitter" onMouseDown={onMouseDown} role="separator" aria-orientation="vertical" />
}
