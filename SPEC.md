# Belfry chat client specification

Version 0.1 (2026-11-09). Platform-neutral: what any client (iOS, Android, web) must do to be a
correct chat client for a **belfry**, a community's self-hosted server. Derived from the web chat
(the reference implementation: `village-app`, branch `belfry-chat`, files named below) and the
belfry's server code (`collective-belfry`, `services/onboarding/belfry_onboarding/`).

Conformance is checked with the shared test vectors in [`vectors/`](vectors/) (section 17).
Where the web pattern and a platform's conventions differ, section 16 lists the choice each
native app made; the protocol rules (sections 1 to 15) are the same everywhere.

Words: MUST / SHOULD / MAY as in RFC 2119. "Group" and "channel" mean the same thing (a NIP-29
group). Times are Unix seconds. Keys are 64-char lowercase hex unless written `npub…`.

Open questions are collected in section 18 and marked **(Q n)** where they arise.

---

## 1. Discovery

A client asks the person for one thing: the community's **domain** (e.g. `belfry.sh`). An app
built for one community MAY ship with its domain.

1. `GET https://<domain>/.well-known/belfry.json` (no auth; CORS open). Cache it; on failure use
   the cached copy (the app MUST open offline).
2. Endpoints, with the fallback when a field is missing (`src/config.ts`):

| What | belfry.json | Fallback |
|---|---|---|
| Community name | `name` | the domain |
| Groups relay (NIP-29) | `relays.groups` | `wss://groups-relay.<domain>` |
| Community relay | `relays.community` | `wss://relay.<domain>` |
| Signer (bunker) relays | `relays.signer[]` | `wss://bunker.<domain>` |
| File server (Blossom) | `blossom` | `https://blossom.<domain>` |
| API base (NIP-98) | `api.base` | `https://belfry.<domain>/api/v1` |
| Guest links | `api.channel_invites` | `<api base>/channel-invites` |
| Sign-in authorize | `sign_in.connect.authorize` | `https://belfry.<domain>/connect/authorize` |
| Sign-in token | `sign_in.connect.token` | `https://belfry.<domain>/connect/token` |
| Sign-in logout | `sign_in.connect.logout` | `https://belfry.<domain>/connect/logout` |
| Community admins | `admins[]` (64-hex only; drop anything else) | none |
| The chat on the web | `apps[]` entry named `Chat` → `url` | `https://<domain>/chat/` |

   Today's live documents (belfry.sh, enspiral.eu) have no `api.base` or `api.channel_invites`
   and their `api.*` entries point at `pass.<domain>/api`. The web chat uses
   `https://belfry.<domain>/api/v1` regardless; clients SHOULD do the same until `api.base`
   is published **(Q1)**.
3. Well-known keys, from NIP-05 on the apex (`https://<domain>/.well-known/nostr.json?name=…`),
   cached, refreshed at start:
   - `_smtp`: the **mail bridge** key (sends/receives e-mail as Nostr Mail, section 10).
   - `_groups`: the **groups key**, which posts e-mail cards in shared inboxes and guest joins.
   - `<username>`: a member's key (resolving `name@<domain>` when starting a DM).

## 2. Sign-in (OAuth 2.0 code + PKCE → NIP-46)

The member's secret key never lives on the device. Sign-in yields a **bunker URL**: a NIP-46
remote signer session on the belfry's signer (Keycast) that signs as the member.
(`src/core/auth.ts`, server `connect.py`.)

1. Make `state` (24 random bytes) and `code_verifier` (48 random bytes), both base64url without
   padding. `code_challenge = base64url(SHA-256(ASCII(code_verifier)))`, method `S256` (the
   server rejects challenges shorter than 43 chars).
2. Open, in the system browser session (not an embedded web view):
   `GET <authorize>?client_id=<id>&redirect_uri=<uri>&scope=policy:belfry-event&state=<state>&code_challenge=<challenge>&code_challenge_method=S256`
   Optional `prompt=none` for a silent attempt (the server answers `error=login_required`).
3. The person types their e-mail and a mailed 6-digit code (or is already signed in to
   `belfry.<domain>` in that browser). The server redirects to
   `<redirect_uri>?code=…&state=…` or `?error=…&state=…`.
