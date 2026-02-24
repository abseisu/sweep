// src/server.ts
// Fastify API server — entry point.

import 'dotenv/config';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import authRoutes from './routes/auth.js';
import aiRoutes from './routes/ai.js';
import userRoutes from './routes/user.js';
import ledgerRoutes from './routes/ledger.js';
import imessageRoutes from './routes/imessage.js';

const app = Fastify({
  logger: {
    level: process.env.LOG_LEVEL || 'info',
    ...(process.env.NODE_ENV !== 'production' ? { transport: { target: 'pino-pretty' } } : {}),
  },
  trustProxy: true,  // Fly.io uses a reverse proxy
});

// ── Plugins ──

await app.register(cors, {
  origin: true,  // Allow all origins (iOS app uses direct HTTP, not browser)
  methods: ['GET', 'POST', 'PUT', 'DELETE'],
});

await app.register(helmet, {
  contentSecurityPolicy: false,  // API only, no HTML
});

// ── Global Error Handler ──

// Allow empty JSON bodies (iOS sends Content-Type: application/json with no body on some requests)
app.addContentTypeParser('application/json', { parseAs: 'string' }, (req, body, done) => {
  try {
    const str = (body as string || '').trim();
    done(null, str ? JSON.parse(str) : {});
  } catch (err: any) {
    done(err, undefined);
  }
});

app.setErrorHandler((error, request, reply) => {
  // Zod validation errors
  if (error.name === 'ZodError') {
    let details;
    try { details = JSON.parse(error.message); } catch { details = error.message; }
    return reply.code(400).send({
      error: 'Validation error',
      details,
    });
  }

  // JWT errors
  if (error.message?.includes('token') || error.message?.includes('JWT')) {
    return reply.code(401).send({ error: error.message });
  }

  // Log unexpected errors
  app.log.error(error);
  return reply.code(500).send({ error: 'Internal server error' });
});

// ── Health Check ──

app.get('/health', async () => ({
  status: 'ok',
  timestamp: new Date().toISOString(),
  version: '1.0.0',
}));

// ── Routes ──

await app.register(authRoutes);
await app.register(aiRoutes);
await app.register(userRoutes);
await app.register(ledgerRoutes);
await app.register(imessageRoutes);

// ── Start ──

const port = parseInt(process.env.PORT || '3000');
const host = '0.0.0.0';  // Required for Docker/Fly.io

try {
  await app.listen({ port, host });
  app.log.info(`🚀 Ledger API running on ${host}:${port}`);
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
