# Ledger Backend — Architecture & Design

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Why These Choices](#2-why-these-choices)
3. [AI Cost Routing (Gemini Overflow)](#3-ai-cost-routing)
4. [API Design](#4-api-design)
5. [Security Model](#5-security-model)
6. [Data Model](#6-data-model)
7. [Background Email Processing Pipeline](#7-background-email-processing-pipeline)
8. [Push Notification Flow](#8-push-notification-flow)
9. [Cost Analysis](#9-cost-analysis)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        iOS App (Client)                         │
│  • OAuth sign-in (Google/Microsoft)                             │
│  • Sends tokens to backend for storage                          │
│  • Calls /score, /redraft, /send through backend proxy          │
│  • Receives push notifications via APNs                         │
└────────────────────┬────────────────────────────────────────────┘
                     │ HTTPS (TLS 1.3)
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                    API Gateway (Fly.io)                          │
│  • Node.js + Fastify + TypeScript                               │
│  • JWT authentication (ES256) on every request                  │
│  • Anti-abuse rate limiting (per-user + per-IP)                 │
│  • Request validation (Zod schemas)                             │
│  • Routes:                                                      │
│    POST /auth/register        — Register device + tokens        │
│    POST /auth/refresh         — Refresh Ledger JWT              │
│    POST /auth/device          — Update APNs device token        │
│    DELETE /auth/account       — Delete all user data (GDPR)     │
│    POST /score                — AI email scoring (unlimited)    │
│    POST /redraft              — AI draft rewrite (unlimited)    │
│    POST /send                 — Proxy email send                │
│    POST /subscription/verify  — Verify App Store receipt        │
│    GET  /user/settings        — Get user preferences            │
│    PUT  /user/settings        — Update user preferences         │
│    GET  /user/subscription    — Get subscription status         │
│    GET  /user/accounts        — List connected accounts         │
└──────┬──────────────┬──────────────┬────────────────────────────┘
       │              │              │
       ▼              ▼              ▼
┌──────────┐  ┌──────────────┐  ┌──────────────┐
│ Postgres │  │ Redis        │  │ Bull Queue   │
│ (Neon)   │  │ (Upstash)    │  │ (on Redis)   │
│          │  │              │  │              │
│ • Users  │  │ • Rate limits│  │ • Email scan │
│ • Tokens │  │ • JWT block  │  │ • AI scoring │
│ • Subs   │  │ • Score cache│  │ • Push notif │
│ • Stats  │  │ • AI routing │  │              │
│ • Scores │  │   counters   │  │              │
└──────────┘  └──────────────┘  └──────┬───────┘
                                       │
                              ┌────────▼────────┐
                              │  Worker Process  │
                              │  (Fly.io)        │
                              │                  │
                              │ • Polls Gmail/   │
                              │   Outlook APIs   │
                              │ • Runs AI scoring│
                              │ • Sends APNs     │
                              │   push notifs    │
                              └──────────────────┘
```

Two processes, one codebase:

**API Server** — handles all client requests. The iOS app calls it instead of calling OpenAI/Gmail/Gemini directly. API keys never live on the device.

**Worker Process** — runs on a schedule via BullMQ. For each user, refreshes OAuth tokens, fetches new emails from Gmail/Outlook, scores them with AI, and sends push notifications via APNs. This is what makes notifications work while the app is backgrounded.

---

## 2. Why These Choices

### Fly.io (not AWS/GCP/Firebase)
- ~$5/mo at low scale (1 shared-cpu VM)
- Workers run continuously (not cold-started like Lambda)
- `fly scale count 3` for instant horizontal scaling
- Standard Docker — no vendor lock-in

### Neon Postgres (not Firebase/DynamoDB)
- Free tier: 0.5GB storage, 190 compute hours/mo — enough for 100k users
- Relational: users → accounts → subscriptions have real relationships
- No surprise bills (unlike Firestore per-read pricing)

### Upstash Redis (not self-hosted)
- Free tier: 10k commands/day
- Serverless — no VM to manage
- Handles: rate limiting, score caching, JWT blocklist, AI routing counters, BullMQ

### Fastify (not Express)
- 2-3x faster in benchmarks
- Built-in validation, plugin architecture, TypeScript-first

---

## 3. AI Cost Routing

**Core principle: Every user gets unlimited AI. No walls. No "limit reached." Cost is controlled by routing, not limiting.**

```
User makes a request (score or redraft)
        │
        ▼
pickProvider(userId, tier)
        │
        ├── Premium quota remaining? → GPT-4o Mini (quality)
        │
        └── Quota exhausted?         → Gemini 2.0 Flash (free/near-free)
        
Pro users additionally get:
  • Claude Haiku for gray-zone re-scoring (25-55 range)
  • Claude Haiku for escalated redrafts (after 2+ attempts)
  These always use Claude regardless of quota.
```

### Premium Quotas (per user per day, resets at midnight UTC)

| Tier     | Premium calls/day | After quota          |
|----------|-------------------|----------------------|
| Free     | 30                | Gemini Flash (free)  |
| Standard | 150               | Gemini Flash (free)  |
| Pro      | 500               | Gemini Flash (free)  |

### Why This Works

- 30 premium calls/day is generous — normal users make ~20-30 total
- Gemini 2.0 Flash is excellent for email scoring (same quality tier as GPT-4o Mini)
- Gemini's free tier: 1,500 requests/day per API key
- Users never notice the switch
- OpenAI spend is hard-capped per-user by Redis counter — can't be bypassed client-side
- Even under adversarial conditions, max OpenAI cost per free user: $0.002/day

### Gemini Fallback Safety

If Gemini itself rate-limits or errors, `callGemini()` falls back to OpenAI. The user never sees an error. This is a safety net, not a normal path.

---

## 4. API Design

### Authentication Flow
```
1. User signs in with Google/Microsoft in iOS app
2. App receives OAuth access_token + refresh_token
3. App calls POST /auth/register with:
   - provider, access_token, refresh_token, email, display_name
   - device_token (APNs), device_id (UUID)
4. Backend validates token against Google/Microsoft API
5. Encrypts refresh_token with AES-256-GCM, stores in Postgres
6. Returns a Ledger JWT (ES256, 24h expiry)
7. All subsequent requests use the Ledger JWT
```

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | /auth/register | No | Register device + provider tokens |
| POST | /auth/refresh | JWT | Refresh Ledger JWT |
| POST | /auth/device | JWT | Update APNs device token |
| DELETE | /auth/account | JWT | Delete all user data (GDPR) |
| POST | /score | JWT | Score emails with AI (unlimited) |
| POST | /redraft | JWT | Rewrite a draft with AI (unlimited) |
| POST | /send | JWT | Send email reply via Gmail/Outlook |
| POST | /subscription/verify | JWT | Verify App Store receipt |
| GET | /user/settings | JWT | Get user preferences |
| PUT | /user/settings | JWT | Update preferences + sync to worker |
| GET | /user/subscription | JWT | Get tier + trial status |
| GET | /user/accounts | JWT | List connected accounts |
| GET | /health | No | Health check |

---

## 5. Security Model

### Token Encryption
- Provider refresh tokens encrypted with AES-256-GCM before storage
- Encryption key: environment variable, never in code
- Even a full database dump is useless without the key

### JWT Design
- Algorithm: ES256 (ECDSA P-256) — smaller and faster than RSA
- Payload: `{ sub: user_id, device_id, jti, iat, nbf, exp }`
- Expiry: 24 hours
- `jti` (token ID): enables revocation via Redis blocklist
- `nbf` (not-before): replay protection with 30s clock tolerance
- Auth middleware checks: valid signature → not expired → not revoked → user exists in DB

### Rate Limiting (anti-abuse, not usage limits)
- /score: 60/hour per-user, 120/hour per-IP
- /redraft: 120/hour per-user, 240/hour per-IP
- /send: 30/hour per-user
- /auth/register: 10/minute per-device, 20/minute per-IP
- Implemented via Redis sliding window sorted sets

### Request Validation
- Every body validated with Zod schemas
- Email bodies capped at 10KB, style context at 2KB
- Body size limit: 1MB global
- SQL injection impossible (Drizzle ORM parameterized queries)

### Registration Security
- Gmail/Outlook: access token validated against provider API, email must match
- Slack/Telegram/GroupMe: blocked until proper OAuth validation is implemented
- Prevents fake account creation for AI abuse

### Error Handling
- Client gets generic errors ("Authentication failed", "Internal server error")
- Full details logged server-side only (Pino structured logging)
- Sensitive fields redacted from logs (tokens, auth headers)

### Additional Measures
- CORS disabled entirely (iOS native HTTP doesn't need it)
- Helmet security headers (HSTS, referrer policy, etc.)
- Non-root Docker user
- TLS enforced by Fly.io
- Startup validation: fails fast if any required secret is missing
- Invalid APNs tokens cleaned up automatically
- CASCADE deletes for complete GDPR account deletion

---

## 6. Data Model

```sql
users                    -- Core user record
  id UUID PK
  created_at, updated_at

accounts                 -- Gmail, Outlook connections
  id UUID PK
  user_id FK → users (CASCADE)
  provider, email, display_name
  refresh_token_encrypted BYTEA  -- AES-256-GCM
  refresh_token_iv BYTEA
  is_enabled, last_scan_at

devices                  -- APNs push tokens
  id UUID PK
  user_id FK → users (CASCADE)
  device_id, device_token, platform
  UNIQUE(user_id, device_id)

subscriptions            -- Tier + trial
  user_id FK → users (CASCADE) UNIQUE
  tier ('free'|'standard'|'pro')
  trial_started_at, expires_at
  original_transaction_id

user_settings            -- Synced to worker for scheduling
  user_id PK FK → users (CASCADE)
  mode ('stack'|'window')
  window_hour, window_minute
  sensitivity, snooze_hours
  score_threshold, scan_interval_minutes

score_cache              -- Prevents re-scoring + flip-flopping
  email_hash TEXT PK     -- SHA-256(provider:email_id)
  user_id FK → users (CASCADE)
  replyability, summary, draft, tone, category
  scored_at

usage_log                -- Analytics + cost tracking
  id BIGSERIAL PK
  user_id FK → users (CASCADE)
  action, provider, tokens_used, email_count
  created_at
```

---

## 7. Background Email Processing Pipeline

```
Scan Scheduler (BullMQ repeatable jobs)
  • Stack mode:  every 15-60 min per user (tier-based)
  • Window mode: once/day at (window_time - 5 min)
        │
        ▼
Worker: processScan(userId)
  1. Load user's enabled accounts from DB
  2. Decrypt refresh tokens (AES-256-GCM)
  3. Refresh access tokens via Google/Microsoft API
  4. Fetch unread emails since last scan
  5. Pre-filter obvious noise (no-reply, marketing, automated)
  6. Check score cache — skip already-scored emails
  7. Score new emails via AI (uses same Gemini overflow routing)
  8. Cache scores in Redis (24h TTL) + Postgres
  9. Filter by user's threshold
  10. If qualifying emails → send APNs push notification
```

### Scan Frequency by Tier
| Tier     | Min Interval | Max scans/day |
|----------|-------------|---------------|
| Free     | 60 min      | 24            |
| Standard | 30 min      | 48            |
| Pro      | 15 min      | 96            |

---

## 8. Push Notification Flow

```
Worker detects qualifying emails
        │
        ▼
Build APNs payload (title, body, badge, sound, data.type)
        │
        ▼
Load user's device tokens from DB
        │
        ▼
Send via APNs HTTP/2
  • JWT-authenticated (ES256 with Apple .p8 key)
  • Connection pooling
  • Invalid tokens auto-deleted from DB
```

Three notification types:
- **Batch** (stack mode): "3 emails need your reply — including Jane Smith"
- **Window** (window mode): "Your evening ledger is ready — 5 emails to review"
- **Urgent** (score ≥ 80): "Urgent: Jane Smith — Meeting reschedule"

---

## 9. Cost Analysis

### At Launch (< 1,000 users)

| Service        | Monthly Cost |
|----------------|-------------|
| Fly.io (1 VM)  | $5          |
| Neon Postgres   | $0 (free)   |
| Upstash Redis   | $0 (free)   |
| OpenAI API      | ~$30        |
| Gemini API      | $0 (free)   |
| Anthropic API   | ~$10        |
| APNs            | $0          |
| **Total**       | **~$45/mo** |

### At 10,000 users

| Service        | Monthly Cost |
|----------------|-------------|
| Fly.io (2 VMs) | $30         |
| Neon Postgres   | $19         |
| Upstash Redis   | $10         |
| OpenAI API      | ~$300       |
| Gemini API      | ~$50        |
| Anthropic API   | ~$100       |
| **Total**       | **~$510/mo**|

Revenue (20% paid): ~$12.5k/mo → **96% margin**

### At 100,000 users

| Service        | Monthly Cost |
|----------------|-------------|
| Fly.io (6 VMs) | $200        |
| Neon Postgres   | $69         |
| Upstash Redis   | $50         |
| OpenAI API      | ~$3,000     |
| Gemini API      | ~$1,500     |
| Anthropic API   | ~$700       |
| **Total**       | **~$5,520/mo**|

Revenue: ~$124.7k/mo → **96% margin**

### Why This Is Cheaper Than Before
The Gemini overflow model cuts AI costs by ~50-60% versus routing everything through OpenAI. Most overflow hits Gemini's free tier (1,500 req/day). At scale, the paid Gemini overflow is still 3-5x cheaper than GPT-4o Mini per token.