4. Check `state` equals the one sent. `error=access_denied` → "Sign-in was cancelled."; any
   other error → a fixed "Not signed in" message (never echo the URL's text).
5. `POST <token>` with JSON `{grant_type:"authorization_code", code, client_id, redirect_uri,
   code_verifier}`. `client_id` and `redirect_uri` MUST be byte-identical to step 2.
   Answer: `{"bunker_url":"bunker://<signer pubkey>?relay=wss://…&secret=…", "token_type":"bunker",
   "pubkey":"<member hex>", "npub":"…"}`. Errors: `{"error":"invalid_grant" | "app_not_approved"
   | "own_key" | …}` with 4xx; map each to a fixed message.
6. Generate a **client key** (random secp256k1 secret) for this device, kept in secure storage
   and reused for this session. Connect to the bunker (NIP-46, section 3).
7. Cache the member's pubkey (`pubkey` from the token answer, else `get_public_key`) so the
   app opens offline.

**Which apps may sign in.** `connect.py` gives a session only to approved apps: the belfry's own
web apps (`https://<domain>/<app>/`) and addresses an admin approved. A return address MUST be
`https://` (or `http://localhost`). A native app's custom-scheme redirect is therefore refused
today: see `SERVER-NEEDS.md` **(Q2)**.

**Sign-out**: forget the bunker URL and client key, `POST <revoke>` `{token, client_id}` (best
effort, 3 s; the connect endpoint just answers ok), wipe all local data (events, outbox,
decrypted messages), optionally open `<logout>?return_to=<redirect_uri>` to end the browser
session.

## 3. The remote signer (NIP-46)

- Parse `bunker://<remote-signer-pubkey>?relay=<wss>&relay=…&secret=<s>`.
- Requests are kind 24133 events from the client key, `p`-tagged to the remote signer, content
  = NIP-44 v2 encrypted JSON-RPC `{"id","method","params"}`; answers likewise
  `{"id","result"|"error"}`. Subscribe on the bunker relays to `{kinds:[24133], "#p":[client
  pubkey]}`. (nostr-tools' `BunkerSigner` also accepts NIP-04 answers; clients SHOULD try
  NIP-44 first and MAY fall back to NIP-04 for decrypting answers.)
- First `connect` with params `[remote-signer-pubkey, secret]`; answer `"ack"` (or the secret).
- Methods used: `get_public_key`, `sign_event` (param: the unsigned event JSON as a string, with
  `pubkey` = member), `nip44_encrypt [peer, plaintext]`, `nip44_decrypt [peer, payload]`,
  `nip04_decrypt [peer, payload]` (old DMs only).
- Every request has a **20 s timeout**. On a timeout the connection is rebuilt and the request
  fails (the outbox retries later). A phone that slept may hold a dead socket without knowing.

## 4. Relays

Two relays carry the chat (`src/core/sync.ts`):

- **groups** (NIP-29, zooid): channels and everything in them.
- **main** = the community relay (members only): profiles (kind 0), calendar, proposals' texts,
  and the member's DMs and e-mail (gift wraps), delivery reports.

Connection rules:

- NIP-42: when a relay sends `["AUTH", challenge]`, sign kind 22242 with tags
  `[["relay", url], ["challenge", c]]` and send `["AUTH", event]`; after `["OK", id, true]`
  re-send the subscriptions. A publish answered `auth-required:` → authenticate, publish once more.
- Reconnect with backoff `min(30 s, 0.8 s × 2^attempt)`; reset attempts on wake-ups.
- Wake-ups: network back online, app back in the foreground, a **15 s watchdog** while signed
  in (reconnect closed relays; flush if anything is queued). Going offline drops the sockets.

Subscriptions (resent after every (re)connect and AUTH; `since` overlaps to catch late events):

| Relay | Filter |
|---|---|
| groups | `{kinds: KINDS_GROUPS, since: latest(KINDS_GROUPS) − 3600, limit: 2000}` |
| main | `{kinds: [0, 31922, 31923, 31925, 30023, 5], since: latest − 3600, limit: 2000}` |
| main | `{kinds: [1059], "#p": [me], since: latest(1059) − 3 days, limit: 1000}` (wraps are back-dated up to 2 days) |
| main | `{kinds: [4], "#p": [me], since: latest(4) − 3600, limit: 500}` and the same with `authors: [me]` |

`KINDS_GROUPS = [0, 39000, 39001, 39002, 9, 1111, 7, 9007, 9002, 9008, 9000, 9001, 9005, 9021, 9022, 1068, 1018, 5, 1985, 30078, 2100, 2101, 2102, 2103, 8534, 8535, 8536, 8538]`.
A chat-only client MUST subscribe at least to `0, 39000-39002, 9, 1111, 7, 5, 9000, 9001, 9002, 9005, 9007, 9008, 9021, 9022, 1985, 30078`.

Access: the groups relay decides whether someone is in. A `CLOSED` or refusal whose reason starts
with `restricted` or `blocked`, or mentions `pass`/`member`, means "no access (yet)"; after the
groups relay's first EOSE the person is in. Guests (section 13) are in on the groups relay and
refused by the community relay: only the groups relay's verdict counts.

First channel: if after the groups relay's EOSE there is no 39000 at all, the client creates
`general` (9007 then 9002 `name=general`, `about="Everything about <name>. Say hi 👋"`), once.

Events are stored locally by id (dedupe) and every view is derived from the local log (section 6).

## 5. The outbox

Every write is saved locally **before** anything goes on the network, and shows at once
(`src/core/sync.ts`, `store.ts`):

- An outbox item: `localId`, `target` (`groups` | `main`), `kind`, `content`, `tags`,
  `created_at`, attachments, `status` (`queued` | `failed`), `tries`, `error`, optionally a
  pre-signed event (`signed`, gift wraps) and the DM it carries (`dm`).
- `created_at` MUST strictly increase per client: `max(last + 1, now)`.
- Every queued event gets the client tag appended: web `["client","osv-village"]`; native apps
  `["client","belfry-ios"]` / `["client","belfry-android"]`.
- Unsent items show in the feed as if published, marked: "Sending…" (never tried), "Waiting for
  connection…" (tried), or "Not sent: <reason> · Retry" (failed). Retry → `queued`, flush.
- **Flush** (one at a time; a request during a flush runs it again after): walk items by
  `created_at`; skip `failed`; skip items whose target is **stalled** in this pass; sign (if not
  pre-signed), upload attachments, publish (15 s for the connection, 15 s for `OK`).
  - `OK true` → remove the item; the signed event joins the log.
  - Error starting `duplicate:` → counts as sent; remove.
  - **Permanent** (`^(blocked|invalid|restricted|pow|duplicate|error):` or
    `/not allowed|denied|unauthori[sz]ed/i`) → `failed`, `tries+1`, keep the reason; does not
    block later items.
  - Anything else (timeouts, `auth-required:`, `rate-limited:`, no connection, upload errors) →
    stays `queued`, `tries+1`, and its target is stalled for this pass (order kept per relay;
    other relays continue).
- Flush runs on: enqueue, relay connected, online, foreground, and every 15 s while something is
  queued. The outbox and its attachments MUST survive app restarts.
- Pre-signed gift wraps (DMs, e-mail) go through the same outbox (`enqueueSigned`). A DM counts
  as sent once no wrap for **someone else** is left (the self-copy may follow).
- Attachments (Blossom BUD-02): `PUT <blossom>/upload` with the bytes, `Content-Type`, and
  `Authorization: Nostr base64(kind 24242 {content:"Upload <name>", tags:[["t","upload"],
  ["x",sha256hex],["expiration",now+600]]})`. Then add
  `["imeta","url <url>","m <mime>","size <n>","x <sha256>","dim <w>x<h>","alt <name>"]` and
  append the URL on its own line to the content.

Vectors: `outbox.json` (error classes, a multi-round sequence).

## 6. Event log and derived state

Everything is a pure function of the local event log plus queued outbox items.
Ordering everywhere: `created_at` ascending, ties by `id` ascending (string compare).

**Deletion** (`deleted()` in `model.ts`): an event id is deleted if a kind 5 by **the same
author** lists it in an `e` tag (or its address in an `a` tag, `kind:pubkey:d`), or a kind 9005
(moderator removal; the relay only accepts those from moderators) lists it in an `e` tag.

**Profiles** (kind 0, latest per pubkey): `name = display_name || name`, `picture`, `nip05`.
A guest's name comes from the 9000 that admitted them (`name` tag, ≤100 chars) until they have
a profile. Display name: "You" for me; else name, else the nip05's local part, else the first 12
chars of the npub + "…". `realName` (for e-mail From lines and mentions): never "You".

## 7. Channels (NIP-29)

Derivation (`groups()`), processing events in log order; the group id is the `d` tag for
39000-39003, the `h` tag otherwise:

- Metadata `name`, `about`, `picture` from 9007, 9002 and 39000: per field, the latest wins.
  Access `closed` / `open` tags and `prompt` likewise. Default name = the id.
- Admins: the author of any 9007 (the creator; Belfry's relay patch) plus every `p` of 39001.
- Members: the `p` tags of the latest-processed 39002 replace the set; then 9000 adds `p`, 9001
  removes `p`; any kind 9 author is added; 9021 adds its author (open group) or files an
  application (closed group); 9022 removes its author.
- Applications (closed groups): the latest 9021 per person, unless they are a member or a 9000 /
  9001 for them is at least as recent.
- Type by id prefix: `ws-` or `ev-` = event, `pod-` = pod, `prop-` = proposal, else channel.
- Parent (pods, proposals): the `h` of the first kind 9 carrying `["pod", id]` or
  `["proposal", id]` outside the group itself; default `general`.
- `lastActivity` = latest kind 9 in it (else its first event).
- A 9008 (delete group) with that `h` removes the group.
- Order: `general` first, then by `lastActivity` descending.

Actions (vectors `actions.json`): create = 9007 `[["h",id]]` then 9002 `[["h",id],["name",…],
["about",…]]`, id = `slug(name) + "-" + 4 hex`; edit = 9002; join = 9021 (content = answer to
the prompt for a closed group); leave = 9022.

Vectors: `groups.json`.

## 8. Messages, reactions, threads

**Messages**: kind 9 with `["h", group]`, not deleted, by log order. Media: each `imeta` tag
(fields `"key value"`); keep only `url` starting with `http:`/`https:`; the URLs are cut out of
the text, which is then trimmed. Topics: `t` tags, lowercased, deduplicated.
Special posts: a message with an `a` tag of a calendar event (31922/31923) is an event card; with
`["pod",id]` a pod card; with `["proposal",id]` a proposal card; `["client","belfry-mail"]` is a
member's e-mail posted by the bridge ("via e-mail", `subject`, the leading `**<subject>**` line
removed from the text); from the groups key with `mail-from` an inbox card; from the groups key
with `["client","belfry-mail-out"]` an answer sent as the channel. A native client MAY show
cards as plain messages at first (they carry readable text).

**Posting** (`postMessage`): `kind 9`, content = text, tags `["h",g]`, then `["t",x]` for: the
open topic (if any), `announcement` (admins only), and each hashtag in the text (deduplicated,
in that order); then mention `p` tags (section 9).

**Day separators**: a separator before the first message and whenever the local calendar day
changes. **Grouping**: a message starts a new block (avatar + name + time) after a day change, a
different author, or more than 300 s since the previous message.

**Reactions** (NIP-25): kind 7 in the group, `["h",g],["e",message],["p",author],["k","9"]`,
content = the emoji. Interpretation: target = the **last** `e` tag; `+` or empty = 👍;
content longer than 16 UTF-16 code units is ignored; per message, per emoji, the set of
reacting keys; sorted by count descending (ties: first seen first). Tapping my reaction again
removes it: kind 5 `[["h",g],["e",<my reaction id>],["k","7"]]` (if my reaction is still in the
outbox, it is not sent at all). Default emoji row `👍 ❤️ 😂 🎉 🙏 👀`, the person's most used first.
Vectors: `reactions.json`.

**Threads** (NIP-22, `postThreadReply`): kind 1111 in the group:
`["h",g],["E",root.id,"",root.pubkey],["K","9"],["P",root.pubkey],["e",root.id,"",root.pubkey],
["k","9"],["p",root.pubkey]`, then hashtags, then mention `p` tags (skipping the root author).
A reply belongs to the root named by its **`E`** tag. Replies never show as channel messages.
Per root: count, latest time, distinct authors in order.

- **Inline thread**: long-press a message → react or **Reply**. Reply unfolds the thread under
  the message: the **latest 3 replies**, "Show N earlier replies" for the rest, a reply box, and
  Hide. A message with replies shows a chip: up to 3 faces, "N replies", time of the latest.
- **Resurfacing**: an older thread shows again in the feed **at its latest reply** when at least
  one channel message came strictly between the root and that latest reply: a line "<last
  author> replied to <root author>: “<root snippet, 80 chars>”" with the reply's first 140 chars.
  Tapping it unfolds the thread there. Feed order: by time; at equal times messages first.
- Guest joins (section 13) are feed items too.

Vectors: `threads.json`, `messages.json`.

**Delete my message**: kind 5 `[["h",g],["e",id]]`.

## 9. Mentions, hashtags, Markdown

**Mentions** (NIP-27): in the text as `nostr:npub1…`. On send, every valid npub in the text
becomes a `["p",hex]` tag (deduplicated, first appearance order; invalid ones skipped).
Belfry e-mails mentioned people (`mentions.py`). Composer: typing `@` plus up to 30
letters/digits/`_.-` right after a space or at the start opens a picker of people whose name has
a word starting with the query; a pick inserts `@Name ` and on send each picked `@Name` (longest
names first) becomes `nostr:<npub>`. Shown as `@<realName>` (highlighted when it is me).

**Hashtags**: `(^|[^\p{L}\p{N}_&/])#([\p{L}\p{N}_][\p{L}\p{N}_-]{0,48})`, lowercased,
deduplicated. Pinned topics of a channel: the latest kind 1985 with `["L","#t"]` in the group;
its `["l",topic,"#t"]` tags in order.

**Markdown subset** (never rendered as HTML): blocks = paragraphs (single newlines are line
breaks), `#`..`###` headings, `-`/`*`/`+` and `1.`/`1)` lists, `>` quotes, ``` fences; inline =
`**bold**` `__bold__` `*italic*` `_italic_` `` `code` `` `~~strike~~` `[text](url)` (only
`https?://` and `mailto:` become links; others stay literal) and bare `https?://` URLs (trailing
`.,;:!?'")` not included). The exact algorithm (regexes, precedence, the quirks it keeps, e.g. a
fence right after a paragraph line stays text, `snake_case` italicizes) is pinned by
`markdown.json`; compare after merging adjacent text nodes. Plain text nodes in chat messages
are further split into mentions and #topics (same file).

Vectors: `mentions.json`, `markdown.json`.

## 10. Direct messages and e-mail

(`src/core/dm.ts`, `mime.ts`.) All on the **community relay**; decrypted messages are kept on
the device only and wiped at sign-out.

**Receiving**: for each kind 1059 `p`-tagged to me: decrypt the content with NIP-44
(`peer = wrap.pubkey`) → a seal (kind 13; MUST verify its signature) → decrypt its content
(`peer = seal.pubkey`) → the rumor. Drop it if `rumor.pubkey ≠ seal.pubkey`. Kind 4 (NIP-04,
read only) from or to me: peer = the other side. Remember processed wrap ids. If decryption
times out (signer away) stop and try again later; other failures mark the wrap as seen.

**Conversations** (`Conv` key):
- Nostr: `n:` + the sorted pubkeys of everyone in the rumor (author + `p` tags) minus me,
  comma-joined (`n:<me>` for notes to self).
- E-mail: `m:<address>|<subject key>`; `m:<address>` alone = a new e-mail not yet sent.

**NIP-17 send** (kind 14 rumor: `pubkey=me`, `tags=[["p",peer]…]`, `content=text`, id computed,
unsigned): seal = kind 13 signed by me (through the signer), content =
`nip44_encrypt(recipient, rumor JSON)`, `created_at` random up to 2 days in the past, no tags;
wrap = kind 1059 signed by a fresh one-time key, `["p",recipient]`, content = NIP-44 of the seal
with the one-time key, `created_at` back-dated likewise. One wrap per recipient **and one for
me** (other devices see what I sent). All wraps go to the outbox (target main); the message
shows at once as pending.

**E-mail (Nostr Mail)**, through the bridge (`_smtp` key):
- Incoming: a 1301 rumor from the bridge with `mail-from` (sender address), `email-id`,
  `subject`, `belfry-auth` (`pass` = DKIM/SPF aligned, shown as verified), content = the RFC 2822
  message, or empty with `x`, `url`, `decryption-key`, `decryption-nonce` for a large one stored
  on Blossom (AES-256-GCM; key and nonce base64).
