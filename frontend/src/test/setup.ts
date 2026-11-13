// Vitest global setup: jest-dom matchers (toBeInTheDocument, toHaveValue, …)
// and a clean DOM/cookie between tests.
import '@testing-library/jest-dom/vitest'
import { afterEach } from 'vitest'
import { cleanup } from '@testing-library/react'

afterEach(() => {
  cleanup()
  // wipe cookies so theme tests don't bleed into each other
  document.cookie.split(';').forEach((c) => {
    const name = c.split('=')[0].trim()
    if (name) document.cookie = `${name}=; max-age=0; path=/`
  })
})
