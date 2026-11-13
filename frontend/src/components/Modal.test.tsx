import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Modal } from './Modal'

describe('Modal', () => {
  it('renders the title, body and footer', () => {
    render(
      <Modal title="My Title" onClose={() => {}} footer={<button>Done</button>}>
        <p>Body content</p>
      </Modal>,
    )
    expect(screen.getByText('My Title')).toBeInTheDocument()
    expect(screen.getByText('Body content')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Done' })).toBeInTheDocument()
  })

  it('closes on the × button', async () => {
    const onClose = vi.fn()
    render(<Modal title="T" onClose={onClose}>x</Modal>)
    await userEvent.click(screen.getByLabelText('Close'))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('closes on Escape', async () => {
    const onClose = vi.fn()
    render(<Modal title="T" onClose={onClose}>x</Modal>)
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('closes when the backdrop is clicked but not the dialog body', async () => {
    const onClose = vi.fn()
    render(<Modal title="T" onClose={onClose}><p>inside</p></Modal>)
    // clicking inside the dialog does NOT close
    await userEvent.click(screen.getByText('inside'))
    expect(onClose).not.toHaveBeenCalled()
    // clicking the backdrop DOES close
    await userEvent.click(document.querySelector('.modal-backdrop') as HTMLElement)
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
