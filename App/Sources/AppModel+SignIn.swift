import BelfryCore
import Foundation

// The native sign-in (SPEC 19.20) as the screens call it. The flow itself, its checks and what it
// keeps across the app being killed are BelfryCore's `NativeSignInFlow`; here its result becomes
// the stored session. Errors come back as `SessionError`: fixed messages, never the belfry's text.

extension AppModel {
    /// Screen 1 → the belfry mails a code → screen 2 (`pendingCode`).
    func requestCode(_ address: String) async -> SessionError? {
        signInError = nil
        do {
            pendingCode = try await nativeFlow.requestCode(address)
            return nil
        } catch let e as SessionError {
            return e
        } catch {
            return SessionError(.other)
        }
    }

    /// "Send a new code": the same request, the same session key.
    func resendCode() async -> SessionError? {
        do {
            pendingCode = try await nativeFlow.resendCode()
            return nil
        } catch let e as SessionError {
            if e.failure.endsTheRequest { backToAddress(e) }
            return e
        } catch {
            return SessionError(.other)
        }
    }

    /// Screen 2: the six digits. On success the session is stored and opened.
    func verifyCode(_ code: String) async -> SessionError? {
        do {
            let opened = try await nativeFlow.verifyCode(code)
            let s = StoredSession(domain: opened.config.domain, bunkerURL: opened.bunkerURL, clientSecret: opened.clientSecretHex, pubkey: opened.pubkey)
            Keychain.save(s)
            pendingCode = nil
            signInError = nil
            open(s, config: opened.config)
            return nil
        } catch let e as SessionError {
            if e.failure.endsTheRequest { backToAddress(e) }
            return e
        } catch {
            return SessionError(.other)
        }
    }

    /// "Use another address": forget the request; the address stays in the field.
    func cancelCode() {
        nativeFlow.cancel()
        signInError = nil
        pendingCode = nil
    }

    /// The request is over (expired, this phone's key is taken…): screen 1 with the reason.
    private func backToAddress(_ e: SessionError) {
        nativeFlow.cancel()
        signInError = e.display
        pendingCode = nil
    }
}
