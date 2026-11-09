// The cases behind vectors/*.json, run through the web chat's own code (see build.mjs).
// Where the logic lives in a React component or in module-private state (the feed order in
// Chat.tsx, the mail-thread assignment in dm.ts, the outbox loop in sync.ts, the Markdown parser in
// markdown.tsx), it is copied here line for line and marked "copied from".
import { writeFileSync } from 'node:fs'
import path from 'node:path'
import { finalizeEvent, getEventHash, getPublicKey, nip19, nip44, verifyEvent } from 'nostr-tools'
import { sha256 } from '@noble/hashes/sha256'
import { bytesToHex, hexToBytes } from '@noble/hashes/utils'
import * as model from '@ref/core/model'
import * as dm from '@ref/core/dm'
import * as actions from '@ref/core/actions'
import * as access from '@ref/core/access'
import * as mime from '@ref/core/mime'

const outDir = process.argv[2]
const G = globalThis as any
const write = (name: string, data: unknown) =>
  writeFileSync(path.join(outDir, name), JSON.stringify(data, null, 2) + '\n')

// ---- people and events --------------------------------------------------------------------
const sk = (name: string) => sha256('belfry-vector:' + name)
const pk = (name: string) => getPublicKey(sk(name))
const KEYS = Object.fromEntries(['alice', 'bob', 'carol', 'dave', 'erin', 'zoe', 'relay', 'groups', 'bridge'].map((n) => [n, pk(n)]))
const people = Object.fromEntries(Object.entries(KEYS).map(([n, k]) => [n, { pubkey: k, secret: bytesToHex(sk(n)), npub: nip19.npubEncode(k) }]))
const T0 = 1793000000 // 2026-10-26
const id = (label: string) => bytesToHex(sha256('ev:' + label))
type E = { id: string; pubkey: string; kind: number; created_at: number; tags: string[][]; content: string; sig: string; _label: string }
const ev = (label: string, who: string, kind: number, at: number, tags: string[][] = [], content = ''): E =>
  ({ id: id(label), pubkey: KEYS[who] ?? who, kind, created_at: at, tags, content, sig: '', _label: label })
const setLog = (me: string, events: E[]) => { G.__me = KEYS[me] ?? me; G.__events = events }
const sorted = (s: Iterable<string>) => [...s].sort()
const header = (what: string) => ({
  about: what,
  generated_by: 'tools/vectors/build.mjs from the web chat (village-app, branch belfry-chat)',
  people,
})

// ---- groups.json --------------------------------------------------------------------------
{
  const events: E[] = [
    ev('general-create', 'alice', 9007, T0, [['h', 'general']]),
    ev('general-edit', 'alice', 9002, T0 + 1, [['h', 'general'], ['name', 'general'], ['about', 'Say hi']]),
    ev('general-meta', 'relay', 39000, T0 + 5, [['d', 'general'], ['name', 'General'], ['about', 'From the relay']]),
    ev('general-admins', 'relay', 39001, T0 + 5, [['d', 'general'], ['p', KEYS.carol, 'admin']]),
    ev('general-members', 'relay', 39002, T0 + 5, [['d', 'general'], ['p', KEYS.alice], ['p', KEYS.bob]]),
    ev('general-msg', 'dave', 9, T0 + 100, [['h', 'general']], 'hello'),
    ev('garden-meta', 'relay', 39000, T0 + 2, [['d', 'garden'], ['name', 'Garden'], ['about', 'Plants']]),
    ev('garden-msg', 'bob', 9, T0 + 200, [['h', 'garden']], 'tomatoes'),
    ev('quiet-meta', 'relay', 39000, T0 + 3, [['d', 'quiet'], ['name', 'Quiet']]),
    ev('pod-create', 'bob', 9007, T0 + 10, [['h', 'pod-tools-ab']]),
    ev('pod-edit', 'bob', 9002, T0 + 11, [['h', 'pod-tools-ab'], ['name', 'Tools'], ['about', 'Shared tools'], ['closed'], ['prompt', 'What would you bring?']]),
    ev('pod-announce', 'bob', 9, T0 + 12, [['h', 'garden'], ['pod', 'pod-tools-ab']], '⬡ New pod: Tools'),
    ev('pod-apply-carol', 'carol', 9021, T0 + 20, [['h', 'pod-tools-ab']], 'A drill'),
    ev('pod-apply-dave', 'dave', 9021, T0 + 21, [['h', 'pod-tools-ab']], 'A saw'),
    ev('pod-admit-dave', 'bob', 9000, T0 + 30, [['h', 'pod-tools-ab'], ['p', KEYS.dave, 'member']]),
    ev('prop-create', 'alice', 9007, T0 + 40, [['h', 'prop-rules-cd']]),
    ev('event-create', 'erin', 9007, T0 + 50, [['h', 'ws-1234']]),
    ev('event-edit', 'erin', 9002, T0 + 51, [['h', 'ws-1234'], ['name', 'Picnic'], ['about', 'Bring food']]),
    ev('open-join', 'erin', 9021, T0 + 60, [['h', 'garden']]),
    ev('leave', 'erin', 9022, T0 + 70, [['h', 'garden']]),
    ev('old-meta', 'relay', 39000, T0 + 4, [['d', 'old'], ['name', 'Old']]),
    ev('old-delete', 'alice', 9008, T0 + 80, [['h', 'old']]),
  ]
  setLog('alice', events)
  const out = model.groups().map((g) => ({
    id: g.id, name: g.name, about: g.about, created_at: g.createdAt, last_activity: g.lastActivity,
    members: sorted(g.members), admins: sorted(g.admins), type: model.channelType(g), parent: g.parent ?? null,
    closed: g.closed, prompt: g.prompt ?? null, applications: g.applications.map((a) => ({ pubkey: a.pubkey, answer: a.answer, at: a.at })),
  }))
  write('groups.json', { ...header('NIP-29 groups derived from the event log: metadata (latest per field), admins, members, type, parent, closed + applications, deletion (9008), order (general first, then latest activity).'), cases: [{ name: 'basics', me: KEYS.alice, events, expect: { groups: out } }] })
}

