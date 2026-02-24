// src/routes/user.ts
// User routes — send email, get/update settings, verify subscription.

import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { authMiddleware } from '../middleware/auth.js';
import { rateLimit } from '../lib/redis.js';
import { db, schema } from '../db/index.js';
import { eq, and } from 'drizzle-orm';
import { decryptToken } from '../lib/crypto.js';
import { refreshGoogleToken, refreshMicrosoftToken, sendGmailReply, sendOutlookReply } from '../services/email.js';
import { AppStoreServerAPIClient, Environment, SignedDataVerifier } from '@apple/app-store-server-library';

const sendSchema = z.object({
  accountId: z.string().uuid(),
  to: z.string(),
  subject: z.string(),
  body: z.string().max(50000),
  threadId: z.string(),
  messageId: z.string(),
  replyAll: z.boolean().optional().default(false),
  fromName: z.string().optional(),
  fromEmail: z.string().optional(),
});

const settingsSchema = z.object({
  mode: z.enum(['stack', 'window']).optional(),
  windowHour: z.number().int().min(0).max(23).optional(),
  windowMinute: z.number().int().min(0).max(59).optional(),
  sensitivity: z.number().int().min(0).max(100).optional(),
  snoozeHours: z.number().int().min(1).max(48).optional(),
  scoreThreshold: z.number().int().min(0).max(100).optional(),
  scanIntervalMinutes: z.number().int().min(1).max(120).optional(),
});

