// src/worker/index.ts
// Background worker — scans emails, scores with AI, sends push notifications.
// Runs as a separate process from the API server.

import 'dotenv/config';
import { Queue, Worker, Job } from 'bullmq';
import { db, schema } from '../db/index.js';
import { eq, and, sql } from 'drizzle-orm';
import { decryptToken, encryptToken } from '../lib/crypto.js';
import { refreshGoogleToken, refreshMicrosoftToken, fetchGmailUnread, fetchOutlookUnread } from '../services/email.js';
import { scoreEmails } from '../services/ai.js';
import { sendPushToUser, batchNotification, windowNotification, urgentNotification } from '../services/push.js';
import { redis, setCachedScore, getCachedScore } from '../lib/redis.js';
import { createHash } from 'crypto';

// ── Queue Setup ──

const QUEUE_NAME = 'email-scan';

const connection = {
  host: new URL(process.env.REDIS_URL!).hostname,
  port: parseInt(new URL(process.env.REDIS_URL!).port || '6379'),
  password: new URL(process.env.REDIS_URL!).password,
  tls: process.env.REDIS_URL?.startsWith('rediss://') ? {} : undefined,
};

export const scanQueue = new Queue(QUEUE_NAME, { connection });

// ── Scan Job Payload ──

interface ScanJobData {
  userId: string;
  mode: 'stack' | 'window';
  scoreThreshold: number;
  sensitivity: number;
}

// ── Worker ──

