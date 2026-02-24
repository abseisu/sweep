// src/services/ai.ts
// AI routing — unlimited scoring and redrafts for all users.
//
// COST MODEL:
//   Every user gets unlimited AI. We control cost by routing, not limiting.
//
//   Scoring pipeline (per user per day):
//     1. First N calls → GPT-4o Mini (fast, great quality)
//     2. Overflow      → Gemini 2.0 Flash (free tier / near-free)
//     3. Pro gray-zone → Claude Haiku (re-scores items scored 25-55)
//
//   Redraft pipeline:
//     1. First N calls → GPT-4o Mini
//     2. Overflow      → Gemini 2.0 Flash
//     3. Pro escalated → Claude Haiku (after 2+ redrafts on same email)
//
//   N varies by tier:
//     Free:     30 premium calls/day then Gemini
//     Standard: 150 premium calls/day then Gemini
//     Pro:      500 premium calls/day then Gemini
//
//   The user NEVER hits a wall. They never see "limit reached."
//   Quality degrades very slightly on overflow — Gemini is still excellent.

import { db, schema } from '../db/index.js';
import { redis } from '../lib/redis.js';

const OPENAI_URL = 'https://api.openai.com/v1/chat/completions';
const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';
const GEMINI_URL = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent';

// Premium call thresholds per tier (per user per day, combined score + redraft)
const PREMIUM_DAILY_QUOTA: Record<string, number> = {
  free: 30,
  standard: 150,
  pro: 500,
};

interface ScoreRequest {
  id: string;
  from: string;
  fromEmail: string;
  subject: string;
  body: string;
  source: string;
  isUnread: boolean;
  hasReplied: boolean;
  attachmentSummary?: string;
  linkSummary?: string;
  recipients?: string;
}

interface ScoreResult {
  id: string;
  replyability: number;
  summary: string | null;
  draft: string | null;
  tone: string | null;
  category: string | null;
  suggestReplyAll: boolean;
}

interface RedraftRequest {
  email: ScoreRequest;
  currentDraft: string;
  instruction: string;
  redraftCount: number;
  styleContext?: string;
}

// ── Provider Selection ──

async function pickProvider(userId: string, tier: string, callCount: number = 1): Promise<'openai' | 'gemini'> {
  const quota = PREMIUM_DAILY_QUOTA[tier] || 30;
  const todayKey = `premium:${userId}:${new Date().toISOString().slice(0, 10)}`;
  const used = parseInt(await redis.get(todayKey) || '0');

  if (used + callCount <= quota) {
    // Increment premium counter
    await redis.incrby(todayKey, callCount);
    await redis.expire(todayKey, 90000); // 25 hours
    return 'openai';
  }

  // Over quota — use Gemini (free/near-free)
  return 'gemini';
}

// ── Score Emails (batch) ──

export async function scoreEmails(
  emails: ScoreRequest[],
  userId: string,
  tier: string,
  styleContext?: string
): Promise<ScoreResult[]> {
  // Pick provider based on daily premium usage
  const provider = await pickProvider(userId, tier, emails.length);
  
  let results: ScoreResult[];
  if (provider === 'gemini') {
    results = await scoreWithGemini(emails, styleContext);
  } else {
    results = await scoreWithOpenAI(emails, styleContext);
  }

  // Pro tier: re-score gray zone (25-55) with Claude — always uses Claude regardless of quota
  if (tier === 'pro') {
    const grayZone = results.filter(r => r.replyability >= 25 && r.replyability <= 55);
    if (grayZone.length > 0) {
      const grayEmails = emails.filter(e => grayZone.some(g => g.id === e.id));
      const claudeResults = await scoreWithAnthropic(grayEmails, styleContext);
      for (const cr of claudeResults) {
        const idx = results.findIndex(r => r.id === cr.id);
        if (idx !== -1) results[idx] = cr;
      }
    }
  }

  await logUsage(userId, 'score', provider, emails.length);
  return results;
}

