// Writes vectors/push.json: push payloads (collective-belfry docs/push.md §4) encrypted with
// NIP-44 v2 using the device key K directly as the conversation key, with the web chat's
// nostr-tools (fixed nonces, so the ciphertext is stable):
//
//   NODE_PATH=~/agents/belfry/work/village-app/node_modules node tools/vectors/push.mjs
import { createRequire } from 'node:module'
import { writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'

const require = createRequire(path.join(process.env.NODE_PATH ?? '', 'x.js'))
const { nip44 } = require('nostr-tools')
const bytes = (label) => new Uint8Array(createHash('sha256').update(label).digest())
const K = bytes('belfry-push-test-key')
const b64 = (u) => Buffer.from(u).toString('base64')
const ev = 'e'.repeat(64)
const ada = 'a'.repeat(64)

const cases = [
  { name: 'mention', plain: { v: 1, domain: 'belfry.sh', type: 'mention', title: '#general', body: 'Ada: are you coming tonight?', channel: 'general', event: ev, from: ada, url: `https://chat.belfry.sh/#/c/general/m/${ev}` },
    expect: { channel: 'mentions', title: '#general', body: 'Ada: are you coming tonight?', open: { kind: 'channel', channel: 'general', message: ev } } },
  { name: 'reply', plain: { v: 1, domain: 'belfry.sh', type: 'reply', title: '#garden', body: 'Tomás: yes, at 10', channel: 'garden-3f9a', event: ev, from: ada, url: `https://chat.belfry.sh/#/c/garden-3f9a/m/${ev}` },
    expect: { channel: 'mentions', title: '#garden', body: 'Tomás: yes, at 10', open: { kind: 'channel', channel: 'garden-3f9a', message: ev } } },
  { name: 'dm', plain: { v: 1, domain: 'belfry.sh', type: 'dm', title: 'Belfry', body: 'New message', url: 'https://chat.belfry.sh/#/dm' },
    expect: { channel: 'dms', title: 'Belfry', body: 'New message', open: { kind: 'dms' } } },
  { name: 'announcement', plain: { v: 1, domain: 'belfry.sh', type: 'announcement', title: '📣 #general', body: 'Maya: the gate code changes on Monday', channel: 'general', event: ev, from: ada, url: `https://chat.belfry.sh/#/c/general/m/${ev}` },
    expect: { channel: 'announcements', title: '📣 #general', body: 'Maya: the gate code changes on Monday', open: { kind: 'channel', channel: 'general', message: ev } } },
  { name: 'pin', plain: { v: 1, domain: 'belfry.sh', type: 'pin', title: '📌 #garden', body: 'Joris: watering rota', channel: 'garden-3f9a', event: ev, from: ada, url: `https://chat.belfry.sh/#/c/garden-3f9a/m/${ev}` },
    expect: { channel: 'pins', title: '📌 #garden', body: 'Joris: watering rota', open: { kind: 'channel', channel: 'garden-3f9a', message: ev } } },
  { name: 'message', plain: { v: 1, domain: 'belfry.sh', type: 'message', title: '#random', body: 'Sam: pears, anyone?', channel: 'random', event: ev, from: ada, url: `https://chat.belfry.sh/#/c/random/m/${ev}` },
    expect: { channel: 'messages', title: '#random', body: 'Sam: pears, anyone?', open: { kind: 'channel', channel: 'random', message: ev } } },
  { name: 'url on another host: home', plain: { v: 1, domain: 'belfry.sh', type: 'mention', title: '#general', body: 'x', channel: 'general', event: ev, url: `https://evil.example/#/c/general/m/${ev}` },
    expect: { channel: 'mentions', title: '#general', body: 'x', open: { kind: 'home' } } },
  { name: 'another belfry: home', plain: { v: 1, domain: 'enspiral.eu', type: 'mention', title: '#general', body: 'x', channel: 'general', event: ev, url: `https://chat.enspiral.eu/#/c/general/m/${ev}` },
    expect: { channel: 'mentions', title: '#general', body: 'x', open: { kind: 'home' } } },
  { name: 'unknown version: dropped', plain: { v: 2, domain: 'belfry.sh', type: 'mention', title: 'x', body: 'y' }, expect: null },
].map((c, i) => ({ ...c, payload: nip44.v2.encrypt(JSON.stringify(c.plain), K, bytes('nonce-' + i)) }))

const out = {
  about: 'Push payloads (collective-belfry docs/push.md §4): NIP-44 v2 with the device key K (base64 of 32 bytes) used directly as the conversation key, no ECDH. data.b of the FCM message = payload. Signed in to signed_in; expect = the Android notification: its channel (dms | mentions | announcements | pins | messages), title, body, and what a tap opens (the channel at the message when url\'s host is chat.<signed-in domain> and domain matches, the conversation list for a dm, else home). null = not shown.',
  generated_by: 'tools/vectors/push.mjs with nostr-tools 2.10.4 (the web chat\'s)',
  key: b64(K),
  signed_in: 'belfry.sh',
  cases: cases.map(({ name, payload, expect }) => ({ name, payload, expect })),
  wrong_key: b64(bytes('another device')),
}
const here = path.dirname(fileURLToPath(import.meta.url))
writeFileSync(path.resolve(here, '../../vectors/push.json'), JSON.stringify(out, null, 2) + '\n')
