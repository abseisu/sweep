// src/lib/redis.ts
// Redis connection (Upstash) and sliding-window rate limiter.

import IORedis from 'ioredis';

export const redis = new IORedis.default(process.env.REDIS_URL!, {
  maxRetriesPerRequest: 3,
  enableReadyCheck: false,
  lazyConnect: true,
  connectTimeout: 5000,          // 5s connection timeout
  commandTimeout: 3000,          // 3s per command timeout
  retryStrategy(times: number) {
    if (times > 5) return null;  // stop retrying after 5 attempts
    return Math.min(times * 500, 3000);
  },
  tls: process.env.REDIS_URL?.startsWith('rediss://') ? { rejectUnauthorized: false } : undefined,
});

// Connect eagerly but don't crash on failure
redis.connect().catch((err: Error) => {
  console.error('Redis initial connection failed:', err.message);
});

redis.on('error', (err: Error) => {
  console.error('Redis error:', err.message);
});

// ── Sliding Window Rate Limiter ──

interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  resetAt: Date;
}

export async function rateLimit(
  key: string,
  maxRequests: number,
  windowSeconds: number
): Promise<RateLimitResult> {
  try {
    const now = Date.now();
    const windowStart = now - windowSeconds * 1000;
    const redisKey = `rl:${key}`;

    // Wrap in a timeout — if Redis is down, fail open (allow the request)
    const result = await Promise.race([
      (async () => {
        const pipeline = redis.pipeline();
        pipeline.zremrangebyscore(redisKey, 0, windowStart);
        pipeline.zcard(redisKey);
        pipeline.expire(redisKey, windowSeconds);

        const results = await pipeline.exec();
        const currentCount = (results?.[1]?.[1] as number) ?? 0;

        if (currentCount < maxRequests) {
          // Only count the request if it's allowed
          await redis.zadd(redisKey, now, `${now}-${Math.random()}`);
        }

        return {
          allowed: currentCount < maxRequests,
          remaining: Math.max(0, maxRequests - currentCount - 1),
          resetAt: new Date(now + windowSeconds * 1000),
        };
      })(),
      new Promise<RateLimitResult>((resolve) =>
        setTimeout(() => resolve({ allowed: true, remaining: maxRequests, resetAt: new Date(Date.now() + windowSeconds * 1000) }), 3000)
      ),
    ]);

    return result;
  } catch (err) {
    // Redis is down — fail open, allow the request
    console.warn('Rate limit check failed, allowing request:', (err as Error).message);
    return {
      allowed: true,
      remaining: maxRequests,
      resetAt: new Date(Date.now() + windowSeconds * 1000),
    };
  }
}

// ── JWT Blocklist ──

export async function blockJWT(jti: string, expiresInSeconds: number): Promise<void> {
  await redis.set(`jwt:blocked:${jti}`, '1', 'EX', expiresInSeconds);
}

export async function isJWTBlocked(jti: string): Promise<boolean> {
  const result = await redis.get(`jwt:blocked:${jti}`);
  return result !== null;
}

// ── Score Cache ──

export async function getCachedScore(emailHash: string): Promise<string | null> {
  return redis.get(`score:${emailHash}`);
}

export async function setCachedScore(emailHash: string, score: string, ttlSeconds = 86400): Promise<void> {
  await redis.set(`score:${emailHash}`, score, 'EX', ttlSeconds);
}
