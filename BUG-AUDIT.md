# Comprehensive Bug Audit

Full security and correctness audit of all three implementations: iOS app (InboxLedger), backend (ledger-backend), and Mac app (LedgerRelay).

---

## CRITICAL Severity

### 1. [Backend] Unauthenticated `/imessage/reauth` Issues JWTs for Any User
**File:** `ledger-backend/src/routes/imessage.ts:562-594`

The `/imessage/reauth` endpoint has **no auth middleware**. It accepts `oldUserId` and `macDeviceId` from the request body with zero authentication. If a matching device record exists, it mints a brand-new JWT via `signJWT(devices[0].userId, devices[0].deviceId)`. An attacker who knows or guesses a `userId` gets full account takeover.

### 2. [Backend] Unauthenticated `/auth/register-device` Allows Mass Account Creation + Data Theft
**File:** `ledger-backend/src/routes/auth.ts:194-299`

No authentication, no rate limiting. Anyone can POST `{ "deviceId": "anything" }` and receive a valid JWT. Worse, the `previousUserId` migration logic (lines 236-282) lets an attacker send `{ deviceId: "new", previousUserId: "<victim>" }` to hijack the victim's relay pairings, pending replies, and all ledger items.

### 3. [Backend] Schema-Migration Mismatch Corrupts All Encrypted Tokens
**Files:** `ledger-backend/src/db/schema.ts:20-21`, `ledger-backend/src/db/migrate.ts:29-30`

The migration creates `refresh_token_encrypted BYTEA` and `refresh_token_iv BYTEA`, but the Drizzle schema defines them as `text(...)`. The `encryptToken()` function returns base64 strings. Inserting base64 text into BYTEA columns causes Postgres to misinterpret the data, corrupting every stored refresh token. OAuth token refresh, email sending, and scanning all break silently.

### 4. [iOS] Hardcoded Live Telegram Bot Token in Source Code
**File:** `InboxLedger/InboxLedger/Managers/TelegramManager.swift:33`

```swift
private let botToken = "8478743122:AAERaX0zJaOwvbIqrgB5-LcIUQOLXlyVpn8"
```

A live Telegram Bot API bearer token is hardcoded and checked into version control. Anyone with repo access or who decompiles the IPA can read all messages sent to this bot from all users, send messages as the bot, and impersonate the service.

### 5. [iOS + Mac] OAuth Access Tokens Stored in Plaintext UserDefaults
**Files:** `InboxLedger/InboxLedger/App/AppState.swift:586-589`, `LedgerRelay/LedgerRelay/LedgerRelay/RelayState.swift:45-48`

All OAuth tokens (Gmail, Outlook, Slack, Teams, GroupMe, Telegram) are serialized via `JSONEncoder` and stored in `UserDefaults`, an unencrypted plist on disk. The JWT in the Mac app is also in UserDefaults. These are trivially extractable from iTunes backups, jailbroken devices, or any process with file access. A `KeychainHelper` already exists in the codebase but is not used for these tokens.

### 6. [iOS] iMessage "Send" Swipe Silently Discards the Reply
**File:** `InboxLedger/InboxLedger/App/AppState.swift:2008-2009`

```swift
case .imessage:
    items.removeAll { $0.id == item.id }; return true
```

When a user swipes right to "send" an iMessage reply, the card is removed and a "Sent" toast is shown, but **the message is never actually delivered**. The reply is silently discarded. Users believe they responded when they did not.

### 7. [Mac] AppleScript Injection — Remote Code Execution
**File:** `LedgerRelay/LedgerRelay/LedgerRelay/Services/AppleScriptSender.swift:14-28`