// ---- messages.json: deletion and media ----------------------------------------------------
{
  const url = 'https://blossom.example.org/0f3c.jpg'
  const events: E[] = [
    ev('m1', 'alice', 9, T0, [['h', 'general']], 'one'),
    ev('m2', 'bob', 9, T0 + 1, [['h', 'general']], 'two'),
    ev('m3', 'alice', 9, T0 + 2, [['h', 'general']], 'three'),
    ev('m4', 'carol', 9, T0 + 3, [['h', 'general'], ['imeta', `url ${url}`, 'm image/jpeg', 'size 1234', 'dim 640x480', 'alt beach.jpg'], ['t', 'Beach']], `look #beach\n${url}`),
    ev('m5', 'dave', 9, T0 + 4, [['h', 'garden']], 'elsewhere'),
    ev('m6', 'dave', 9, T0 + 3, [['h', 'general'], ['imeta', 'url javascript:alert(1)', 'm image/png']], 'bad media'),
    ev('del-own', 'alice', 5, T0 + 10, [['h', 'general'], ['e', id('m1')]]),
    ev('del-other', 'alice', 5, T0 + 11, [['h', 'general'], ['e', id('m2')]]),
    ev('mod-remove', 'carol', 9005, T0 + 12, [['h', 'general'], ['e', id('m3')]]),
  ]
  setLog('alice', events)
  const out = model.messages('general').map((m) => ({ id: m.ev.id, text: m.text, media: m.media, topics: m.topics }))
  write('messages.json', { ...header('A channel feed: kind 9 with the h tag, oldest first (ties by id), minus deletions (kind 5 by the same author, 9005 by a moderator); imeta media (http/https only) cut out of the text; t tags lowercased.'), cases: [{ name: 'deletion and media', me: KEYS.alice, group: 'general', events, expect: { messages: out } }] })
}

// ---- reactions.json -----------------------------------------------------------------------
{
  const m1 = id('m1')
  const events: E[] = [
    ev('m1', 'carol', 9, T0, [['h', 'general']], 'hi'),
    ev('r-alice-up', 'alice', 7, T0 + 1, [['h', 'general'], ['e', m1], ['p', KEYS.carol], ['k', '9']], '👍'),
    ev('r-bob-plus', 'bob', 7, T0 + 2, [['h', 'general'], ['e', m1], ['p', KEYS.carol], ['k', '9']], '+'),
    ev('r-carol-heart', 'carol', 7, T0 + 3, [['h', 'general'], ['e', m1], ['k', '9']], '❤️'),
    ev('r-bob-heart', 'bob', 7, T0 + 4, [['h', 'general'], ['e', m1], ['k', '9']], '❤️'),
    ev('r-dave-heart', 'dave', 7, T0 + 5, [['h', 'general'], ['e', m1], ['k', '9']], '❤️'),
    ev('r-alice-party', 'alice', 7, T0 + 6, [['h', 'general'], ['e', m1], ['k', '9']], '🎉'),
    ev('r-empty', 'erin', 7, T0 + 7, [['h', 'general'], ['e', m1], ['k', '9']], ''),
    ev('r-too-long', 'erin', 7, T0 + 8, [['h', 'general'], ['e', m1], ['k', '9']], 'this is not an emoji at all'),
    ev('r-other-group', 'erin', 7, T0 + 9, [['h', 'garden'], ['e', m1], ['k', '9']], '🔥'),
    ev('undo-alice-up', 'alice', 5, T0 + 10, [['h', 'general'], ['e', id('r-alice-up')], ['k', '7']]),
  ]
  setLog('alice', events)
  const rx = model.reactions('general')
  const out = Object.fromEntries([...rx].map(([k, list]) => [k, list.map((r) => ({ emoji: r.emoji, who: sorted(r.who), mine: r.mine?.id ?? null }))]))
  write('reactions.json', { ...header('NIP-25 reactions in a group: target = the last e tag; "+" or empty = 👍; content over 16 UTF-16 units ignored; most given first (ties keep first-seen order); mine = my reaction event (to undo it with kind 5).'), cases: [{ name: 'counts, undo, plus', me: KEYS.alice, group: 'general', events, expect: { reactions: out } }] })
}

