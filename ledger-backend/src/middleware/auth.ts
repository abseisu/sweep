// src/middleware/auth.ts
// JWT authentication middleware.
// Checks: valid signature, not expired, not revoked, user exists.

import { FastifyRequest, FastifyReply } from 'fastify';
import { verifyJWT, LedgerJWTPayload } from '../lib/jwt.js';
import { isJWTBlocked } from '../lib/redis.js';
import { db, schema } from '../db/index.js';
import { eq } from 'drizzle-orm';

declare module 'fastify' {
  interface FastifyRequest {
    userId: string;
    deviceId: string;
  }
}

export async function authMiddleware(request: FastifyRequest, reply: FastifyReply) {
  const authHeader = request.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    // Generic message — don't reveal what's missing
    return reply.code(401).send({ error: 'Authentication failed' });
  }

  const token = authHeader.slice(7);

  // Reject obviously malformed tokens (JWTs have 3 base64 segments)
  if (token.split('.').length !== 3 || token.length > 2048) {
    return reply.code(401).send({ error: 'Authentication failed' });
  }

  try {
    const payload: LedgerJWTPayload = await verifyJWT(token);

    if (!payload.sub || !payload.jti) {
      return reply.code(401).send({ error: 'Authentication failed' });
    }

    // Check JWT blocklist (for revoked tokens — e.g. after password change or logout)
    // Fail open if Redis is down — better to allow than to lock everyone out
    try {
      const blocked = await Promise.race([
        isJWTBlocked(payload.jti),
        new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 2000)),
      ]);
      if (blocked) {
        return reply.code(401).send({ error: 'Authentication failed' });
      }
    } catch {
      // Redis down — skip blocklist check
    }

    // Verify user still exists (catches deleted accounts)
    const [user] = await db
      .select({ id: schema.users.id })
      .from(schema.users)
      .where(eq(schema.users.id, payload.sub))
      .limit(1);

    if (!user) {
      return reply.code(401).send({ error: 'Authentication failed' });
    }

    request.userId = payload.sub;
    request.deviceId = payload.device_id || '';
  } catch {
    // All auth failures return the same generic message — prevents enumeration
    return reply.code(401).send({ error: 'Authentication failed' });
  }
}
