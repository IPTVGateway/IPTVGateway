import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ArchiveBadge } from './ArchiveBadge'

describe('ArchiveBadge', () => {
  it('shows the catch-up window', () => {
    render(<ArchiveBadge days={3} />)
    expect(screen.getByText('⟲ 3d')).toBeInTheDocument()
  })
  it('renders nothing without an archive', () => {
    const { container } = render(<ArchiveBadge days={0} />)
    expect(container).toBeEmptyDOMElement()
    render(<ArchiveBadge />)
    expect(screen.queryByText(/⟲/)).toBeNull()
  })
})