// ---- threads.json: grouping, inline view, resurfacing ---------------------------------------
// copied from Chat.tsx Conversation(): the feed items
function feed(groupId: string) {
  const list = model.messages(groupId)
  const th = model.threadsOf(groupId)
  const joins = model.guestJoins(groupId)
  type Item = { t: 'msg'; id: string; at: number } | { t: 'join'; id: string; pubkey: string; by: string | null; at: number } | { t: 'act'; root: string; last: string; at: number }
  const items: Item[] = []
  for (const m of list) items.push({ t: 'msg', id: m.ev.id, at: m.ev.created_at })
  for (const j of joins) items.push({ t: 'join', id: j.id, pubkey: j.pubkey, by: j.by ?? null, at: j.at })
  for (const [rootId, info] of th) {
    const root = list.find((m) => m.ev.id === rootId)
    if (!root) continue
    const later = list.some((m) => m.ev.created_at > root.ev.created_at && m.ev.created_at < info.last)
    if (!later) continue
    const last = model.threadReplies(groupId, rootId).at(-1)
    if (last) items.push({ t: 'act', root: rootId, last: last.ev.id, at: info.last })
  }
  items.sort((a, b) => a.at - b.at || (a.t === 'msg' ? -1 : 1))
  return items
}
{
  const reply = (label: string, who: string, at: number, root: string, rootAuthor: string, text: string) =>
    ev(label, who, 1111, at, [['h', 'general'], ['E', id(root), '', KEYS[rootAuthor]], ['K', '9'], ['P', KEYS[rootAuthor]], ['e', id(root), '', KEYS[rootAuthor]], ['k', '9'], ['p', KEYS[rootAuthor]]], text)
  const events: E[] = [
    ev('m1', 'alice', 9, T0, [['h', 'general']], 'Who has a ladder?'),
    ev('m2', 'bob', 9, T0 + 60, [['h', 'general']], 'Lunch at noon'),
    reply('r1', 'bob', T0 + 90, 'm1', 'alice', 'I do'),
    ev('m3', 'carol', 9, T0 + 120, [['h', 'general']], 'Rain tomorrow'),
    reply('r2', 'dave', T0 + 130, 'm3', 'carol', 'Bring boots'),
    ev('guest', 'groups', 9000, T0 + 200, [['h', 'general'], ['p', KEYS.erin, 'member'], ['guest', ''], ['invited-by', KEYS.alice], ['name', 'Erin']]),
    reply('r3', 'carol', T0 + 300, 'm1', 'alice', 'Me too'),
    reply('r4', 'carol', T0 + 301, 'm1', 'alice', 'deleted later'),
    ev('del-r4', 'carol', 5, T0 + 302, [['h', 'general'], ['e', id('r4')]]),
    reply('rx', 'dave', T0 + 400, 'missing-root', 'alice', 'orphan'),
  ]
  setLog('alice', events)
  const th = model.threadsOf('general')
  const threads = Object.fromEntries([...th].map(([k, v]) => [k, { count: v.count, last: v.last, who: v.who }]))
  const replies = Object.fromEntries([...th.keys()].map((k) => [k, model.threadReplies('general', k).map((m) => m.ev.id)]))
  const case1 = { name: 'replies, resurfacing and a guest join', me: KEYS.alice, group: 'general', events, expect: { threads, replies, feed: feed('general') } }

  const many: E[] = [ev('root', 'alice', 9, T0, [['h', 'general']], 'Plan?')]
  for (let i = 1; i <= 5; i++) many.push(reply('reply' + i, i % 2 ? 'bob' : 'carol', T0 + i, 'root', 'alice', 'reply ' + i))
  setLog('alice', many)
  const all5 = model.threadReplies('general', id('root')).map((m) => m.ev.id)
  const case2 = { name: 'inline thread shows the latest 3', me: KEYS.alice, group: 'general', events: many, expect: { replies: { [id('root')]: all5 }, inline_visible: all5.slice(-3), inline_hidden_count: all5.length - 3, feed: feed('general') } }
  write('threads.json', { ...header('NIP-22 threads (kind 1111, E = root message) in a group: per-root count/last/who; replies oldest first; the feed with guest joins and resurfaced threads ("act": an older thread shows again at its latest reply when other messages came between the root and that reply). Inline: the latest 3 replies, the rest on demand.'), cases: [case1, case2] })
}

// ---- mail-threads.json ------------------------------------------------------------------------
{
  const subjects = ['Hello', 'Re: Hello', 'RE: re: Fwd: Hello', 'Fw: Hello', 'Fwd:Hello', 'AW: Termin', 'SV: Möte', 'TR: Réunion', 'WG: Termin',
    'Antw: Vraag', 'RIF: Domanda', 'R: Domanda', 'Re[2]: Hello', 'Re [3] : Hello', '  Re:  Spaces  around  ', 'Re: ', '', 'Hello Re: inside',
    'Réponse: pas un préfixe', 'Re: Fwd: Re: Budget 2027', 'Rex: not a prefix', 'Re:Re:Re:', 'Café ☕ | menu']
  const base = subjects.map((s) => ({ subject: s, base: dm.baseSubject(s), thread_key_for_ana: dm.mailThreadOf('Ana@Example.ORG', s) }))
  const newMail = ['m:ana@example.org', 'm:ana@example.org|hello', 'n:' + KEYS.bob].map((c) => ({ conv: c, is_new_mail: dm.isNewMail(c), is_mail: dm.isMail(c), address: c.startsWith('m:') ? dm.mailAddress(c) : null }))

  // copied from dm.ts: convOf (1301 part) + mailConv, over a list of messages already placed
  type M = { label: string; mine: boolean; address: string; subject: string; message_id?: string; in_reply_to?: string; references?: string }
  const msgIds = (v?: string) => (v ?? '').match(/<[^<>\s]+>/g) ?? []
  const place = (seq: M[]) => {
    const items: { messageId?: string; conv: string }[] = []
    return seq.map((m) => {
      const address = m.address.toLowerCase()
      const refs = [...msgIds(m.references), ...msgIds(m.in_reply_to)]
      let conv = dm.mailThreadOf(address, m.subject)
      outer: for (const rid of refs.reverse()) {
        for (const d of items) if (d.messageId === rid && d.conv.startsWith('m:') && dm.mailAddress(d.conv) === address) { conv = d.conv; break outer }
      }
      items.push({ messageId: m.message_id, conv })
      return { ...m, expect_conv: conv }
    })
  }
  const seq: M[] = [
    { label: 'first mail from Ana', mine: false, address: 'ana@example.org', subject: 'Hello', message_id: '<a1@example.org>' },
    { label: 'my answer (Re:)', mine: true, address: 'ana@example.org', subject: 'Re: Hello', message_id: '<b1@belfry.example>', in_reply_to: '<a1@example.org>', references: '<a1@example.org>' },
    { label: 'Ana changes the subject but answers my mail', mine: false, address: 'ana@example.org', subject: 'New subject entirely', message_id: '<a2@example.org>', in_reply_to: '<b1@belfry.example>', references: '<a1@example.org> <b1@belfry.example>' },
    { label: 'Ana answers without headers, same subject', mine: false, address: 'ana@example.org', subject: 'RE: Hello', message_id: '<a3@example.org>' },
    { label: 'Bob, same subject: another address, another thread', mine: false, address: 'bob@example.net', subject: 'Hello', message_id: '<c1@example.net>' },
    { label: 'Carol quotes Ana\'s message id: not her thread (address differs)', mine: false, address: 'carol@example.net', subject: 'Fwd: Hello', message_id: '<d1@example.net>', in_reply_to: '<a1@example.org>' },
    { label: 'Ana, a new subject without references', mine: false, address: 'ANA@example.org', subject: 'Invoice', message_id: '<a4@example.org>' },
    { label: 'references point at an unknown message: falls back to the subject', mine: false, address: 'ana@example.org', subject: 'Re: Invoice', message_id: '<a5@example.org>', references: '<unknown@x>' },
  ]
  write('mail-threads.json', {
    ...header('E-mail threads (Messages): conversation keys "m:<address>|<subject key>"; a new e-mail "m:<address>" (no "|") becomes a thread once sent; a mail joins the thread its In-Reply-To / References name (In-Reply-To first, then References from the last), only among mails with the same address, else the thread of its base subject.'),
    subjects: base, conversations: newMail, sequences: [{ name: 'Ana, Bob and Carol', messages: place(seq) }],
  })
}

