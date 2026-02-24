// src/services/email.ts
// Server-side email provider interactions.
// Refreshes OAuth tokens, fetches emails, sends replies.
// Client secrets stay server-side.

const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const GMAIL_API = 'https://gmail.googleapis.com/gmail/v1/users/me';

const MICROSOFT_TOKEN_URL = 'https://login.microsoftonline.com/common/oauth2/v2.0/token';
const GRAPH_API = 'https://graph.microsoft.com/v1.0/me';

// ── Auth Code Exchange ──
// Google: iOS sends a serverAuthCode (one-time authorization code).
// The backend must exchange it for a long-lived refresh token.
// This only needs to happen once — the refresh token persists until revoked.

export async function exchangeGoogleAuthCode(authCode: string): Promise<{ accessToken: string; refreshToken: string; expiresIn: number }> {
  const res = await fetch(GOOGLE_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code: authCode,
      client_id: process.env.GOOGLE_CLIENT_ID!,
      client_secret: process.env.GOOGLE_CLIENT_SECRET!,
      redirect_uri: '',  // iOS uses empty redirect_uri for native apps
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Google auth code exchange failed (${res.status}): ${err}`);
  }

  const data = await res.json() as any;
  if (!data.refresh_token) {
    throw new Error('Google auth code exchange returned no refresh_token — code may already be used');
  }

  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    expiresIn: data.expires_in || 3600,
  };
}

// Microsoft: if the iOS app sends a refresh token directly (from MSAL), we can
// verify it works by doing a token refresh. If it fails, the token may be invalid.
export async function verifyMicrosoftRefreshToken(refreshToken: string): Promise<{ accessToken: string; newRefreshToken: string }> {
  const result = await refreshMicrosoftToken(refreshToken);
  return {
    accessToken: result.accessToken,
    newRefreshToken: result.newRefreshToken || refreshToken,
  };
}

// ── Token Refresh ──

export async function refreshGoogleToken(refreshToken: string): Promise<{ accessToken: string; expiresIn: number }> {
  const res = await fetch(GOOGLE_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: process.env.GOOGLE_CLIENT_ID!,
      client_secret: process.env.GOOGLE_CLIENT_SECRET!,
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Google token refresh failed (${res.status}): ${err}`);
  }

  const data = await res.json() as any;
  return {
    accessToken: data.access_token,
    expiresIn: data.expires_in || 3600,
  };
}

