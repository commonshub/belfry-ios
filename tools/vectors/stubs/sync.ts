// Stub of village-app src/core/sync.ts.
export const me = () => (globalThis as any).__me as string
export const enqueue = async (target: string, t: any) => { ((globalThis as any).__enqueued ??= []).push({ target, ...t }); return 'local-x' }
export const enqueueSigned = async () => 'local-x'
export const newId = (n = 8) => '00'.repeat(n)
export const currentSigner = () => { throw new Error('no signer in the generator') }
export const flush = async () => {}
export const isLocalOnly = () => true
export const onOutbox = () => {}
export const publishNow = async () => {}
export const queryOnce = async () => []
export const signedFetch = async () => { throw new Error('no network') }