// ---- mentions.json (and hashtags) -------------------------------------------------------------
{
  const npubB = nip19.npubEncode(KEYS.bob), npubC = nip19.npubEncode(KEYS.carol)
  const texts = [
    `hi nostr:${npubB}`,
    `nostr:${npubB} and nostr:${npubC} and again nostr:${npubB}`,
    `no prefix ${npubB}`,
    `nostr:npub1notavalidkeyatallxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`,
    `@Bob plain at-sign`,
    `(nostr:${npubC}).`,
  ]
  const mention_tags = texts.map((t) => ({ text: t, p_tags: actions.mentionTags(t) }))
  const skip = { text: `thanks nostr:${npubB} and nostr:${npubC}`, skip: [KEYS.bob], p_tags: actions.mentionTags(`thanks nostr:${npubB} and nostr:${npubC}`, [KEYS.bob]) }
  // copied from Chat.tsx Composer: "@" + letters before the caret opens the picker; a pick writes
  // "@Name " and on send every picked "@Name" (longest first) becomes nostr:npub…
  const query = (before: string) => { const q = /(^|\s)@([\p{L}\p{N}_.-]{0,30})$/u.exec(before); return q ? q[2] : null }
  const queries = ['@', 'hi @', 'hi @Bo', 'email@bob', 'hi @Ana-Marie.', '@@x', 'x @a b', 'hi @Zoë'].map((t) => ({ before_caret: t, query: query(t) }))
  const subst = (text: string, picked: [string, string][]) => {
    let out = text
    for (const [name, key] of [...picked].sort((a, b) => b[0].length - a[0].length)) out = out.split('@' + name).join('nostr:' + nip19.npubEncode(key))
    return out
  }
  const substitutions = [
    { text: 'hi @Bob and @Bob Smith', picked: [['Bob', KEYS.bob], ['Bob Smith', KEYS.carol]] as [string, string][] },
    { text: '@Carol, see this', picked: [['Carol', KEYS.carol]] as [string, string][] },
  ].map((c) => ({ ...c, sent: subst(c.text, c.picked) }))
  const hashtagTexts = ['#Garden party', 'a#b no', 'x #one #two #one', 'url https://x.org/#frag', '&#123;', 'ünï #Café-au-lait_2 end', '#' + 'a'.repeat(60), '(#paren)']
  const hashtags = hashtagTexts.map((t) => ({ text: t, topics: model.hashtags(t) }))
  write('mentions.json', { ...header('Mentions (NIP-27 nostr:npub… in the text → p tags, deduplicated, in order of first appearance), the composer\'s @ picker and substitution, and hashtags (NIP-24 t tags, lowercased).'), mention_tags, mention_tags_with_skip: skip, picker_queries: queries, substitutions, hashtags })
}