- Text = the new part of the mail (section 10.1); `fromName` from the `From` header.
- **Thread key**: base subject = the subject with leading `re fw fwd aw sv tr wg antw rif r`
  prefixes removed (case-insensitive, optional `[n]`, any spaces before `:`, repeated); subject
  key = `encodeURIComponent(lowercase(base) with whitespace runs → one space)`, or `-` when
  empty. A mail joins the thread that its `In-Reply-To` (first) or `References` (last to first)
  names among known mails **with the same address**; else the thread of its subject key.
- Sending: needs my address (`<username>@<domain>`, from my nip05) and the bridge key. Build the
  mail (section 10.1); rumor kind 1301 tags `[["email-id",uuid],["mail-from",me@domain],
  ["rcpt-to",to],["subject",s]]`, content = the raw mail; wrap to the bridge and to me. In a
  thread: answer its last mail with `Re: <base subject>`, `In-Reply-To` = that mail's
  Message-ID, `References` = its references + its id. A new mail needs a subject and becomes
  the thread `mailThreadOf(to, subject)`.
- Delivery reports: kind 7679 from the bridge on the community relay, `["r", email-id]`,
  `ephemeral-pubkey` tag; content = NIP-44 (with that ephemeral key as peer) of
  `{status: delivered|failed|delayed|queued, details?, smtp_response?}`. Query
  `{kinds:[7679], authors:[bridge], "#r":[open ids]}` 3, 10, 30 and 90 s after a send is out.
- Unread: per conversation, messages not mine newer than the last read time (local only).
- Starting a conversation: a member's name or nip05, a 64-hex key, `name@<domain>` (resolved
  by NIP-05; else e-mail), or any other address (e-mail).

### 10.1 MIME

Reading: headers (first occurrence wins, folded lines joined), RFC 2047 encoded words (B and
Q), `base64` / `quoted-printable`, `multipart/*` (depth ≤ 8), attachments (a disposition of
`attachment`, or a name on a non-text part). Text = the plain part, else the HTML part as text;
then the new part only: stop at a line `On … wrote:`, `Le … a écrit :` or `----- Original
Message -----`, drop lines starting with `>`, collapse 3+ newlines. Writing: UTF-8,
`multipart/alternative` with the text as written (`text/plain`) and the Markdown rendered as
escaped HTML (`text/html`), both base64 (76-char lines); headers `From: "<name>" <addr>`,
`To: <addr>`, `Subject` (encoded word if not ASCII), `Date`, `Message-ID: <uuid@domain>`,
optional `In-Reply-To`/`References`, `MIME-Version: 1.0`.

Vectors: `mail-threads.json`, `mime.json`, `events.json` (gift wraps).

## 11. Seen events and "active this month"

Opening a channel publishes, **at most every 6 hours per channel** (checked against my latest
seen event and the last one sent from this device), kind 30078 `[["d","seen:<id>"],["h",<id>]]`,
empty content. A closed pod I'm not a member of is not marked.

`recentlyActive(id)`: the people with a seen event for that channel, or a kind 9, 1111 or 7 in
it, in the **last 30 days**; with each one's latest time; most recent first; if the channel has a
member list (members ∪ admins non-empty) only those people. The channel header shows "N active
members this month" (or "Nobody active this month yet") and their avatars. Vectors:
`recently-active.json`. See **(Q4)** about card-posting keys counting as members.

## 12. Admin rights and channel settings

`canAdmin(channel)` = I am one of its admins (section 7) **or** a community admin: a key in
belfry.json `admins` (64-hex only) or in `access.admins`. Unknown channel → false. Vectors:
`can-admin.json`.

Admins see **Settings**: name and description (9002 with `name`, `about`), and the **shared
inbox** switch: kind 30078 `[["d","belfry:inbox"],["h",id]]` content `{"on":true|false}`; the
setting counts only from the channel's own admins (latest wins). With it on, anyone can e-mail
`<id>@<domain>`; otherwise members can, and their mail shows as their message.
Announcements: admins may tag a message `["t","announcement"]` ("📣 Announcement", e-mailed to
followers); the tag counts only from the channel's admins.

## 13. Guests and invites

- **Member link**: the web chat's address for the channel, `<chat url>#/c/<encoded id>`. Shown
  as text, QR code and share sheet.
