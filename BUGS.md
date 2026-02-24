# Codebase Security & Correctness Audit

**Date:** 2026-02-24
**Scope:** InboxLedger (iOS), ledger-backend (Node.js/TypeScript), LedgerRelay (macOS)

---

## Summary

| Severity | iOS | Backend | Mac | Total |
|----------|-----|---------|-----|-------|
| **Critical** | 2 | 4 | 2 | **8** |
| **High** | 6 | 7 | 3 | **16** |
| **Medium** | 8 | 9 | 5 | **22** |
| **Total** | **16** | **20** | **10** | **46** |

---

## CRITICAL SEVERITY

### 1. Hardcoded Telegram Bot Token (iOS)
- **File:** `InboxLedger/Managers/TelegramManager.swift:33`
- **Bug:** A live Telegram Bot API token is hardcoded in source. Anyone who decompiles the app can steal the token, impersonate the bot, and read all user messages.
- **Fix:** Revoke the token immediately. Move it to the backend; the iOS app should proxy Telegram calls through the backend API.

### 2. Unauthenticated Endpoints Issue JWTs (Backend)
- **File:** `ledger-backend/src/routes/auth.ts:194-299`, `ledger-backend/src/routes/imessage.ts:562-594`
- **Bug:** `POST /auth/register-device` creates a user and issues a JWT based solely on a client-provided `deviceId` — zero authentication. `POST /imessage/reauth` issues a JWT to anyone providing an `oldUserId`. Both are complete auth bypasses.
- **Fix:** Add rate limiting to `/auth/register-device`. Require proof of identity for `/imessage/reauth` (e.g., verify the old JWT's signature even if expired).

### 3. Unvalidated `previousUserId` Allows Data Theft (Backend)
- **File:** `ledger-backend/src/routes/auth.ts:236-282`
- **Bug:** The server trusts a client-provided `previousUserId` to migrate Mac relay, pending iMessage replies, and all ledger items to a new account. An attacker steals the victim's data and silently hijacks their Mac relay.
- **Fix:** Require proof that the caller owns `previousUserId` (e.g., verify an expired JWT's signature).

### 4. OAuth Tokens in Plaintext UserDefaults (iOS)
- **File:** `InboxLedger/App/AppState.swift:586-589`, `InboxLedger/Models/ConnectedAccount.swift:13`
- **Bug:** OAuth tokens for Gmail, Outlook, Slack, etc. are serialized to `UserDefaults` (unencrypted plist). Accessible via unencrypted iTunes backups, MDM, or jailbreak.
- **Fix:** Store `accessToken` in Keychain using the existing `KeychainHelper`, keyed by account ID.

### 5. JWT in Plaintext UserDefaults (Mac)
- **File:** `LedgerRelay/RelayState.swift:45-48`
- **Bug:** The JWT is stored in `UserDefaults` instead of Keychain. Any process running as the same user can read the plist and get full account access.
- **Fix:** Use `Security.framework` (Keychain Services) to store the JWT.

### 6. No Server-Side App Store Receipt Validation (Backend)
- **File:** `ledger-backend/src/routes/user.ts:197-242`
- **Bug:** `/subscription/verify` trusts the client-provided `productId`. Any user can send `{ "productId": "fake_pro" }` and get a pro subscription. The `@apple/app-store-server-library` dependency exists but is never used.
- **Fix:** Validate `originalTransactionId` against Apple's servers before granting the tier.

### 7. AppleScript Injection via Server-Controlled Data (Mac)
- **File:** `LedgerRelay/Services/AppleScriptSender.swift:14-28`
- **Bug:** iMessage `recipient` and `text` come from the backend. A compromised backend can send arbitrary iMessages as the user to any phone number. Newlines and control characters bypass the escaping.
- **Fix:** Use `NSAppleEventDescriptor` for programmatic Apple Event construction, or validate that `recipient` matches an expected phone/email pattern.

### 8. Unauthenticated Reauth Endpoint (Mac)
- **File:** `LedgerRelay/RelayState.swift:461-477`, `LedgerRelay/Services/RelayAPI.swift:148-151`
- **Bug:** Reauth is called without JWT, sending only `oldUserId` (plaintext in UserDefaults) and a predictable `macDeviceId`. Anyone who knows a user ID gets a valid JWT.
- **Fix:** Require the old JWT (verify signature, skip expiry check) or use a long-lived refresh token stored in Keychain.

---

## HIGH SEVERITY

### 9. Account Takeover via Device ID Squatting (Backend)
- **File:** `ledger-backend/src/routes/auth.ts:61-68`
- **Bug:** In `/auth/register`, a known `deviceId` lets an attacker associate a new provider account with the victim's user ID.
- **Fix:** Device ID alone should not resolve a user from an unauthenticated context.

### 10. Pairing Code Race Condition (Backend)
- **File:** `ledger-backend/src/routes/imessage.ts:43-93`
- **Bug:** Redis GET + DEL is non-atomic; two concurrent submissions of the same code can both succeed.
- **Fix:** Use atomic `GETDEL` (Redis 6.2+).

### 11. Pairing Code Brute-Force (Backend)
- **File:** `ledger-backend/src/routes/imessage.ts:43-93`
- **Bug:** Unauthenticated, no rate limiting. 6-char codes can be brute-forced during the 5-minute TTL.
- **Fix:** Add per-IP rate limiting and consider increasing code length.

### 12. Cross-User Data Leak in ledger_items Updates (Backend)
- **File:** `ledger-backend/src/routes/imessage.ts:392, 672`
- **Bug:** WHERE clauses filter by `id` alone without `userId`. Two users in the same group chat share the same message ID — updates cross user boundaries.
- **Fix:** Add `eq(schema.ledgerItems.userId, userId)` to all WHERE clauses.

### 13. Gemini API Key in URL Query String (Backend)
- **File:** `ledger-backend/src/services/ai.ts:255`
- **Bug:** API key in URL gets logged by proxies, load balancers, and Fastify's pino logger.
- **Fix:** Ensure URL logging is suppressed for this endpoint, or use `x-goog-api-key` header.

### 14. Crypto Buffer Concatenation Bug (Backend)
- **File:** `ledger-backend/src/lib/crypto.ts:45`
- **Bug:** `decipher.update(ciphertext)` returns Buffer, concatenated with `decipher.final('utf8')` string. Multi-byte UTF-8 split at chunk boundary corrupts data.
- **Fix:** `Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8')`

### 15. Slack Client Secret == Client ID (iOS)
- **File:** `InboxLedger/Managers/SlackManager.swift:33-34`
- **Bug:** `clientSecret` equals `clientID` — either a copy-paste bug (Slack OAuth always fails) or a leaked secret.
- **Fix:** Move secret to backend; do token exchange server-side.

### 16. GroupMe Client ID is Placeholder (iOS)
- **File:** `InboxLedger/Managers/GroupMeManager.swift:59`
- **Bug:** Literal string `"YOUR_GROUPME_CLIENT_ID"`. Every GroupMe connection fails.
- **Fix:** Replace with real ID or hide GroupMe from the UI until configured.

### 17. SafariView Force Unwrap Crash (iOS)
- **File:** `InboxLedger/Views/SafariView.swift:26-27`
- **Bug:** `URL(string: "https://about:blank")!` — not a valid URL, returns nil, force unwrap crashes.
- **Fix:** Use `URL(string: "https://example.com")!` or don't present SafariView for invalid URLs.

### 18. NSAttributedString HTML Parsing Off Main Thread (iOS)
- **File:** `InboxLedger/Managers/GmailManager.swift:402-414`
- **Bug:** HTML-to-plaintext uses NSAttributedString with `.html` (requires WebKit, must be on main thread). Called from background — causes crashes or deadlocks.
- **Fix:** Use `await MainActor.run { ... }` or the regex-based fallback.

### 19. BackendManager JWT Refresh Race Condition (iOS)
- **File:** `InboxLedger/Managers/BackendManager.swift:13, 118, 224-226`
- **Bug:** `isRefreshing` Bool on non-actor class with no synchronization. Concurrent API calls race into `refreshJWT()` simultaneously.
- **Fix:** Make `BackendManager` an `actor` or use `AsyncSemaphore`.

### 20. SQLite NOMUTEX + No BUSY Handling (Mac)
- **File:** `LedgerRelay/Services/ChatDBReader.swift:46`
- **Bug:** `SQLITE_OPEN_NOMUTEX` disables thread safety. Messages.app's WAL checkpoints return `SQLITE_BUSY` which is never handled — messages silently skipped.
- **Fix:** Remove `NOMUTEX`, add `sqlite3_busy_timeout(db, 5000)`.

### 21. SQLite Dangling Pointer in bind_text (Mac)
- **File:** `LedgerRelay/Services/ChatDBReader.swift:182, 234, 343`
- **Bug:** `(chatId as NSString).utf8String` creates a temporary, but `nil` (SQLITE_STATIC) tells SQLite not to copy. Pointer may dangle — intermittent crashes.
- **Fix:** Use `SQLITE_TRANSIENT` or `chatId.withCString { ... }`.

### 22. waitUntilExit() Blocks Main Thread (Mac)
- **File:** `LedgerRelay/Services/AppleScriptSender.swift:90`
- **Bug:** `RelayState` is `@MainActor` and calls `sendMessage()` synchronously. With multiple replies × multiple attempts, UI freezes for over a minute.
- **Fix:** Make `sendMessage` async, run Process on background thread.

### 23. Slack OAuth Token Logged to Console (iOS)
- **File:** `InboxLedger/Managers/SlackManager.swift:104`
- **Bug:** Full OAuth token exchange response `print()`-ed to system log.
- **Fix:** Remove the print statement or redact the token.

### 24. Gemini-to-OpenAI Fallback Bypasses Cost Quotas (Backend)
- **File:** `ledger-backend/src/services/ai.ts:271-275`
- **Bug:** When Gemini fails, fallback to `callOpenAI` skips all quota checks. During a Gemini outage, all traffic hits OpenAI with no limits.
- **Fix:** Add quota check before fallback, or decrement the premium counter on Gemini failure.

---

## MEDIUM SEVERITY

### 25. ledger_items Has No Primary Key (Backend)
- **File:** `ledger-backend/src/db/schema.ts:98-130`

### 26. Outlook messageId Not URL-Encoded (Backend)
- **File:** `ledger-backend/src/services/email.ts:208`
- **Bug:** Outlook message IDs contain `+`, `/`, `=`. Without `encodeURIComponent()`, replies fail with 404.

### 27. Rate Limiter Self-Amplifying Lockout (Backend)
- **File:** `ledger-backend/src/lib/redis.ts:49-56`

### 28. Schema/Migration Default Value Mismatches (Backend)
- **File:** `ledger-backend/src/db/migrate.ts:69-70` vs `schema.ts:63-64`

### 29. Schema/Migration Column Type Mismatch (Backend)
- **File:** `ledger-backend/src/db/migrate.ts:29` vs `schema.ts:20`

### 30. AES-256-GCM Uses 16-byte IV (Backend)
- **File:** `ledger-backend/src/lib/crypto.ts:8`

### 31. Worker Redis URL Password Encoding (Backend)
- **File:** `ledger-backend/src/worker/index.ts:20-25`

### 32. Unvalidated Body on /imessage/verify-active (Backend)
- **File:** `ledger-backend/src/routes/imessage.ts:639-641`

### 33. Error Handler JSON.parse Can Crash (Backend)
- **File:** `ledger-backend/src/server.ts:47-52`

### 34. CalendarManager Reads Stale Tokens (iOS)
- **File:** `InboxLedger/Managers/CalendarManager.swift:294-304`

### 35. Double sqlite3_close on Failed Open (Mac)
- **File:** `LedgerRelay/RelayState.swift:261-273`

### 36. Infinite Reply Retry Loop (Mac)
- **File:** `LedgerRelay/RelayState.swift:431-448`

### 37. JSONEncoder with Existential Type (Mac)
- **File:** `LedgerRelay/Services/RelayAPI.swift:178`

### 38. Private Message Content in Console Logs (Mac)
- **File:** `LedgerRelay/RelayState.swift:380-381, 432`

### 39. Timer May Not Fire Off Main RunLoop (iOS)
- **File:** `InboxLedger/App/AppState.swift:~2065`

### 40. Duplicate Backend Sync Call (iOS)
- **File:** `InboxLedger/App/AppState.swift:~306-310`

### 41. Notification Category Registration Race (iOS)
- **File:** `InboxLedger/Managers/NotificationManager.swift:454-461`

### 42. Timer Leak in iMessage Setup View (iOS)
- **File:** `InboxLedger/Views/iMessageSetupView.swift:442-449`

### 43. Force Unwraps on URL Construction (iOS)
- **File:** `InboxLedger/Managers/BackendManager.swift:45, 72, 122, 187, 232`

### 44. GroupMe Tokens in URL Query Parameters (iOS)
- **File:** `InboxLedger/Managers/GroupMeManager.swift:38, 92, 154, 176, 245, 273`

### 45. SoundManager engineReady Timing Issue (iOS)
- **File:** `InboxLedger/Managers/SoundManager.swift:52, 76, 95`

### 46. saveLedgerState() Called Rapidly Without Debounce (iOS)
- **File:** `InboxLedger/App/AppState.swift:2295-2313`