// ---- actions.json: the events a client publishes ------------------------------------------------
{
  setLog('alice', [])
  G.__enqueued = []
  const npubB = nip19.npubEncode(KEYS.bob)
  const cases: { action: string; args: unknown }[] = []
  const run = async (action: string, args: unknown, f: () => Promise<unknown>) => { await f(); cases.push({ action, args }) }
  const root = { id: id('m1'), pubkey: KEYS.carol, kind: 9 }
  await run('postMessage', { group: 'general', text: `Hi #Garden nostr:${npubB}`, topic: 'Plans', announce: true }, () => actions.postMessage('general', `Hi #Garden nostr:${npubB}`, [], 'Plans', true))
  await run('postMessage', { group: 'general', text: 'plain' }, () => actions.postMessage('general', 'plain', []))
  await run('postThreadReply', { group: 'general', root, text: `ok nostr:${nip19.npubEncode(KEYS.carol)} #later` }, () => actions.postThreadReply('general', root, `ok nostr:${nip19.npubEncode(KEYS.carol)} #later`, []))
  await run('react', { group: 'general', message: { id: id('m1'), pubkey: KEYS.carol }, emoji: '🎉' }, () => actions.react('general', { id: id('m1'), pubkey: KEYS.carol }, '🎉') as Promise<unknown>)
  await run('unreact', { group: 'general', reaction: id('r-alice-up') }, () => actions.react('general', { id: id('m1'), pubkey: KEYS.carol }, '🎉', { id: id('r-alice-up') }) as Promise<unknown>)
  await run('deleteMessage', { group: 'general', message: id('m1') }, () => actions.deleteMessage('general', id('m1')))
  await run('editChannel', { group: 'general', name: 'General', about: 'Say hi' }, () => actions.editChannel('general', 'General', 'Say hi'))
  await run('setInbox', { group: 'general', on: true }, () => actions.setInbox('general', true))
  await run('joinGroup', { group: 'garden' }, () => actions.joinGroup('garden'))
  await run('leaveGroup', { group: 'garden' }, () => actions.leaveGroup('garden'))
  await run('createChannel', { name: 'Book club', about: 'Monthly', id: 'book-club-0000' }, () => actions.createChannel('Book club', 'Monthly', 'book-club-0000'))
  Date.now = () => (T0 + 86400) * 1000
  await run('markSeen', { group: 'general', now: T0 + 86400 }, async () => actions.markSeen('general'))
  const out = (G.__enqueued as any[]).map((e) => ({ target: e.target, kind: e.kind, content: e.content ?? '', tags: e.tags }))
  // markSeen is one event; createChannel is two: line them up with their actions
  const grouped: unknown[] = []
  let i = 0
  for (const c of cases) {
    const n = c.action === 'createChannel' ? 2 : 1
    grouped.push({ ...c, events: out.slice(i, i + n) })
    i += n
  }
  write('actions.json', { ...header('The events a user action queues (before the client tag ["client", …] is appended and before signing). target: "groups" = the NIP-29 groups relay, "main" = the community relay.'), slug_examples: ['Book club', 'Été 2027!', '***', 'A very long channel name that goes on and on'].map((n) => ({ name: n, slug: actions.slug(n) })), cases: grouped })
}

// ---- recently-active.json and seen ------------------------------------------------------------
{
  const now = T0 + 40 * 86400
  const day = 86400
  const events: E[] = [
    ev('members', 'relay', 39002, T0, [['d', 'general'], ['p', KEYS.alice], ['p', KEYS.bob], ['p', KEYS.carol]]),
    ev('admins', 'relay', 39001, T0, [['d', 'general'], ['p', KEYS.erin]]),
    ev('alice-msg', 'alice', 9, now - day, [['h', 'general']], 'hi'),
    ev('bob-seen', 'bob', 30078, now - 2 * day, [['d', 'seen:general'], ['h', 'general']]),
    ev('bob-reply', 'bob', 1111, now - 3600, [['h', 'general'], ['E', id('alice-msg')]], 'yo'),
    ev('carol-old', 'carol', 7, now - 31 * day, [['h', 'general'], ['e', id('alice-msg')]], '👍'),
    ev('dave-msg-not-member', 'groups', 9, now - 3 * day, [['h', 'general'], ['client', 'belfry-mail']], 'a card'),
    ev('erin-seen', 'erin', 30078, now - 4 * day, [['d', 'seen:general'], ['h', 'general']]),
    ev('alice-seen', 'alice', 30078, now - 5 * day, [['d', 'seen:general'], ['h', 'general']]),
    ev('bob-seen-other', 'bob', 30078, now - day, [['d', 'seen:garden'], ['h', 'general']]),
    ev('carol-profile', 'carol', 0, now - day, [], '{"name":"Carol"}'),
  ]
  Date.now = () => now * 1000
  setLog('alice', events)
  const ra = model.recentlyActive('general')
  const open: E[] = [
    ev('x-seen', 'dave', 30078, now - day, [['d', 'seen:lobby'], ['h', 'lobby']]),
    ev('y-react', 'erin', 7, now - 2 * day, [['h', 'lobby'], ['e', id('nothing')]], '🔥'),
  ]
  setLog('alice', open)
  const ra2 = model.recentlyActive('lobby')
  setLog('alice', events)
  const mine = model.mySeen('general')
  write('recently-active.json', {
    ...header('"N active this month": who opened (kind 30078 d=seen:<channel>, h=<channel>) or wrote (9, 1111, 7) in a channel in the last 30 days, most recent first; with a member list (members + admins), only those people. mySeen = my latest seen event for the channel. A client sends its seen event at most every 6 hours per channel.'),
    cases: [
      { name: 'members only, 30 days', me: KEYS.alice, now, group: 'general', events, expect: { recently_active: ra, my_seen: mine } },
      { name: 'no member list: everyone counts', me: KEYS.alice, now, group: 'lobby', events: open, expect: { recently_active: ra2 } },
    ],
  })
}

// ---- can-admin.json ---------------------------------------------------------------------------
{
  const events: E[] = [
    ev('g1-create', 'alice', 9007, T0, [['h', 'g1']]),
    ev('g2-meta', 'relay', 39000, T0, [['d', 'g2'], ['name', 'G2']]),
    ev('g2-admins', 'relay', 39001, T0, [['d', 'g2'], ['p', KEYS.bob, 'admin']]),
  ]
  const cases = []
  for (const who of ['alice', 'bob', 'zoe', 'carol', 'dave']) {
    G.fetch = async () => ({ json: async () => ({ admins: [KEYS.zoe, 'not-a-key'], access: { relay: '', service: '', admins: [KEYS.dave], needs_admin: false, synced: true } }) })
    setLog(who, events)
    await access.loadAccessInfo()
    const gs = model.groups()
    const g = (x: string) => gs.find((y) => y.id === x)
    cases.push({ me: KEYS[who], name: who, expect: { g1: access.canAdmin(g('g1')), g2: access.canAdmin(g('g2')), unknown: access.canAdmin(g('nope')), is_community_admin: access.isAdmin() } })
  }
  write('can-admin.json', { ...header('canAdmin(channel): its own admins (the creator\'s 9007, the relay\'s 39001 p tags) or a community admin (belfry.json "admins", 64-hex keys only, or access.admins). Unknown channel: false.'), belfry_json: { admins: [KEYS.zoe, 'not-a-key'], access: { admins: [KEYS.dave] } }, events, cases })
}

