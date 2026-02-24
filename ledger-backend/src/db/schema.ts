// src/db/schema.ts
// Drizzle ORM schema — single source of truth for all tables.

import { pgTable, uuid, text, integer, boolean, timestamp, bigserial, index, uniqueIndex } from 'drizzle-orm/pg-core';

// ── Users ──
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
});

// ── Connected Accounts (Gmail, Outlook, Slack, etc.) ──
export const accounts = pgTable('accounts', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  provider: text('provider').notNull(),           // 'gmail', 'outlook', 'slack', etc.
  email: text('email').notNull(),
  displayName: text('display_name'),
  refreshTokenEncrypted: text('refresh_token_encrypted'),
  refreshTokenIv: text('refresh_token_iv'),
  tokenExpiresAt: timestamp('token_expires_at', { withTimezone: true }),
  isEnabled: boolean('is_enabled').default(true).notNull(),
  lastScanAt: timestamp('last_scan_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
}, (table) => ({
  userIdx: index('idx_accounts_user').on(table.userId),
  uniqueAccount: uniqueIndex('idx_accounts_unique').on(table.userId, table.provider, table.email),
}));

// ── Devices (APNs push tokens) ──
export const devices = pgTable('devices', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  deviceId: text('device_id').notNull(),
  deviceToken: text('device_token'),              // APNs hex token
  platform: text('platform').default('ios').notNull(),
  lastSeenAt: timestamp('last_seen_at', { withTimezone: true }).defaultNow().notNull(),
}, (table) => ({
  uniqueDevice: uniqueIndex('idx_devices_unique').on(table.userId, table.deviceId),
}));

// ── Subscriptions ──
export const subscriptions = pgTable('subscriptions', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull().unique(),
  tier: text('tier').default('free').notNull(),    // 'free', 'standard', 'pro'
  originalTransactionId: text('original_transaction_id'),
  expiresAt: timestamp('expires_at', { withTimezone: true }),
  trialStartedAt: timestamp('trial_started_at', { withTimezone: true }),
  receiptData: text('receipt_data'),
  verifiedAt: timestamp('verified_at', { withTimezone: true }),
});

// ── User Settings (synced for worker scheduling) ──
export const userSettings = pgTable('user_settings', {
  userId: uuid('user_id').primaryKey().references(() => users.id, { onDelete: 'cascade' }),
  mode: text('mode').default('stack').notNull(),
  windowHour: integer('window_hour').default(19).notNull(),
  windowMinute: integer('window_minute').default(0).notNull(),
  sensitivity: integer('sensitivity').default(50).notNull(),
  snoozeHours: integer('snooze_hours').default(6).notNull(),
  scoreThreshold: integer('score_threshold').default(25).notNull(),
  scanIntervalMinutes: integer('scan_interval_minutes').default(2).notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
});

// ── Score Cache (prevents re-scoring, prevents flip-flopping) ──
export const scoreCache = pgTable('score_cache', {
  emailHash: text('email_hash').primaryKey(),      // SHA-256(provider + email_id)
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  replyability: integer('replyability'),
  summary: text('summary'),
  draft: text('draft'),
  tone: text('tone'),
  category: text('category'),
  suggestReplyAll: boolean('suggest_reply_all').default(false),
  scoredAt: timestamp('scored_at', { withTimezone: true }).defaultNow().notNull(),
}, (table) => ({
  userIdx: index('idx_score_cache_user').on(table.userId),
  scoredIdx: index('idx_score_cache_scored').on(table.scoredAt),
}));

// ── Usage Log (rate limiting, analytics, cost tracking) ──
export const usageLog = pgTable('usage_log', {
  id: bigserial('id', { mode: 'number' }).primaryKey(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  action: text('action').notNull(),                // 'score', 'redraft', 'send', 'scan'
  provider: text('provider'),                      // 'openai', 'anthropic'
  tokensUsed: integer('tokens_used').default(0),
  emailCount: integer('email_count').default(0),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
}, (table) => ({
  userDateIdx: index('idx_usage_log_user_date').on(table.userId, table.createdAt),
}));

// ── Ledger Items (pre-scored emails ready for the app to pull) ──
export const ledgerItems = pgTable('ledger_items', {
  id: text('id').notNull(),                         // Original email ID (Gmail/Outlook msg id)
  userId: uuid('user_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  accountId: uuid('account_id'),
  source: text('source').notNull(),                  // gmail, outlook, slack, etc.
  threadId: text('thread_id').default(''),
  messageId: text('message_id').default(''),
  senderName: text('sender_name').default(''),
  senderEmail: text('sender_email').default(''),
  subject: text('subject').default(''),
  snippet: text('snippet').default(''),
  body: text('body').default(''),
  date: timestamp('date', { withTimezone: true }).notNull(),
  isUnread: boolean('is_unread').default(true),
  toRecipients: text('to_recipients'),               // JSON array string
  ccRecipients: text('cc_recipients'),               // JSON array string
  // AI scores
  replyability: integer('replyability').default(0).notNull(),
  aiSummary: text('ai_summary'),
  suggestedDraft: text('suggested_draft'),
  detectedTone: text('detected_tone'),
  category: text('category'),
  suggestReplyAll: boolean('suggest_reply_all').default(false),
  // State
  status: text('status').default('active').notNull(),  // active, dismissed, snoozed, sent
  snoozedUntil: timestamp('snoozed_until', { withTimezone: true }),
  // Timestamps
  scannedAt: timestamp('scanned_at', { withTimezone: true }).defaultNow().notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
}, (table) => ({
  userStatusIdx: index('idx_ledger_items_user_status').on(table.userId, table.status),
  uniqueItem: uniqueIndex('idx_ledger_items_unique').on(table.userId, table.id),
}));
