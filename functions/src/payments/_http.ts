/**
 * Internal axios wrapper used by all gateway clients. Centralises timeouts,
 * user-agent, and a sanitiser that strips secrets before persisting gateway
 * responses into Firestore.
 */
import axios, { AxiosInstance, AxiosRequestConfig } from "axios";

export function httpClient(opts: {
  baseURL: string;
  timeoutMs?: number;
  headers?: Record<string, string>;
}): AxiosInstance {
  return axios.create({
    baseURL: opts.baseURL,
    timeout: opts.timeoutMs ?? 15000,
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      "User-Agent": "PaykariBazarCloudFunctions/1.0",
      ...opts.headers,
    },
  });
}

/** Strip common secret keys before persisting a gateway payload. */
export function sanitise(obj: unknown): unknown {
  if (obj === null || typeof obj !== "object") return obj;
  if (Array.isArray(obj)) return obj.map(sanitise);
  const redact = [
    "app_secret",
    "appSecret",
    "password",
    "token",
    "accessToken",
    "refreshToken",
    "id_token",
    "idToken",
    "privateKey",
    "signature",
  ];
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
    if (redact.includes(k)) {
      out[k] = "[REDACTED]";
    } else {
      out[k] = sanitise(v);
    }
  }
  return out;
}

/** Memoised async cache for OAuth-style tokens with a TTL. */
export class TokenCache {
  private token: string | null = null;
  private expiresAtMs = 0;
  private inflight: Promise<string> | null = null;

  async get(refresh: () => Promise<{ token: string; ttlMs: number }>): Promise<string> {
    if (this.token && Date.now() < this.expiresAtMs - 5_000) {
      return this.token;
    }
    if (!this.inflight) {
      this.inflight = (async () => {
        try {
          const { token, ttlMs } = await refresh();
          this.token = token;
          this.expiresAtMs = Date.now() + ttlMs;
          return token;
        } finally {
          this.inflight = null;
        }
      })();
    }
    return this.inflight;
  }
}

/** Common shape returned by create-payment callables — the client gets just
 *  what it needs to navigate the user to the gateway. */
export interface CreatePaymentResult {
  provider: string;
  gatewayUrl: string;
  paymentRefId: string;
  orderId: string;
  amountPoisha: number;
}

/** Apply with-config default — useful for stub-injection in unit tests. */
export type GatewayConfig = Record<string, unknown>;
export const axiosSafe = axios;
export type { AxiosRequestConfig };