// ---- outbox.json ------------------------------------------------------------------------------
{
  // copied from sync.ts flush(): the error classes and the per-relay order
  const classify = (msg: string) => {
    if (/^duplicate:/.test(msg)) return 'duplicate'
    const permanent = /^(blocked|invalid|restricted|pow|duplicate|error):/.test(msg) || /not allowed|denied|unauthori[sz]ed/i.test(msg)
    return permanent ? 'failed' : 'retry'
  }
  const messages = ['blocked: you have no pass', 'invalid: bad signature', 'restricted: not a member of this group', 'pow: difficulty 20 needed',
    'duplicate: already have this event', 'error: internal', 'auth-required: sign in first', 'timeout: the relay did not answer',
    'timeout: no connection to the relay', 'rate-limited: slow down', 'Not allowed here', 'Unauthorized', 'Access denied', 'connection closed', 'upload failed (413 too big)']
  type Item = { localId: string; target: string; created_at: number; status: 'queued' | 'failed'; tries: number; error?: string }
  const run = (items: Item[], rounds: { outcomes: Record<string, string>; retry?: string[] }[]) => {
    let box = items.map((x) => ({ ...x }))
    const log: unknown[] = []
    for (const r of rounds) {
      for (const id of r.retry ?? []) box = box.map((x) => (x.localId === id ? { ...x, status: 'queued', error: undefined } : x))
      const attempted: string[] = []
      const sent: string[] = []
      const stalled = new Set<string>()
      for (const item of [...box].sort((a, b) => a.created_at - b.created_at)) {
        if (item.status === 'failed' || stalled.has(item.target)) continue
        attempted.push(item.localId)
        const outcome = r.outcomes[item.localId] ?? 'ok'
        if (outcome === 'ok') { box = box.filter((x) => x.localId !== item.localId); sent.push(item.localId); continue }
        const c = classify(outcome)
        if (c === 'duplicate') { box = box.filter((x) => x.localId !== item.localId); sent.push(item.localId); continue }
        box = box.map((x) => (x.localId === item.localId ? { ...x, tries: x.tries + 1, status: c === 'failed' ? 'failed' : 'queued', error: outcome } : x))
        if (c !== 'failed') stalled.add(item.target)
      }
      log.push({ retry: r.retry ?? [], outcomes: r.outcomes, expect: { attempted, sent, remaining: box.map(({ localId, status, tries, error }) => ({ localId, status, tries, error: error ?? null })) } })
    }
    return log
  }
  const items: Item[] = [
    { localId: 'A', target: 'groups', created_at: T0 + 1, status: 'queued', tries: 0 },
    { localId: 'B', target: 'groups', created_at: T0 + 2, status: 'queued', tries: 0 },
    { localId: 'C', target: 'main', created_at: T0 + 3, status: 'queued', tries: 0 },
    { localId: 'D', target: 'groups', created_at: T0 + 4, status: 'queued', tries: 0 },
  ]
  const rounds = run(items, [
    { outcomes: { A: 'timeout: the relay did not answer' } },
    { outcomes: { B: 'restricted: not a member of this group' } },
    { outcomes: {} },
    { retry: ['B'], outcomes: { B: 'duplicate: already have this event' } },
  ])
  write('outbox.json', {
    ...header('The outbox: every write is saved first, then published in created_at order. Per relay ("target"), a transient error stops that relay\'s later items for this pass (order kept), other relays go on; a permanent error marks the item failed (shown with Retry) and does not block; "duplicate:" counts as sent. A pass runs on: enqueue, online, foreground, relay connected, and every 15 s while something is queued.'),
    classify: messages.map((m) => ({ message: m, result: classify(m) })),
    sequences: [{ name: 'order per relay, failures, retry, duplicate', items, rounds }],
  })
}

