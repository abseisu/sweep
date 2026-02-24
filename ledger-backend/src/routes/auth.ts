// src/routes/auth.ts
// Authentication routes — register, refresh JWT, update device token, delete account.

import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { db, schema } from '../db/index.js';
import { eq, and } from 'drizzle-orm';
import { signJWT } from '../lib/jwt.js';
import { encryptToken } from '../lib/crypto.js';
import { authMiddleware } from '../middleware/auth.js';
import { rateLimit, redis } from '../lib/redis.js';
import { exchangeGoogleAuthCode } from '../services/email.js';

const registerSchema = z.object({
  provider: z.enum(['gmail', 'outlook', 'slack', 'telegram', 'groupme']),
  accessToken: z.string().min(1),
  refreshToken: z.string().default(''),   // serverAuthCode for Gmail, refresh token for Outlook, or empty
  email: z.string().email(),
  displayName: z.string().optional(),
  deviceToken: z.string().optional(),
  deviceId: z.string().min(1),
});

const deviceSchema = z.object({
  deviceToken: z.string().min(1),
  deviceId: z.string().min(1),
});

export default async function authRoutes(app: FastifyInstance) {

  // ── Register / Add Account ──
  app.post('/auth/register', async (request, reply) => {
    const body = registerSchema.parse(request.body);

    // Rate limit: 10 registrations per minute per device
    const rl = await rateLimit(`register:${body.deviceId}`, 10, 60);
    if (!rl.allowed) return reply.code(429).send({ error: 'Too many requests' });

    // Validate the access token against the provider
    const valid = await validateProviderToken(body.provider, body.accessToken, body.email);
    if (!valid) return reply.code(401).send({ error: 'Invalid provider token' });

    // Find or create user — by email first, then by device
    let userId: string;

    // 1. Check if any user already has an account with this email
    const existingAccount = await db
      .select()
      .from(schema.accounts)
      .where(and(
        eq(schema.accounts.provider, body.provider),
        eq(schema.accounts.email, body.email),
      ))
      .limit(1);

    if (existingAccount.length > 0) {
      // Reuse the existing user — same email = same person
      userId = existingAccount[0].userId;
    } else {
      // 2. Check if this device already has a user
      const existingDevice = await db
        .select()
        .from(schema.devices)
        .where(eq(schema.devices.deviceId, body.deviceId))
        .limit(1);

      if (existingDevice.length > 0) {
        userId = existingDevice[0].userId;
      } else {
        // 3. Create new user
        const [newUser] = await db.insert(schema.users).values({}).returning();
        userId = newUser.id;

        // Create default settings
        await db.insert(schema.userSettings).values({ userId });

        // Create trial subscription
        await db.insert(schema.subscriptions).values({
          userId,
          tier: 'free',
          trialStartedAt: new Date(),
        });
      }
    }

    // Exchange auth code for refresh token (Google) or use directly (Microsoft/Slack)
    let refreshTokenToStore = body.refreshToken;

    if (body.provider === 'gmail' && body.refreshToken) {
      try {
        // Google sends a serverAuthCode — exchange it for a real refresh token
        const exchanged = await exchangeGoogleAuthCode(body.refreshToken);
        refreshTokenToStore = exchanged.refreshToken;
        console.log(`✅ Google auth code exchanged for refresh token: ${body.email}`);
      } catch (err: any) {
        // Auth code may have already been exchanged (one-time use).
        // If the account already exists with a stored refresh token, keep it.
        const existingAcct = await db
          .select()
          .from(schema.accounts)
          .where(and(
            eq(schema.accounts.provider, body.provider),
            eq(schema.accounts.email, body.email),
          ))
          .limit(1);

        if (existingAcct.length > 0 && existingAcct[0].refreshTokenEncrypted) {
          console.log(`⚠️ Google auth code exchange failed but account has existing refresh token — keeping it: ${err.message}`);
          refreshTokenToStore = '__KEEP_EXISTING__';
        } else {
          console.error(`❌ Google auth code exchange failed and no existing token: ${err.message}`);
          // Still continue registration — the backend won't be able to fetch emails
          // but the iOS app can still work with its own tokens
        }
      }
    }

    // Encrypt refresh token
    const shouldUpdateToken = refreshTokenToStore !== '__KEEP_EXISTING__' && refreshTokenToStore.length > 0;
    const tokenData = shouldUpdateToken ? encryptToken(refreshTokenToStore) : null;

    // Upsert account
    const existing = await db
      .select()
      .from(schema.accounts)
      .where(and(
        eq(schema.accounts.userId, userId),
        eq(schema.accounts.provider, body.provider),
        eq(schema.accounts.email, body.email),
      ))
      .limit(1);

    if (existing.length > 0) {
      const updateSet: any = {
        displayName: body.displayName,
        isEnabled: true,
      };
      if (tokenData) {
        updateSet.refreshTokenEncrypted = tokenData.encrypted;
        updateSet.refreshTokenIv = tokenData.iv;
      }
      await db.update(schema.accounts)
        .set(updateSet)
        .where(eq(schema.accounts.id, existing[0].id));
    } else {
      await db.insert(schema.accounts).values({
        userId,
        provider: body.provider,
        email: body.email,
        displayName: body.displayName,
        refreshTokenEncrypted: tokenData?.encrypted || null,
        refreshTokenIv: tokenData?.iv || null,
      });
    }

    // Upsert device
    const existingDev = await db
      .select()
      .from(schema.devices)
      .where(and(
        eq(schema.devices.userId, userId),
        eq(schema.devices.deviceId, body.deviceId),
      ))
      .limit(1);

    if (existingDev.length > 0) {
      await db.update(schema.devices)
        .set({
          deviceToken: body.deviceToken,
          lastSeenAt: new Date(),
        })
        .where(eq(schema.devices.id, existingDev[0].id));
    } else {
      await db.insert(schema.devices).values({
        userId,
        deviceId: body.deviceId,
        deviceToken: body.deviceToken,
      });
    }

    // Issue JWT
    const { token, expiresAt } = await signJWT(userId, body.deviceId);

    return { jwt: token, userId, expiresAt: expiresAt.toISOString() };
  });

  // ── Refresh JWT ──
  app.post('/auth/refresh', { preHandler: authMiddleware }, async (request) => {
    const { token, expiresAt } = await signJWT(request.userId, request.deviceId);
    return { jwt: token, expiresAt: expiresAt.toISOString() };
  });

  // ── Register Device Only (for iMessage-only users with no email account) ──
  app.post('/auth/register-device', async (request, reply) => {
    const body = z.object({
      deviceId: z.string().min(1),
      previousUserId: z.string().optional(),  // iOS sends this if it had a prior user
    }).parse(request.body);

    // Check if this device already has a user
    const existingDevice = await db
      .select()
      .from(schema.devices)
      .where(eq(schema.devices.deviceId, body.deviceId))
      .limit(1);

    let userId: string;

    if (existingDevice.length > 0) {
      userId = existingDevice[0].userId;
    } else {
      // Create new user
      const [newUser] = await db.insert(schema.users).values({}).returning();
      userId = newUser.id;

      // Create default settings
      await db.insert(schema.userSettings).values({ userId });

      // Create trial subscription
      await db.insert(schema.subscriptions).values({
        userId,
        tier: 'free',
        trialStartedAt: new Date(),
      });

      // Create device
      await db.insert(schema.devices).values({
        userId,
        deviceId: body.deviceId,
      });

      // ── Migrate Mac relay pairing from previous user ──
      // If iOS had a previous userId with an active Mac relay,
      // move the relay info and device to the new user so the Mac
      // continues working seamlessly without re-pairing.
      const oldUserId = body.previousUserId;
      if (oldUserId && oldUserId !== userId) {
        try {
          const relayInfo = await redis.get(`imsg_relay:${oldUserId}`);
          if (relayInfo) {
            // Move relay info to new user
            await redis.set(`imsg_relay:${userId}`, relayInfo);
            await redis.del(`imsg_relay:${oldUserId}`);

            // Move any pending replies
            const pendingReplies = await redis.lrange(`imsg_replies:${oldUserId}`, 0, -1);
            if (pendingReplies.length > 0) {
              for (const r of pendingReplies) {
                await redis.rpush(`imsg_replies:${userId}`, r);
              }
              await redis.del(`imsg_replies:${oldUserId}`);
            }

            // Move Mac relay device to new user
            const macDeviceId = `mac_relay_${oldUserId}`;
            const newMacDeviceId = `mac_relay_${userId}`;
            await db.update(schema.devices)
              .set({ userId, deviceId: newMacDeviceId })
              .where(and(
                eq(schema.devices.userId, oldUserId),
                eq(schema.devices.deviceId, macDeviceId),
              ));

            // Move ledger items from old user
            await db.update(schema.ledgerItems)
              .set({ userId })
              .where(eq(schema.ledgerItems.userId, oldUserId));

            // Issue a fresh JWT for the Mac relay under the new user
            const { token: macJwt, expiresAt: macExpiry } = await signJWT(userId, newMacDeviceId);
            // Store the fresh Mac JWT in Redis so the Mac can pick it up
            await redis.set(`imsg_mac_jwt:${userId}`, JSON.stringify({
              jwt: macJwt,
              expiresAt: macExpiry.toISOString(),
            }), 'EX', 86400); // 24h TTL

            console.log(`🔄 Migrated Mac relay from user ${oldUserId} → ${userId}`);
          }
        } catch (err) {
          console.error('⚠️ Relay migration error (non-fatal):', err);
        }
      }
    }

    // Fresh install / re-register → reactivate all dismissed items (clean slate).
    // Deleting and re-downloading the app always starts fresh.
    await db.update(schema.ledgerItems)
      .set({ status: 'active', updatedAt: new Date() })
      .where(and(
        eq(schema.ledgerItems.userId, userId),
        eq(schema.ledgerItems.status, 'dismissed'),
      ));
    console.log(`🔄 Ledger reset for user ${userId.slice(0, 8)} — clean slate on register`);

    // Issue JWT
    const { token, expiresAt } = await signJWT(userId, body.deviceId);

    return { jwt: token, userId, expiresAt: expiresAt.toISOString() };
  });

  // ── Update Device Token ──
  app.post('/auth/device', { preHandler: authMiddleware }, async (request, reply) => {
    const body = deviceSchema.parse(request.body);

    await db.update(schema.devices)
      .set({
        deviceToken: body.deviceToken,
        lastSeenAt: new Date(),
      })
      .where(and(
        eq(schema.devices.userId, request.userId),
        eq(schema.devices.deviceId, body.deviceId),
      ));

    return { ok: true };
  });

  // ── Delete Account (GDPR) ──
  app.delete('/auth/account', { preHandler: authMiddleware }, async (request) => {
    // CASCADE deletes: accounts, devices, subscriptions, settings, score_cache, usage_log
    await db.delete(schema.users).where(eq(schema.users.id, request.userId));
    return { ok: true };
  });
}

// ── Provider Token Validation ──

async function validateProviderToken(provider: string, accessToken: string, email: string): Promise<boolean> {
  try {
    if (provider === 'gmail') {
      const res = await fetch('https://www.googleapis.com/oauth2/v1/userinfo', {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      if (!res.ok) return false;
      const data = await res.json() as any;
      return data.email?.toLowerCase() === email.toLowerCase();
    }

    if (provider === 'outlook') {
      const res = await fetch('https://graph.microsoft.com/v1.0/me', {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      if (!res.ok) return false;
      const data = await res.json() as any;
      return data.mail?.toLowerCase() === email.toLowerCase() ||
             data.userPrincipalName?.toLowerCase() === email.toLowerCase();
    }

    // Other providers — trust the token for now
    return true;
  } catch {
    return false;
  }
}
