// src/lib/jwt.ts
// JWT signing and verification using ES256 (ECDSA P-256).
// Includes jti (token ID) for revocation and nbf (not-before) for replay protection.

import { SignJWT, jwtVerify, importPKCS8, importSPKI, JWTPayload, KeyLike } from 'jose';
import { randomBytes } from 'crypto';

const ALG = 'ES256';
const ISSUER = 'ledger-api';
const AUDIENCE = 'ledger-ios';
const EXPIRY = '24h';

let privateKey: KeyLike | null = null;
let publicKey: KeyLike | null = null;

async function getPrivateKey(): Promise<KeyLike> {
  if (!privateKey) {
    const pem = process.env.JWT_PRIVATE_KEY!.replace(/\\n/g, '\n');
    privateKey = await importPKCS8(pem, ALG) as KeyLike;
  }
  return privateKey!;
}

async function getPublicKey(): Promise<KeyLike> {
  if (!publicKey) {
    const pem = process.env.JWT_PUBLIC_KEY!.replace(/\\n/g, '\n');
    publicKey = await importSPKI(pem, ALG) as KeyLike;
  }
  return publicKey!;
}

export interface LedgerJWTPayload extends JWTPayload {
  sub: string;        // user_id
  device_id: string;
  jti: string;        // unique token ID (for revocation)
}

export async function signJWT(userId: string, deviceId: string): Promise<{ token: string; expiresAt: Date }> {
  const key = await getPrivateKey();
  const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000);
  const jti = randomBytes(16).toString('hex');

  const token = await new SignJWT({ device_id: deviceId })
    .setProtectedHeader({ alg: ALG })
    .setSubject(userId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setNotBefore(Math.floor(Date.now() / 1000))
    .setExpirationTime(EXPIRY)
    .setJti(jti)
    .sign(key);

  return { token, expiresAt };
}

export async function verifyJWT(token: string): Promise<LedgerJWTPayload> {
  const key = await getPublicKey();
  const { payload } = await jwtVerify(token, key, {
    issuer: ISSUER,
    audience: AUDIENCE,
    clockTolerance: 30,
  });
  return payload as LedgerJWTPayload;
}