// ---- markdown.json ----------------------------------------------------------------------------
// copied from markdown.tsx (blocks + inline) and Topics.tsx RichText (mentions and #topics in plain text)
{
  type N = Record<string, unknown>
  const plainRich = (t: string): N[] => {
    const out: N[] = []
    const re = /nostr:(npub1[02-9ac-hj-np-z]{58})|(^|[^\p{L}\p{N}_&/])#([\p{L}\p{N}_][\p{L}\p{N}_-]{0,48})/gu
    let last = 0
    for (const m of t.matchAll(re)) {
      if (m[1]) {
        if (m.index! > last) out.push({ t: 'text', v: t.slice(last, m.index) })
        out.push({ t: 'mention', npub: m[1] })
        last = m.index! + m[0].length
      } else {
        const at = m.index! + m[2].length
        if (at > last) out.push({ t: 'text', v: t.slice(last, at) })
        out.push({ t: 'topic', name: m[3] })
        last = at + 1 + m[3].length
      }
    }
    if (last < t.length) out.push({ t: 'text', v: t.slice(last) })
    return out
  }
  const asIs = (t: string): N[] => [{ t: 'text', v: t }]
  const SAFE_URL = /^(https?:\/\/|mailto:)/i
  const inline = (text: string, plain: (t: string) => N[]): N[] => {
    const out: N[] = []
    const re = /(\*\*([^*]+)\*\*|__([^_]+)__|`([^`]+)`|~~([^~]+)~~|\[([^\]]+)\]\(([^)\s]+)\)|\*([^*\s][^*]*)\*|_([^_\s][^_]*)_|(https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"]))/g
    let last = 0
    let m: RegExpExecArray | null
    while ((m = re.exec(text))) {
      if (m.index > last) out.push(...plain(text.slice(last, m.index)))
      if (m[2] ?? m[3]) out.push({ t: 'bold', c: inline(m[2] ?? m[3], plain) })
      else if (m[4]) out.push({ t: 'code', v: m[4] })
      else if (m[5]) out.push({ t: 'strike', c: inline(m[5], plain) })
      else if (m[6] && m[7]) out.push(SAFE_URL.test(m[7]) ? { t: 'link', href: m[7], c: inline(m[6], asIs) } : { t: 'text', v: m[0] })
      else if (m[8] ?? m[9]) out.push({ t: 'italic', c: inline(m[8] ?? m[9], plain) })
      else if (m[10]) out.push({ t: 'link', href: m[10], c: [{ t: 'text', v: m[10] }] })
      last = m.index + m[0].length
    }
    if (last < text.length) out.push(...plain(text.slice(last)))
    return out
  }
  const lines = (block: string[], plain: (t: string) => N[]) => block.map((l) => inline(l, plain))
  const parse = (text: string, plain: (t: string) => N[]) => {
    const blocks: N[] = []
    const src = text.replace(/\r\n?/g, '\n').split('\n')
    let i = 0
    while (i < src.length) {
      const line = src[i]
      if (!line.trim()) { i++; continue }
      if (/^```/.test(line)) {
        const code: string[] = []
        i++
        while (i < src.length && !/^```/.test(src[i])) code.push(src[i++])
        i++
        blocks.push({ type: 'code', text: code.join('\n') })
        continue
      }
      const h = /^(#{1,3})\s+(.*)$/.exec(line)
      if (h) { blocks.push({ type: 'heading', level: h[1].length, c: inline(h[2], plain) }); i++; continue }
      if (/^\s*([-*+]|\d+[.)])\s+/.test(line)) {
        const ordered = /^\s*\d+[.)]\s+/.test(line)
        const items: string[] = []
        while (i < src.length && /^\s*([-*+]|\d+[.)])\s+/.test(src[i])) items.push(src[i++].replace(/^\s*([-*+]|\d+[.)])\s+/, ''))
        blocks.push({ type: ordered ? 'ordered_list' : 'list', items: items.map((t) => inline(t, plain)) })
        continue
      }
      if (/^>\s?/.test(line)) {
        const q: string[] = []
        while (i < src.length && /^>\s?/.test(src[i])) q.push(src[i++].replace(/^>\s?/, ''))
        blocks.push({ type: 'quote', lines: lines(q, plain) })
        continue
      }
      const p: string[] = []
      while (i < src.length && src[i].trim() && !/^(#{1,3}\s|>\s?|\s*([-*+]|\d+[.)])\s+)/.test(src[i])) p.push(src[i++])
      blocks.push({ type: 'paragraph', lines: lines(p, plain) })
    }
    return blocks
  }
  const npubB = nip19.npubEncode(KEYS.bob)
  const inputs = [
    'Hello **bold** and *it* and _it2_ and `code` and ~~gone~~',
    'Two\nlines\n\nNew paragraph',
    '# Title\n## Sub\n### Third\n#### not a heading',
    '- one\n- two\n* three\n\n1. first\n2) second',
    '> quoted\n> more\nafter',
    '```\nlet x = 1 **not bold**\n```',
    'Paragraph\n```\ncode right after a paragraph line\n```',
    'A [safe link](https://example.org/x) and [bad](javascript:alert(1)) and [mail](mailto:a@b.c)',
    'Bare https://example.org/path?q=1. And (https://example.org/x), end',
    `Hey nostr:${npubB} see #Garden and a#b and **#bold**`,
    'Snake_case_word and 2*3*4 and **unclosed',
    '__under bold__ and ***triple***',
    '\r\nWindows\r\nlines\r\n',
  ]
  write('markdown.json', {
    ...header('The Markdown subset (paragraphs with line breaks, # to ### headings, - * + and 1. 1) lists, > quotes, ``` code, **bold** __bold__, *italic* _italic_, `code`, ~~strike~~, [text](https|mailto) links, bare https links) as a neutral tree; text nodes in the chat also carry @mentions (nostr:npub…) and #topics. Never rendered as HTML: unsafe links stay literal text.'),
    cases: inputs.map((text) => ({ text, blocks: parse(text, plainRich) })),
  })
}

