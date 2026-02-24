// src/routes/ledger.ts
// Ledger routes — fetch pre-scored items, dismiss, snooze, update drafts.
// This is the core endpoint for smart stack mode: the app opens → calls GET /ledger → instant card stack.

import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { authMiddleware } from '../middleware/auth.js';
import { db, schema } from '../db/index.js';
import { eq, and, sql } from 'drizzle-orm';

export default async function ledgerRoutes(app: FastifyInstance) {

  // ── GET /ledger — Fetch pre-scored items ready for the card stack ──
  app.get('/ledger', { preHandler: authMiddleware }, async (request) => {
    const userId = request.userId;

    // First, restore any snoozed items whose snooze has expired
    await db.update(schema.ledgerItems)
      .set({ status: 'active', snoozedUntil: null, updatedAt: new Date() })
      .where(and(
        eq(schema.ledgerItems.userId, userId),
        eq(schema.ledgerItems.status, 'snoozed'),
        sql`${schema.ledgerItems.snoozedUntil} IS NOT NULL AND ${schema.ledgerItems.snoozedUntil} <= NOW()`,
      ));

    // Fetch all active items, ordered by replyability desc then date desc
    const items = await db
      .select()
      .from(schema.ledgerItems)
      .where(and(
        eq(schema.ledgerItems.userId, userId),
        eq(schema.ledgerItems.status, 'active'),
      ))
      .orderBy(sql`${schema.ledgerItems.replyability} DESC, ${schema.ledgerItems.date} DESC`)
      .limit(50);

    // Get last scan time for the user (most recent account scan)
    const accounts = await db
      .select({ lastScanAt: schema.accounts.lastScanAt })
      .from(schema.accounts)
      .where(eq(schema.accounts.userId, userId))
      .orderBy(sql`${schema.accounts.lastScanAt} DESC NULLS LAST`)
      .limit(1);

    const lastScanAt = accounts[0]?.lastScanAt?.toISOString() || null;

    return {
      items: items.map(item => ({
        id: item.id,
        source: item.source,
        threadId: item.threadId,
        messageId: item.messageId,
        senderName: item.senderName,
        senderEmail: item.senderEmail,
        subject: item.subject,
        snippet: item.snippet,
        body: item.body,
        date: item.date.toISOString(),
        isUnread: item.isUnread,
        accountId: item.accountId || '',
        toRecipients: item.source === 'imessage' ? [] : safeParseJSON(item.toRecipients, []),
        ccRecipients: safeParseJSON(item.ccRecipients, []),
        // For iMessage items, toRecipients stores conversation context JSON
        conversationContext: item.source === 'imessage' ? item.toRecipients : null,
        replyability: item.replyability,
        aiSummary: item.aiSummary,
        suggestedDraft: item.suggestedDraft,
        detectedTone: item.detectedTone,
        category: item.category,
        suggestReplyAll: item.suggestReplyAll || false,
      })),
      count: items.length,
      lastScanAt,
    };
  });

  // ── POST /ledger/dismiss — Mark item(s) as dismissed ──
  app.post('/ledger/dismiss', { preHandler: authMiddleware }, async (request) => {
    const body = z.object({
      ids: z.array(z.string()).min(1).max(50),
    }).parse(request.body);

    for (const id of body.ids) {
      await db.update(schema.ledgerItems)
        .set({ status: 'dismissed', updatedAt: new Date() })
        .where(and(
          eq(schema.ledgerItems.userId, request.userId),
          eq(schema.ledgerItems.id, id),
        ));
    }

    return { ok: true, dismissed: body.ids.length };
  });

  // ── POST /ledger/snooze — Snooze item(s) until a given time ──
  app.post('/ledger/snooze', { preHandler: authMiddleware }, async (request) => {
    const body = z.object({
      ids: z.array(z.string()).min(1).max(50),
      until: z.string().datetime(),  // ISO datetime
    }).parse(request.body);

    const snoozedUntil = new Date(body.until);

    for (const id of body.ids) {
      await db.update(schema.ledgerItems)
        .set({ status: 'snoozed', snoozedUntil, updatedAt: new Date() })
        .where(and(
          eq(schema.ledgerItems.userId, request.userId),
          eq(schema.ledgerItems.id, id),
        ));
    }

    return { ok: true, snoozed: body.ids.length };
  });

  // ── POST /ledger/sent — Mark item as sent (reply was sent) ──
  app.post('/ledger/sent', { preHandler: authMiddleware }, async (request) => {
    const body = z.object({
      id: z.string(),
    }).parse(request.body);

    await db.update(schema.ledgerItems)
      .set({ status: 'sent', updatedAt: new Date() })
      .where(and(
        eq(schema.ledgerItems.userId, request.userId),
        eq(schema.ledgerItems.id, body.id),
      ));

    return { ok: true };
  });

  // ── PUT /ledger/draft — Update the draft text for an item ──
  app.put('/ledger/draft', { preHandler: authMiddleware }, async (request) => {
    const body = z.object({
      id: z.string(),
      draft: z.string(),
    }).parse(request.body);

    await db.update(schema.ledgerItems)
      .set({ suggestedDraft: body.draft, updatedAt: new Date() })
      .where(and(
        eq(schema.ledgerItems.userId, request.userId),
        eq(schema.ledgerItems.id, body.id),
      ));

    return { ok: true };
  });

  // ── POST /ledger/reset — Reactivate all dismissed items (fresh install) ──
  // Called when the user reinstalls the app and wants a clean slate.
  app.post('/ledger/reset', { preHandler: authMiddleware }, async (request) => {
    const userId = request.userId;

    const result = await db.update(schema.ledgerItems)
      .set({ status: 'active', updatedAt: new Date() })
      .where(and(
        eq(schema.ledgerItems.userId, userId),
        eq(schema.ledgerItems.status, 'dismissed'),
      ));

    console.log(`🔄 Ledger reset for user ${userId.slice(0, 8)} — all dismissed items reactivated`);
    return { ok: true };
  });
}

function safeParseJSON(str: string | null, fallback: any): any {
  if (!str) return fallback;
  try { return JSON.parse(str); } catch { return fallback; }
}
