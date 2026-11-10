# Belfry for iPhone: notes for agents

Native SwiftUI client for a community's belfry (self-hosted community server). The protocol is in
[SPEC.md](SPEC.md) (platform-neutral; an Android app will follow from it). The web chat
(`village-app`, branch `belfry-chat`; also `commonshub/collective-belfry` branch `chat-source`) is
the reference implementation: read it, don't guess.

## Layout

- `SPEC.md`: what a correct Belfry chat client does. Update it when behaviour changes; mark
  unknowns as open questions (section 18).
- `vectors/*.json`: shared test cases. Generated from the web chat's own code:
  `VILLAGE=~/agents/belfry/work/village-app node tools/vectors/build.mjs` (needs the village-app
  checkout with node_modules; `tools/vectors/gen.ts` defines the cases, `stubs/` replace its
  IndexedDB/relay modules). `nip44.json` is the official NIP-44 file (sha256 269ed0f6…5040).
- `Package.swift` → `Sources/BelfryCore`: everything that is not UI.
  - `Crypto/`: hex, HMAC/HKDF, ChaCha20, NIP-44 v2, BIP-340 + ECDH via swift-secp256k1 (P256K,
    pinned 0.23.2; only `Keys.swift` imports it: P256K and CryptoKit both define SHA256), bech32.
  - `Nostr/`: events (canonical serialization, ids), `Signer` protocol, `LocalSigner`.
  - `Model/Derive.swift`: port of `src/core/model.ts` (groups, messages, reactions, threads,
    feed with resurfacing, recentlyActive, canAdmin…). `Actions.swift`: the events each action
    queues. `Text.swift`: hashtags, mentions, JS-like regex helper (`Rx`, UTF-16 offsets).
  - `Mail/`: mail-thread keys, MIME read/write. `Markdown/`: the subset as a tree + e-mail HTML.
  - `Outbox/`: outbox items, error classes, one flush pass (pure, tested).
  - `Net/`: discovery + PKCE sign-in, `Relay` (URLSessionWebSocketTask, NIP-42), `BunkerSigner`
    (NIP-46), `SyncEngine` (relays, subscriptions, outbox, watchdog, NWPathMonitor).
  - `Store/Database.swift`: SQLite (events, outbox, kv). `DM/`: gift wraps, `DirectMessages`.
- `Tests/BelfryCoreTests`: XCTest against `vectors/` (found via `#filePath`).
- `App/Sources`: the SwiftUI app (`AppModel` = state + actions; views). `project.yml` is the
  XcodeGen spec; the `.xcodeproj` and `App/Info.plist` are generated, not committed.
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
community on the device (`App/Sources/Demo.swift`), local-only. `-screen feed|thread|details|
invite|messages|conversation|mail|search|channels` opens a screen (used by the screenshot job).

## Decisions

- Bundle id `sh.belfry.app`, redirect `sh.belfry.app://connect`, client_id `belfry-ios`, client
  tag `["client","belfry-ios"]`.
- iOS 17+. NavigationSplitView; channel details as a sheet with medium/large detents (web: custom
  pull-down); `.contextMenu` for reactions/Reply/Copy/Delete; `.searchable`; `ShareLink`; CoreImage
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
- Derived views recompute over the whole log per version (fine for a community; add indexes per
  group if logs grow past tens of thousands of events).
