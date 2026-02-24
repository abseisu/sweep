// src/routes/imessage.ts
// iMessage relay routes — pairing with Mac app, message ingestion, reply queue.

import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { authMiddleware } from '../middleware/auth.js';
import { db, schema } from '../db/index.js';
import { eq, and, sql } from 'drizzle-orm';
import { redis, rateLimit } from '../lib/redis.js';
import { signJWT, verifyJWTSignatureOnly } from '../lib/jwt.js';
import { scoreEmails } from '../services/ai.js';

const PAIR_CODE_TTL = 300; // 5 minutes
const PAIR_PREFIX = 'imsg_pair:';

// ── Generate Pairing Code ──

function generateCode(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // No I/O/0/1 to avoid confusion
  let code = '';
  for (let i = 0; i < 6; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

export default async function imessageRoutes(app: FastifyInstance) {

  // ── Start Pairing (called from iOS app) ──
  // Returns a 6-char code that the user enters on their Mac
  app.post('/imessage/pair/start', { preHandler: authMiddleware }, async (request) => {
    const userId = request.userId;
    const code = generateCode();

    // Store code → userId mapping in Redis with 5 min TTL
    await redis.set(`${PAIR_PREFIX}${code}`, userId, 'EX', PAIR_CODE_TTL);

    return { code, expiresIn: PAIR_CODE_TTL };
  });

  // ── Confirm Pairing (called from Mac app) ──
  // Mac sends the code, gets back a JWT linked to the user's account
  app.post('/imessage/pair/confirm', async (request, reply) => {
    const body = z.object({
      code: z.string().min(4).max(8),
      macName: z.string().optional(),
    }).parse(request.body);

    const code = body.code.toUpperCase().trim();
    const userId = await redis.get(`${PAIR_PREFIX}${code}`);

    if (!userId) {
      return reply.code(400).send({ error: 'Invalid or expired pairing code' });
    }

    // Delete the code (single use)
    await redis.del(`${PAIR_PREFIX}${code}`);

    // Create a device entry for the Mac relay
    const deviceId = `mac_relay_${userId}`;
    const existingDev = await db
      .select()
      .from(schema.devices)
      .where(and(
        eq(schema.devices.userId, userId),
        eq(schema.devices.deviceId, deviceId),
      ))
      .limit(1);

    if (existingDev.length > 0) {
      await db.update(schema.devices)
        .set({ lastSeenAt: new Date() })
        .where(eq(schema.devices.id, existingDev[0].id));
    } else {
      await db.insert(schema.devices).values({
        userId,
        deviceId,
        platform: 'mac_relay',
      });
    }

    // Store Mac relay info for the user
    await redis.set(`imsg_relay:${userId}`, JSON.stringify({
      macName: body.macName || 'Mac',
      pairedAt: new Date().toISOString(),
      active: true,
    }));

    // Issue a JWT for the Mac app
    const { token, expiresAt } = await signJWT(userId, deviceId);

    return { jwt: token, userId, expiresAt: expiresAt.toISOString() };
  });

  // ── Check Pairing Status (polled by iOS app) ──
  app.get('/imessage/status', { preHandler: authMiddleware }, async (request) => {
    const userId = request.userId;
    const relayInfo = await redis.get(`imsg_relay:${userId}`);

    if (!relayInfo) {
      return { connected: false };
    }

    try {
      const info = JSON.parse(relayInfo);
      return {
        connected: info.active === true,
        macName: info.macName,
        pairedAt: info.pairedAt,
      };
    } catch {
      return { connected: false };
    }
  });

  // ── Push Messages (called from Mac app) ──
  // Smart iMessage ingestion:
  // 1. Groups burst messages (sent in quick succession) into one card
  // 2. Only surfaces the LATEST unreplied burst — if user replied after old messages, those are stale
  // 3. AI scores the full conversation context so the draft addresses ALL messages in the burst
  app.post('/imessage/messages', { preHandler: authMiddleware }, async (request) => {
    const body = z.object({
      messages: z.array(z.object({
        id: z.string(),
        senderName: z.string(),
        senderPhone: z.string(),
        text: z.string(),
        date: z.string(),
        chatId: z.string(),
        isGroupChat: z.boolean().optional(),
        groupName: z.string().nullable().optional(),
        isFromMe: z.boolean().optional(),
      })),
      context: z.record(z.string(), z.array(z.object({
        text: z.string(),
        isFromMe: z.boolean(),
        date: z.string(),
        senderName: z.string().optional(),
      }))).optional(),
      // Definitive last reply dates per chatId — queried directly from chat.db
      // This is the most reliable way to know when the user last responded
      lastReplyDates: z.record(z.string(), z.string()).optional(),
      // Group chat members — chatId → array of phone numbers/emails
      groupMembers: z.record(z.string(), z.array(z.string())).optional(),
    }).parse(request.body);

    const userId = request.userId;
    if (body.messages.length === 0) return { ok: true, scored: 0 };

    // ── Step 1: Sort ALL messages (including isFromMe) by date to understand conversation flow ──
    const allSorted = [...body.messages].sort(
      (a, b) => new Date(a.date).getTime() - new Date(b.date).getTime()
    );

    // ── Step 2: For each chatId, find the LATEST unreplied burst ──
    // Key insight: if the user sent a reply AFTER some incoming messages, those old messages
    // are "replied to" and should NOT create a card. Only messages AFTER the user's last reply matter.
    const chatMessages = new Map<string, typeof allSorted>();
    for (const msg of allSorted) {
      const existing = chatMessages.get(msg.chatId) || [];
      existing.push(msg);
      chatMessages.set(msg.chatId, existing);
    }

    // Also check conversation context for the user's last reply
    interface MessageGroup {
      chatId: string;
      senderName: string;
      senderPhone: string;
      isGroupChat: boolean;
      groupName: string | null;
      messages: Array<{ id: string; text: string; date: string; isFromMe?: boolean; senderName?: string }>;
      latestDate: string;
      earliestDate: string;
      combinedId: string;
    }

    const groups = new Map<string, MessageGroup>();
    const BURST_WINDOW_MS = 5 * 60 * 1000; // 5 minutes between messages = new burst

    for (const [chatId, msgs] of chatMessages) {
      // Find the user's last outgoing message — use definitive lastReplyDates first
      let lastUserReplyTime = 0;

      // PRIMARY: Use lastReplyDates from Mac relay (queried directly from chat.db — most reliable)
      const definitiveReplyDate = body.lastReplyDates?.[chatId];
      if (definitiveReplyDate) {
        lastUserReplyTime = new Date(definitiveReplyDate).getTime();
      } else {
        // FALLBACK: Check conversation context for user's last reply
        const ctx = body.context?.[chatId];
        if (ctx) {
          for (const c of ctx) {
            if (c.isFromMe) {
              const t = new Date(c.date).getTime();
              if (t > lastUserReplyTime) lastUserReplyTime = t;
            }
          }
        }

        // FALLBACK: Check this batch for user's outgoing messages
        for (const msg of msgs) {
          if (msg.isFromMe) {
            const t = new Date(msg.date).getTime();
            if (t > lastUserReplyTime) lastUserReplyTime = t;
          }
        }
      }

      // Filter to only INCOMING messages AFTER the user's last reply
      const unreplied = msgs.filter(m => {
        if (m.isFromMe) return false;
        if (!m.text || m.text.trim() === '') return false;
        const t = new Date(m.date).getTime();
        return t > lastUserReplyTime;
      });

      if (unreplied.length === 0) continue;

      // Group unreplied messages into bursts (messages within 5 min of each other)
      // We only care about the LATEST burst
      let currentBurst: typeof unreplied = [unreplied[0]];

      for (let i = 1; i < unreplied.length; i++) {
        const prevTime = new Date(unreplied[i - 1].date).getTime();
        const thisTime = new Date(unreplied[i].date).getTime();

        if (thisTime - prevTime < BURST_WINDOW_MS) {
          // Same burst — continue
          currentBurst.push(unreplied[i]);
        } else {
          // Gap > 5 min — start new burst (drop the old one, we only want the latest)
          currentBurst = [unreplied[i]];
        }
      }

      // currentBurst now contains only the LATEST burst of unreplied messages
      const sampleMsg = currentBurst[0];
      groups.set(chatId, {
        chatId,
        senderName: sampleMsg.senderName,
        senderPhone: sampleMsg.senderPhone,
        isGroupChat: sampleMsg.isGroupChat || false,
        groupName: sampleMsg.groupName || null,
        messages: currentBurst.map(m => ({ id: m.id, text: m.text, date: m.date, isFromMe: m.isFromMe, senderName: m.senderName })),
        latestDate: currentBurst[currentBurst.length - 1].date,
        earliestDate: currentBurst[0].date,
        combinedId: currentBurst.map(m => m.id).join('_'),
      });
    }

    if (groups.size === 0) return { ok: true, scored: 0 };

    // ── Step 3: Build combined body for AI scoring ──
    // The AI gets the FULL conversation context + all burst messages so it can
    // draft a reply that addresses EVERYTHING, not just the last message.
    const toScore: Array<{
      id: string;
      from: string;
      fromEmail: string;
      subject: string;
      body: string;
      source: string;
      isUnread: boolean;
      hasReplied: boolean;
    }> = [];

    const groupList = Array.from(groups.values());

    for (const group of groupList) {
      let bodyParts: string[] = [];

      // Add conversation context (both sides) for AI to understand the full picture
      const ctx = body.context?.[group.chatId];
      if (ctx && ctx.length > 0) {
        bodyParts.push('--- Recent conversation ---');
        for (const c of ctx) {
          const label = c.isFromMe ? 'You' : (c.senderName || group.senderName);
          bodyParts.push(`${label}: ${c.text}`);
        }
        bodyParts.push('--- New messages (reply to ALL of these) ---');
      }

      // Add all burst messages — these are what the AI should reply to
      for (const m of group.messages) {
        const sender = m.isFromMe ? 'You' : (m.senderName || group.senderName);
        bodyParts.push(`${sender}: ${m.text}`);
      }

      const combinedBody = bodyParts.join('\n');

      toScore.push({
        id: group.combinedId,
        from: group.senderName,
        fromEmail: group.senderPhone,
        subject: group.isGroupChat ? (group.groupName || 'Group Chat') : '',
        body: combinedBody,
        source: 'imessage',
        isUnread: true,
        hasReplied: false,
      });
    }

    // ── Step 4: Score grouped messages ──
    const [sub] = await db
      .select()
      .from(schema.subscriptions)
      .where(eq(schema.subscriptions.userId, userId))
      .limit(1);
    const tier = sub?.tier || 'free';

    let scores;
    try {
      scores = await scoreEmails(toScore, userId, tier);
    } catch (err: any) {
      console.error(`❌ iMessage scoring failed: ${err.message}`);
      scores = toScore.map(e => ({
        id: e.id,
        replyability: 60,
        summary: null,
        draft: null,
        tone: 'casual',
        category: 'personal',
        suggestReplyAll: false,
      }));
    }

    // ── Step 4: Save or merge grouped items into ledger ──
    // Key insight: if there's already an active card for this chatId, we should
    // MERGE new messages into it (e.g. Mom sends 3 msgs, then 2 more a minute later).
    const [settings] = await db
      .select()
      .from(schema.userSettings)
      .where(eq(schema.userSettings.userId, userId))
      .limit(1);
    const scoreThreshold = settings?.scoreThreshold || 40;

    let savedCount = 0;
    for (let i = 0; i < groupList.length; i++) {
      const group = groupList[i];
      const score = scores.find(s => s.id === group.combinedId);
      if (!score || score.replyability < scoreThreshold) continue;

      // Plain text body for display (newline-separated messages)
      const displayBody = group.isGroupChat
        ? group.messages.map(m => `${m.senderName || 'Unknown'}: ${m.text}`).join('\n')
        : group.messages.map(m => m.text).join('\n');

      // Structured messages with timestamps for iOS card rendering
      const structuredMessages = JSON.stringify(
        group.messages.map(m => ({
          text: m.text,
          date: m.date,
          senderName: group.isGroupChat ? (m.senderName || undefined) : undefined,
        }))
      );

      const ctx = body.context?.[group.chatId];
      const conversationContext = ctx ? JSON.stringify(ctx) : null;

      try {
        // Check for existing ACTIVE card from the same chat (threadId = chatId)
        const [existing] = await db
          .select()
          .from(schema.ledgerItems)
          .where(and(
            eq(schema.ledgerItems.userId, userId),
            eq(schema.ledgerItems.threadId, group.chatId),
            eq(schema.ledgerItems.source, 'imessage'),
            eq(schema.ledgerItems.status, 'active'),
          ))
          .orderBy(sql`${schema.ledgerItems.date} DESC`)
          .limit(1);

        if (existing) {
          // Replace: the new burst is the LATEST unreplied messages.
          // Since the backend now only surfaces the latest burst,
          // replace the entire card content rather than appending.
          await db.update(schema.ledgerItems)
            .set({
              body: displayBody,
              snippet: structuredMessages,
              date: new Date(group.latestDate),
              messageId: group.messages[group.messages.length - 1].id,
              replyability: score.replyability,
              aiSummary: score.summary,
              suggestedDraft: score.draft,
              detectedTone: score.tone,
              toRecipients: conversationContext || existing.toRecipients,
              updatedAt: new Date(),
            })
            .where(eq(schema.ledgerItems.id, existing.id));

          console.log(`🔄 Updated card for ${group.senderName}: ${group.messages.length} messages in latest burst`);
          savedCount++;
        } else {
          // No existing card — create new one
          await db.insert(schema.ledgerItems).values({
            id: group.combinedId,
            userId,
            source: 'imessage',
            threadId: group.chatId,
            messageId: group.messages[group.messages.length - 1].id,
            senderName: group.isGroupChat ? (group.groupName || 'Group Chat') : group.senderName,
            senderEmail: group.isGroupChat
              ? (body.groupMembers?.[group.chatId]?.join(',') || group.chatId)
              : group.senderPhone,
            subject: group.isGroupChat ? (group.groupName || 'Group Chat') : '',
            snippet: structuredMessages,
            body: displayBody,
            date: new Date(group.latestDate),
            isUnread: true,
            replyability: score.replyability,
            aiSummary: score.summary,
            suggestedDraft: score.draft,
            detectedTone: score.tone,
            category: score.category || 'personal',
            suggestReplyAll: false,
            status: 'active',
            toRecipients: conversationContext,
          });
          savedCount++;
        }
      } catch (err: any) {
        if (err.code !== '23505') {
          console.error(`⚠️ Failed to save/merge iMessage group ${group.combinedId}: ${err.message}`);
        }
      }
    }

    const totalIncoming = allSorted.filter(m => !m.isFromMe).length;
    console.log(`📱 iMessage: ${totalIncoming} incoming → ${groups.size} groups → ${savedCount} saved for user ${userId.slice(0, 8)}`);
    return { ok: true, scored: savedCount };
  });

  // ── Get iMessage Items (called from iOS app to fetch relay-pushed messages) ──
  app.get('/imessage/messages', { preHandler: authMiddleware }, async (request) => {
    const userId = request.userId;

    const items = await db
      .select()
      .from(schema.ledgerItems)
      .where(and(
        eq(schema.ledgerItems.userId, userId),
        eq(schema.ledgerItems.source, 'imessage'),
        eq(schema.ledgerItems.status, 'active'),
      ))
      .orderBy(sql`${schema.ledgerItems.date} DESC`)
      .limit(50);

    const messages = items.map(item => {
      // Parse structured messages from snippet field
      let structuredMessages: Array<{ text: string; date: string; senderName?: string }> = [];
      try {
        if (item.snippet) structuredMessages = JSON.parse(item.snippet);
      } catch { /* snippet might be plain text */ }

      // Parse conversation context from toRecipients field
      let conversationContext: Array<{ text: string; isFromMe: boolean; date: string; senderName?: string }> | null = null;
      try {
        if (item.toRecipients) conversationContext = JSON.parse(item.toRecipients);
      } catch { /* ignore */ }

      return {
        id: item.id,
        senderName: item.senderName,
        senderPhone: item.senderEmail,
        text: item.body || '',
        date: item.date?.toISOString() || new Date().toISOString(),
        chatId: item.threadId || '',
        isGroupChat: (item.subject && item.subject !== '') ? true : false,
        groupName: item.subject || null,
        isFromMe: false,
        aiSummary: item.aiSummary,
        suggestedDraft: item.suggestedDraft,
        replyability: item.replyability,
        detectedTone: item.detectedTone,
        category: item.category,
        conversationContext,
        structuredMessages,
      };
    });

    console.log(`📱 GET /imessage/messages: returning ${messages.length} items for user ${userId.slice(0, 8)}`);
    return { messages };
  });

  // ── Get Pending Replies (polled by Mac app) ──
  app.get('/imessage/replies', { preHandler: authMiddleware }, async (request) => {
    const userId = request.userId;
    const key = `imsg_replies:${userId}`;

    const raw = await redis.lrange(key, 0, -1);
    const replies = raw.map(r => {
      try { return JSON.parse(r); } catch { return null; }
    }).filter(Boolean);

    return { replies };
  });

  // ── Queue a Reply (called from iOS app when user sends a reply to an iMessage) ──
  app.post('/imessage/reply', { preHandler: authMiddleware }, async (request) => {
    const body = z.object({
      recipient: z.string(),   // Phone number or email
      text: z.string(),
      itemId: z.string().optional(),  // ledger_items id
    }).parse(request.body);

    const userId = request.userId;
    const replyId = `reply_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

    // Push to Redis list (Mac app polls this)
    await redis.rpush(`imsg_replies:${userId}`, JSON.stringify({
      id: replyId,
      recipient: body.recipient,
      text: body.text,
    }));

    // Set a 24h TTL on the list (auto-cleanup if Mac is off)
    await redis.expire(`imsg_replies:${userId}`, 86400);

    // Mark the ledger item as sent
    if (body.itemId) {
      await db.update(schema.ledgerItems)
        .set({ status: 'sent', updatedAt: new Date() })
        .where(and(
          eq(schema.ledgerItems.userId, userId),
          eq(schema.ledgerItems.id, body.itemId),
        ));
    }

    return { ok: true, replyId };
  });

  // ── Acknowledge Reply Sent (called from Mac app after sending via AppleScript) ──
  app.post('/imessage/reply/ack', { preHandler: authMiddleware }, async (request) => {
    const body = z.object({
      id: z.string(),
    }).parse(request.body);

    const userId = request.userId;
    const key = `imsg_replies:${userId}`;

    // Remove the acknowledged reply from the list
    const all = await redis.lrange(key, 0, -1);
    for (const raw of all) {
      try {
        const reply = JSON.parse(raw);
        if (reply.id === body.id) {
          await redis.lrem(key, 1, raw);
          break;
        }
      } catch { /* skip */ }
    }

    return { ok: true };
  });

  // ── Mac Relay Re-Auth ──
  // When the Mac relay gets a 401, it sends its expired JWT as a Bearer token.
  // We verify the signature (ignoring expiry) to prove the Mac once held a valid token,
  // then issue a fresh JWT. This prevents anyone from minting JWTs with just a userId.
  app.post('/imessage/reauth', async (request, reply) => {
    // Require the expired JWT as proof of prior authentication
    const authHeader = request.headers.authorization;
    if (!authHeader?.startsWith('Bearer ')) {
      return reply.code(401).send({ error: 'Authentication failed' });
    }

    const oldToken = authHeader.slice(7);
    if (oldToken.split('.').length !== 3 || oldToken.length > 2048) {
      return reply.code(401).send({ error: 'Authentication failed' });
    }

    let oldUserId: string;
    try {
      // Verify signature but allow expired tokens — proves this Mac once had a valid JWT
      const payload = await verifyJWTSignatureOnly(oldToken);
      if (!payload.sub) {
        return reply.code(401).send({ error: 'Authentication failed' });
      }
      oldUserId = payload.sub;
    } catch {
      return reply.code(401).send({ error: 'Authentication failed' });
    }

    // Rate limit: 5 reauth attempts per user per hour
    const rl = await rateLimit(`reauth:${oldUserId}`, 5, 3600);
    if (!rl.allowed) return reply.code(429).send({ error: 'Too many requests' });

    // Check if there's a fresh JWT waiting (set by register-device migration)
    const stored = await redis.get(`imsg_mac_jwt:${oldUserId}`);
    if (!stored) {
      // Also check if old relay info was moved — find which user has it now
      const devices = await db.select()
        .from(schema.devices)
        .where(eq(schema.devices.deviceId, `mac_relay_${oldUserId}`))
        .limit(1);

      if (devices.length > 0) {
        const { token, expiresAt } = await signJWT(devices[0].userId, devices[0].deviceId);
        return { jwt: token, userId: devices[0].userId, expiresAt: expiresAt.toISOString() };
      }

      return reply.code(404).send({ error: 'No migration found. Please re-pair.' });
    }

    try {
      const parsed = JSON.parse(stored);
      await redis.del(`imsg_mac_jwt:${oldUserId}`);
      return { jwt: parsed.jwt, userId: oldUserId, expiresAt: parsed.expiresAt };
    } catch {
      return reply.code(500).send({ error: 'Migration data corrupted' });
    }
  });

  // ── Disconnect Relay ──
  app.post('/imessage/disconnect', { preHandler: authMiddleware }, async (request) => {
    const userId = request.userId;
    await redis.del(`imsg_relay:${userId}`);
    await redis.del(`imsg_replies:${userId}`);
    // Set a flag so the Mac relay knows it's been disconnected
    await redis.set(`imsg_relay_disconnected:${userId}`, '1', 'EX', 86400 * 7);

    // Remove the Mac relay device
    await db.delete(schema.devices)
      .where(and(
        eq(schema.devices.userId, userId),
        eq(schema.devices.deviceId, `mac_relay_${userId}`),
      ));

    return { ok: true };
  });

  // ── Relay Status (called by Mac to check if still paired) ──
  app.get('/imessage/relay-status', { preHandler: authMiddleware }, async (request) => {
    const userId = request.userId;

    // Check if iOS explicitly disconnected this relay
    const disconnected = await redis.get(`imsg_relay_disconnected:${userId}`);
    if (disconnected) {
      return { paired: false, reason: 'disconnected_by_phone' };
    }

    // Check if relay device still exists
    const devices = await db.select()
      .from(schema.devices)
      .where(and(
        eq(schema.devices.userId, userId),
        eq(schema.devices.deviceId, `mac_relay_${userId}`),
      ))
      .limit(1);

    return { paired: devices.length > 0 };
  });

  // ── Verify Active Items ──
  // Called by Mac relay on reconnect with lastReplyDates for all active chats.
  // Dismisses any items where the user has replied since the item was created.
  app.post('/imessage/verify-active', { preHandler: authMiddleware }, async (request) => {
    const userId = request.userId;
    const body = request.body as { lastReplyDates: Record<string, string> };
    const replyDates = body.lastReplyDates || {};

    if (Object.keys(replyDates).length === 0) {
      return { ok: true, dismissed: 0 };
    }

    // Get all active iMessage items for this user
    const activeItems = await db
      .select()
      .from(schema.ledgerItems)
      .where(and(
        eq(schema.ledgerItems.userId, userId),
        eq(schema.ledgerItems.source, 'imessage'),
        eq(schema.ledgerItems.status, 'active'),
      ));

    let dismissedCount = 0;
    for (const item of activeItems) {
      const chatId = item.threadId;
      if (!chatId) continue;
      const lastReply = replyDates[chatId];
      if (!lastReply) continue;

      const replyTime = new Date(lastReply).getTime();
      const itemTime = new Date(item.date).getTime();

      // If user replied AFTER this item was created, dismiss it
      if (replyTime > itemTime) {
        await db.update(schema.ledgerItems)
          .set({ status: 'dismissed', updatedAt: new Date() })
          .where(eq(schema.ledgerItems.id, item.id));
        dismissedCount++;
        console.log(`🧹 Auto-dismissed stale card for ${item.senderName} — user replied at ${lastReply}`);
      }
    }

    return { ok: true, dismissed: dismissedCount };
  });
}
