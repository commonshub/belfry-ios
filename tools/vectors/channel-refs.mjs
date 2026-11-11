// Writes vectors/channel-refs.json with the web chat's own nostr-tools (village-app's
// node_modules), the same calls as model.ts channelRef / channelOfNaddr / plainRefs:
//
//   NODE_PATH=~/agents/belfry/work/village-app/node_modules node tools/vectors/channel-refs.mjs
import { createRequire } from 'node:module'
import { writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire(path.join(process.env.NODE_PATH ?? '', 'x.js'))
const { nip19 } = require('nostr-tools')

const relayKey = '959c24202b2b46602cf8614c4d930f571518551fbf121930b371a2ca321beddd'
const relay = 'wss://groups-relay.example.org'
const ref = (identifier, relays = [relay], kind = 39000, pubkey = relayKey) =>
  nip19.naddrEncode({ kind, pubkey, identifier, relays })

const encode = [
  { identifier: 'general', relays: [relay] },
  { identifier: 'pod-3f9a1c', relays: [relay] },
  { identifier: 'ev-20261112-ab12', relays: [relay] },
  { identifier: 'général', relays: [relay] },
  { identifier: 'general', relays: [] },
  { identifier: 'general', relays: [relay, 'wss://relay.example.org'] },
].map((c) => ({ kind: 39000, pubkey: relayKey, ...c, naddr: ref(c.identifier, c.relays) }))

// channelOfNaddr: the group id when it is a kind 39000 address, else null
const npub = nip19.npubEncode(relayKey)
const decode = [
  { naddr: ref('general'), group: 'general' },
  { naddr: ref('pod-3f9a1c', []), group: 'pod-3f9a1c' },
  { naddr: ref('my-article', [relay], 30023), group: null },
  { naddr: npub, group: null },
  { naddr: ref('general').slice(0, -1) + (ref('general').endsWith('q') ? 'p' : 'q'), group: null }, // bad checksum
]

// plainRefs(text): npub → "@…", a channel reference → "#<name>" (its id when the channel is unknown)
const groups = { general: 'General', 'pod-3f9a1c': 'Garden pod' }
const NADDR = /nostr:(naddr1[02-9ac-hj-np-z]{20,400})/g
const channelOf = (a) => { try { const d = nip19.decode(a); return d.type === 'naddr' && d.data.kind === 39000 ? d.data.identifier : undefined } catch { return undefined } }
const plainRefs = (text) => text.replace(/nostr:npub1[02-9ac-hj-np-z]+/g, '@…').replace(NADDR, (all, a) => {
  const id = channelOf(a)
  return id ? '#' + (groups[id] ?? id) : all
})
const plain = [
  `See nostr:${ref('general')} for that`,
  `nostr:${npub} moved it to nostr:${ref('pod-3f9a1c')}.`,
  `Unknown: nostr:${ref('elsewhere')}`,
  `An article nostr:${ref('my-article', [relay], 30023)} stays`,
  'No refs, a #topic only',
].map((text) => ({ text, plain: plainRefs(text) }))

const out = {
  about: 'Channel references (NIP-19 naddr of a NIP-29 group\'s kind 39000 metadata, by the relay\'s key, d = group id, relay = the groups relay; NIP-27 nostr: in text). TLVs: 0 identifier (UTF-8), 1 relay (each, UTF-8), 2 author (32 bytes), 3 kind (u32 big-endian), written in the order 3, 2, 1 (relays in order), 0 as nostr-tools does; a reader takes any order. plain: one-line previews as plainRefs does (npub → "@…", channel → "#<name>", or its id when the channel is unknown; anything else left as is). groups = the names known in the plain cases.',
  generated_by: `tools/vectors/channel-refs.mjs with nostr-tools 2.10.4 (the web chat's)`,
  groups,
  encode,
  decode,
  plain,
}
const here = path.dirname(fileURLToPath(import.meta.url))
writeFileSync(path.resolve(here, '../../vectors/channel-refs.json'), JSON.stringify(out, null, 2) + '\n')