The `recipient` and `text` fields (sourced from the backend API) are interpolated into AppleScript source code with inadequate escaping. An attacker who compromises the backend (or exploits bug #1 or #2) can inject arbitrary AppleScript, including `do shell script "..."`, achieving full remote code execution on every connected Mac.

### 8. [Mac] Re-auth Endpoint Uses Guessable userId as Sole Auth Factor
**File:** `LedgerRelay/LedgerRelay/LedgerRelay/RelayState.swift:461-477`

When the JWT expires, the Mac app calls `api.reauth(oldUserId:macDeviceId:)` with no authentication header. The `macDeviceId` is deterministically `"mac_relay_\(oldUserId)"`, adding zero security. Combined with backend bug #1, this is a complete auth bypass chain.

---

## HIGH Severity

### 9. [Backend] Subscription Verification Trusts Client-Provided `productId` — No Apple Server Validation
**File:** `ledger-backend/src/routes/user.ts:197-242`

The subscription tier is determined by `body.productId.includes('pro')` with no server-side receipt validation against Apple's App Store Server API. The `@apple/app-store-server-library` is in `package.json` but never imported. An attacker can send `{ productId: "com.fake.pro" }` and get a pro subscription with 500 AI calls/day for free.

### 10. [Backend] `ledger_items.id` Has No Primary Key — Cross-User Data Corruption
**Files:** `ledger-backend/src/db/schema.ts:99`, `ledger-backend/src/routes/imessage.ts:392`

The `ledger_items` table has no PRIMARY KEY. The only uniqueness constraint is composite `(user_id, id)`. But the update at `imessage.ts:392` filters by `.where(eq(schema.ledgerItems.id, existing.id))` — only `id`, without `userId`. If two users have items with the same external ID, one user's data overwrites the other's.

### 11. [Backend] Non-Atomic Rate Limiter Bypassable Under Concurrency
**File:** `ledger-backend/src/lib/redis.ts:49-56`

The rate limiter pipeline does `zremrangebyscore` → `zcard` → `zadd` → `expire`, but not within a `MULTI/EXEC` transaction. Two concurrent requests can both read the same count and both pass the limit check, systematically bypassing rate limits on AI endpoints.

### 12. [Backend] Error Handler Leaks Internal Error Messages
**File:** `ledger-backend/src/server.ts:55-57`

Any error whose message contains "token" or "JWT" has its raw `error.message` sent to the client, potentially exposing database column names, library versions, or API keys embedded in third-party error messages.

### 13. [Backend] `decryptToken()` Buffer + String Concatenation Risk
**File:** `ledger-backend/src/lib/crypto.ts:45`

`decipher.update(ciphertext) + decipher.final('utf8')` — the `update()` returns a Buffer, which is coerced to string separately from `final()`. If a multi-byte UTF-8 character spans the boundary, each chunk's `.toString()` produces mojibake. Should use `Buffer.concat([...]).toString('utf8')`.

### 14. [Backend] Gemini API Key Exposed in URL Query String
**File:** `ledger-backend/src/services/ai.ts:255`

The API key is placed in the URL (`?key=${apiKey}`), where it will appear in server access logs, proxy logs, error reporters, and monitoring tools.

### 15. [iOS] Slack Client Secret Hardcoded and Identical to Client ID (Copy-Paste Bug)
**File:** `InboxLedger/InboxLedger/Managers/SlackManager.swift:33-34`

```swift
private let clientID = "10477916588257.10464995370402"
private let clientSecret = "10477916588257.10464995370402"
```

The `clientSecret` is the same value as the `clientID` — a copy-paste error. The entire Slack OAuth flow is broken and will never produce a valid token. Additionally, client secrets should never be in client-side code.

### 16. [iOS] Race Condition on `isRefreshing`/`jwt` in BackendManager
**File:** `InboxLedger/InboxLedger/Managers/BackendManager.swift:13,117-120,223-226`

`isRefreshing` is a plain `Bool` on a non-actor class. Multiple concurrent `async` callers can all read `false` before any sets `true`, triggering multiple simultaneous JWT refreshes. One succeeds, others fail, causing intermittent 401 errors.

### 17. [iOS] Slack Token Response Logged to Console
**File:** `InboxLedger/InboxLedger/Managers/SlackManager.swift:104`

`print("🔄 Slack token response: \(json)")` — the full OAuth token response (including the access token) is printed to console, extractable via Xcode, device logs, or crash reporting tools.

### 18. [iOS] GroupMe Access Token Passed in URL Query Parameters
**File:** `InboxLedger/InboxLedger/Managers/GroupMeManager.swift:38,92,154,176,245,273,305`

The token appears in every API URL (`?token=...`), where it gets logged by URLSession, proxy servers, crash reports, and the app's own print statements.

### 19. [iOS] Outlook Signature Fetch Reads Wrong JSON Key
**File:** `InboxLedger/InboxLedger/Managers/OutlookManager.swift:300-311`

The code reads `json["userPurpose"]` (a mailbox type indicator like `"user"` or `"shared"`), not the actual signature field. Outlook signature fetch silently always returns `nil`, breaking the signature feature for all Outlook users.

### 20. [iOS] `saveDismissedIds()` Drops Auto-Dismissed iMessage IDs
**File:** `InboxLedger/InboxLedger/App/AppState.swift:2205-2209`

`saveDismissedIds()` overwrites `dismissedIds` with only the IDs from `dismissedItems`, silently dropping IDs added by `deduplicateByThread()`. After the next save-load cycle, older iMessage thread cards that were auto-suppressed resurface as duplicates.

### 21. [iOS] Reply-All Toggle Only Shown for Gmail, Not Outlook
**File:** `InboxLedger/InboxLedger/Views/DraftEditorView.swift:33`

The reply-all section is conditionally gated to `email.source == .gmail`, even though `sendReply()` fully supports Outlook reply-all. Outlook users with multi-recipient emails have no way to toggle reply-all.

### 22. [iOS] `DismissalMemory` Singleton Not Thread-Safe
**File:** `InboxLedger/InboxLedger/Models/DismissalMemory.swift:37-46`

The `signals` dictionary is mutated from swipe callbacks (main thread) and read during AI scoring (background `Task`) with no synchronization. Concurrent read/write on a Swift dictionary can crash.

### 23. [Mac] `sqlite3_bind_text` with Temporary NSString — Dangling Pointer
**File:** `LedgerRelay/LedgerRelay/LedgerRelay/Services/ChatDBReader.swift:182,234,343`

`sqlite3_bind_text(stmt, 1, (chatId as NSString).utf8String, -1, nil)` — the `nil` final argument means `SQLITE_STATIC` (SQLite won't copy the string). But `(chatId as NSString)` is a temporary that ARC may deallocate immediately, leaving SQLite holding a dangling pointer. In release builds with optimizations, this can cause crashes or corrupted query results.

### 24. [Mac] Failed Reply Ack Causes Infinite Duplicate iMessage Sends
**File:** `LedgerRelay/LedgerRelay/LedgerRelay/RelayState.swift:423-458`

When `AppleScriptSender.sendMessage()` succeeds but `api.ackReply()` fails (silently swallowed by `try?`), the backend never learns the reply was sent. On the next poll (15 seconds later), the same reply is fetched and sent again — repeating every 15 seconds indefinitely, flooding the recipient with duplicate iMessages.

### 25. [Mac] `post()` Takes Existential `Encodable` — Fragile JSON Encoding
**File:** `LedgerRelay/LedgerRelay/LedgerRelay/Services/RelayAPI.swift:170-178`

The `body` parameter is typed as `Encodable` (existential) instead of `<B: Encodable>`. Depending on Swift version, `JSONEncoder().encode(body)` may encode the existential wrapper instead of the actual struct, producing empty or malformed JSON for every POST request.

---

## MEDIUM Severity

### 26. [Backend] `scoreThreshold` Default Mismatch: Schema Says 25, Migration Says 40
**Files:** `ledger-backend/src/db/schema.ts:63`, `ledger-backend/src/db/migrate.ts:70`

Users created via different code paths get different default thresholds (25 vs 40) and scan intervals (2 min vs 15 min), causing inconsistent behavior and potential AI cost explosion.

### 27. [Backend] `cleanupScoreCache()` Is a No-Op — Score Cache Grows Unbounded
**File:** `ledger-backend/src/worker/index.ts:378-383`

The function calculates a cutoff date but never executes any deletion. It's also never called. The `score_cache` table grows indefinitely.

### 28. [Backend] Email Header Injection in `buildRFC2822`
**File:** `ledger-backend/src/services/email.ts:261-276`

`to`, `subject`, and `fromName` are interpolated into headers with no CRLF sanitization. An attacker controlling these fields can inject `BCC:` headers or additional email content.

### 29. [Backend] `Math.random()` Pairing Codes — Predictable, No Rate Limit on Confirm
**File:** `ledger-backend/src/routes/imessage.ts:18-25`

6-character codes from `Math.random()` (not crypto-secure) with no rate limit on `/imessage/pair/confirm`. The 32-char alphabet gives ~1B possibilities, brute-forceable within the 5-min TTL.

### 30. [Backend] Orphaned Worker Jobs for Deleted Users Never Cleaned Up
**File:** `ledger-backend/src/worker/index.ts:341-375`

When users are deleted, their BullMQ repeatable `scan:<userId>` jobs persist forever, accumulating over time.

### 31. [Backend] Inconsistent TLS Config Between Worker and API Redis Connections
**Files:** `ledger-backend/src/worker/index.ts:20-25`, `ledger-backend/src/lib/redis.ts:16`

The API server uses `rejectUnauthorized: false` (MITM-vulnerable), while the worker uses `tls: {}` (strict). One will fail if the cert is non-standard; the other is insecure.

### 32. [Backend] Sequential DB Queries in Loop for Dismiss/Snooze (Up to 50)
**File:** `ledger-backend/src/routes/ledger.ts:83-89,104-111`

50 individual UPDATE queries in a `for` loop with no transaction. Should be a single `WHERE id IN (...)` query.

### 33. [iOS] GroupMe Placeholder Client ID Never Replaced
**File:** `InboxLedger/InboxLedger/Managers/GroupMeManager.swift:59`

```swift
let clientID = "YOUR_GROUPME_CLIENT_ID"
```

GroupMe OAuth is completely broken — the authorization URL uses a placeholder string.

### 34. [iOS] Outlook Email Fetch URL Double-Encoded — OData Parameters Garbled
**File:** `InboxLedger/InboxLedger/Managers/OutlookManager.swift:203-207`

The entire query string (including `&`, `=`, `$`) is percent-encoded, turning `$filter=` into `%24filter%3D`. Microsoft Graph API won't parse the OData parameters. Outlook email fetching may return unfiltered results or fail entirely.

### 35. [iOS] Outlook Calendar URL Double-Encoded — Silently Returns No Events
**File:** `InboxLedger/InboxLedger/Managers/CalendarManager.swift:247-250`

Same double-encoding pattern. Outlook Calendar integration silently returns empty arrays; calendar awareness for Outlook-only users is broken.

### 36. [iOS] Duplicate Backend Sync Call in `saveMode()`
**File:** `InboxLedger/InboxLedger/App/AppState.swift:304-311`

Two identical `Task` blocks both call `BackendManager.shared.syncSettings()` with the same payload. Every mode change fires two concurrent identical network requests.

### 37. [iOS] `cachedAPIEvents` Race Condition in CalendarManager
**File:** `InboxLedger/InboxLedger/Managers/CalendarManager.swift:135-153`

Mutable array written from `async` method and read synchronously from another, with no synchronization.

### 38. [Mac] SQLite Opened with `SQLITE_OPEN_NOMUTEX`
**File:** `LedgerRelay/LedgerRelay/LedgerRelay/Services/ChatDBReader.swift:46`

Threading mutex disabled. Currently protected by `@MainActor` on the caller, but `ChatDBReader` itself has no actor annotation — fragile and crash-prone if any future caller runs off-main.

### 39. [Mac] Double `sqlite3_close` on Open-Success + Query-Failure Path
**File:** `LedgerRelay/LedgerRelay/LedgerRelay/RelayState.swift:261-273`

When `sqlite3_open_v2` succeeds but `sqlite3_prepare_v2` fails, the handle is closed on line 267 then again on line 273. Double-closing is undefined behavior in SQLite.

### 40. [Mac] Conversation Context Only Attached to First Message Per Chat
**File:** `LedgerRelay/LedgerRelay/LedgerRelay/Services/ChatDBReader.swift:145-151`

Only the most recent message per chat gets conversation context; all others are pushed to the backend with `nil` context, degrading AI reply quality.

### 41. [Mac + iOS] Private Message Content and Phone Numbers Logged to Console
**Files:** `LedgerRelay/LedgerRelay/LedgerRelay/RelayState.swift:381,432-433`, various iOS files

Message text, sender names, recipient phone numbers, and pairing codes are printed to the system console, readable by any process on the same machine.
