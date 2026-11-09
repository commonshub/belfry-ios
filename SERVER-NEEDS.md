# What the iOS app needs from the belfry (server side)

Changes in `collective-belfry` (services/onboarding/belfry_onboarding/) that this app depends on.
This repo does not touch the servers; each item says exactly what to change.

## 1. Accept the app's redirect URI in `/connect` (blocking: sign-in)

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

## 2. Publish `api.base` in belfry.json (nice to have)

`discovery.py` computes `base` from `console_url`, but the live documents (belfry.sh, enspiral.eu)
have no `api.base` and no `api.channel_invites`, and their `api.*` entries point at
`pass.<domain>/api`. The app falls back to `https://belfry.<domain>/api/v1` like the web chat.
Publishing `api.base` (and `api.channel_invites`) removes the guess. NIP-98: `holder_invites.authenticate`
already accepts both the `pass.` and `belfry.<domain>/api/v1` URLs.

## 3. Push notifications (later; needed for a real phone app)

Nothing wakes the app when a message arrives. Proposal:

- The app registers its APNs device token: `POST <api base>/me/push` (NIP-98)
  `{"platform":"apns","token":"…","app":"sh.belfry.app","events":["mention","dm","mail","reply"]}`;
  `DELETE` on sign-out.
- The belfry already knows mentions (mentions.py) and mail (mailfront); it would send a
  content-free push ("New message in #general", or just a badge) through APNs with the app's key
  (an APNs auth key `.p8`, team id, key id, kept as belfry secrets), never the message text
  (end-to-end privacy for DMs).
- Needs the APNs key from Xavier's Apple developer account; ask before adding it.

## 4. Session lifetime and revocation (question)

The token answer has no refresh token or expiry. How long does a Keycast bunker session live,
and what does the signer answer once it is removed on the account page (an error string the app
can recognise, so it can ask the person to sign in again instead of retrying)?
