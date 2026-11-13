import { Component, type ErrorInfo, type ReactNode } from 'react'

interface Props {
  children: ReactNode
}
interface State {
  error: Error | null
}

/**
 * Catches render-time errors so one bad component (e.g. a malformed API row that
 * trips a `.map`) doesn't unmount the whole tree into a blank white page. Shows a
 * minimal recovery panel with a reload button instead.
 */
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // surface it for debugging; the UI still shows the recovery panel
    console.error('Unhandled UI error:', error, info.componentStack)
  }

  render() {
    if (this.state.error) {
      return (
        <div className="app-checking" role="alert" style={{ padding: 24, maxWidth: 640 }}>
          <h2>Something went wrong</h2>
          <p className="muted">
            The interface hit an unexpected error and couldn't render. Your data is safe — this is
            only the admin UI.
          </p>
          <pre
            style={{
              whiteSpace: 'pre-wrap',
              fontSize: 12,
              opacity: 0.8,
              maxHeight: 160,
              overflow: 'auto',
            }}
          >
            {String(this.state.error.message || this.state.error)}
          </pre>
          <button type="button" onClick={() => window.location.reload()}>
            Reload
          </button>
        </div>
      )
    }
    return this.props.children
  }
}
