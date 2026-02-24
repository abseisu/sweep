-- Migration: Add ledger_items table for pre-scored background-scanned emails
-- Run this against your Neon Postgres database

CREATE TABLE IF NOT EXISTS ledger_items (
  id TEXT NOT NULL,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_id UUID REFERENCES accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  thread_id TEXT DEFAULT '',
  message_id TEXT DEFAULT '',
  sender_name TEXT DEFAULT '',
  sender_email TEXT DEFAULT '',
  subject TEXT DEFAULT '',
  snippet TEXT DEFAULT '',
  body TEXT DEFAULT '',
  date TIMESTAMPTZ NOT NULL,
  is_unread BOOLEAN DEFAULT true,
  to_recipients TEXT,
  cc_recipients TEXT,
  -- AI scores
  replyability INTEGER DEFAULT 0 NOT NULL,
  ai_summary TEXT,
  suggested_draft TEXT,
  detected_tone TEXT,
  category TEXT,
  suggest_reply_all BOOLEAN DEFAULT false,
  -- State
  status TEXT DEFAULT 'active' NOT NULL,
  snoozed_until TIMESTAMPTZ,
  -- Timestamps
  scanned_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Composite unique: one item per user per email ID
CREATE UNIQUE INDEX IF NOT EXISTS idx_ledger_items_unique ON ledger_items (user_id, id);

-- Fast lookup for active items by user
CREATE INDEX IF NOT EXISTS idx_ledger_items_user_status ON ledger_items (user_id, status);
