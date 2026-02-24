// src/lib/crypto.ts
// AES-256-GCM encryption for provider refresh tokens.
// Key is loaded from environment — never hardcoded.

import { createCipheriv, createDecipheriv, randomBytes } from 'crypto';

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 16;       // 128 bits
const TAG_LENGTH = 16;      // 128 bits

function getKey(): Buffer {
  const hex = process.env.TOKEN_ENCRYPTION_KEY;
  if (!hex || hex.length !== 64) {
    throw new Error('TOKEN_ENCRYPTION_KEY must be a 64-character hex string (32 bytes)');
  }
  return Buffer.from(hex, 'hex');
}

export function encryptToken(plaintext: string): { encrypted: string; iv: string } {
  const key = getKey();
  const iv = randomBytes(IV_LENGTH);
  const cipher = createCipheriv(ALGORITHM, key, iv);

  const encryptedBuf = Buffer.concat([
    cipher.update(plaintext, 'utf8'),
    cipher.final(),
    cipher.getAuthTag(),    // Append auth tag (16 bytes) to ciphertext
  ]);

  return { encrypted: encryptedBuf.toString('base64'), iv: iv.toString('base64') };
}

export function decryptToken(encryptedB64: string, ivB64: string): string {
  const key = getKey();
  const encrypted = Buffer.from(encryptedB64, 'base64');
  const iv = Buffer.from(ivB64, 'base64');

  // Auth tag is the last 16 bytes
  const tag = encrypted.subarray(encrypted.length - TAG_LENGTH);
  const ciphertext = encrypted.subarray(0, encrypted.length - TAG_LENGTH);

  const decipher = createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(tag);

  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
}