const worker = new Worker<ScanJobData>(QUEUE_NAME, async (job: Job<ScanJobData>) => {
  const { userId, mode, scoreThreshold, sensitivity } = job.data;
  console.log(`📬 Scanning for user ${userId.slice(0, 8)}... (${mode} mode)`);

  try {
    // 1. Load user's enabled accounts
    const accounts = await db
      .select()
      .from(schema.accounts)
      .where(eq(schema.accounts.userId, userId));

    const enabledAccounts = accounts.filter(a => a.isEnabled);
    if (enabledAccounts.length === 0) {
      console.log(`  ⏭️ No enabled accounts — skipping`);
      return;
    }

    // 2. Fetch emails from all accounts
    const allEmails: any[] = [];

    for (const account of enabledAccounts) {
      if (!account.refreshTokenEncrypted || !account.refreshTokenIv) continue;

      try {
        const refreshToken = decryptToken(
          account.refreshTokenEncrypted!,
          account.refreshTokenIv!
        );

        // Determine scan window (since last scan or 24h)
        const since = account.lastScanAt || new Date(Date.now() - 24 * 60 * 60 * 1000);

        let accessToken: string;
        let newRefreshToken: string | undefined;

        if (account.provider === 'gmail') {
          const result = await refreshGoogleToken(refreshToken);
          accessToken = result.accessToken;
          const emails = await fetchGmailUnread(accessToken, since);
          allEmails.push(...emails.map(e => ({ ...e, accountId: account.id })));
        } else if (account.provider === 'outlook') {
          const result = await refreshMicrosoftToken(refreshToken);
          accessToken = result.accessToken;
          newRefreshToken = result.newRefreshToken;
          const emails = await fetchOutlookUnread(accessToken, since);
          allEmails.push(...emails.map(e => ({ ...e, accountId: account.id })));

          // Microsoft may rotate refresh tokens — save the new one
          if (newRefreshToken && newRefreshToken !== refreshToken) {
            const { encrypted, iv } = encryptToken(newRefreshToken);
            await db.update(schema.accounts)
              .set({ refreshTokenEncrypted: encrypted, refreshTokenIv: iv })
              .where(eq(schema.accounts.id, account.id));
          }
        }

        // Update last scan timestamp
        await db.update(schema.accounts)
          .set({ lastScanAt: new Date() })
          .where(eq(schema.accounts.id, account.id));

      } catch (err: any) {
        console.error(`  ❌ ${account.provider}/${account.email}: ${err.message}`);
        // Don't throw — continue with other accounts
      }
    }

    if (allEmails.length === 0) {
      console.log(`  📭 No new emails`);
      return;
    }

    console.log(`  📨 Found ${allEmails.length} new emails`);

    // 3. Pre-filter obvious noise
    const filtered = allEmails.filter(e => !isObviousNoise(e));
    console.log(`  🔍 ${filtered.length} after pre-filter (${allEmails.length - filtered.length} noise removed)`);

    if (filtered.length === 0) return;

    // 4. Check score cache — skip already-scored
    const uncached: any[] = [];
    const cachedScores: any[] = [];

    for (const email of filtered) {
      const hash = emailHash(email.source || 'unknown', email.id);
      const cached = await getCachedScore(hash);
      if (cached) {
        cachedScores.push({ ...JSON.parse(cached), id: email.id });
      } else {
        uncached.push(email);
      }
    }

    console.log(`  💾 ${cachedScores.length} cached, ${uncached.length} to score`);

    // 5. Score uncached emails with AI
    let newScores: any[] = [];
    if (uncached.length > 0) {
      const [sub] = await db
        .select()
        .from(schema.subscriptions)
        .where(eq(schema.subscriptions.userId, userId))
        .limit(1);

      const tier = getEffectiveTier(sub);

      newScores = await scoreEmails(
        uncached.map(e => ({
          id: e.id,
          from: e.senderName,
          fromEmail: e.senderEmail,
          subject: e.subject,
          body: e.body?.slice(0, 5000) || '',
          source: e.source,
          isUnread: e.isUnread,
          hasReplied: false,
        })),
        userId,
        tier,
      );

      // Cache new scores (Redis + Postgres)
      for (const score of newScores) {
        const email = uncached.find(e => e.id === score.id);
        if (email) {
          const hash = emailHash(email.source, email.id);
          await setCachedScore(hash, JSON.stringify(score), 86400); // 24h TTL

          await db.insert(schema.scoreCache).values({
            emailHash: hash,
            userId,
            replyability: score.replyability,
            summary: score.summary,
            draft: score.draft,
            tone: score.tone,
            category: score.category,
            suggestReplyAll: score.suggestReplyAll,
          }).onConflictDoUpdate({
            target: schema.scoreCache.emailHash,
            set: {
              replyability: score.replyability,
              summary: score.summary,
              draft: score.draft,
              scoredAt: new Date(),
            },
          });
        }
      }
    }

    // 6. Combine all scores and filter by threshold
    const allScores = [...cachedScores, ...newScores];
    const qualifying = allScores.filter(s => s.replyability >= scoreThreshold);

    console.log(`  🎯 ${qualifying.length}/${allScores.length} above threshold (${scoreThreshold})`);

    // 7. Save qualifying items to ledger_items (upsert — don't duplicate)
    let newItemCount = 0;
    for (const score of qualifying) {
      const email = filtered.find(e => e.id === score.id);
      if (!email) continue;

      try {
        // Check if this item already exists and is active
        const existing = await db
          .select({ id: schema.ledgerItems.id, status: schema.ledgerItems.status })
          .from(schema.ledgerItems)
          .where(and(
            eq(schema.ledgerItems.userId, userId),
            eq(schema.ledgerItems.id, email.id),
          ))
          .limit(1);

        if (existing.length > 0) {
          // Already exists — update score if active, skip if dismissed/snoozed/sent
          if (existing[0].status === 'active') {
            await db.update(schema.ledgerItems)
              .set({
                replyability: score.replyability,
                aiSummary: score.summary,
                suggestedDraft: score.draft,
                detectedTone: score.tone,
                category: score.category,
                suggestReplyAll: score.suggestReplyAll || false,
                updatedAt: new Date(),
              })
              .where(and(
                eq(schema.ledgerItems.userId, userId),
                eq(schema.ledgerItems.id, email.id),
              ));
          }
          continue;
        }

        // New item — insert
        await db.insert(schema.ledgerItems).values({
          id: email.id,
          userId,
          accountId: email.accountId || null,
          source: email.source || 'gmail',
          threadId: email.threadId || '',
          messageId: email.messageId || '',
          senderName: email.senderName || '',
          senderEmail: email.senderEmail || '',
          subject: email.subject || '',
          snippet: email.snippet || '',
          body: (email.body || '').slice(0, 50000),
          date: new Date(email.date || Date.now()),
          isUnread: email.isUnread ?? true,
          toRecipients: email.toRecipients ? JSON.stringify(email.toRecipients) : null,
          ccRecipients: email.ccRecipients ? JSON.stringify(email.ccRecipients) : null,
          replyability: score.replyability,
          aiSummary: score.summary,
          suggestedDraft: score.draft,
          detectedTone: score.tone,
          category: score.category,
          suggestReplyAll: score.suggestReplyAll || false,
          status: 'active',
        });
        newItemCount++;
      } catch (err: any) {
        // Unique constraint violation = already exists, skip
        if (err.code === '23505') continue;
        console.error(`  ⚠️ Failed to save ledger item ${email.id}: ${err.message}`);
      }
    }

    console.log(`  📝 Saved ${newItemCount} new ledger items (${qualifying.length - newItemCount} already existed)`);

    // 8. Expire old items — mark items older than 7 days as dismissed
    await db.update(schema.ledgerItems)
      .set({ status: 'dismissed', updatedAt: new Date() })
      .where(and(
        eq(schema.ledgerItems.userId, userId),
        eq(schema.ledgerItems.status, 'active'),
        sql`${schema.ledgerItems.date} < NOW() - INTERVAL '7 days'`,
      ));

    // 9. Restore snoozed items whose snooze has expired
    await db.update(schema.ledgerItems)
      .set({ status: 'active', snoozedUntil: null, updatedAt: new Date() })
      .where(and(
        eq(schema.ledgerItems.userId, userId),
        eq(schema.ledgerItems.status, 'snoozed'),
        sql`${schema.ledgerItems.snoozedUntil} IS NOT NULL AND ${schema.ledgerItems.snoozedUntil} <= NOW()`,
      ));

    // 10. Send push notification only for NEW qualifying items
    if (newItemCount > 0) {
      const topSender = filtered.find(e => e.id === qualifying[0].id)?.senderName || 'someone';
      const urgentEmails = qualifying.filter(s => s.replyability >= 80);

      let payload;
      if (mode === 'window') {
        // Count total active items for window notification
        const activeItems = await db
          .select({ id: schema.ledgerItems.id })
          .from(schema.ledgerItems)
          .where(and(
            eq(schema.ledgerItems.userId, userId),
            eq(schema.ledgerItems.status, 'active'),
          ));
        payload = windowNotification(activeItems.length);
      } else if (urgentEmails.length > 0) {
        const urgentEmail = filtered.find(e => e.id === urgentEmails[0].id);
        payload = urgentNotification(
          urgentEmail?.senderName || 'someone',
          urgentEmail?.subject || 'Urgent email'
        );
      } else {
        payload = batchNotification(newItemCount, topSender);
      }

      const sent = await sendPushToUser(userId, payload);
      console.log(`  🔔 Push sent to ${sent} device(s) — ${newItemCount} new items`);
    }

  } catch (err: any) {
    console.error(`❌ Scan failed for ${userId.slice(0, 8)}: ${err.message}`);
    throw err; // Bull will retry
  }
}, {
  connection,
  concurrency: 5,     // Process 5 users simultaneously
  limiter: {
    max: 20,           // Max 20 jobs per 10 seconds
    duration: 10000,
  },
});