- **Guest link** (30 days, this channel only): `POST <api base>/channel-invites` with JSON
  `{"channel": id}` and a NIP-98 header (`Authorization: Nostr base64(kind 27235 event)`, tags
  `[["u", exact url], ["method","POST"], ["payload", sha256hex(body)]]`, `created_at` now).
  Answer `{url, days, expires_at}`; errors `{error, message}` with `error` in `invalid`,
  `unsupported`, `guest` (guests can't invite), `no_channel`, `not_allowed`, `refused`,
  `unauthorized`: show a fixed message per `error`. Any member may make one (Belfry checks).
- **Guest joins**: a kind 9000 in the group with `invited-by` (from the groups key, `guests.py`),
  tags `["p",guest,"member"]`, `["name",…]`, `["guest",<end date>]`. The feed shows "<name>
  joined as a guest, invited by <inviter>" at its time. A 9001 with `["guest","ended"]` removes
  them.
- An empty channel shows "<name> is new · No messages yet. Bring the people who belong here,
  then say hi." with an **Invite people** button.

## 14. Search

Every word of the query (accents and case folded) must appear in the message text, the author's
display name or an attachment name. Scope: this channel or all channels. Newest first, at most
200. A result opens its channel on that message.

## 15. Errors, privacy, security

- **Never render text taken from a URL** (query, fragment, redirect parameters): show fixed
  messages chosen by a key. Server error bodies are mapped by their `error` code too.
- Never log or display secrets (bunker URL secret, client key, codes).
- The client key and bunker URL live in the platform's secure storage (Keychain / Keystore).
- Verify signatures of relay events before storing them (a relay could forge); verify seals
  always.
- Links in messages: only `http(s)` and `mailto` open; everything else stays text.
- Images from `imeta` load only over `https` (http allowed for local development).

## 16. Platform choices (where native differs from the web)

| Web chat | iOS app | Why |
|---|---|---|
| Hash routes, ☰ drawer, laptop sidebar ≥ 900 px | `NavigationSplitView`: channel list (sidebar) → feed; on iPhone a stack with swipe-back | System navigation |
| Custom pull-down header (peek / full) | Tapping the title opens a **sheet with medium and large detents** (about, active members, members, settings) | Sheets with detents are the iOS idiom |
| Long-press opens a bottom sheet with emojis | `.contextMenu` with a reaction row and Reply / Copy / Delete | System menu, haptics |
| "Search" screen | `.searchable` on the channel list (all channels) and on a channel | System search field |
| Copy / `navigator.share` | `ShareLink`, `UIPasteboard`, CoreImage QR | System share sheet |
| Redirect back to the page | `ASWebAuthenticationSession` with the app's URL scheme | Needs SERVER-NEEDS item 1 |
| IndexedDB | SQLite (SwiftData not used: plain tables, testable) | Offline, survives restarts |
| Enter sends on keyboards | Return adds a line; the send button sends | iOS messaging convention |
| Pull to refresh: none (live) | `.refreshable` reconnects and re-subscribes | Expected gesture |

Android should make its own platform choices against the same protocol rules.

## 17. Test vectors

`vectors/*.json` are generated from the web chat's own code by
`tools/vectors/build.mjs` (needs a village-app checkout); where the logic lives in a component
or private state, `tools/vectors/gen.ts` copies it line for line. Each file has `about`,
`people` (names → pubkey, secret, npub; deterministic test keys) and cases:

| File | Checks |
|---|---|
| `nip44.json` | the official NIP-44 v2 vectors (sha256 `269ed0f6…5040`) |
| `events.json` | event id, BIP-340 verify, bech32, NIP-59 unwrap (DM, e-mail, forged rumor) |
| `groups.json` | channel derivation |
| `messages.json` | feed, deletion, media |
| `reactions.json` | reaction aggregation and undo |
| `threads.json` | thread grouping, inline window, feed with resurfacing and guest joins |
| `mail-threads.json` | base subjects, thread keys, thread assignment by references |
| `mentions.json` | mention tags, picker, substitution, hashtags |
| `actions.json` | the exact events each action queues |
| `recently-active.json` | active this month, my seen |
| `can-admin.json` | admin rights |
| `outbox.json` | error classes (refused uploads: 19.17, an Android addition), per-relay order, retry, duplicate |
| `markdown.json` | the Markdown subset as a tree |
| `mime.json` | reading e-mails |
| `channel-refs.json` | naddr encode / decode, channel references in previews (19.14; Android addition, made by `tools/vectors/channel-refs.mjs` with the web's nostr-tools) |

Rules for comparing: ids and keys are hex; sets are given sorted; `_label` fields are for humans.

## 18. Open questions

1. **API base.** Live `belfry.json` documents have no `api.base`/`api.channel_invites`; the web
   chat hard-codes `https://belfry.<domain>/api/v1`. Will belfry.json publish `api.base`, and is
   `pass.<domain>/api` still valid for `channel-invites`?
2. **Native redirect URI.** `/connect` accepts only `https://` return addresses of approved apps.
   A native app needs either a custom scheme (`belfry://connect`) approved by default, or a
   universal link on a domain Belfry controls. See `SERVER-NEEDS.md`.
3. **Refresh / expiry.** The token answer has no refresh token and no expiry; the web stores
   `refresh_token` if present. How long does a bunker session live, and how does a client learn
   it was revoked (signer answers an error? which one)?
4. **Card keys as members.** `recentlyActive` says it excludes "the keys that post e-mail or
   drop-box cards", but `groups()` adds every kind 9 author to the members, so the groups key
   counts as an active member once it posted a card (`recently-active.json` pins today's
   behaviour). Should 9 authors who are the groups key or bridge be excluded?
5. **Member link for native apps.** The member invite link is the web chat's URL. Should a native
   app claim it (universal links on `<domain>/chat/`) so links open in the app?
6. **Markdown quirks.** `snake_case_word` renders italic and a fence right after a paragraph
   line stays text. Keep (all clients identical) or fix in all clients?
7. **Push notifications.** None today. A native app needs a push relay (APNs/FCM) fed by the
   belfry for mentions, DMs and e-mail. See `SERVER-NEEDS.md`.
8. **NIP-46 encryption.** Does Keycast answer in NIP-44 only, or may it answer NIP-04?
9. **Client tag.** Should native apps send `["client","belfry-ios"]` or reuse the web's value?

---

## 19. Additions since the iOS spec

Written for the Android app (2026-11-10) from the web chat's source at `belfry-chat` 85ccbd4
(`src/core/model.ts`, `actions.ts`, `people.ts`, `ui/Chat.tsx`, `ui/MailPost.tsx`). Everything
here is protocol, not layout, and is meant to be ported back into sections 7 to 13. The Android
core implements it in `core/src/main/kotlin/sh/belfry/core/model/` (`World`, `Actions`); the iOS
core in `Sources/BelfryCore/Model/` (`Derive` + its extensions `Events`, `Proposals`,
`ChannelLine`, `ChannelRefs`, `Access`, `People`, `Actions2`), since 2026-11-11. `vectors/` is
kept identical in both repositories (opencollective/belfry-ios and opencollective/belfry-android)
and this file differs only in this paragraph and the (iOS) notes that end 19.19 and 19.20:
change both in both. Android's 19.21 (web changes of 2026-11-11 / 12) and 19.22 (snapshots built
on the one before), 19.23 to 19.25 are not ported here yet. 19.26 (guest mode) is Android's text
with the (iOS) notes at its end.

`KINDS_GROUPS` (section 4) now also has **1010** (edits).

### 19.1 Message edits (kind 1010)

- Edit **my own** message (kind 9) or thread reply (kind 1111): a kind 1010 event in the group,
  `[["h",g],["e",<message id>],["k","<kind of the message>"], <kept imeta tags…>, ["t",topic]…,
  <mention p tags of the new text>]`, content = the new text, then the kept media URLs, one per
  line (`[text, ...urls].filter(non-empty).join("\n")`).
  - Kept from the **original** event: every `imeta` tag, and every `t` tag that the text shown
    before the edit did not spell as a #hashtag (the topic it was sent in, `announcement`).
    `t` tags = those kept ones, then the hashtags of the new text (deduplicated, lowercased).
- Reading: per message id, the edit with the greatest `created_at` (ties: greatest id) that is
  not deleted and **whose author is the message's author**. The message is then shown with the
  edit's content, `imeta` and `t` tags (parsed exactly like a message), keeps its own id, author
  and time (reactions, threads and links hang off the original id), and is marked "edited"
  (with the edit's time). Clients that do not know kind 1010 show the first version.
  (The web picks the latest 1010 of any author and then drops it if the author differs, so a
  later foreign 1010 hides the author's own edit there; Android ignores foreign edits first.
  Suggested for all clients.)
- An edit can be deleted by its author (kind 5): the previous edit, or the original, shows again.
- Only a plain message can be edited: mine, already sent (not in the outbox), with text, and not
  an event / pod / proposal card, an e-mail, an inbox card or an answer sent as the channel.

### 19.2 Deleting my message

Kind 5 `[["h",g],["e",id]]` as before. The client MUST ask first, in the app (no system
dialog), showing the message: author name and the first 240 characters of the text with
`nostr:npub…` runs replaced by `@…` (or "A photo or file" / "N photos or files" when it has no
text), and "It disappears for everyone, with its reactions. This can't be undone."

### 19.3 Guests: labels, agents, lines that disappear

- The join event (kind 9000 with `invited-by`, section 13) may carry `["agent","1"]` (an agent
  invited by a member: "joined as an agent") and `["unsaved","1"]` (an account without an e-mail
  yet: "guest · not saved").
- The belfry labels a guest with kind 1985 events in the same group:
  `["h",g],["L","belfry/guest"],["l","saved","belfry/guest"],["p",guest]` once they proved an
  e-mail address (clears "not saved"), and `["l","member","belfry/guest"]` once an admin made
  them a member (`POST /admins`): from then on they are **not called a guest** anywhere (chips,
  profile, members list); their join line stays in the feed.
- A guest who was removed (9001 for them, at or after the join) **without ever writing** in the
  group (no kind 9 or 1111 by them) leaves no join line.
- "Am I a guest": some join of mine, in any group, without the `member` label. Guests cannot
  create guest links; a guest's profile has no "Message" button; a guest cannot be made admin while every join of
  theirs is unsaved ("This guest has no e-mail yet…"); an agent never ("An agent cannot be an
  admin."). The server answers the same with `guest_not_saved` / `agent` / `not_member`.

### 19.4 Guest links without a code

(`src/core/auth.ts` inviteInfo / joinAsNew, `src/core/sync.ts` joinWithAccount, `src/ui/Login.tsx`
JoinScreen, `src/ui/Invite.tsx`; server `guests.py`.) This replaces the hand-off code of earlier
versions: there is no `/api/guest-sessions` any more.

- **The link**: `https://chat.<domain>/join/<token>` (the web chat also reads `…/#/join/<token>`).
  `<token>` matches `[A-Za-z0-9_-]{20,}`. A native app registers for these links (Android App
  Links, iOS universal links) and MUST take only the domain and the token from the address;
  nothing else of the address is ever shown.
- **Making one** (any member, not a guest): `POST <api.channel_invites>` (NIP-98) with
  `{"channel": id, "people": 1 | 50, "link_days": 1 | 7 | 30}` (defaults 1 and 1). Answer
  `{url, agent_url?, days, people, link_days, expires_at}`; `days` is how long a guest stays
  (30). Errors as in section 13. The invite sheet offers "How many: one person / up to 50" and
  "Link works for: 1 day / 1 week / 1 month", shows the link as text, QR code and share sheet.
- **Reading one** (no sign-in): `GET <api.channel_invites>/<token>` →
  `{community, channel, channel_name, about, inviter, state, days}`; `state` is `open`, `used`,
  `expired` or `revoked` (fixed messages: "This invite was used already / has expired / was
  withdrawn. Ask for a new one."). 404 → "This invite link is not known here. Ask for a new one."
- **Joining as someone new** (not signed in): the device makes a **session key** (a fresh
  secp256k1 secret), and sends `POST <api.channel_invites>/<token>/join` with body
  `{"name": "<their name>"}` and a NIP-98 header **signed by that session key** (not by a
  member key: there is none yet). Answer `{bunker_url, channel, pubkey?}`: the belfry made the
  account in its signer and bound its first NIP-46 session to the session key, which is from
  then on the client key of section 3. The guest is in `channel` only, `saved: false`.
  - **One session key per invite**, kept in secure storage until the join succeeds: the server
    is idempotent per signing key, so a second tap, a retry after a timeout or an app restart
    gets the **same** account, never a second one. Forget the key after success.
  - `409` (the key is another account's in the signer): forget the key; the next try makes a new
    one. Other errors by `error` code: `name_needed`, `closed`, `unsupported`, `relay`, `failed`.
- **Joining with an account** (signed in, member or guest): the same `POST …/join` with body
  `{}` and a NIP-98 header signed **as the member** (through the bunker). Answer
  `{channel, already, guest?}`: the account gets the channel (a member: a 9000 in the group; a
  guest: one more guest pass on the same person); `already: true` when they were in (the link
  is not used up). No second account is ever made. A link opened while signed out is kept
  (pending invite) through sign-in and used right after.
- A guest saves their account with `POST <api>/guest/save` `{email}` then
  `POST <api>/guest/save/verify` `{email, code}` (both NIP-98 as the guest); the groups key then
  labels them `saved` (19.3).
- **Since 2026-11-12 a client opening a link signed out sends `{}`, not a name** (guest mode,
  19.26). The `{"name"}` body still works (older clients).

### 19.5 Profiles: tags and places (kind 30078, `d` = `belfry:profile`)

- One replaceable event per member on the **community relay** (members only):
  `[["d","belfry:profile"]]`, content JSON
  `{"tags":[…],"share":"city"|"country"|"none","place":{"id","name","region","country","lat","lon"}}`.
  The newest per author counts.
- Tags: trimmed, lowercased, leading `#` removed, whitespace runs → `-`, only letters, digits,
  `_`, `-` kept, at most 32 characters each, deduplicated, at most 30.
- `share`: anything but `country` / `none` reads as `city`. `none` → no place. `country` → only
  `{country}`. A place needs `country` matching `^[A-Z]{2}$`; `id` ≤ 40, `name`/`region` ≤ 80
  characters, `lat` (|x| ≤ 90) and `lon` (|x| ≤ 180) rounded to 2 decimals. A place is a city's
  point from the belfry's list (`GET <api>/places?q=&limit=8`, no auth; answer
  `{places:[…], attribution}`) or one a member added (`POST <api>/places` NIP-98
  `{name,country,near:<id of the nearest listed city>}` → `{place}`; error `bad_country`).
  Never the device's GPS.
- Suggestions when adding tags: every member's tags by use (ties alphabetical).
- Name, about (Markdown), picture stay in kind 0 on the community relay: saving keeps the other
  fields of my latest kind 0 and sets `name` = `display_name` (≤ 100) and `about` (≤ 2000);
  a new picture is uploaded (resized to 512 px, JPEG) and set as `picture`.
- "Admin of the belfry" switch on a profile (belfry admins only): `POST <api>/admins` NIP-98
  `{pubkey, admin}`; errors `not_member`, `guest_not_saved`, `agent`, `last_admin`,
  `not_admin`, each with a fixed message. Afterwards reload `belfry.json` (its `admins`).

### 19.6 Special posts (precise rules)

A kind 9 message is, in this order of precedence:

1. **Inbox card**: author = the groups key, has `mail-from` and `["client","belfry-mail"]`.
   Tags: `mail-from`, `mail-name`, `subject`, `message-id`, `belfry-auth` (`pass` = verified),
   optional `["mail-original", https url, key, nonce]` (the whole mail, AES-256-GCM on Blossom).
2. **Sent as the channel**: author = the groups key with `["client","belfry-mail-out"]`; tags
   `e` (the card it answers), `mail-to`, `subject`, `sent-by` (the member who wrote it).
3. **Event card**: first `a` tag starts with `31922:` or `31923:`.
4. **Pod card**: `["pod", id]` with id starting `pod-`. 5. **Proposal card**: `["proposal", id]`
   with id starting `prop-`.
6. **Member's e-mail**: `["client","belfry-mail"]` (not from the groups key): "via e-mail",
   `subject`, optional `mail-original`.

For 1 and 6 the text shown drops a leading `**<subject>**` line. Cards 3 to 5 always show
their author with the line "Created an event / a pod / a proposal". A message with
`["client","belfry-drop"]` from a key without a profile is named "Drop box".

**Inbox card state** (per card id = the `e` tag of the events below, in log order, deleted ones
skipped): kind 1985 with `["L","belfry/inbox"]` and `["l",x,"belfry/inbox"]`: `open` / `closed`
set the status, `assigned` sets the assignee to its `p` tag (none = nobody); each "sent as the
channel" post counts as an answer and turns `open` into `waiting` (shown "Answered").
Actions: `[["h",g],["L","belfry/inbox"],["l","open"|"closed","belfry/inbox"],["e",card]]`;
assigning adds `["l","assigned","belfry/inbox"],["e",card],["p",assignee]`.

### 19.7 Feed layout rules (shared by clients)

- With a topic open the feed has only that topic's messages (no joins, no resurfaced threads);
  the topic `announcement` shows admins' announcements only.
- A message starts a block (avatar, name, time) on a new day, after a non-message item, after
  another author, after more than 300 s, right after a message whose thread is unfolded, and
  always when it is an announcement, an e-mail or a card.
- "Topics a message carries but does not spell" (sent inside an open topic) are shown as chips
  under it, except the open topic and `announcement`.

### 19.8 Pods, events, proposals, drop links, task list (events as the web writes them)

- **Pod**: id `pod-` + slug(name)[:24] + `-` + 4 hex. 9007 `[["h",id]]`; 9002
  `[["h",id],["name",…],["about",…],["open"]]` or `…,["closed"],["prompt",question]`
  (default question "Why do you want to join, and what would you bring?"); then in the parent
  kind 9 `⬡ New pod: <name>[ · <about>]` with `[["h",parent],["pod",id]]`. Admit an applicant:
  9000 `[["h",id],["p",pk,"member"]]`; decline / remove: 9001 `[["h",id],["p",pk]]`.
- **Event**: `x` = 8 hex; chat `ws-<x>` (9007 + 9002, about = first line of the description or
  "Chat for this event"); on the **community relay** kind 31923 (timed) or 31922 (all-day):
  `[["d","session-<x>"],["title",…],["h","ws-<x>",<groups relay>],["start",…],["start_tzid",tz],
  ["end",…],["end_tzid",tz],["location",…],["r",https link]]` (all-day: ISO dates, no tzid),
  content = description; then in the channel kind 9 `📅 <title> · <when>[ · <location>]` with
  `[["h",channel],["a","<kind>:<me>:session-<x>",<community relay>]]`.
  Reading: latest per coordinate; deleted by kind 5 `a`; `channel` = the `h` of the first
  non-deleted kind 9 linking it outside `ws-` groups (default `general`); group = its `h` tag or
  `ws-` + d without `session-`. RSVP: kind 31925 on the community relay
  `[["d",sha256hex("<me>:<author>:<d>")[:30]],["a",coord],["e",event id],["status",
  "accepted"|"tentative"|"declined"],["p",author]]`, latest per person. Delete: kind 5
  `[["a",coord],["e",id]]` on the community relay. Upcoming = end (or start) ≥ today 00:00 local.
- **Proposal**: `x` = 6 hex; chat `prop-` + slug(title)[:24] + `-<x>`; text = kind 30023 on the
  community relay `[["d","proposal-<x>"],["title",…],["summary",…],["t","proposal"],
  ["h",chat,<groups relay>],["version","1"],["status",s],["published_at",now]]`; card in the
  parent: kind 9 `📝 Proposal: <title>[ · <summary>]` with `[["h",parent],["proposal",chat],
  ["a",coord,<community relay>]]`. New version: same `d`, `version` + 1, and in its chat kind 9
  `📝 Version N[: note]` with `[["h",chat],["a",coord,relay],["version","N"]]`. Status: the
  latest kind 1985 in its chat `[["h",chat],["L","belfry/proposal-status"],["l",s,
  "belfry/proposal-status"],["a",coord]]` by the author or an admin of the chat or of its
  parent (`draft feedback voting passed rejected closed`; before any label, the text's `status`
  tag). Vote: kind 1068 in its chat `[["h",chat],["a",coord],["version",N],["polltype",
  "singlechoice"],["option","yes","Yes"],["option","no","No"],["option","abstain","Abstain"]]`,
  content `<title> (version N): do you approve?`, opened when the status becomes `voting` (and
  again for a new version under vote); answers kind 1018 `[["h",chat],["e",poll id],
  ["response",option]]`, latest per person; the latest poll counts and voting is open only
  while its version is the text's version.
- **Drop box link**: kind 30078 in the group `[["d","drop:<token>"],["h",g],["expiration",ts],
  ["login"]?,["alt",…]]`, token = 16 random bytes base64url; live while not deleted (kind 5 by
  its author with `e` and `a` = `30078:<author>:drop:<token>`) and `expiration` > now. The page
  is `https://<domain>/drop/<token>`. Choices: 1 day / 1 week / 1 month; anyone / signed in.
- **Pinned topics**: `[["h",g],["L","#t"],["l",topic,"#t"]…]` (kind 1985), the whole list each
  time; any member may pin.
- **Member labels** (per channel): kind 1985 `[["h",g],["L","osv/member-label"],
  ["l",label,"osv/member-label"]…,["p",member]]`, latest per member. (The namespace keeps the
  web's historical name.)
- **Task list** (tasklist.sh): list id = `sha256hex("osv-village:"+group)[:16]`; kinds 2100
  (task, content = title ≤ 300), 2101 (`["e",task],["action","claim|unclaim|done|undone|delete"]`),
  2103 (comment), each with `["t",list id],["h",group]`.
- **Following a channel by e-mail** is not an event: `GET/POST <api>/me/follows` (NIP-98).
- The web chat has **no unread count per channel** (only for direct messages and e-mail).

### 19.9 Engine rules the Android app adds or pins down

- **Subscriptions** follow today's web chat: `KINDS_GROUPS` includes `1010`, and the community
  relay gets one more filter, `{kinds:[30078], "#d":["belfry:profile"], since: latest − 3600,
  limit: 2000}` (19.5). After a disconnect the `since` values are computed again from the log.
- **Mail threads do not depend on arrival order.** Wraps are back-dated at random and read newest
  first, so an answer can be decrypted before the mail it answers. After each batch every
  incoming mail is placed again, oldest first, with the rule of section 10 (the web places a
  mail once, when it is read).
- **Demo mode** (`localOnly`): no relay and no HTTP at all. A flush signs with the local key and
  adds the event to the log; a 9007 / 9002 also yields the 39000 / 39002 a relay would write;
  attachments stay on the device and are addressed as `https://blob.local/<key>` (never
  fetched); e-mails report "Demo mode sends no e-mail."
- **Sign-out**: the app ends its own session with `POST <api>/me/sessions/revoke`
  `{bunker_pubkey: <the bunker URL's key>}` (NIP-98, best effort, 3 s): `/connect/token` gives
  no refresh token to revoke.
- **Signed GETs** to the same address are spaced by more than a second: the belfry refuses a
  NIP-98 event id it has seen, and two identical GETs in one second share an id.


### 19.10 Pinned messages (kind 1985, `L` = `belfry/pin`)

(Web: `model.ts` `pinned`, `actions.ts` `pinMessage`, village-app 30e775b.)

- Pin or unpin: kind 1985 in the group, tags
  `[["h",g],["L","belfry/pin"],["l","pinned"|"unpinned","belfry/pin"],["e",<message id>]]`, empty
  content.
- A label counts only when its author is one of the channel's admins (section 7) or a community
  admin (section 12). Per message the label with the latest `created_at` wins (ties: the one
  processed later). Labels with another `l` value are ignored.
- The pinned messages of a channel are its kind 9 messages (not deleted) whose winning label is
  `pinned`, most recently pinned first. Only channel messages (kind 9) can be pinned, not thread
  replies; a queued message cannot be pinned.
- "Got it, hide" is local to the device (a list of at most 200 message ids): it only stops the
  pin from being the summary line; the pull-down still lists it.

### 19.11 To-dos made from messages

The task list of 19.8 is called **To-dos** in the interface. "Turn into a to-do" on a message
queues a kind 2100 with the list's tags plus `["q", <message id>]`; its title is the message's
text without `nostr:npub…` mentions, whitespace runs collapsed, 300 characters at most (nothing
is offered when that is empty, when the message is still queued, or when a to-do with that `q`
exists already). The message then shows a mark: "To do", "To do · <assignee>" or "Done"; tapping
it queues a 2101 `done` (or `undone` when it was done).

### 19.12 A pod's mark

A regular polygon with one side per member: `max(3, members)` sides, point up; 13 members and
more draw a circle. (`icons.tsx` `PodShape`; in a 24-unit box: radius 9.5 around (12, 12), a
triangle around (12, 13.5); the circle has radius 9.)

### 19.13 The one line under a channel's name

(`ui/ChannelLine.tsx`.) Facts of a channel: its pods and its **open** proposals (sub-channels
whose parent it is; open = status draft, feedback or voting — the web's list says `draft`,
`review`, `voting`, and `review` is not a status, so a proposal open for feedback is missing
from the web's line until `belfry-chat` 956e3d2, which fixed it), its upcoming events (ending today or later), its pinned
messages, its to-dos not done, the people active this month (section 11).

The line is the first of these that applies:

1. The feed is filtered on a topic: "Showing **#topic** only" (or "announcements"), pill "Show all".
2. The channel is a proposal's chat: while voting on the current version "**Voting** · N yes ·
   N no" with my vote or a "Vote" pill; else "**<Status>** · version N · by <author>".
3. A pod I may administer with applications: "**N people ask to join** · N members", "Review".
4. An open proposal I have not voted on (voting, poll of the current version): its title, "Vote".
5. An upcoming event I have not answered (no state, 19.18; not cancelled) that starts within 7
   days: "**<day> <time>** · <title>", "RSVP".
6. A pinned message I did not hide: its first line without Markdown marks, mentions as "@…".
7. The next event: as 5, with my state ("Going", "Maybe", "Can't go", "Applied", "Hosting"…) or "RSVP".
8. An open proposal: "**<title>** · <status>".
9. A pod: "N members · open to join" / "by application" (shown muted).
10. "N people active this month" / "1 person active this month" / "Nobody active this month
    yet" (shown muted).

At the right, counts above zero: events (minus one and written "+N" when the line shows an
event), open proposals (likewise), pods, to-dos. With a topic filter no counts.

Pulled down, in this order: (pod or proposal) "Pod in # <parent>"; a proposal's own state; the
people asking to join; **Pinned** (each with author, day, "Show in the channel", "Got it,
hide"); **Coming up** (3 events, then "All N events"); **To decide** (open proposals, "Vote" /
"Voted"); **To do** (4 to-dos with a box that ticks them off and who is on it, then "All N
to-dos"); **Pods** (shape, name, members); **Topics**; the people line leading to members,
files and settings; the first line of the description.

### 19.14 Channel references (`nostr:naddr1…`)

(Web `belfry-chat` 4d5682d: `model.ts` channelRef / channelOfNaddr / plainRefs / NADDR,
`Topics.tsx` ChannelRef, the composer's # suggestions. Vectors: `vectors/channel-refs.json`.)

- A channel picked after "#" in the composer is written in the text as `nostr:` + the NIP-19
  `naddr` of the group's metadata: kind **39000**, author = the key that signed the group's
  latest kind 39000 (the relay's), identifier = the group id, one relay hint = the groups relay.
  TLVs 0 identifier (UTF-8), 1 relay, 2 author (32 bytes), 3 kind (u32 big-endian); nostr-tools
  writes them in the order 3, 2, 1, 0 (clients should too, so both produce the same string).
  A channel whose 39000 was never seen has no reference (not offered by the picker).
- Found in text by `nostr:(naddr1[02-9ac-hj-np-z]{20,400})`. It is a channel reference when it
  decodes to kind 39000; the group is its identifier. It is no topic: a picked "#Name" is
  replaced by the reference before hashtags (`t` tags) are read; a "#word" typed by hand stays
  a topic.
- Picker: opens on `(^|[^\p{L}\p{N}_&/])#([\p{L}\p{N}_-]{0,30})$` before the caret (not while the
  @ picker is open); offers channels that are not events' chats, whose id starts with the query
  or whose name has a word (split on spaces, `_`, `-`) that does; most recently active first; 6.
  A pick writes "#<name> " and remembers name → reference; sending replaces each picked
  "#<name>" (longest first) by its reference. Editing shows each reference again as "#<name>".
- Shown in a message: "#<name>" that opens the channel. The web shows the id for a channel it
  does not know and the raw text for an naddr that is not a group's; Android shows "#channel"
  (muted, not tappable) and "Nostr address" instead: a raw naddr is never shown.
- One-line previews (thread lines, delete confirmation, pinned line, to-do titles, search,
  drawer, Messages): `plainRefs` = mentions as "@…" (or the caller's text), references as
  "#<name>", "#<id>" when the channel is unknown, other naddrs as written.

### 19.15 Inviting someone who is here already

(Web `core/invite.ts`, `ui/Invite.tsx`, `ui/Chat.tsx`, commits 1834584 and 453684b; server
`guests.py` `/api/channel-guests`.)

- Who someone is: a **member's own agent** when belfry.json `agents` maps their key to a member
  (`{agent key: member key}`, absent when there are none); a **guest** when they have a guest
  join (19.3) that is not "member" and are not a member's agent; an **agent** when either a
  member's agent or a guest join carries `["agent","1"]`.
- Can read channel G: its members and admins; nobody else in a closed group; in an open one
  everyone but guests (of other channels).
- The invite search lists everyone with a name (members, guests, agents), me left out, a word of
  the name starting with the query, 5 at most, each marked "<owner>'s agent", "Agent, a guest",
  "Guest" (or nothing for a member) and "Already in" / "Can already open it" / "Not in this
  channel".
- A **guest** is added: `POST <api>/channel-guests` `{"channel","pubkey"}` (NIP-98) →
  `{"added","already","member"}`; when the answer says `member`, carry on as for a member. Errors:
  `invalid` 422, `unsupported` 409, `guest` / `agent` 403 (the caller is one), `no_channel` 404,
  `not_allowed` 403 (`may_invite`: only people who have the channel), `unknown` 404.
- A **member** gets one NIP-17 DM: "<my name> invited you to <# name | pod/event/proposal name>:
  https://chat.<domain>/#/c/<id>" (my name as others know it, else "A member"). In a closed group
  I administer they are admitted first (9000 `["p",key,"member"]`); in a closed group I do not:
  "<my name> thinks you should join <name>. It takes an application: <link>".
- The composer marks "not in this channel" in the @ picker and, for each picked person who cannot
  read the channel, says so above the field with Invite ("Add as a guest" for a guest).
- **The register decides when it can** (belfry-sh 5cbab04): `POST <api>/whois` `{"pubkeys":
  [hex…]}` (NIP-98, at most 500 per call) → `{"people": {hex: "member" | "agent" | "guest"}}`;
  keys holding no active pass are left out; errors `not_here` 403 (the caller holds no pass),
  `invalid` 400. Ask it for every key brought in by a link (9000 with `invited-by`) or listed in
  belfry.json `agents`: once per session in batches, again for the people of a profile or members
  list when it opens. Its answer overrules the events: "member" or "agent" = not a guest (a guest
  join counts as "member since"), "guest" = a guest even if a label says member; a key it leaves
  out, an old belfry (404) or no connection: the events decide as above.
- **belfry.json is revalidated, never trusted from a cache**: request it with `Cache-Control:
  no-cache` and `If-None-Match: <the ETag of the copy held>`; 304 = the copy is current. Since
  5cbab04 the belfry sends `Cache-Control: no-cache` and an ETag itself (it used to allow a
  300 s cache). Clients re-read it at start, after changing admins or agents, and when a profile
  or members list opens (at most every 30 s).

### 19.16 Members' own agents

(Web `access.ts` agentOwner, `invite.ts` myAgents / setMyAgent, `Profile.tsx`, `Invite.tsx`;
server `agents.py`.)

- `POST <api>/agents` (NIP-98): `{}` → `{"agents":[{"pubkey","name","since"}],"limit":n}`;
  `{"pubkey","mine":true}` makes a guest agent mine (only the member who invited it, or an admin
  for themselves, within the limit); `{"pubkey","mine":false}` removes my agent (its member or an
  admin). Errors: `not_member` 403 / 409; making it mine, 409 with the reason (belfry-sh
  a6c9a69): `unknown` (nobody has that key), `taken` (someone's agent already),
  `not_guest_agent` (did not join as a guest agent), `not_inviter` (invited by someone else),
  `limit`; `refused` on older belfries; `not_agent` 404, `not_yours` 403, `invalid` 400,
  `unsupported` 409. The answer is the new list; belfry.json `agents` follows.
- Profile: a member's agent shows the chip "agent" and "agent of <owner | you>"; no admin
  switch. "Make it my agent" when it is a guest agent, I am a member (not a guest, not an agent)
  and I invited it or am an admin. "Remove this agent…" (its member or an admin) asks in the app.
- Join line of a member's agent (its 9000 has `agent` and a `member` label and `invited-by`):
  "<name> joined as <owner>'s agent" (no "invited by").
- "My own agent" in the invite sheet (when `limit` > 0; off when the limit is reached):
  `POST <api>/channel-invites` with `"agent": true` (people 1) → the link to hand over is
  `agent_url` (the instructions, `…/invite/<token>.md`); it works once. Error `agent`: agents
  can't invite.

### 19.17 Outbox: refused uploads

A file the storage refuses with a 4xx other than 401, 408 or 429 (error text
`upload failed (<status>…)`) is **permanent**: the message is failed ("Not sent", Retry /
Discard) and does not hold back later items to its relay. 401, 408, 429, 5xx and network errors
stay retryable. (Web `sync.ts`, 1834584; `vectors/outbox.json` classify cases.)

### 19.18 Belfry events (web belfry-chat ef9e1cc; server events.py; PROTOCOL.md)

New events are **Belfry events**; the older `ws-` ones above are still read and answered.

- **Ids.** `d` = `<year in UTC>-<6 of a-z0-9>` (matches `^\d{4}-[a-z0-9]{6}$`), never recomputed.
  Its chat is the NIP-29 group `ev-<d>`; the creator is its admin, co-hosts are admins added
  with 9000 `[["h",g],["p",pk,"admin"]]`. URL: `https://<domain>/events/<link>`, link = the
  custom name (`slug` tag, `^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$`, not shaped like a `d`, not
  `new|slug|feed|past|mine`) or `d`.
- **Make.** 9007 `[["h",g]]`; 9002 `[["h",g],["name",title],["about",first line[:200] or "The
  event’s chat"],["picture",cover]?,["open"|"closed"]]`; on the community relay 31923 / 31922
  `[["d",d],["title",…],["h",g,<groups relay>],["visibility","members"|"link"|"public"],
  ["start",…],["start_tzid",tz]?,["end",…]?,["end_tzid",tz]?,["location",…]?,["r",https]?,
  ["image",cover]?,["slug",…]?]`, content = Markdown description. No post in any channel: the
  URL is sent like any message. Then `PUT <api>/events/<d>/slug {"slug"}` (409 `taken`).
  Android adds, when "by application" is picked, one ticket type (below) `closed` with the
  question and the group `closed`.
- **Rule B.** Versions are grouped by `d` (any author). Hosts = the group's creator (first 9007)
  ∪ its admins (39001, 9007, 9000 with role `admin`). Versions not signed by a host are ignored;
  the newest host version counts; the coordinate stays `<kind of the creator's>:<creator>:<d>`.
  A host's edit = a new version (keeps `status cancelled` while cancelled) + a 9002 when the
  name or picture changed.
- **Status.** NIP-32 kind 1985 in the group `[["h",g],["L","belfry/event-status"],["l",
  "cancelled"|"scheduled","belfry/event-status"],["a",coord]]`, content = a line for the guests
  (500), plus a new version with / without `["status","cancelled"]`. Reading: the latest label by
  a host wins when it is as new as the version, or when the version says scheduled.
- **Ticket types.** NIP-99 kind 30402 on the community relay `[["d","<d>:<id>"],["a",coord,relay],
  ["h",g],["title",…],["t","ticket"],["position",n],["summary",…]?,["quantity",n]?,
  ["closed"]+["prompt",q]?,["members"]?]`, no price in v1; latest per `d` by a host; deleted by a
  host's kind 5 `a` ending in `:<d:id>`. None: the implicit open ticket `<d>:free`. A closed ticket
  closes the group (9002 `closed`), the last one gone opens it.
- **People.** In the group, by time: 9000 with `ticket` puts a holder, a later 9001 takes them out
  (declined when out after the last decision); 9021 (`ticket`, `waitlist`?, content = answer) is an
  application until a decision or a 9022 after it. Going = holders ∪ accepted RSVPs, minus those
  whose RSVP says otherwise. A 9021 with `ticket` or `waitlist` is not a join of the group.
- **Where I stand** (first match): declined; holder (Maybe / Can't go by my RSVP, else going);
  applied / waitlist; my RSVP; host; none. API events add `me` from the answer.
- **RSVP.** 31925 as above plus `["ticket",d]` when one is held; a guest's (or one for an API
  event) goes on the groups relay with `["h",g]` and no `e`. "Still going?": my RSVP's `e` (else the
  version before it) differs from the current one in start, end or location.
- **Take / apply / decide.** Member + implicit ticket: RSVP. Else `POST <api>/events/<d>/join
  {"ticket"}` (codes `full`, `needs_application`, `members_only`, `cancelled`, `ended`,
  `no_ticket`, `too_many`, `relay`). Apply: a member sends the 9021; a guest signs it and `POST
  <api>/events/<d>/apply {"ticket","request":<signed 9021>}`. Decide: a member host 9000
  `[["h",g],["p",pk,"member"],["ticket",t],["paid","free"],["a",coord],["e",application]?]` /
  9001; a guest host `POST <api>/events/<d>/decide {"pubkey","action":"approve"|"decline",
  "ticket"?}` (403 `not_host`).
- **Read through the API.** `GET <api>/events/<link>` (NIP-98): 403 `members_only`, 404
  `not_found`; the answer has `d, coord, kind, group, link, url, title, description, all_day,
  start, end (ISO), tz, location, online, links (only to those in it), cover (the page's
  /cover), visibility, status, status_reason, hosts [{pubkey,name}], tickets [{d,id,title,
  summary,quantity,left,closed,prompt,members,position,implicit}], going, community, me`.
  Cached a minute. `GET <api>/events/slug?name=&event=` → `{free, suggestion, problem?}`.
- **Cards.** A message's cards = its `a` tags naming 31922/31923 (up to three) and the URLs of
  this belfry's events in its text, deduplicated by `d`; sending a text with such URLs adds
  `["a",coord,<community relay>]` for the ones known. An event's channels = every channel a
  non-deleted kind 9 with its `a` tag or URL is in (not its own chat). The older "📅 …" post
  with only the `a` tag stays the card alone.
- **Co-host link.** `POST <channel invites> {"channel":g,"role":"host","people":1,
  "link_days":1}`. Used by an account: it becomes an admin of `g`. Used by someone new: they join
  as a guest and the answer has `email_needed: true`; once their e-mail is saved and proven, the
  client posts `…/channel-invites/<token>/join` again with the account.
- **Lists.** Past = ends before today 00:00 local; Mine = not past and my state is not none /
  declined / can't go (includes hosting); Your events (drawer) = Belfry events I host or hold /
  ask a place at, ending at most 30 days ago.

### 19.19 Push notifications (collective-belfry `docs/push.md`, 2026-11-11)

The contract is `docs/push.md` in collective-belfry (server, gateway and both apps build against
it; the server is built, its *(built)* notes are folded in here); this section only says what a
client does. The same section is in the iPhone app's SPEC (19.19). Vectors: `vectors/push.json`
(made with the web's nostr-tools by `tools/vectors/push.mjs`; the server's payloads decrypt with
them).

- **Device key.** The device makes a random 32-byte key `K` per belfry and keeps it where its
  notification code can read it (iOS: the keychain group shared with the Notification Service
  Extension; Android: the Keystore-encrypted `Secrets`, read by the FCM service). `K` is used
  directly as the NIP-44 v2 conversation key (no ECDH).
- **Register** on every start once the person allowed notifications (never ask at launch: ask
  where it explains itself, e.g. a "Get notified" row the first time a channel opens, or Me →
  Notifications; Android: Me → Notifications or a push level picked in a channel's bell; the
  Android 13+ `POST_NOTIFICATIONS` permission): `POST <api>/push/devices` (NIP-98)
  `{"add":{"platform":"apns"|"fcm","token":<hex APNs token | FCM token>,"env":"production"|"sandbox",
  "key":<base64 K>,"app":"belfry-ios"|"belfry-android","name":<device model>}}` → `{"id"}`. The
  same token again replaces the old row (Android also registers on a new FCM token). The belfry
  drops a device whose pass closed, on a gateway 410, or after 60 days without a call.
  **Sign-out**: `{"remove":<token>}` before the session is revoked; forget `K`.
- **Payload.** APNs: `aps.alert` is a placeholder, `mutable-content: 1`, `aps.thread-id` =
  collapse, custom key `b` = base64 NIP-44 v2 ciphertext. FCM: data-only, `data.b`, high priority
  when urgent (dm, mention, reply, announcement; not pin, message). Plaintext:
  `{"v":1,"domain","type":"dm"|"mention"|"reply"|"announcement"|"pin"|"message","title","body",
  "channel"?,"event"?,"from"?,"url"}`; a client shows `title` and `body` (≤ 180), groups by
  `dm` / the channel, and ignores a payload whose `v` is not 1, whose `domain` is not the belfry
  the key belongs to, or that does not open (the placeholder stays). As built:
  - dm: `title` = the belfry's name, `body` = "New message", no `from` / `channel` / `event`
    (the belfry can't read gift wraps); `url` = `https://chat.<domain>/#/dm`.
  - pin: `title` = "📌 #channel", `body` = the pinned message's author and text; `event` and
    `from` are the pinned message's. announcement: `title` = "📣 #channel".
  - A thread reply's `url` is its thread, `#/c/<id>/thread/<root id>` (`event` = the reply's
    own id). `title` = the channel's label (`#name`, or a pod's / event's own name). A message
    without text says "📷 Photo" (or "…").
- **Channels / grouping.** Android notification channels: dm → Direct messages; mention, reply →
  Mentions and replies; announcement → Announcements; pin → Pinned; message (and an unknown type)
  → All messages. One notification per conversation (`dm`, else the group id).
- **Own copies.** NIP-17 senders also wrap a copy to themselves, which the belfry can't tell
  apart: a "dm" arriving within 30 s of this phone sending a DM or e-mail is not shown, nor one
  arriving while Messages or a conversation is on screen in the foreground.
- **Tap.** Only when `url`'s host is `chat.<domain>` of the signed-in belfry (and `domain` is
  that belfry): `#/c/<id>/m/<event>` opens the channel at the message, `#/c/<id>/thread/<root>`
  that thread, `#/c/<id>` the channel, `#/dm` Messages; anything else opens the app's home. Ids
  are checked (`[A-Za-z0-9_.-]{1,64}`, 64 hex). `url` is never shown.
- **Settings.** `POST <api>/notifications` `{}` reads, `{"set":{…}}` merges: `dms`, `mentions`,
  `announcements`, `pins` (booleans, default true; `mentions` covers replies too, `dms` covers
  e-mail threads) and `channels` = {group id: `all` | `default` | `mentions` | `off`} (absent =
  `default`). all = every message and thread reply plus what default notifies; default =
  mentions of me, replies to me, announcements, pinned messages (each subject to its switch);
  mentions = mentions and replies only; off = nothing. Me → Notifications shows the four switches
  and each of my channels' level; a channel's bell shows its push level next to the e-mail follow.
- A build without push (Android: no `google-services.json`) says so; the settings can still be
  changed (they apply to the person's other devices).
- (iOS) The Notification Service Extension cannot drop a notification without Apple's
  notification-filtering entitlement, so an own copy that arrives in the background is delivered
  silently (passive, no sound); in the foreground it is not presented.

### 19.20 Signing in without a browser (collective-belfry `sessions.py`, 2026-11-12)

The default sign-in of the phone apps. Section 2 (the browser, OAuth code + PKCE) stays as the
second way ("Sign in with the browser instead") and is what the app offers by itself on an older
belfry. The contract is the module docstring of `services/onboarding/belfry_onboarding/sessions.py`.

- **Screen 1.** One field, the member's address `name@domain` (e-mail keyboard, no
  capitalisation, ≥ 16 pt). Accept it only as: trimmed, lower-cased, exactly one `@`, name
  `[a-z0-9][a-z0-9._-]{0,63}`, domain a hostname (section 1's rule). Fetch
  `https://<domain>/.well-known/belfry.json`; no document → "There is no belfry at <domain>."
  (the domain is the one typed and validated; nothing from an answer is shown).
- **Session key.** The app makes the NIP-46 client key *before* asking (a fresh 32-byte key)
  and keeps it with the address in secure storage until the sign-in ends: the same key signs
  the resend, the verify, and is the client key of the session afterwards (the belfry binds the
  connection to it when it creates it). Keep the pending request across a process death: the
  person leaves the app to read the e-mail. A new address, or `key_taken`, makes a new key.
- **Ask for a code.** `POST <api.base>/session`, NIP-98 signed **by the session key**, body
  `{"nip05":"name@domain","app":"sh.belfry.app://connect","client":"belfry-android"}` (iOS:
  `belfry-ios`; `client` names the session, `app` is the approved native app address).
  - 200 `{"state":"code_sent","to":"x•••@example.org","nip05":"name@domain"}` → screen 2. Show
    `to` only when it matches `^[^\s@•]•••@<hostname>$` (≤ 260 characters); otherwise say "your
    e-mail address".
  - `{"error": key}` → a fixed message per key: 404 `unknown` (no such member here, or the
    belfry answers for another domain), 409 `no_email`, 422 `invalid` (also `app_address`), 429
    `too_many` ("try again in half an hour"), 401 `unauthorized` (a wrong clock is the usual
    cause).
  - 404 / 405 **without an `error` key** (FastAPI's `{"detail":"Not Found"}`, a proxy's page):
    an older belfry → say so and turn the main button into the browser sign-in of section 2.
- **NIP-98 `created_at`.** The belfry accepts each signed event once. Use
  `max(last + 1, now)` for these calls so a resend or a retry in the same second is a different
  event.
- **Screen 2.** Six digit boxes over one numeric field (number pad; typing advances, backspace
  goes back; whatever is typed or pasted is reduced to its first six ASCII digits, so "123 456"
  fills them); the sixth digit submits. "Send a new code" repeats the first request with the same
  key and is locked for 30 s after each send. Back (the system's and a "Use another address"
  row) returns to screen 1 with the address still in the field. The request lives 15 minutes on
  the belfry (a code 10): after that the app forgets it.
- **Verify.** `POST <api.base>/session/verify` `{"code":"123456"}`, signed by the same key.
  - 200 `{"state":"open","bunker_url":"bunker://…","pubkey":"<hex>","npub":"…","nip05":"…"}`:
    accept only with `state` = `open`, a parsable bunker URL and a 64-hex `pubkey`. Connect as
    in section 3 with the session key, then ask the signer `get_public_key` (do not trust the
    answer's `pubkey` for that): it **must equal** `pubkey`, else disconnect, forget the request
    and show the `mismatch` message. Store the session exactly like section 2's. Keep the bunker
    URL with the pending request until the signer has answered: the code is spent, so "Try
    again" after a timeout reconnects without a second verify.
  - 422 `wrong_code` with `tries_left` (int): empty the boxes, "That code is not right. N tries
    left." (0 → "Ask for a new one."). 410 `expired` → screen 1 with a fixed note. 409
    `key_taken` → forget the key, screen 1 (the next try makes a new key). 409 `own_key` (the
    member holds their own key: the app cannot sign them in yet), 409 `mismatch`, 403
    `app_not_approved` → screen 1 with their messages. 429, no connection → stay on screen 2
    with the digits and a "Try again" button.
- The server's `message` field is never shown. Guest links (19.4) are unchanged.
- Android: `core/net/NativeSignIn.kt` (the two calls, the checks), `Onboarding.requestCode /
  resendCode / verifyCode / pendingCode` (vault key `native-signin`), `ui/signin/SignInScreen.kt`
  (`SignInContent`, `CodeContent`, `CodeBoxes`); tests `NativeSignInTest`.
- (iOS) Differences from the text above, to carry back to Android's:
  - **The endpoint is named by belfry.json**: `sign_in.sessions.api` is the full address of the
    session endpoint (`https://belfry.<domain>/api/v1/session`; verify = that + `/verify`). The
    iPhone app posts there (https only), not to `<api.base>/session`. No such key = an older
    belfry: nothing is asked and the browser sign-in is offered; a 404 / 405 without an `error`
    key from the address named is read the same way.
  - **503 `signer`** on verify (since collective-belfry 60c82bf): the belfry's own signer did
    not answer it. The code is spent but the request stands: empty the boxes, say so, and
    unlock "Send a new code" at once (no 30 s wait). Before that commit this case read `own_key`.
  - A signer that does not answer *this phone* after a right code is the app's own `connect`
    failure: screen 2 stays with the digits and "Try again", which reconnects with the bunker
    address kept (no second verify).
  - The code field carries the system's one-time-code hint (`.textContentType(.oneTimeCode)`):
    iOS offers the code from Mail / Messages above the keyboard.
  - `Sources/BelfryCore/Net/NativeSignIn.swift` (`MemberAddress`, `NativeSignIn`: the two calls
    and the checks; `NativeSignInFlow`: the request kept in the Keychain under `native-signin`,
    service `sh.belfry.app.session.keys`), `App/Sources/SignInView.swift` (`AddressScreen`,
    `CodeScreen`, `CodeBoxes`), `AppModel+SignIn.swift`; tests `NativeSignInTests`.

### 19.26 Guest mode: opening an invitation reads the channel at once (2026-11-12)

(collective-belfry `docs/guests.md` "Opening it: guest mode", `guests.py`; web village-app
b2e968b `core/guestmode.ts`, `core/guestjoin.ts`, `ui/GuestJoin.tsx`.) Replaces the name screen
of 19.4 for people who have no account on that belfry. Joining with an account (19.4, 19.24's
"which account?") is unchanged.

- **Opening the link, no account here.** No screen asks anything. The device makes its session
  key (one per invitation, kept until the join succeeds: a retry signs with the same key and the
  belfry answers with the same guest) and sends `POST <api.channel_invites>/<token>/join` with
  body `{}` (NIP-98 by that key). 200 →
  `{"channel","new":true,"guest":true,"reading":true,"bunker_url","pubkey"}`. The session's
  pubkey is the answer's `pubkey` (do not ask the signer for it first). `reading` absent or
  `true` → guest mode; `false` (a belfry that still names guests) → a plain unsaved guest.
  Errors by code, fixed texts: 410 `closed` "This invite can’t be used any more. Ask for a new
  one.", 410 `for_agent` "This link is for an AI agent, not a person.", 409 `unsupported` "This
  belfry does not take guests.", 422 `name_needed` (an older belfry) "This belfry is being
  updated. Try again in a few minutes.", 409 `session_taken`: forget the key, make a new one and
  send once more (then give up). The invite's info (`GET …/<token>`) is read alongside for the
  loading line and, when the join fails, to say why (`state` used / expired / revoked → its
  fixed text, 19.4).
- **One loading screen** from the moment the link is read until the channel can be drawn in
  full: a spinner and "Opening # <channel_name>…" ("Opening…" until the info is in). It stays
  while the session is made and until the groups relay has sent its stored events (EOSE) or
  refused the key, at most 10 s after the session exists. Nothing else is drawn in between: no
  empty channel ("… is new · Invite people"), no home. A failure replaces it with the fixed
  "This invite can’t be used" screen (Try again when not closed, "I have an account: sign in",
  Close).
- **Guest mode** (the device's guest record says `reading`; kept with the saved session): the
  channel shows; where the composer would be, a bar "**Guest mode** · You’re reading
  # <channel> as a guest." with **Join**. The thread screen and inline threads show the same bar
  (no reply box). An empty channel says "No messages here yet." (no Invite button).
  **Nothing is sent**: every write (messages, replies, reactions, edits, RSVPs, votes, to-dos,
  profile, invites, follows, the first channel of an empty belfry, any belfry API call that
  changes something) is refused on the device where events are queued and API writes are made,
  and opens the Join sheet instead. No `seen` mark (19.21 / 11) is sent. Allowed: reading,
  `GET`s, push registration, `/guest/save`, `/guest/save/verify`, revoking the own session,
  using another link. Long-press / "add a reaction" on a message opens the Join sheet. The
  relay does not enforce this: it would store what such a key signs.
- **The Join sheet** ("Join # <channel>"): "Your name and e-mail address, and you can write
  here. We’ll send a 6-digit code to your e-mail to confirm it." Fields name (required, ≤100,
  spaces folded) and e-mail (required, `\S+@\S+\.\S+`), Continue, then "Already have an account
  on <domain>? Use its e-mail address." Continue → `POST <api>/guest/save {"email","name"}` →
  202. The code step: title **"Check your e-mail"**, "We sent a 6-digit code by e-mail to
  <the address as typed>. It can take a minute.", six boxes (the sign-in's), the sixth digit
  sends `POST <api>/guest/save/verify {"email","code","name"}` → 200
  `{"saved":true,"joined":bool}`; the guest record becomes saved and not reading, the bar goes
  and the composer is there (the channel then gets the guest's second 9000 with `name`: the join
  line). Under the boxes "Checking the code…" / the error / "Not there? Look in your spam
  folder."; "Send a new code" (locked 30 s after each send; "A new code is on its way to your
  e-mail.") and "Use another address" (back to the fields).
- **Errors** (never the server's text): `invalid` "That doesn’t look like an e-mail address.",
  `name_needed` "Your name is needed to join.", `too_many` "Too many codes for now. Try again in
  half an hour.", `wrong_code` with `tries_left` (int, collective-belfry d2b4c52) "That code is
  not right. N tries left." / "… 1 try left." / (0) "That code is not right. Send a new one.",
  without it "That code is not right. Check the e-mail and try again." (boxes emptied), `expired` "That code has expired. Send a new one.", `not_guest` "This guest access
  has ended. Ask for a new invite.", no connection "No connection. Try again.", else "That did
  not work. Try again.". 409 `taken` (body `{"error":"taken","moved":bool,"nip05"?}`; `nip05` =
  that account's name@domain when the belfry can read it, d2b4c52): a step titled
  "You have an account here": "<address> already has an account on <domain>." + (moved) "Sign
  in with it: # <channel> is waiting there." / (not moved) "Sign in with it instead." and
  **Sign in instead** (+ "Use another address" when not moved). Sign in instead: the guest
  account is dropped from the device (its session revoked unless `moved`, where the belfry closed
  it already), the native sign-in (19.20) starts, and once signed in the channel opens. The
  native sign-in takes `name@domain`: its address field gets the answer's `nip05` when that is a
  `name@domain` of this belfry (lower-cased), else the typed e-mail when it is one; otherwise the
  field is empty with the fixed hint
  "Sign in with your address here (name@<domain>), or with the browser using the e-mail you
  typed." (The web's browser sign-in takes the e-mail itself.)
- **The save-your-account bar** of a guest who has a name but no e-mail (19.3: after their first
  message / reply / reaction, or a co-host link) opens the same sheet without the name field:
  title "Save your account", "Add your e-mail address to come back from any device. We’ll send a
  6-digit code to it.", body `{"email"}` / `{"email","code"}`. Done: "Saved. Sign in with
  <address> on any device." The bar is never shown in guest mode.
- **Other people's reading guests** (how everyone else's client reads the events). A key is
  **reading** in a channel when its latest kind 9000 there (in time order) carries
  `["reading","1"]`; a later 9000 without it, a kind 1985 `L belfry/guest` with `l saved` or
  `l member` for that `p`, or a 9001 ends it. For reading keys (except me): no join line ("…
  joined as a guest", 19.3), not in the channel's members (also when the relay's 39002 lists
  them), member counts, "active this month", the channel line's faces or mention / invite
  pickers. The Members tab adds one line "1 guest is reading" / "N guests are reading: they
  opened an invite link and have not joined yet." The join line comes from the later 9000
  without `reading` (which carries the name). A guest put in with a name and `unsaved` (a
  meeting's held guests, older links) never carries `reading` and is **not** hidden.
- Vectors: `vectors/guestmode.json` (events → reading keys, members, join lines per channel).
- (iOS) Differences from the text above, to carry back to Android's:
  - **`tries_left` and `nip05`** (collective-belfry d2b4c52): 422 `wrong_code` carries an int
    `tries_left` → "That code is not right. N tries left." ("1 try left."; 0 → "That code is not
    right. Ask for a new one."; absent → the text above). 409 `taken` carries `nip05` (that
    account's `name@domain`) when the belfry can read it: "Sign in instead" puts it in the native
    sign-in's address field; without it, the typed e-mail when it is `name@<domain>`; else the
    field is empty with the fixed hint above.
  - **No push registration while reading** (the web has no push; iOS registers once joined): the
    task asked for nothing to be sent before Join. `/whois` (a read sent as a POST) is allowed.
  - Automatic writes are skipped, not refused, while reading (seen marks, the first channel,
    push), so they never open the Join sheet by themselves.
  - Code: `Sources/BelfryCore/Model/GuestMode.swift` (`GuestModeGate`: `reading`, `refuse()`,
    `check(url:method:)`, `allowsWhileReading`; `GuestJoinError` / `GuestJoinFailure`;
    `GuestJoinForm`), `SyncEngine.guestMode` (enqueue / enqueueSigned return "" and ask to join;
    `signedRequest` and `upload` throw), `BelfryAPI(guestMode:)` (`signed` throws `guest_mode`),
    `DirectMessages` sends check it; `Derive`: `Group.reading`, `readingCount`, `onlyReading`,
    `amReading`; `BelfryAPI.joinAsNew(name: nil)` → `JoinedNew.reading`, `guestSave(email:name:)`,
    `guestVerify(email:code:name:) -> joined`. App: `AppModel+Guest.swift` (`openInvite`, the
    loading screen's wait, `sendJoinCode` / `verifyJoinCode`, `finishJoining`, `signInInstead`;
    `StoredSession.reading` / `guestChannel` in the Keychain), `GuestUI.swift` (`OpeningScreen`,
    `InviteProblemScreen`, `GuestBar`, `JoinSheet`). The Join sheet is presented from the root, so
    a write refused inside another sheet (channel details, an event page) opens it only once that
    sheet is closed. Tests `GuestModeTests`. Demo: `-guest opening|feed|join|code` (code 123456;
    `taken@example.org` answers `taken`, moved).
