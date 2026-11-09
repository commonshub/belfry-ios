// Stub of village-app src/core/db.ts: an in-memory key-value store.
const kv = new Map<string, unknown>()
export const kvGet = async <T,>(k: string) => kv.get(k) as T | undefined
export const kvSet = async (k: string, v: unknown) => { kv.set(k, v) }
export const kvDel = async (k: string) => { kv.delete(k) }
export const db = async () => { throw new Error('no IndexedDB in the generator') }