// ── Redraft ──

export async function redraft(
  req: RedraftRequest,
  userId: string,
  tier: string
): Promise<string> {
  // Pro: escalate to Claude after 2+ redrafts (always uses Claude, not quota-gated)
  if (tier === 'pro' && req.redraftCount >= 2) {
    const result = await callAnthropic(buildRedraftSystemPrompt(), buildRedraftUserPrompt(req));
    await logUsage(userId, 'redraft', 'anthropic', 1);
    return result;
  }

  // Everyone else: pick provider based on daily quota
  const provider = await pickProvider(userId, tier, 1);

  const systemPrompt = buildRedraftSystemPrompt();
  const userPrompt = buildRedraftUserPrompt(req);

  let result: string;
  if (provider === 'gemini') {
    result = await callGemini(systemPrompt, userPrompt);
  } else {
    result = await callOpenAI(systemPrompt, userPrompt);
  }

  await logUsage(userId, 'redraft', provider, 1);
  return result;
}

// ── OpenAI Scoring ──

async function scoreWithOpenAI(emails: ScoreRequest[], styleContext?: string): Promise<ScoreResult[]> {
  const systemPrompt = buildScoringSystemPrompt(styleContext);
  const results: ScoreResult[] = [];

  // Batch up to 3 emails per call (smaller batches = more reliable ID matching)
  for (let i = 0; i < emails.length; i += 3) {
    const batch = emails.slice(i, i + 3);
    try {
      const userPrompt = formatEmailBatch(batch);
      const response = await callOpenAI(systemPrompt, userPrompt, true);
      results.push(...parseScoreResponse(response, batch));
    } catch (err) {
      console.error(`⚠️ OpenAI batch failed:`, (err as Error).message);
      for (const email of batch) {
        results.push({
          id: email.id, replyability: 0, summary: null, draft: null,
          tone: null, category: null, suggestReplyAll: false,
        });
      }
    }
  }

  return results;
}

// ── Gemini Scoring ──

async function scoreWithGemini(emails: ScoreRequest[], styleContext?: string): Promise<ScoreResult[]> {
  const systemPrompt = buildScoringSystemPrompt(styleContext);
  const results: ScoreResult[] = [];

  for (let i = 0; i < emails.length; i += 3) {
    const batch = emails.slice(i, i + 3);
    try {
      const userPrompt = formatEmailBatch(batch);
      const response = await callGemini(systemPrompt, userPrompt, true);
      results.push(...parseScoreResponse(response, batch));
    } catch (err) {
      console.error(`⚠️ Gemini batch failed:`, (err as Error).message);
      for (const email of batch) {
        results.push({
          id: email.id, replyability: 0, summary: null, draft: null,
          tone: null, category: null, suggestReplyAll: false,
        });
      }
    }
  }

  return results;
}

// ── Anthropic Scoring (Pro gray-zone only) ──

async function scoreWithAnthropic(emails: ScoreRequest[], styleContext?: string): Promise<ScoreResult[]> {
  const systemPrompt = buildScoringSystemPrompt(styleContext);
  const results: ScoreResult[] = [];

  for (const email of emails) {
    const userPrompt = formatEmailBatch([email]);
    const response = await callAnthropic(systemPrompt, userPrompt, true);
    results.push(...parseScoreResponse(response, [email]));
  }

  return results;
}

// ── Raw API Calls ──