export async function refreshMicrosoftToken(refreshToken: string): Promise<{ accessToken: string; expiresIn: number; newRefreshToken?: string }> {
  const res = await fetch(MICROSOFT_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: process.env.MSAL_CLIENT_ID!,
      client_secret: process.env.MSAL_CLIENT_SECRET!,
      scope: 'https://graph.microsoft.com/.default offline_access',
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Microsoft token refresh failed (${res.status}): ${err}`);
  }

  const data = await res.json() as any;
  return {
    accessToken: data.access_token,
    expiresIn: data.expires_in || 3600,
    newRefreshToken: data.refresh_token,  // Microsoft may rotate refresh tokens
  };
}

// ── Fetch Emails ──

export async function fetchGmailUnread(accessToken: string, since: Date, maxResults = 40): Promise<any[]> {
  const afterEpoch = Math.floor(since.getTime() / 1000);
  const query = `in:inbox after:${afterEpoch}`;

  // List messages
  const listRes = await fetch(
    `${GMAIL_API}/messages?q=${encodeURIComponent(query)}&maxResults=${maxResults}`,
    { headers: { Authorization: `Bearer ${accessToken}` } }
  );

  if (!listRes.ok) throw new Error(`Gmail list failed: ${listRes.status}`);
  const listData = await listRes.json() as any;
  const messageIds: string[] = (listData.messages || []).map((m: any) => m.id);

  if (messageIds.length === 0) return [];

  // Fetch each message (batch for efficiency)
  const emails: any[] = [];
  for (const id of messageIds) {
    try {
      const msgRes = await fetch(
        `${GMAIL_API}/messages/${id}?format=full`,
        { headers: { Authorization: `Bearer ${accessToken}` } }
      );
      if (msgRes.ok) {
        const msg = await msgRes.json() as any;
        emails.push(parseGmailMessage(msg));
      }
    } catch {
      // Skip individual failures
    }
  }

  return emails;
}

export async function fetchOutlookUnread(accessToken: string, since: Date, maxResults = 40): Promise<any[]> {
  const sinceISO = since.toISOString();
  const url = `${GRAPH_API}/mailFolders/inbox/messages?$filter=isRead eq false and receivedDateTime ge ${sinceISO}&$top=${maxResults}&$orderby=receivedDateTime desc&$select=id,conversationId,subject,bodyPreview,body,from,toRecipients,ccRecipients,receivedDateTime,isRead,hasAttachments`;

  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  if (!res.ok) throw new Error(`Outlook fetch failed: ${res.status}`);
  const data = await res.json() as any;

  return (data.value || []).map((msg: any) => ({
    id: msg.id,
    threadId: msg.conversationId,
    messageId: msg.id,
    senderName: msg.from?.emailAddress?.name || '',
    senderEmail: msg.from?.emailAddress?.address || '',
    subject: msg.subject || '',
    snippet: msg.bodyPreview || '',
    body: msg.body?.content || '',
    date: msg.receivedDateTime,
    isUnread: !msg.isRead,
    source: 'outlook',
  }));
}

// ── Send Replies ──

export async function sendGmailReply(
  accessToken: string,
  to: string,
  subject: string,
  body: string,
  threadId: string,
  messageId: string,
  fromName: string,
  fromEmail: string
): Promise<void> {
  const raw = buildRFC2822(fromName, fromEmail, to, subject, body, messageId);
  const base64 = Buffer.from(raw).toString('base64url');

  const res = await fetch(`${GMAIL_API}/messages/send`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ raw: base64, threadId }),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Gmail send failed (${res.status}): ${err}`);
  }
}

export async function sendOutlookReply(
  accessToken: string,
  messageId: string,
  body: string
): Promise<void> {
  const res = await fetch(`${GRAPH_API}/messages/${messageId}/reply`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      comment: body,
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Outlook reply failed (${res.status}): ${err}`);
  }
}

// ── Helpers ──

function parseGmailMessage(msg: any): any {
  const headers = msg.payload?.headers || [];
  const getHeader = (name: string) => headers.find((h: any) => h.name.toLowerCase() === name.toLowerCase())?.value || '';

  const from = getHeader('From');
  const nameMatch = from.match(/^(.+?)\s*<(.+?)>$/);

  let body = '';
  const parts = msg.payload?.parts || [];
  for (const part of parts) {
    if (part.mimeType === 'text/plain' && part.body?.data) {
      body = Buffer.from(part.body.data, 'base64url').toString('utf-8');
      break;
    }
  }
  if (!body && msg.payload?.body?.data) {
    body = Buffer.from(msg.payload.body.data, 'base64url').toString('utf-8');
  }

  return {
    id: msg.id,
    threadId: msg.threadId,
    messageId: getHeader('Message-Id'),
    senderName: nameMatch ? nameMatch[1].replace(/"/g, '').trim() : from,
    senderEmail: nameMatch ? nameMatch[2] : from,
    subject: getHeader('Subject'),
    snippet: msg.snippet || '',
    body,
    date: new Date(parseInt(msg.internalDate)).toISOString(),
    isUnread: (msg.labelIds || []).includes('UNREAD'),
    source: 'gmail',
  };
}

function buildRFC2822(
  fromName: string, fromEmail: string,
  to: string, subject: string, body: string,
  inReplyTo: string
): string {
  return [
    `From: ${fromName} <${fromEmail}>`,
    `To: ${to}`,
    `Subject: ${subject}`,
    `In-Reply-To: ${inReplyTo}`,
    `References: ${inReplyTo}`,
    `Content-Type: text/plain; charset=UTF-8`,
    '',
    body,
  ].join('\r\n');
}
