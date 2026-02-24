# Ledger Backend — Deployment Guide

Step-by-step from zero to production. Estimated time: 45–60 minutes.

---

## Prerequisites

- Node.js 24 LTS installed (download at https://nodejs.org — select the LTS version, not "Current")
- macOS Terminal or iTerm
- Apple Developer Account ($99/year — you already have this)
- Credit card for Fly.io (free tier covers launch)

---

## Step 1: Create Accounts (10 min)

### 1a. Fly.io
```bash
brew install flyctl
fly auth signup    # or: fly auth login
```

### 1b. Neon (Postgres)
1. Go to https://neon.tech → Sign up
2. Create project: "ledger"
3. Copy the connection string:
   `postgresql://user:pass@ep-xxx.us-east-2.aws.neon.tech/neondb?sslmode=require`

### 1c. Upstash (Redis)
1. Go to https://upstash.com → Sign up
2. Create Redis database in "US-East-1"
3. Copy the Redis URL:
   `rediss://default:xxx@us1-xxx.upstash.io:6379`

---

## Step 2: Generate Security Keys (5 min)

### 2a. JWT Signing Keys (ES256)
```bash
openssl ecparam -genkey -name prime256v1 -noout | openssl pkcs8 -topk8 -nocrypt -out jwt_private.pem
openssl ec -in jwt_private.pem -pubout -out jwt_public.pem
cat jwt_private.pem
cat jwt_public.pem
```

### 2b. Token Encryption Key (AES-256-GCM)
```bash
openssl rand -hex 32
```
Save this 64-character hex string.

---

## Step 3: Google OAuth Server Credentials (10 min)

The iOS app uses a client-side OAuth client. The backend needs a **server-side** one (with a client secret) to refresh tokens.

1. Go to https://console.cloud.google.com/apis/credentials
2. Click **"+ CREATE CREDENTIALS" → "OAuth client ID"**
3. Application type: **Web application**
4. Name: "Ledger Backend"
5. No redirect URIs needed
6. Copy **Client ID** and **Client Secret**

> The iOS app's Google Sign-In must set `serverClientID` to this web client ID
> to get a refresh token. See IOS_CHANGES.md.

---

## Step 4: Microsoft OAuth (5 min)

1. Go to https://portal.azure.com → Azure AD → App registrations
2. Find your Ledger app registration
3. Certificates & secrets → New client secret
4. Copy the **secret value**
5. Note the **Application (client) ID** from Overview

---

## Step 5: Gemini API Key (2 min)

1. Go to https://aistudio.google.com/apikey
2. Click "Create API Key"
3. Copy the key (starts with `AIza...`)
4. Free tier: 1,500 requests/day, 1M tokens/min — more than enough at launch

---

## Step 6: Apple Push Notifications (10 min)

### 6a. Create APNs Key
1. https://developer.apple.com/account/resources/authkeys/list
2. Click "+" → Name: "Ledger Push" → Check "Apple Push Notifications service (APNs)"
3. Continue → Register → **Download the .p8 file** (one-time download!)
4. Note the **Key ID** (e.g., ABC123DEFG)
5. Note your **Team ID** (top-right of developer portal)

### 6b. Encode for deployment
```bash
base64 -i AuthKey_ABC123DEFG.p8
```

---

## Step 7: Deploy to Fly.io (10 min)

### 7a. Create app
```bash
cd ledger-backend
fly apps create ledger-api
```

### 7b. Set all secrets
```bash
fly secrets set \
  DATABASE_URL="postgresql://..." \
  REDIS_URL="rediss://..." \
  JWT_PRIVATE_KEY="$(cat jwt_private.pem)" \
  JWT_PUBLIC_KEY="$(cat jwt_public.pem)" \
  TOKEN_ENCRYPTION_KEY="your_64_hex_char_key" \
  OPENAI_API_KEY="sk-..." \
  ANTHROPIC_API_KEY="sk-ant-..." \
  GEMINI_API_KEY="AIza..." \
  GOOGLE_CLIENT_ID="xxx.apps.googleusercontent.com" \
  GOOGLE_CLIENT_SECRET="GOCSPX-..." \
  MSAL_CLIENT_ID="xxx" \
  MSAL_CLIENT_SECRET="xxx" \
  MSAL_TENANT_ID="common" \
  APNS_KEY_ID="ABC123DEFG" \
  APNS_TEAM_ID="DEF456" \
  APNS_BUNDLE_ID="com.yourcompany.ledger" \
  APNS_KEY_BASE64="LS0tLS1CRUdJTi..."
```

### 7c. Run database migrations
```bash
npm install
DATABASE_URL="postgresql://..." npx tsx src/db/migrate.ts
```

### 7d. Deploy
```bash
fly deploy
fly scale count api=1 worker=1
curl https://ledger-api.fly.dev/health
```

---

## Step 8: Set Provider Spending Limits

**This is your circuit breaker — do this before launch.**

1. **OpenAI**: https://platform.openai.com/settings/organization/limits → Set monthly hard cap ($200 at launch)
2. **Anthropic**: https://console.anthropic.com/settings/billing → Set spending limit ($100 at launch)
3. **Gemini**: Free tier has built-in limits. Paid tier at https://console.cloud.google.com/billing

---

## Step 9: Verify

```bash
# Health check
curl https://ledger-api.fly.dev/health
# → { "status": "ok", "timestamp": "...", "version": "1.0.0" }

# Check logs
fly logs
# → 🚀 Ledger API running on 0.0.0.0:3000
# → 🔄 Worker starting...
# → ✅ Worker ready
```

---

## Scaling Playbook

```bash
# More API capacity
fly scale count api=3
fly scale vm shared-cpu-2x

# More worker capacity
fly scale count worker=2

# Multi-region (international users)
fly scale count api=2 --region ewr,lhr
```

---

## Security Checklist

- [x] All secrets in Fly.io (never in code or Docker image)
- [x] OAuth refresh tokens encrypted at rest (AES-256-GCM)
- [x] JWT with ES256, jti for revocation, nbf for replay protection
- [x] Anti-abuse rate limiting on all endpoints (per-user + per-IP)
- [x] Input validation (Zod) on every request body
- [x] Parameterized SQL (Drizzle ORM)
- [x] Non-root Docker user
- [x] TLS enforced (Fly.io managed certificates)
- [x] CORS disabled (not needed for iOS native HTTP)
- [x] Provider tokens validated on registration
- [x] Generic error messages to client (no internal detail leakage)
- [x] Sensitive fields redacted from logs
- [x] Startup fails fast on missing environment variables
- [x] Invalid APNs tokens auto-cleaned
- [x] CASCADE deletes for GDPR compliance
- [x] OpenAI/Anthropic monthly spending caps set
- [ ] TODO: App Store Server Notifications webhook (subscription renewals)
- [ ] TODO: Sentry for error tracking
- [ ] TODO: Encryption key rotation procedure