async function callOpenAI(system: string, user: string, json = false): Promise<string> {
  const res = await fetch(OPENAI_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`,
    },
    body: JSON.stringify({
      model: 'gpt-4o-mini',
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: user },
      ],
      temperature: 0.4,
      max_tokens: 2000,
      ...(json ? { response_format: { type: 'json_object' } } : {}),
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`OpenAI error ${res.status}: ${err}`);
  }

  const data = await res.json() as any;
  return data.choices?.[0]?.message?.content || '';
}

async function callGemini(system: string, user: string, json = false): Promise<string> {
  const apiKey = process.env.GEMINI_API_KEY;
  const url = `${GEMINI_URL}?key=${apiKey}`;

  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: system }] },
      contents: [{ parts: [{ text: user }] }],
      generationConfig: {
        temperature: 0.4,
        maxOutputTokens: 2000,
        ...(json ? { responseMimeType: 'application/json' } : {}),
      },
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    // If Gemini fails (rate limit, quota), fall back to OpenAI
    console.error(`Gemini error ${res.status}: ${err} — falling back to OpenAI`);
    return callOpenAI(system, user, json);
  }

  const data = await res.json() as any;
  return data.candidates?.[0]?.content?.parts?.[0]?.text || '';
}

async function callAnthropic(system: string, user: string, json = false): Promise<string> {
  const res = await fetch(ANTHROPIC_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': process.env.ANTHROPIC_API_KEY!,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5-20251001',
      system,
      messages: [{ role: 'user', content: user }],
      temperature: 0.3,
      max_tokens: 2000,
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Anthropic error ${res.status}: ${err}`);
  }

  const data = await res.json() as any;
  return data.content?.[0]?.text || '';
}

// ── Prompt Builders ──

function buildScoringSystemPrompt(styleContext?: string): string {
  let prompt = `You are an email triage assistant. Your job is to help the user see every message that ACTUALLY deserves a reply. ERR ON THE SIDE OF SURFACING for genuine human messages, but be RUTHLESS about filtering out mass communications.

CRITICAL RULE: If you cannot write a meaningful, specific reply to the email, give it replyability 0. The draft field is your litmus test — if you can't imagine the user actually sending a reply, the email doesn't belong in their stack.

For each email, determine:
1. replyability (0-100): How likely is it that this message deserves a human reply?
2. summary: One-sentence summary of the NEW messages needing a reply. Focus on what's being asked/said.
3. draft: A suggested reply (2-3 sentences). This MUST be a real, sendable reply — not a placeholder. If you can't write one, set replyability to 0.
4. tone: Emotional tone (e.g. "urgent", "friendly", "formal", "frustrated").
5. category: One of "work", "personal", "finance", "scheduling", "social", "transactional".
6. suggestReplyAll: true if reply should go to all recipients.

WHAT TO SURFACE (replyability 25+):
- Direct messages from a real human being expecting/hoping for a reply → 40-80
- Questions, requests, invitations, or asks from humans → 50-90
- Urgent, time-sensitive, or high-stakes → 70-100
- Community/org emails where the user's input or RSVP is specifically requested → 40-70
- Emails from colleagues, classmates, friends, family, professors, mentors → 50-90
- iMessage/text messages from a real person → 50+ (almost always surface)

WHAT TO NEVER SURFACE (replyability 0):
- Mass emails, newsletters, announcements, digests — even from orgs the user belongs to, if no reply is expected
- Marketing, promotional, commercial emails of any kind
- Automated transactional (receipts, shipping, password resets, confirmations)
- Social media notifications (likes, follows, views, connection requests)
- FYI broadcasts, event recaps, org-wide updates that don't ask for the user's input
- Emails where the only sensible response would be "thanks" or "noted" with no substance
- Any email you cannot write a real, specific reply to

THE TEST: Ask yourself "Would a real person actually sit down and type a reply to this?" If the answer is no or probably not, replyability = 0.

Respond in JSON format: { "id": "<the email ID>", "replyability": <number>, "summary": "<string>", "draft": "<string or null>", "tone": "<string>", "category": "<string>", "suggestReplyAll": <boolean> }
For multiple emails, return: { "emails": [...] } with the same fields. IMPORTANT: Always include the exact "id" from each email in your response.`;

  if (styleContext) {
    prompt += `\n\n--- USER CONTEXT ---\n${styleContext}`;
  }

  return prompt;
}

