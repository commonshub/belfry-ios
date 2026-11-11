# What the iOS app needs from the belfry (server side)

Changes in `collective-belfry` (services/onboarding/belfry_onboarding/) that this app depends on.
This repo does not touch the servers; each item says exactly what to change.

## 1. Accept the app's redirect URI in `/connect` — DONE (Belfry after 36ff214, 2026-11-09)

`apps.NATIVE_APPS = {"sh.belfry.app://connect": "Belfry for iPhone"}`, approved by default. The
Android app uses the same redirect, so its sessions are also named "Belfry for iPhone" (see the
Android repo's SERVER-NEEDS 2: a neutral name or one chosen from `client_id` would fix it).
Kept below for the record.

The app signs in with `ASWebAuthenticationSession` and the return address
**`sh.belfry.app://connect`** (`client_id=belfry-ios`, PKCE S256, as the web chat).

Today `apps.app_uri()` (apps.py) raises for anything but `https://` (or `http://localhost`):

```python
if u.scheme != "https" and not (u.scheme == "http" and local):
    raise ValueError("an app's address must be https://")
```

and `is_approved()` only passes the belfry's own web apps (`own_app`) and admin-approved
addresses. Needed:

1. `app_uri()`: also accept the exact URI `sh.belfry.app://connect` (no other custom schemes, no
   query/fragment), returning it unchanged as the app's identity.
2. `is_approved()` / `own_app()`: treat `sh.belfry.app://connect` as one of the belfry's own apps
   (approved by default on every belfry, like `https://<domain>/chat/`), or let admins approve it
   in the Apps tab like any other app. Default-approved is what makes "type your domain, sign in"
   work on a fresh belfry.
3. `address()` / `display_name()`: show it as **"Belfry for iPhone"** (a fixed name chosen by the
   server for this exact URI; never a name from the URL).
4. `back_to()` works as is (`sh.belfry.app://connect?code=…&state=…`).
5. `/connect/logout?return_to=sh.belfry.app://connect`: same allow-list (optional; the app does
   not call it today).
6. The token endpoint needs no CORS for the app (native requests).

Security note: any iOS app can claim a custom scheme. PKCE protects the code (only the app that
made the verifier can redeem it), which is the standard for native apps (RFC 8252 section 8.1).
A universal link (`https://belfry.sh/app/connect` with an apple-app-site-association file) would
be stronger but only works for one domain, not for every community's own domain.

## 2. Publish `api.base` in belfry.json — DONE (both live documents publish `api.base`, `api.channel_invites`, `api.follows`)

`discovery.py` computes `base` from `console_url`, but the live documents (belfry.sh, enspiral.eu)
have no `api.base` and no `api.channel_invites`, and their `api.*` entries point at
`pass.<domain>/api`. The app falls back to `https://belfry.<domain>/api/v1` like the web chat.
Publishing `api.base` (and `api.channel_invites`) removes the guess. NIP-98: `holder_invites.authenticate`
already accepts both the `pass.` and `belfry.<domain>/api/v1` URLs.

## 3. Push notifications — the app side is built against collective-belfry `docs/push.md`

The protocol is `docs/push.md` (gateway at push.belfry.sh, `/api/v1/push/devices`,
`/api/v1/notifications`); this app does not change it. What Xavier must do in the Apple
developer portal before TestFlight can carry push:

1. App ID `sh.belfry.app`: enable **Push Notifications** and **App Groups** (group
   `group.sh.belfry.app`).
2. A second App ID **`sh.belfry.app.notifications`** (the Notification Service Extension), with
   **App Groups** (`group.sh.belfry.app`).
3. Both share the keychain access group `<TEAM_ID>.sh.belfry.app.shared` (declared in the
   entitlements; no portal switch needed beyond the same team).
4. An **APNs auth key** (.p8, Keys → Apple Push Notifications service) for the gateway: its key
   id, the team id and the .p8 go into the gateway's secrets (`apns_key.p8`, `APNS_KEY_ID`,
   `APNS_TEAM_ID`), never into this repo.
5. With automatic signing (`-allowProvisioningUpdates` and the App Store Connect API key), the
   profiles for both targets are made by the TestFlight job; the entitlements are
   `aps-environment` = development (Debug) / production (Release), the App Group and the keychain
   group (project.yml). CI's simulator build is unsigned, so these only matter for TestFlight.

Questions on the contract, raised here rather than changed:
- `env` for a TestFlight build is `production` (TestFlight uses the production APNs); Debug
  builds from Xcode use `sandbox`. The app sends that; the gateway must pick the APNs host by it.
- The DM payload has `title` = the belfry's name: fine for one community per phone; with
  several communities later, the extension shows it as is.
- No badge count is in the payload; the app sets none.

## 4. Session lifetime and revocation (question)

The token answer has no refresh token or expiry. How long does a Keycast bunker session live,
and what does the signer answer once it is removed on the account page (an error string the app
can recognise, so it can ask the person to sign in again instead of retrying)?

## 5. `apple-app-site-association` so guest links and event addresses open in the app

The app claims `https://chat.belfry.sh` and `https://chat.enspiral.eu` (entitlement
`com.apple.developer.associated-domains`, `applinks:chat.<domain>` in `project.yml`) for:

- guest links `https://chat.<domain>/join/<token>` (SPEC 19.4), and
- event addresses `https://chat.<domain>/events/<link>` (SPEC 19.18; the belfry 302s these to
  `/#/events/<link>` today).

iOS only opens them in the app once each chat host serves this file, **as JSON, over HTTPS,
without a redirect**, at `https://chat.<domain>/.well-known/apple-app-site-association` (no
file extension, `Content-Type: application/json`), next to the `assetlinks.json` already served
for Android:

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["<TEAM_ID>.sh.belfry.app"],
        "components": [
          { "/": "/join/*", "comment": "guest links" },
          { "/": "/events/*", "comment": "event addresses" }
        ]
      }
    ]
  }
}
```

`<TEAM_ID>` is the Apple Developer Team ID that will sign the app (the `APPLE_TEAM_ID` secret of
the TestFlight job; not known in this repo). Apple's CDN caches the file: after changing it, a
fresh install picks it up within a day. Until it is served, the links open the web chat (which
handles them), so nothing breaks. Another community's chat host needs the same file and one more
`applinks:` line in `project.yml` (or a per-community build).

## 6. Small things seen while porting (2026-11-11)

- NIP-98 same-second replay (Android SERVER-NEEDS 5) applies here too: two identical signed GETs
  in one second share an event id and the second gets 401. A nonce tag would remove it.
- `POST /admins` returning the new admin list would save the belfry.json re-read after the admin
  switch (Android SERVER-NEEDS 6).
- Push notifications (section 3) are still the main missing piece for a phone app.
