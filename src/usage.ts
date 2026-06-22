import { AuthStorage } from "@earendil-works/pi-coding-agent";

import { PROVIDER_ID } from "./constants.ts";
import { getCommonHeaders } from "./device.ts";
import { refreshKimiAuthToken } from "./oauth.ts";

const MEMBERSHIP_LEVEL_NAMES: Record<string, string> = {
  LEVEL_FREE: "Free",
  LEVEL_BASIC: "Adagio",
  LEVEL_STANDARD: "Moderato",
  LEVEL_INTERMEDIATE: "Allegretto",
  LEVEL_ADVANCED: "Allegro",
  LEVEL_PREMIUM: "Vivace",
};

export interface UsageRow {
  label: string;
  used: number;
  limit: number;
}

export function getKimiUsageToken(): string | null {
  const credential = AuthStorage.create().get(PROVIDER_ID);
  if (credential?.type === "oauth" && credential.access) return credential.access;
  const apiKey = process.env.KIMI_API_KEY?.trim();
  return apiKey || null;
}

function toNumber(value: unknown): number | null {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

export function parseUsageRow(value: unknown, fallbackLabel: string): UsageRow | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const limit = toNumber(record.limit);
  const usedValue = toNumber(record.used);
  const remaining = toNumber(record.remaining);
  const used = usedValue ?? (limit !== null && remaining !== null ? limit - remaining : null);
  if (limit === null && used === null) return null;
  return {
    label: String(record.name || record.title || fallbackLabel),
    used: used ?? 0,
    limit: limit ?? 0,
  };
}

export function parseUsageSummary(payload: unknown): string {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
    return "Usage: unavailable";
  }

  const record = payload as Record<string, unknown>;
  const lines: string[] = [];
  const membership = parseMembership(record);
  if (membership) lines.push(membership);

  const rows: UsageRow[] = [];
  const summary = parseUsageRow(record.usage, "Weekly limit");
  if (summary) rows.push(summary);

  if (Array.isArray(record.limits)) {
    for (const [index, item] of record.limits.entries()) {
      const detail =
        typeof item === "object" && item !== null && !Array.isArray(item)
          ? ((item as Record<string, unknown>).detail ?? item)
          : item;
      const row = parseUsageRow(detail, index === 0 ? "5h rate limit" : `Limit #${index + 1}`);
      if (row) rows.push(row);
    }
  }

  lines.push(...rows.map(formatUsageRow));
  return lines.length === 0 ? "Usage: no usage data" : lines.join("\n");
}

export function parseMembership(record: Record<string, unknown>): string | null {
  const user = record.user;
  if (typeof user !== "object" || user === null || Array.isArray(user)) return null;
  const membership = (user as Record<string, unknown>).membership;
  if (typeof membership !== "object" || membership === null || Array.isArray(membership)) {
    return null;
  }
  const level = (membership as Record<string, unknown>).level;
  if (typeof level !== "string" || !level) return null;
  const name = MEMBERSHIP_LEVEL_NAMES[level];
  return name ? `Membership: ${name} (${level})` : `Membership: ${level}`;
}

export function formatUsageRow(row: UsageRow): string {
  if (row.limit <= 0) return `${row.label}: ${row.used} used`;
  const remaining = Math.max(0, Math.min(row.limit - row.used, row.limit));
  const percent = Math.round((remaining / row.limit) * 100);
  return `${row.label}: ${quotaBar(remaining, row.limit)} ${percent}% left (${remaining}/${row.limit})`;
}

function quotaBar(remaining: number, limit: number): string {
  const width = 20;
  const filled = Math.max(0, Math.min(width, Math.round((remaining / limit) * width)));
  return `[${"#".repeat(filled)}${"-".repeat(width - filled)}]`;
}

function fetchKimiUsage(token: string, signal: AbortSignal): Promise<Response> {
  return fetch("https://api.kimi.com/coding/v1/usages", {
    method: "GET",
    headers: {
      ...getCommonHeaders(),
      Authorization: `Bearer ${token}`,
    },
    signal,
  });
}

export async function fetchKimiUsageSummary(): Promise<string> {
  const token = getKimiUsageToken();
  if (!token) return "Usage: missing credentials. Run /login kimi-coding.";

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    let response = await fetchKimiUsage(token, controller.signal);
    if (response.status === 401) {
      const refreshed = await refreshKimiAuthToken(token);
      if (refreshed) response = await fetchKimiUsage(refreshed, controller.signal);
    }
    if (!response.ok) return `Usage: fetch failed (${response.status})`;
    return parseUsageSummary(await response.json());
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return `Usage: fetch failed (${message})`;
  } finally {
    clearTimeout(timeout);
  }
}