function buildRedraftSystemPrompt(): string {
  return `You are a professional email assistant. Rewrite the draft according to the user's instruction. Return ONLY the rewritten email body, no preamble.`;
}

function buildRedraftUserPrompt(req: RedraftRequest): string {
  return `Original email from ${req.email.from}:
Subject: ${req.email.subject}
Body: ${req.email.body.slice(0, 3000)}

Current draft reply:
${req.currentDraft}

${req.styleContext ? `Style context: ${req.styleContext}` : ''}

Instruction: ${req.instruction}

Rewrite the draft according to the instruction above. Return ONLY the new draft text.`;
}

function formatEmailBatch(emails: ScoreRequest[]): string {
  return emails.map((e, idx) => `
--- EMAIL ${idx + 1} ---
ID: ${e.id}
Source: ${e.source}
From: ${e.from} <${e.fromEmail}>
${e.recipients ? `To: ${e.recipients}` : ''}
Subject: ${e.subject}
Status: ${e.isUnread ? 'Unread' : 'Read'}${e.hasReplied ? ' (Already replied)' : ''}
${e.attachmentSummary ? `Attachments: ${e.attachmentSummary}` : ''}
${e.linkSummary ? `Links: ${e.linkSummary}` : ''}

Body:
${e.body.slice(0, 5000)}
`).join('\n');
}

function parseScoreResponse(response: string, batch: ScoreRequest[]): ScoreResult[] {
  try {
    let cleaned = response.trim();
    if (cleaned.startsWith('```json')) cleaned = cleaned.slice(7);
    if (cleaned.startsWith('```')) cleaned = cleaned.slice(3);
    if (cleaned.endsWith('```')) cleaned = cleaned.slice(0, -3);
    cleaned = cleaned.trim();

    const parsed = JSON.parse(cleaned);
    const items: any[] = Array.isArray(parsed) ? parsed : parsed.emails || [parsed];

    // Build lookup by ID — try exact match first, then partial match
    const resultById = new Map<string, any>();
    for (const item of items) {
      if (item.id) {
        resultById.set(item.id, item);
      }
    }

    return batch.map((batchEmail, idx) => {
      // 1. Exact ID match
      let item = resultById.get(batchEmail.id);

      // 2. If no exact match and batch size is 1, use the only result
      if (!item && batch.length === 1 && items.length === 1) {
        item = items[0];
      }

      // 3. If no match and batch size matches result size, use position
      //    but ONLY if the result at this position has no ID (AI omitted it)
      if (!item && items.length === batch.length) {
        const posItem = items[idx];
        if (posItem && (!posItem.id || posItem.id === batchEmail.id)) {
          item = posItem;
        }
      }

      if (!item) {
        console.warn(`⚠️ No AI result matched for email ${batchEmail.id} (${batchEmail.subject?.slice(0, 40)})`);
      }

      return {
        id: batchEmail.id,
        replyability: item ? Math.max(0, Math.min(100, item.replyability || 0)) : 0,
        summary: item?.summary || null,
        draft: item?.draft || null,
        tone: item?.tone || null,
        category: item?.category || null,
        suggestReplyAll: item?.suggestReplyAll || false,
      };
    });
  } catch (err) {
    console.error(`⚠️ AI response parse failed for ${batch.length} items:`, (err as Error).message);
    console.error(`⚠️ Raw response (first 500 chars): ${response.slice(0, 500)}`);
    return batch.map(e => ({
      id: e.id, replyability: 0, summary: null, draft: null,
      tone: null, category: null, suggestReplyAll: false,
    }));
  }
}

// ── Usage Logging ──

async function logUsage(userId: string, action: string, provider: string, emailCount: number) {
  try {
    await db.insert(schema.usageLog).values({
      userId,
      action,
      provider,
      emailCount,
    });
  } catch (err) {
    console.error('Failed to log usage:', err);
  }
}
