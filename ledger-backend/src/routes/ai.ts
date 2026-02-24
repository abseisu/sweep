// src/routes/ai.ts
// AI proxy routes — scoring and redraft.
// UNLIMITED usage for all tiers. Cost controlled by provider routing in services/ai.ts.
// Rate limits here exist only to prevent abuse (bots, scrapers), not to limit normal usage.

import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { authMiddleware } from '../middleware/auth.js';
import { rateLimit, redis } from '../lib/redis.js';
import { scoreEmails, redraft } from '../services/ai.js';
import { db, schema } from '../db/index.js';
import { eq } from 'drizzle-orm';

const emailSchema = z.object({
  id: z.string(),
  from: z.string(),
  fromEmail: z.string(),
  subject: z.string(),
  body: z.string().transform(s => s.slice(0, 10000)),
  source: z.string(),
  isUnread: z.boolean(),
  hasReplied: z.boolean().optional().default(false),
  attachmentSummary: z.string().optional(),
  linkSummary: z.string().optional(),
  recipients: z.string().optional(),
  date: z.string().optional(),
});

const scoreRequestSchema = z.object({
  emails: z.array(emailSchema).min(1).max(20),
  styleContext: z.string().max(4000).optional(),
});

const redraftRequestSchema = z.object({
  email: emailSchema,
  currentDraft: z.string().max(5000),
  instruction: z.string().max(500),
  redraftCount: z.number().int().min(0).max(20),
  styleContext: z.string().max(4000).optional(),
});

export default async function aiRoutes(app: FastifyInstance) {

  // ── Score Emails ──
  app.post('/score', { preHandler: authMiddleware }, async (request, reply) => {
    // Rate limits: generous for scoring since first run can send 100+ items in batches of 5.
    // 500/hour per user, 1000/hour per IP.
    const userRL = await rateLimit(`score:user:${request.userId}`, 500, 3600);
    const ipRL = await rateLimit(`score:ip:${request.ip}`, 1000, 3600);
    if (!userRL.allowed || !ipRL.allowed) {
      return reply.code(429).send({ error: 'Too many requests. Please wait a moment.' });
    }

    const body = scoreRequestSchema.parse(request.body);

    const [sub] = await db
      .select()
      .from(schema.subscriptions)
      .where(eq(schema.subscriptions.userId, request.userId))
      .limit(1);

    const tier = getEffectiveTier(sub);

    // No limits on number of emails or daily calls.
    // The AI service routes to Gemini (free) when the premium quota is exhausted.
    const scores = await scoreEmails(body.emails, request.userId, tier, body.styleContext);
    return { scores };
  });

  // ── Redraft ──
  app.post('/redraft', { preHandler: authMiddleware }, async (request, reply) => {
    // Anti-abuse: 120/hour = 2 per minute. Normal usage is ~5-15/hour.
    const userRL = await rateLimit(`redraft:user:${request.userId}`, 120, 3600);
    const ipRL = await rateLimit(`redraft:ip:${request.ip}`, 240, 3600);
    if (!userRL.allowed || !ipRL.allowed) {
      return reply.code(429).send({ error: 'Too many requests. Please wait a moment.' });
    }

    const body = redraftRequestSchema.parse(request.body);

    const [sub] = await db
      .select()
      .from(schema.subscriptions)
      .where(eq(schema.subscriptions.userId, request.userId))
      .limit(1);

    const tier = getEffectiveTier(sub);

    const draft = await redraft({
      email: body.email,
      currentDraft: body.currentDraft,
      instruction: body.instruction,
      redraftCount: body.redraftCount,
      styleContext: body.styleContext,
    }, request.userId, tier);

    return { draft };
  });
}

// ── Tier Resolution ──

function getEffectiveTier(sub: any): string {
  if (!sub) return 'free';

  if (sub.trialStartedAt) {
    const trialEnd = new Date(sub.trialStartedAt);
    trialEnd.setDate(trialEnd.getDate() + 7);
    if (new Date() < trialEnd && sub.tier === 'free') return 'pro';
  }

  if (sub.tier !== 'free' && sub.expiresAt) {
    if (new Date() > new Date(sub.expiresAt)) return 'free';
  }

  return sub.tier || 'free';
}
