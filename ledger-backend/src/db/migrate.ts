// src/db/migrate.ts
// Run with: npx tsx src/db/migrate.ts
// Pushes the Drizzle schema to the database.

import 'dotenv/config';
import postgres from 'postgres';

const sql = postgres(process.env.DATABASE_URL!, { ssl: 'require' });

async function migrate() {
  console.log('🔄 Running migrations...');

  // Create tables in dependency order
  await sql`
    CREATE TABLE IF NOT EXISTS users (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
      updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
    )
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS accounts (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
      provider TEXT NOT NULL,
      email TEXT NOT NULL,
      display_name TEXT,
      refresh_token_encrypted TEXT,
      refresh_token_iv TEXT,
      token_expires_at TIMESTAMPTZ,
      is_enabled BOOLEAN DEFAULT true NOT NULL,
      last_scan_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
    )
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS devices (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
      device_id TEXT NOT NULL,
      device_token TEXT,
      platform TEXT DEFAULT 'ios' NOT NULL,
      last_seen_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
    )
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS subscriptions (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL UNIQUE,
      tier TEXT DEFAULT 'free' NOT NULL,
      original_transaction_id TEXT,
      expires_at TIMESTAMPTZ,
      trial_started_at TIMESTAMPTZ,
      receipt_data TEXT,
      verified_at TIMESTAMPTZ
    )
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS user_settings (
      user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
      mode TEXT DEFAULT 'stack' NOT NULL,
      window_hour INT DEFAULT 19 NOT NULL,
      window_minute INT DEFAULT 0 NOT NULL,
      sensitivity INT DEFAULT 50 NOT NULL,
      snooze_hours INT DEFAULT 6 NOT NULL,
      score_threshold INT DEFAULT 25 NOT NULL,
      scan_interval_minutes INT DEFAULT 2 NOT NULL,
      updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
    )
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS score_cache (
      email_hash TEXT PRIMARY KEY,
      user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
      replyability INT,
      summary TEXT,
      draft TEXT,
      tone TEXT,
      category TEXT,
      suggest_reply_all BOOLEAN DEFAULT false,
      scored_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
    )
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS usage_log (
      id BIGSERIAL PRIMARY KEY,
      user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
      action TEXT NOT NULL,
      provider TEXT,
      tokens_used INT DEFAULT 0,
      email_count INT DEFAULT 0,
      created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
    )
  `;

  // Create indexes
  await sql`CREATE INDEX IF NOT EXISTS idx_accounts_user ON accounts(user_id)`;
  await sql`CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_unique ON accounts(user_id, provider, email)`;
  await sql`CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_unique ON devices(user_id, device_id)`;
  await sql`CREATE INDEX IF NOT EXISTS idx_score_cache_user ON score_cache(user_id)`;
  await sql`CREATE INDEX IF NOT EXISTS idx_score_cache_scored ON score_cache(scored_at)`;
  await sql`CREATE INDEX IF NOT EXISTS idx_usage_log_user_date ON usage_log(user_id, created_at)`;

  console.log('✅ Migrations complete');
}

migrate().catch((err) => {
  console.error('❌ Migration failed:', err);
  process.exit(1);
});
