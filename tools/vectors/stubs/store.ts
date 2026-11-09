// Stub of village-app src/core/store.ts: the event log is whatever the generator puts in globalThis.__events.
export type Ev = any
export const status = { online: true, relays: {}, access: 'unknown', accessReason: '' }
export const all = (_me?: string) => (globalThis as any).__events as any[]
export const addEvents = (_l: any[]) => {}
export const touch = () => {}
export const subscribe = (_l: () => void) => () => {}
export const outboxItems = () => [] as any[]
export const putOutbox = async (_o: any) => {}
export const dropOutbox = async (_id: string) => {}
export const latestCreatedAt = (_f: any) => 0
export const setStatus = (_p: any) => {}
export const setRelay = (_u: string, _s: string) => {}
export const useVersion = () => 0