// ---- mime.json --------------------------------------------------------------------------------
{
  const crlf = (s: string) => s.replace(/\n/g, '\r\n')
  const mails = [
    { name: 'plain with quote', raw: crlf('From: "Ana Silva" <Ana@Example.org>\nTo: <me@example.org>\nSubject: Re: Hello\nMessage-ID: <a2@example.org>\nIn-Reply-To: <b1@example.org>\nReferences: <a1@example.org> <b1@example.org>\nContent-Type: text/plain; charset=utf-8\n\nYes, Tuesday works.\n\nOn Mon, 2 Nov 2026 at 10:00, Me <me@example.org> wrote:\n> Does Tuesday work?\n') },
    { name: 'encoded subject and quoted-printable', raw: crlf('From: =?UTF-8?B?Sm9zw6k=?= <jose@example.es>\nSubject: =?UTF-8?Q?R=C3=A9union_demain?=\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\nC=C3=A0 demain =\nmatin.\n') },
    { name: 'multipart with an attachment', raw: crlf('From: bob@example.net\nSubject: Photos\nContent-Type: multipart/mixed; boundary="XYZ"\n\n--XYZ\nContent-Type: text/plain; charset=utf-8\n\nSee attached.\n--XYZ\nContent-Type: image/png; name="dot.png"\nContent-Disposition: attachment; filename="dot.png"\nContent-Transfer-Encoding: base64\n\niVBORw0KGgo=\n--XYZ--\n') },
    { name: 'French quote header', raw: crlf('From: claire@example.fr\nSubject: Re: Atelier\nContent-Type: text/plain\n\nOui !\n\nLe lun. 2 nov. 2026, Moi a écrit :\n> On commence quand ?\n') },
  ]
  const parsed = mails.map((m) => {
    const p = mime.parseMail(m.raw)
    return { ...m, expect: { subject: p.subject, from: p.from, text: p.text, full: p.full, message_id: p.headers.get('message-id') ?? null, in_reply_to: p.headers.get('in-reply-to') ?? null, references: p.headers.get('references') ?? null, attachments: p.attachments.map((a) => ({ name: a.name, type: a.type, size: a.data.length })) } }
  })
  const addresses = ['"Ana Silva" <Ana@Example.org>', 'Bob <bob@example.net>', 'carol@example.net', '  <dave@x.org> ', 'Zoë Ünïcode <ZOE@x.org>'].map((v) => ({ value: v, ...mime.addressOf(v) }))
  write('mime.json', { ...header('Reading Nostr Mail (kind 1301 content = RFC 2822): headers (first one wins, folded lines joined), RFC 2047 words, base64 / quoted-printable, multipart, attachments; text = the new part (quoted lines and everything after an "On … wrote:" / "Le … a écrit :" / "----- Original Message -----" line dropped); addressOf.'), mails: parsed, addresses })
}

// ---- events.json: ids, signatures, bech32, gift wraps -------------------------------------------
{
  const a = sk('alice'), b = sk('bob'), br = sk('bridge')
  const tpl = { kind: 9, created_at: T0, tags: [['h', 'general'], ['client', 'belfry-ios']], content: 'Hello "world"\n\\ é 🎉' }
  const signed = finalizeEvent(tpl, a)
  const tampered = { ...signed, content: signed.content + '!' }
  const rumor = (from: Uint8Array, kind: number, tags: string[][], content: string, at: number) => {
    const r = { kind, pubkey: getPublicKey(from), created_at: at, tags, content } as any
    r.id = getEventHash(r)
    return r
  }
  const wrap = (r: any, from: Uint8Array, to: string, at: number) => {
    const seal = finalizeEvent({ kind: 13, created_at: at - 1000, tags: [], content: nip44.v2.encrypt(JSON.stringify(r), nip44.v2.utils.getConversationKey(from, to)) }, from)
    const one = sha256('one-time:' + r.id + to)
    return finalizeEvent({ kind: 1059, created_at: at - 2000, tags: [['p', to]], content: nip44.v2.encrypt(JSON.stringify(seal), nip44.v2.utils.getConversationKey(one, to)) }, one)
  }
  const dm14 = rumor(a, 14, [['p', KEYS.bob]], 'Hi Bob, a private hello', T0 + 5)
  const raw = 'From: "Ana" <ana@example.org>\r\nTo: <bob@example.org>\r\nSubject: Hello\r\nMessage-ID: <a1@example.org>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHi from e-mail\r\n'
  const mail = rumor(br, 1301, [['email-id', '6f1c2a9e-0000-4000-8000-000000000001'], ['mail-from', 'ana@example.org'], ['p', KEYS.bob], ['subject', 'Hello'], ['belfry-auth', 'pass']], raw, T0 + 6)
  const forged = rumor(a, 14, [['p', KEYS.bob]], 'pretending', T0 + 7)
  // a seal by alice that carries a rumor claiming carol's key: must be dropped
  const forgedSealed = (() => {
    const r = { ...forged, pubkey: KEYS.carol }
    r.id = getEventHash(r)
    return wrap(r, a, KEYS.bob, T0 + 7)
  })()
  write('events.json', {
    ...header('Nostr basics: event id = sha256 of [0,pubkey,created_at,kind,tags,content] serialized as compact JSON (NIP-01 escaping); BIP-340 signatures; npub/nsec (NIP-19); NIP-59 gift wraps carrying a NIP-17 message (kind 14) and a Nostr Mail (kind 1301) from the belfry\'s bridge. Unwrap: wrap (NIP-44 with the wrap\'s one-time key) → seal (kind 13, signature checked) → rumor; drop it if rumor.pubkey ≠ seal.pubkey.'),
    bech32: [{ hex: KEYS.alice, npub: nip19.npubEncode(KEYS.alice) }, { secret: bytesToHex(a), nsec: nip19.nsecEncode(a) }],
    signed: { event: signed, id_ok: getEventHash(signed) === signed.id, valid: verifyEvent(signed) },
    tampered: { event: tampered, valid: false },
    id_only: [{ template: { pubkey: KEYS.bob, ...tpl }, id: getEventHash({ pubkey: KEYS.bob, ...tpl } as any) }],
    gift_wraps: [
      { name: 'NIP-17 message from alice to bob', recipient_secret: bytesToHex(b), wrap: wrap(dm14, a, KEYS.bob, T0 + 5), expect: { rumor: dm14, seal_pubkey: KEYS.alice } },
      { name: 'e-mail from the bridge to bob', recipient_secret: bytesToHex(b), bridge: KEYS.bridge, wrap: wrap(mail, br, KEYS.bob, T0 + 6), expect: { rumor: mail, seal_pubkey: KEYS.bridge, conv: dm.mailThreadOf('ana@example.org', 'Hello') } },
      { name: 'rumor in someone else\'s name', recipient_secret: bytesToHex(b), wrap: forgedSealed, expect: { rumor: null, seal_pubkey: KEYS.alice } },
    ],
    hex_check: bytesToHex(hexToBytes(KEYS.alice)) === KEYS.alice,
  })
}
console.log('vectors written to', outDir)