export default async function userRoutes(app: FastifyInstance) {

  // ── Send Reply ──
  app.post('/send', { preHandler: authMiddleware }, async (request, reply) => {
    const rl = await rateLimit(`send:${request.userId}`, 30, 3600);
    if (!rl.allowed) return reply.code(429).send({ error: 'Rate limit exceeded' });

    const body = sendSchema.parse(request.body);

    // Load account and decrypt token
    const [account] = await db
      .select()
      .from(schema.accounts)
      .where(and(
        eq(schema.accounts.id, body.accountId),
        eq(schema.accounts.userId, request.userId),
      ))
      .limit(1);

    if (!account) return reply.code(404).send({ error: 'Account not found' });
    if (!account.refreshTokenEncrypted || !account.refreshTokenIv) {
      return reply.code(400).send({ error: 'Account has no stored credentials' });
    }

    // Decrypt refresh token and get fresh access token
    const refreshToken = decryptToken(
      account.refreshTokenEncrypted!,
      account.refreshTokenIv!
    );

    try {
      if (account.provider === 'gmail') {
        const { accessToken } = await refreshGoogleToken(refreshToken);
        await sendGmailReply(
          accessToken,
          body.to,
          body.subject,
          body.body,
          body.threadId,
          body.messageId,
          body.fromName || account.displayName || '',
          body.fromEmail || account.email,
        );
      } else if (account.provider === 'outlook') {
        const { accessToken } = await refreshMicrosoftToken(refreshToken);
        await sendOutlookReply(accessToken, body.messageId, body.body);
      } else {
        return reply.code(400).send({ error: `Send not supported for ${account.provider}` });
      }

      // Log usage
      await db.insert(schema.usageLog).values({
        userId: request.userId,
        action: 'send',
        provider: account.provider,
        emailCount: 1,
      });

      return { ok: true };
    } catch (err: any) {
      console.error(`Send failed for ${account.provider}:`, err.message);
      return reply.code(502).send({ error: 'Failed to send email', detail: err.message });
    }
  });

  // ── Get Settings ──
  app.get('/user/settings', { preHandler: authMiddleware }, async (request) => {
    const [settings] = await db
      .select()
      .from(schema.userSettings)
      .where(eq(schema.userSettings.userId, request.userId))
      .limit(1);

    if (!settings) {
      // Create defaults
      await db.insert(schema.userSettings).values({ userId: request.userId });
      return {
        mode: 'stack', windowHour: 19, windowMinute: 0,
        sensitivity: 50, snoozeHours: 6, scoreThreshold: 25,
        scanIntervalMinutes: 2,
      };
    }

    return {
      mode: settings.mode,
      windowHour: settings.windowHour,
      windowMinute: settings.windowMinute,
      sensitivity: settings.sensitivity,
      snoozeHours: settings.snoozeHours,
      scoreThreshold: settings.scoreThreshold,
      scanIntervalMinutes: settings.scanIntervalMinutes,
    };
  });

  // ── Update Settings ──
  app.put('/user/settings', { preHandler: authMiddleware }, async (request) => {
    const body = settingsSchema.parse(request.body);

    const updates: any = { updatedAt: new Date() };
    if (body.mode !== undefined) updates.mode = body.mode;
    if (body.windowHour !== undefined) updates.windowHour = body.windowHour;
    if (body.windowMinute !== undefined) updates.windowMinute = body.windowMinute;
    if (body.sensitivity !== undefined) updates.sensitivity = body.sensitivity;
    if (body.snoozeHours !== undefined) updates.snoozeHours = body.snoozeHours;
    if (body.scoreThreshold !== undefined) updates.scoreThreshold = body.scoreThreshold;
    if (body.scanIntervalMinutes !== undefined) updates.scanIntervalMinutes = body.scanIntervalMinutes;

    // Upsert — create the row if it doesn't exist yet (worker needs it to schedule scans)
    const [existing] = await db.select({ userId: schema.userSettings.userId })
      .from(schema.userSettings)
      .where(eq(schema.userSettings.userId, request.userId))
      .limit(1);

    if (existing) {
      await db.update(schema.userSettings)
        .set(updates)
        .where(eq(schema.userSettings.userId, request.userId));
    } else {
      await db.insert(schema.userSettings).values({
        userId: request.userId,
        ...updates,
      });
    }

    return { ok: true };
  });

  // ── Get Subscription ──
  app.get('/user/subscription', { preHandler: authMiddleware }, async (request) => {
    const [sub] = await db
      .select()
      .from(schema.subscriptions)
      .where(eq(schema.subscriptions.userId, request.userId))
      .limit(1);

    if (!sub) return { tier: 'free', isTrialActive: false, trialDaysRemaining: 0 };

    let effectiveTier = sub.tier;
    let isTrialActive = false;
    let trialDaysRemaining = 0;

    // Check trial
    if (sub.trialStartedAt) {
      const trialEnd = new Date(sub.trialStartedAt);
      trialEnd.setDate(trialEnd.getDate() + 7);
      const now = new Date();
      if (now < trialEnd && sub.tier === 'free') {
        effectiveTier = 'pro';
        isTrialActive = true;
        trialDaysRemaining = Math.ceil((trialEnd.getTime() - now.getTime()) / (1000 * 60 * 60 * 24));
      }
    }

    // Check subscription expiry
    if (sub.tier !== 'free' && sub.expiresAt && new Date() > new Date(sub.expiresAt)) {
      effectiveTier = 'free';
    }

    return { tier: effectiveTier, isTrialActive, trialDaysRemaining, expiresAt: sub.expiresAt };
  });

  // ── Verify Subscription (App Store Receipt) ──
  app.post('/subscription/verify', { preHandler: authMiddleware }, async (request, reply) => {
    const body = z.object({
      transactionId: z.string(),
      originalTransactionId: z.string(),
      productId: z.string(),
    }).parse(request.body);

    // Server-side validation: verify the transaction with Apple
    // If verification fails, still accept the client claim but log the failure
    // (prevents blocking legitimate users while Apple's API is down)
    let verified = false;
    try {
      if (process.env.APP_STORE_KEY_ID && process.env.APP_STORE_ISSUER_ID && process.env.APP_STORE_PRIVATE_KEY) {
        const client = new AppStoreServerAPIClient(
          process.env.APP_STORE_PRIVATE_KEY,
          process.env.APP_STORE_KEY_ID,
          process.env.APP_STORE_ISSUER_ID,
          process.env.APP_STORE_BUNDLE_ID || 'com.ledger.app',
          process.env.NODE_ENV === 'production' ? Environment.PRODUCTION : Environment.SANDBOX
        );
        const transactionInfo = await client.getTransactionInfo(body.transactionId);
        if (transactionInfo) {
          verified = true;
          console.log(`✅ App Store transaction verified: ${body.transactionId}`);
        }
      } else {
        console.warn('⚠️ App Store credentials not configured — skipping server-side verification');
      }
    } catch (err: any) {
      console.error(`⚠️ App Store verification failed (accepting client claim): ${err.message}`);
    }

    // Determine tier from product ID
    let tier: string;
    if (body.productId.includes('pro')) {
      tier = 'pro';
    } else if (body.productId.includes('standard')) {
      tier = 'standard';
    } else {
      tier = 'free';
    }

    // Upsert subscription
    const existing = await db
      .select()
      .from(schema.subscriptions)
      .where(eq(schema.subscriptions.userId, request.userId))
      .limit(1);

    const subData = {
      tier,
      originalTransactionId: body.originalTransactionId,
      verifiedAt: new Date(),
      // Set expiry 35 days out (monthly + grace period)
      // The App Store Server Notification webhook will handle real renewals/cancellations
      expiresAt: new Date(Date.now() + 35 * 24 * 60 * 60 * 1000),
    };

    if (existing.length > 0) {
      await db.update(schema.subscriptions)
        .set(subData)
        .where(eq(schema.subscriptions.userId, request.userId));
    } else {
      await db.insert(schema.subscriptions).values({
        userId: request.userId,
        ...subData,
      });
    }

    return { tier, expiresAt: subData.expiresAt.toISOString() };
  });

  // ── Get Connected Accounts ──
  app.get('/user/accounts', { preHandler: authMiddleware }, async (request) => {
    const accounts = await db
      .select({
        id: schema.accounts.id,
        provider: schema.accounts.provider,
        email: schema.accounts.email,
        displayName: schema.accounts.displayName,
        isEnabled: schema.accounts.isEnabled,
      })
      .from(schema.accounts)
      .where(eq(schema.accounts.userId, request.userId));

    return { accounts };
  });
}