worker.on('completed', (job) => {
  console.log(`✅ Scan complete: ${job.data.userId.slice(0, 8)}`);
});

worker.on('failed', (job, err) => {
  console.error(`❌ Scan failed: ${job?.data.userId.slice(0, 8)} — ${err.message}`);
});

// ── Scheduler: Enqueue scans for all users ──

async function scheduleAllScans() {
  console.log('⏰ Scheduling scans for all users...');

  // Load all users with their settings
  const allSettings = await db.select().from(schema.userSettings);

  let scheduled = 0;
  for (const settings of allSettings) {
    const scanInterval = settings.scanIntervalMinutes;

    // Add repeatable job — Bull handles deduplication
    await scanQueue.add(
      `scan:${settings.userId}`,
      {
        userId: settings.userId,
        mode: settings.mode as 'stack' | 'window',
        scoreThreshold: settings.scoreThreshold,
        sensitivity: settings.sensitivity,
      },
      {
        repeat: {
          every: scanInterval * 60 * 1000,  // Convert minutes to ms
        },
        jobId: `scan:${settings.userId}`,   // Prevents duplicate jobs
        removeOnComplete: { count: 10 },     // Keep last 10 completed
        removeOnFail: { count: 50 },         // Keep last 50 failures
        attempts: 3,
        backoff: { type: 'exponential', delay: 30000 },
      }
    );
    scheduled++;
  }

  console.log(`⏰ Scheduled ${scheduled} scan jobs`);
}

// ── Cleanup: Remove stale score cache entries ──

async function cleanupScoreCache() {
  const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000); // 7 days
  // In production, use a proper SQL delete with WHERE scored_at < cutoff
  console.log('🧹 Score cache cleanup scheduled');
}

// ── Helpers ──

function emailHash(provider: string, emailId: string): string {
  return createHash('sha256').update(`${provider}:${emailId}`).digest('hex').slice(0, 32);
}

function isObviousNoise(email: any): boolean {
  const from = (email.senderEmail || '').toLowerCase();
  const subject = (email.subject || '').toLowerCase();

  // No-reply addresses
  if (from.includes('noreply') || from.includes('no-reply') || from.includes('donotreply')) return true;

  // Automated senders
  const automatedDomains = [
    'notifications@', 'alerts@', 'updates@', 'info@',
    'marketing@', 'newsletter@', 'digest@', 'mailer-daemon',
    'postmaster@',
  ];
  if (automatedDomains.some(d => from.startsWith(d))) return true;

  // Common notification subjects
  const noisePatterns = [
    'unsubscribe', 'your order', 'order confirmation',
    'password reset', 'verify your email', 'two-factor',
    'shipping notification', 'delivery update',
  ];
  if (noisePatterns.some(p => subject.includes(p))) return true;

  return false;
}

function getEffectiveTier(sub: any): string {
  if (!sub) return 'free';
  if (sub.trialStartedAt) {
    const trialEnd = new Date(sub.trialStartedAt);
    trialEnd.setDate(trialEnd.getDate() + 7);
    if (new Date() < trialEnd && sub.tier === 'free') return 'pro';
  }
  if (sub.tier !== 'free' && sub.expiresAt && new Date() > new Date(sub.expiresAt)) return 'free';
  return sub.tier || 'free';
}

// ── Start ──

console.log('🔄 Worker starting...');
scheduleAllScans().then(() => {
  console.log('✅ Worker ready');

  // Re-schedule every 5 minutes to pick up new users / setting changes
  setInterval(() => scheduleAllScans(), 5 * 60 * 1000);
});
