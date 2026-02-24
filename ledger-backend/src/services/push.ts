// src/services/push.ts
// APNs push notification service using HTTP/2.
// Sends silent and visible notifications to iOS devices.

import { SignJWT, importPKCS8 } from 'jose';
import { db, schema } from '../db/index.js';
import { eq } from 'drizzle-orm';

const APNS_PRODUCTION = 'https://api.push.apple.com';
const APNS_SANDBOX = 'https://api.sandbox.push.apple.com';

let apnsToken: string | null = null;
let apnsTokenExpiry = 0;

// ── Get APNs JWT (cached, refreshed every 50 min) ──

async function getAPNsToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (apnsToken && apnsTokenExpiry > now) return apnsToken;

  const keyBase64 = process.env.APNS_KEY_BASE64!;
  const keyPem = Buffer.from(keyBase64, 'base64').toString('utf-8');
  const privateKey = await importPKCS8(keyPem, 'ES256');

  apnsToken = await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: process.env.APNS_KEY_ID! })
    .setIssuer(process.env.APNS_TEAM_ID!)
    .setIssuedAt()
    .sign(privateKey);

  apnsTokenExpiry = now + 50 * 60; // 50 minutes
  return apnsToken;
}

// ── Send Push Notification ──

interface PushPayload {
  title: string;
  body: string;
  badge?: number;
  sound?: string;
  data?: Record<string, any>;
  silent?: boolean;
}

export async function sendPush(deviceToken: string, payload: PushPayload): Promise<boolean> {
  const token = await getAPNsToken();
  const bundleId = process.env.APNS_BUNDLE_ID!;
  const apnsHost = process.env.NODE_ENV === 'production' ? APNS_PRODUCTION : APNS_SANDBOX;

  const apnsPayload: any = {
    aps: {
      ...(payload.silent
        ? { 'content-available': 1 }
        : {
            alert: { title: payload.title, body: payload.body },
            sound: payload.sound || 'ledger_chime.caf',
            badge: payload.badge,
          }
      ),
    },
    ...payload.data,
  };

  try {
    const res = await fetch(`${apnsHost}/3/device/${deviceToken}`, {
      method: 'POST',
      headers: {
        'authorization': `bearer ${token}`,
        'apns-topic': bundleId,
        'apns-push-type': payload.silent ? 'background' : 'alert',
        'apns-priority': payload.silent ? '5' : '10',
        'apns-expiration': '0',
        'content-type': 'application/json',
      },
      body: JSON.stringify(apnsPayload),
    });

    if (res.ok) return true;

    const err = await res.json() as any;

    // Handle invalid device tokens (unregistered/expired)
    if (res.status === 410 || err.reason === 'Unregistered' || err.reason === 'BadDeviceToken') {
      console.log(`🗑️ Removing invalid device token: ${deviceToken.slice(0, 8)}...`);
      await db.delete(schema.devices).where(eq(schema.devices.deviceToken, deviceToken));
      return false;
    }

    console.error(`APNs error (${res.status}):`, err);
    return false;
  } catch (err) {
    console.error('APNs request failed:', err);
    return false;
  }
}

// ── Send to All User Devices ──

export async function sendPushToUser(userId: string, payload: PushPayload): Promise<number> {
  const userDevices = await db
    .select()
    .from(schema.devices)
    .where(eq(schema.devices.userId, userId));

  let sent = 0;
  for (const device of userDevices) {
    if (device.deviceToken) {
      const ok = await sendPush(device.deviceToken, payload);
      if (ok) sent++;
    }
  }
  return sent;
}

// ── Notification Templates ──

export function batchNotification(emailCount: number, topSender: string): PushPayload {
  const body = emailCount === 1
    ? `New email from ${topSender} needs your reply`
    : `${emailCount} emails need your reply — including ${topSender}`;

  return {
    title: 'Ledger',
    body,
    badge: emailCount,
    sound: 'ledger_chime.caf',
    data: { type: 'batch', count: emailCount },
  };
}

export function windowNotification(emailCount: number): PushPayload {
  return {
    title: 'Your evening ledger is ready',
    body: `${emailCount} email${emailCount === 1 ? '' : 's'} to review tonight`,
    badge: emailCount,
    sound: 'ledger_chime.caf',
    data: { type: 'window' },
  };
}

export function urgentNotification(senderName: string, subject: string): PushPayload {
  return {
    title: `Urgent: ${senderName}`,
    body: subject,
    badge: 1,
    sound: 'ledger_chime.caf',
    data: { type: 'urgent' },
  };
}
