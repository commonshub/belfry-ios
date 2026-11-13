# Belfry for iPhone: notes for agents

Native SwiftUI client for a community's belfry (self-hosted community server). The protocol is in
[SPEC.md](SPEC.md) (platform-neutral; section 19 = the additions since milestone 1, written by
the Android app and ported here). The web chat (`village-app`, branch `belfry-chat`; also
`commonshub/collective-belfry` branch `chat-source`) is the reference implementation: read it,
don't guess. The Android app (opencollective/belfry-android) is a second reading. What is done:
[PARITY.md](PARITY.md). What the server must add: [SERVER-NEEDS.md](SERVER-NEEDS.md).

`vectors/` is the contract shared with Android: keep both repos' files identical (copy, don't
edit one side). SPEC.md differs from Android's only in the paragraph that opens section 19 and the (iOS) notes
that end 19.19, 19.20 and 19.26 (Android's 19.21 to 19.25 are not ported yet). `vectors/guestmode.json` is Android's.

## Layout

- `SPEC.md`: what a correct Belfry chat client does. Update it when behaviour changes; mark
  unknowns as open questions (section 18).
- `vectors/*.json`: shared test cases. Generated from the web chat's own code:
  `VILLAGE=~/agents/belfry/work/village-app node tools/vectors/build.mjs` (needs the village-app
  checkout with node_modules; `tools/vectors/gen.ts` defines the cases, `stubs/` replace its
  IndexedDB/relay modules). `channel-refs.json` and `push.json` come from `tools/vectors/channel-refs.mjs` / `push.mjs`
  (Android's; the web's nostr-tools). `nip44.json` is the official NIP-44 file (sha256 269ed0f6…5040).
- `Package.swift` → `Sources/BelfryCore`: everything that is not UI.
  - `Crypto/`: hex, HMAC/HKDF, ChaCha20, NIP-44 v2, BIP-340 + ECDH via swift-secp256k1 (P256K,
    pinned 0.23.2; only `Keys.swift` imports it: P256K and CryptoKit both define SHA256), bech32.
  - `Nostr/`: events (canonical serialization, ids), `Signer` protocol, `LocalSigner`.
  - `Model/Derive.swift`: port of `src/core/model.ts`. `Derive` is a **final class snapshot** of
    the log + `WorldContext` (me, domain, community admins, groups key, groups relay, belfry.json
    `agents`, whois `kinds`, pending outbox ids, time zone); every view is computed on first use
    and cached (lazy vars / per-group dictionaries; not thread-safe, the app reads it on the main
    actor). Groups, messages (author's latest edit, specials, event refs), reactions, threads,
    feed + `feedRows`, guests, pins, to-dos, drop links, inbox state, labels, extras, search.
    Extensions: `Events.swift` (calendar, rule B, tickets, my state, lists), `Proposals.swift`,
    `ChannelLine.swift` (the one line, pod shapes), `ChannelRefs.swift` (naddr references),
    `Access.swift` (guest / agent / inChannel / invite text), `People.swift` (tags, places).
    `Actions.swift` + `Actions2.swift` (+ `EventActions`): the events each action queues.
    `Text.swift`: hashtags, mentions, JS-like regex helper (`Rx`, UTF-16 offsets).
  - `Mail/`: mail-thread keys, MIME read/write. `Markdown/`: the subset as a tree + e-mail HTML.
  - `Outbox/`: outbox items, error classes, one flush pass (pure, tested).
  - `Net/`: discovery + PKCE sign-in (belfry.json revalidated with ETag), `NativeSignIn.swift`
    (SPEC 19.20: `MemberAddress`, the two signed calls, `NativeSignInFlow` over a `Vault`), `Relay`
    (URLSessionWebSocketTask, NIP-42), `BunkerSigner` (NIP-46), `SyncEngine` (relays,
    subscriptions, outbox, watchdog, NWPathMonitor), `Api.swift` (`BelfryAPI`: the belfry's HTTP
    API, NIP-98, `ApiError` with fixed messages per `error` code; `InviteLink`), `EventsApi.swift`.
  - `Crypto/Nip19.swift`: naddr encode / decode.
  - `Store/Database.swift`: SQLite (events, outbox, kv). `DM/`: gift wraps, `DirectMessages`.
- `Tests/BelfryCoreTests`: XCTest against `vectors/` (found via `#filePath`).
- `App/Sources`: the SwiftUI app. `AppModel` (state + actions; `+People`: joining, profiles,
  agents, sessions, follows, drop links; `+Events`). Views: `RootView` (sidebar, routing of sheets
  by `model.openProfile / openEvent / showEvents / messageAuthor / pendingInvite`), `ChannelView`
  (+ `PullDown` line and sheet, `MessageRow` + cards, `MessageActions` menu / delete / edit /
  mail reply, `Composer` with @ and # pickers and the ＋ menu, `ThreadView` + `ChannelSearch`),
  `ChannelDetails` (tabs + invite sheet), `PeopleUI` (profile, edit, Me, devices, save account),
  `SignInView` (address → six code boxes, `CodeBoxes` also used by the Join sheet: no length
  limit, digits via `NativeSignIn.next`; a failed connection keeps the digits + "Try again", only
  wrong / expired codes clear them; the browser as a second row; `AppModel+SignIn`),
  `JoinUI` (guest links signed in), `GuestUI` + `AppModel+Guest` (guest mode, SPEC 19.26: the
  loading screen, the guest bar, the Join sheet), `EventsUI`, `Kit` (BusyButton, ActionRow, PodShape, ChannelGlyph,
  Chip, `openChannel` environment). `project.yml` is the XcodeGen spec; the `.xcodeproj`,
  `App/Info.plist` and `App/Belfry.entitlements` are generated, not committed.
- `SERVER-NEEDS.md`: changes the belfry must make for this app (redirect URI, push…). This repo
  never touches the servers.

## Building (no Mac here: CI only)

This Linux box has no Xcode. Push and let GitHub Actions build (`gh run watch`, `gh run view
--log`, `gh run download <id> -n screenshots`):

- `core`: `swift test` on macos-15 (Xcode 16.4, Swift 6.1). Core is Swift language mode 5.
- `app`: `xcodegen generate`, `xcodebuild … -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO
  -skipPackagePluginValidation build` (P256K uses a build-tool plugin), then
  `scripts/screenshots.sh` boots a simulator and captures the screens in demo mode → artifact
  `screenshots`.
- `testflight`: runs on main only when these repository secrets exist (Xavier adds them):
  `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (App Store Connect API key with
  App Manager or Admin role; contents of the .p8). Signing is automatic through the API key
  (`-allowProvisioningUpdates`); the app record `sh.belfry.app` must exist in App Store Connect.

Demo mode: launch argument `-demo` (or "Try the demo" on the sign-in screen) seeds a made-up
community on the device (`App/Sources/Demo.swift`: edits, a pin, to-dos, a closed pod, a
proposal under vote, two Belfry events, a channel reference, an announcement, guests and an
agent), local-only. `-screen <name>` opens a screen for the screenshot job (`scripts/
screenshots.sh` lists them: feed, thread, details, invite, messages, conversation, mail, search,
channels, pulldown, menu, delete, edit, threadscreen, chsearch, add, pod, proposal, event,
profile, editprofile, me, members, todos, files, events, eventhost, eventform). `-join` (no
`-demo`) opens a demo guest link signed out (the loading screen, then guest mode). `-guest
opening|feed|join|code` shows guest mode's screens (the loading screen; #general read as a
guest; the Join sheet; its code step), demo code 123456. `-signin code` / `-signin older`
show the sign-in's code screen / the older-belfry state with made-up values (nothing is sent).

## UI rules (the owner's, not negotiable)

- Every button locks the moment it is tapped and shows progress until its work is done: use
  `BusyButton` / `ActionButtonRow` (Kit.swift), never a bare `Button { Task { … } }` for work.
  A double tap never sends twice.
- Menus and sheets are Discord-style grouped lists with a line icon (`ActionRow`), not stacked
  bordered buttons and not `.contextMenu`. Discord is the reference.
- No horizontal scrolling of a screen. A back button never pushes.
- Text fields ≥ 16 pt (`.font(.body)`).
- Never render text from a URL (a link gives only its domain and token / link); server errors →
  fixed messages by `error` code (`ApiError.message`).

## Decisions

- Bundle id `sh.belfry.app`, redirect `sh.belfry.app://connect`, client_id `belfry-ios`, client
  tag `["client","belfry-ios"]`.
- Push (collective-belfry `docs/push.md`, SPEC 19.19): target `NotificationService` (bundle
  `sh.belfry.app.notifications`, App/NotificationService) decrypts `b` with the device key K
  (BelfryCore `Push.open`, `PushKeyStore`); K lives in the keychain group
  `$(AppIdentifierPrefix)sh.belfry.app.shared` (Info.plist `BelfryKeychainGroup`; falls back to
  the app's own group on an unsigned build); App Group `group.sh.belfry.app`; `aps-environment`
  from `APS_ENVIRONMENT` (development / production). `AppDelegate` (in AppModel+Push) gets the
  token and the taps. The portal set-up Xavier must do is in SERVER-NEEDS 3.
- Sign-in (SPEC 19.20): native by default (`name@domain` → code by e-mail), the endpoint from
  belfry.json `sign_in.sessions.api`; the browser (`ASWebAuthenticationSession`, SPEC 2) is the
  second row and the fallback for a belfry without that key. The pending request (address,
  session key, later the bunker address) lives in the Keychain (service
  `sh.belfry.app.session.keys`, account `native-signin`) for at most 15 minutes. Never test it
  against a live belfry with a real member's name: it mails that person a code.
- Universal links: `applinks:chat.belfry.sh`, `applinks:chat.enspiral.eu` (project.yml
  entitlement) for `/join/<token>` and `/events/<link>`; the chat hosts must serve
  apple-app-site-association (SERVER-NEEDS 5). A guest's join session key lives in the Keychain
  (service `sh.belfry.app.session.keys`, account `join-<token>`) until the join works.
- Join sheet code step: after an attempt whose answer was lost (offline / failed), an expired /
  wrong_code / not_guest answer first checks the relay for the save (`GuestJoinSaved`, 6 s) and
  counts it as joined (web guestjoin.ts savedOnRelay).
- Guest mode (SPEC 19.26): `GuestModeGate` (BelfryCore) is the one check; `SyncEngine.guestMode`
  and `BelfryAPI(guestMode:)` carry it. Any new write path must go through the outbox or
  `BelfryAPI.signed` / `SyncEngine.signedRequest`, or check the gate itself. Automatic writes
  (seen marks, push registration) are skipped while reading, not refused (a refusal opens the
  Join sheet).
- iOS 17+. NavigationSplitView; channel details as a sheet with medium/large detents (web: custom
  pull-down) and the channel line's pull-down as a sheet too; the message menu as a sheet list (not
  `.contextMenu`); `.searchable`; `ShareLink`; CoreImage
  QR; `.refreshable` re-subscribes. Platform differences are listed in SPEC section 16.
- SQLite instead of SwiftData: plain tables, same shape as the web's IndexedDB, no schema magic.
- Relay events are signature-checked before storage; seals always.
- Never render text from a URL; server errors are mapped to fixed messages by their `error` code.

## Rules

- Push freely to `opencollective/belfry-ios`. Ask before: GitHub secrets, TestFlight/App Store
  submissions, other repos, anything on the Belfry servers. Never modify `village-app` or
  `collective-belfry` from here.
- Never print secrets. Commit messages end with the Co-Authored-By / Claude-Session lines.

## Known debt

- NSLock is used from async functions in `Net/` and `DM/` (warnings "unavailable from asynchronous
  contexts" in Swift 5 mode, errors in Swift 6). Move SyncEngine / DirectMessages / Relay state
  into actors before switching the package to Swift 6 language mode.
- A new `Derive` is built per change of the log (cached per `version`); some views (tasks, pins,
  proposals, calendar) scan the whole log. Fine for a community; index per group if logs grow
  past tens of thousands of events.
- Nothing has run on a device or against a real belfry (see PARITY.md). The UI has no XCTest
  (only the core); screenshots are the check.
- Day and time labels in the channel line are fixed English / 24 h (as Android).
