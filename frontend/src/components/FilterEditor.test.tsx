import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { FilterEditor } from './SourcesPanel'
import type { PrefixCount } from '../types'

const PREFIXES: PrefixCount[] = [
  { prefix: 'NL|', count: 1111 },
  { prefix: 'UK|', count: 1382 },
  { prefix: 'DE|', count: 1239 },
]

function setup(tokens: string[] = []) {
  const onChange = vi.fn()
  render(
    <FilterEditor
      kind="exclude"
      tokens={tokens}
      onChange={onChange}
      prefixes={PREFIXES}
      prefixBusy={false}
      editing
    />,
  )
  return { onChange }
}

describe('FilterEditor', () => {
  it('renders the discovered prefixes when editing', () => {
    setup()
    // every prefix is shown as a checkbox label
    expect(screen.getByText('NL|')).toBeInTheDocument()
    expect(screen.getByText('UK|')).toBeInTheDocument()
    expect(screen.getByText('DE|')).toBeInTheDocument()
    // counts shown
    expect(screen.getByText('1111')).toBeInTheDocument()
  })

  it('shows selected tokens as chips', () => {
    setup(['NL|'])
    const chips = document.querySelectorAll('.chip')
    expect(chips).toHaveLength(1)
    expect(chips[0].textContent).toContain('NL|')
  })

  it('ticking a prefix adds it as a token', async () => {
    const { onChange } = setup([])
    await userEvent.click(screen.getByText('UK|'))
    expect(onChange).toHaveBeenCalledWith(['UK|'])
  })

  it('removing a chip drops the token', async () => {
    const { onChange } = setup(['NL|', 'UK|'])
    const chip = [...document.querySelectorAll('.chip')].find((c) => c.textContent?.includes('NL|'))!
    await userEvent.click(within(chip as HTMLElement).getByTitle('Remove'))
    expect(onChange).toHaveBeenCalledWith(['UK|'])
  })

  it('"select all" adds every visible prefix', async () => {
    const { onChange } = setup([])
    await userEvent.click(screen.getByText('select all'))
    expect(onChange).toHaveBeenCalledWith(['NL|', 'UK|', 'DE|'])
  })

  it('search narrows the prefix list and "select all shown" only adds those', async () => {
    const { onChange } = setup([])
    await userEvent.type(screen.getByPlaceholderText(/Search 3 prefixes/), 'uk')
    expect(screen.queryByText('NL|')).not.toBeInTheDocument()
    expect(screen.getByText('UK|')).toBeInTheDocument()
    await userEvent.click(screen.getByText('select all shown'))
    expect(onChange).toHaveBeenCalledWith(['UK|'])
  })

  it('typing a custom token and pressing Enter adds it', async () => {
    const { onChange } = setup([])
    const input = screen.getByPlaceholderText('e.g. XXX, ADULT')
    await userEvent.type(input, 'ADULT{Enter}')
    expect(onChange).toHaveBeenCalledWith(['ADULT'])
  })

  it('hints to refresh when there are no discovered prefixes', () => {
    const onChange = vi.fn()
    render(
      <FilterEditor kind="include" tokens={[]} onChange={onChange} prefixes={[]} prefixBusy={false} editing />,
    )
    expect(screen.getByText(/No prefixes found/)).toBeInTheDocument()
  })

  it('hints to save first when the source is new (not editing)', () => {
    const onChange = vi.fn()
    render(
      <FilterEditor kind="include" tokens={[]} onChange={onChange} prefixes={[]} prefixBusy={false} editing={false} />,
    )
    expect(screen.getByText(/Save the source and refresh/)).toBeInTheDocument()
  })
})
