# Parity with the web chat

Reference: `village-app`, branch `belfry-chat`, at commit ef9e1cc (2026-11-10), Belfry theme,
plus `commonshub/collective-belfry` `chat-source` 85ede89 (Reply opens the thread's own view).
Second reading: the Android app (opencollective/belfry-android 2ce8be8, its PARITY.md). Same
shape as Android's file. Status words: **done** (built, compiled in CI, rendered in demo mode by
the screenshot job, and covered by a core test where noted), **partial** (what is missing is
named), **not yet**.

Read this first: **nothing has run on a phone, and nothing has talked to a real belfry.** No Mac
here: the app is only compiled and screenshotted in the iOS simulator by CI (demo mode, seeded
community, no network). "Done" means the code follows the protocol contract (SPEC.md + the
shared vectors, which the core passes), compiles, and its screen renders with the demo data.
Sign-in, the signer (NIP-46), relays, uploads, the photo picker, universal links, the keyboard
and gestures are untested in the real world. XCTest covers the core (BelfryCore), not the UI.

## Protocol core (`Sources/BelfryCore`, `swift test`)

| Area | Status | Notes |
|---|---|---|
| Events, ids, BIP-340, bech32, NIP-44 v2, NIP-59 | done | `events.json`, `nip44.json`. |
| Channels, messages, reactions, threads, mentions, actions, active members, admin rights | done | Every case of the shared vectors. |
| Markdown subset, MIME, mail threads, outbox pass | done | `outbox.json` includes refused uploads (4xx but 401/408/429 permanent, SPEC 19.17). |
| Channel references (NIP-19 naddr of kind 39000) | done | `channel-refs.json` (encode / decode / previews) + picker test. |
| Edits (1010, only the author's latest), delete preview, pins (1985 `belfry/pin`, admins only), to-dos (2100-2103, `q`), member labels, drop links, inbox card state | done | `AdditionsTests`. |
| Guests: `agent`, `unsaved`, `saved` / `member` labels, cleaned-up joins, whois overrules events, members' own agents (belfry.json `agents`) | done | `GuestsTests`. |
| Belfry events (rule B, hosts, tickets, applications, holders, my state, lists, cards from URLs), proposals, the channel line | done | `EventsTests`, `LineAndLinksTests`, `EventsApiTests` (the API's answer). |
| Profiles: tags and places (30078 `belfry:profile`) | done | Parse / write test; subscription filter on the community relay. |
| belfry.json revalidated (`Cache-Control: no-cache`, `If-None-Match`, 304 keeps the copy) | done | At start, on a profile / members list (30 s), after admin / agent changes. No test against a server. |
| HTTP API (guest links, channel guests, whois, agents, invites, join, guest save, places, admins, follows, username, sessions, website, events) | done, never run live | `Net/Api.swift`, `Net/EventsApi.swift`; fixed messages by `error` code. |
| Relay, NIP-46, sync engine, DMs, e-mail | done (milestone 1) | Engine tests against fakes. |

## Sign-in and joining

| Web feature | Status | Notes |
|---|---|---|
| Sign in with e-mail + code (`/connect`, PKCE → bunker) | done, never run live | `ASWebAuthenticationSession` → `sh.belfry.app://connect` (approved server-side). |
| Guest link `https://chat.<domain>/join/<token>`: join as someone new with a name | done, never run live | One session key per invite in the Keychain until the join works; `session_taken` → new key. Universal link entitlement for `chat.belfry.sh`, `chat.enspiral.eu`; the server serves no `apple-app-site-association` yet (SERVER-NEEDS 5), so links open the web chat until then. Join screen rendered with demo invite data. |
| Guest link opened by an account: joins as itself | done, never run live | Sheet "Join with your account"; another community's link → fixed message. |
| Pending invite kept through sign-in | done | Only domain + token kept (UserDefaults). |
| Closed / expired / unknown link | done | Fixed messages by `state` / 404. |
| Save your account (guest: e-mail + code) | done, never run live | Bar above the composer after my first message, and a card on Me. |
| Sign out ends the session | done, never run live | `POST /me/sessions/revoke {bunker_pubkey}` (best effort, 3 s), then the device is wiped. |
| Signed-in devices: list, this device, end one | done, never run live | |
| Demo mode | done | "Try the demo"; `-demo -screen …` for screenshots. |

## Layout and navigation

| Web feature | Status | Notes |
|---|---|---|
| Channel list, Messages with unread count, "All events", "Your events" | done | `NavigationSplitView` sidebar (iOS idiom for the web's drawer); pod shapes; event chats only under "Your events". |
| One summary line under the channel name + pull-down (Pinned, Coming up, To decide, To do, Pods, Topics, people) | done | SPEC 19.13 priority and counts, core-tested. The pull-down is a sheet with detents (SPEC 16). Day labels fixed English, 24 h. |
| Pod marks (polygon, one side per member; circle from 13) | done | Sidebar, header, cards, pull-down. |
| Back buttons never push | done | NavigationStack pops only. |
| Large screens: thread in a third column | not yet | Threads open as a pushed screen on iPad too. |

## Channel feed

| Web feature | Status | Notes |
|---|---|---|
| Messages, day separators (year for other years), blocks, Markdown, links | done | Layout rules of SPEC 19.7 from the core (`feedRows`). |
| Mentions (@ picker marks "not in this channel"; tap → profile) | done | Note above the field for a picked person who can't read the channel, with Invite / Add as a guest. |
| #channel references (# picker → `nostr:naddr…`, "#name" opens the channel) | done | Unknown channel "#channel", other naddr "Nostr address" (never raw). Edit shows them as "#name" again. |
| #topics (chips for topics not spelled, tap filters the channel) | done | Pin / unpin in the pull-down's Topics. |
| Photos in messages | partial | Grid in Files; no full-screen viewer yet. Other files as attachments: not yet (photos only). |
| Reactions (quick row in the menu, more, undo) | done | |
| Threads: chip, inline unfold (latest 3, show earlier, reply box), "Open thread", thread screen, resurfacing | done | Reply opens the thread screen with its box focused (chat-source 85ede89). |
| Edit my message, "edited" mark | done | Edit sheet; core test. |
| Delete with an in-app confirmation showing the message | done | Inside the menu sheet. |
| Message menu as a list (reactions, Reply, Open thread, Edit, Copy text, Copy link, Message the author, Pin, Turn into a to-do, Make this the website, Delete) | done | Sheet with grouped rows and line icons. "Copy link" copies the channel's link (no per-message link on the web either). |
| Pin / unpin (admins), pinned mark | done | |
| Turn into a to-do; the mark ticks it off | done | |
| Outbox states: Sending… / Waiting… / Not sent · Retry, Discard | done | Retry / Discard lock while they run. |
| Announcements (admins), marked | done | |
| Join lines (guest / agent / member's agent, invited by, not saved; hidden when removed without writing) | done | |
| "Created a pod / a proposal / an event" + cards | done | Pod, proposal, event, member e-mail, inbox card, sent-as-channel. |
| ＋ menu: Photo, To-do, Event, Pod, Proposal, Announcement | done | Drop box links are in channel info → Files. |
| Seen events (6 h) and "active this month" | done | |
| Search (this channel / all, accent-folded, marks, opens on the message with a flash) | done | |

## Channel info

| Web feature | Status | Notes |
|---|---|---|
| Tabs: About, Members, To-dos, Files, Settings | done | Segmented control in a sheet. |
| About: description, e-mail address, follow bell, active list, events, pods, proposals, join / leave | done | |
| Members: guests / agents / not saved, invited by, admin mark, place, labels editor (admins) | done | Members map (Leaflet on the web): not yet (places are listed). |
| To-dos: add, tick, take / let go, comments, delete own | done | |
| Files: photos, files, drop box links (new: 1 day / 1 week / 1 month, anyone / signed in; QR, share, end) | done | |
| Settings (admins): name, description, pod access + question, "E-mails from anyone" | done | |
| Invite: someone who is here already (members, guests, agents; DM with the link; admit in a closed group I administer; `/channel-guests`), member link + QR, guest link (1 / 50 people; 1 day / 1 week / 1 month) + QR, "My own agent" | done, never run live | Agent switch shown when `POST /agents` gives a limit; off when the limit is reached. |
| Follow bell (off / as they happen / monthly) | done, never run live | |
| Pods: join, ask to join (question), admit / decline applications | done | |
| Proposals: card, status, tally, vote, change status, new version (author) | done | |

## E-mail

| Web feature | Status | Notes |
|---|---|---|
| Member's e-mail as their message ("via e-mail", subject) | done | |
| Inbox cards: sender, verified, subject, Open / Answered / Closed, take / let go, close / reopen | done | |
| Reply by e-mail as the channel, 8 s Undo | done, never run live | Admins only. "Full e-mail" (original from Blossom): not yet. |
| DMs, e-mail threads | done (milestone 1) | |

## People

| Web feature | Status | Notes |
|---|---|---|
| Profile: picture, name, address, about, tags, place, chips, shared channels, Message | done | Opens from a face, a name or a mention. |
| Agents: "agent of …", Make it my agent, Remove this agent… (confirmation), error codes | done, never run live | |
| Edit profile: name, username (`POST /username`), about, picture (≤ 512 px), tags with suggestions, place (city search, add a place, country only, nothing) | done, never run live | Never device GPS. |
| "Admin of the belfry" switch with the guest / agent rules | done, never run live | |
| Me: card, address, key copy, devices, outbox count, save account, sign out | done | |

## Belfry events (SPEC 19.18)

| Web feature | Status | Notes |
|---|---|---|
| Model: `ev-<d>`, rule B, status, versions, visibility, slug, cover, channels | done | Core tests. |
| Cards from `https://<domain>/events/<link>` (sent with the `a` tag) | done | Up to three per message. |
| All events (Upcoming / Mine / Hosting / Past), New event | done | |
| "Your events" in the sidebar | done | |
| Event page: cover, the line (cancelled / changed · still going? / asking / my state), when, where, online link, RSVP, tickets (take / apply / waitlist / members only), my application + Withdraw, hosts, description, address (copy, share, QR), the event's chat | done | One page (sheet); the event's chat has a bar back to the event. |
| Hosts: guest list (Asking / Waitlist / Going / Others), approve / decline (one lock), make co-host, tickets sheet, co-host link, cancel (with a line) / reopen, delete (creator) | done, never run live | Guest co-hosts decide through `POST /events/<d>/decide`. |
| Create / edit: title, cover upload, all day, start / end, where (suggestions), online + Jitsi, description, who sees it, who can come (application + question), URL checked as typed | done, never run live | Times in the device's zone (no zone picker). Made from a channel's ＋: the URL goes into that composer. |
| Events read through the API (guests) | done, never run live | Cached a minute; `members_only` / `not_found` → fixed messages. |
| Opening `https://chat.<domain>/events/<link>` from outside | done, never run live | Universal link (same entitlement as guest links); needs SERVER-NEEDS 5. |
| Signed-out event page (RSVP with a name) | not yet | Sign in first. |
| Co-host link used by someone new (e-mail first, then the link again) | done, never run live | `email_needed` → save-account card says why; after the code, the link is used with the account. |
| Prices, payments, check-in | not in v1 | Neither on the web. |

## Not in the web chat, or out of scope

| Item | Status | Notes |
|---|---|---|
| Notifications (APNs, docs/push.md; SPEC 19.19) | done, never run live | Notification Service Extension `sh.belfry.app.notifications` decrypts `b` with K (core-tested with sample payloads), sets title / body / thread / url; K in the keychain group shared through the App Group; registers on every start once allowed (`/push/devices`), removed on sign-out before the revoke; asked from a "Get notified" row in a channel or Me → Notifications (never at launch); settings (four switches, a level per channel; the channel bell shows its push level); a tap opens the channel at the message after checking `chat.<domain>`. Needs the Apple portal set-up (SERVER-NEEDS 3) and the gateway; the web chat has none. |
| OSV access grants | n/a | Hidden in the Belfry theme. |
| TestFlight | waiting | The job runs when Xavier adds the four App Store Connect secrets. |
