// Constants shared by the API client and the components (kept out of api/client
// so component tests that mock that module still see them).

/** Default sample length (s) of a quality probe. */
export const DEFAULT_PROBE_SECONDS = 8

/** What the backend shows instead of a secret query value in a URL (send it back unchanged). */
export const MASKED_SECRET = '***'
