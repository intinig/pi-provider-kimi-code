// Model identity: discovery against the server's /v1/models endpoint, plus the
// extras-merging helpers used by both registration and the OAuth modifyModels hook.

import type { Api, Model, OAuthCredentials } from "@earendil-works/pi-ai";
import type { KimiResolvedModelConfig, ModelConfig } from "./config.ts";

import { getBaseUrl } from "./constants.ts";
import { getCommonHeaders } from "./device.ts";

export interface KimiOAuthExtras {
  wireModelId?: string;
  modelDisplay?: string;
  contextLength?: number;
  supportsReasoning?: boolean;
  supportsImageIn?: boolean;
  supportsVideoIn?: boolean;
  supportsThinkingType?: "only" | "no" | "both";
}

export type KimiOAuthCredentials = OAuthCredentials & KimiOAuthExtras;

export function buildKimiModelFromConfig(config: ModelConfig): Model<Api> {
  return {
    id: "kimi-for-coding",
    name: "Kimi for Coding",
    reasoning: config.reasoning,
    input: [...config.input] as unknown as ("text" | "image" | "video")[],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: config.contextWindow,
    maxTokens: config.maxTokens,
  } as Model<Api>;
}

export function resolveKimiModelConfig(
  config: ModelConfig,
  extras: Partial<KimiOAuthExtras>,
): KimiResolvedModelConfig {
  const resolved: KimiResolvedModelConfig = { ...config, input: [...config.input] };
  if (typeof extras.contextLength === "number" && extras.contextLength > 0) {
    resolved.contextWindow = extras.contextLength;
  }
  if (typeof extras.supportsThinkingType === "string") {
    resolved.supportsThinkingType = extras.supportsThinkingType;
    resolved.reasoning = extras.supportsThinkingType !== "no";
  } else if (typeof extras.supportsReasoning === "boolean") {
    resolved.reasoning = extras.supportsReasoning;
  }
  if (typeof extras.supportsImageIn === "boolean" || typeof extras.supportsVideoIn === "boolean") {
    resolved.input = ["text"];
    if (extras.supportsImageIn) resolved.input.push("image");
    if (extras.supportsVideoIn) resolved.input.push("video");
  }
  return resolved;
}

interface KimiServerModel {
  id?: unknown;
  display_name?: unknown;
  context_length?: unknown;
  supports_reasoning?: unknown;
  supports_image_in?: unknown;
  supports_video_in?: unknown;
  supports_thinking_type?: unknown;
}

function parseSupportsThinkingType(value: unknown): "only" | "no" | "both" | undefined {
  if (value === "only" || value === "no" || value === "both") return value;
  return undefined;
}

export function buildModelsUrl(baseUrl: string): string {
  const base = baseUrl.replace(/\/+$/, "");
  return base.endsWith("/v1") ? `${base}/models` : `${base}/v1/models`;
}

function getModelsUrl(): string {
  return buildModelsUrl(getBaseUrl());
}

export async function discoverKimiModelMetadata(accessToken: string): Promise<KimiOAuthExtras> {
  if (!accessToken) return {};
  try {
    const response = await fetch(getModelsUrl(), {
      headers: {
        ...getCommonHeaders(),
        Authorization: `Bearer ${accessToken}`,
        Accept: "application/json",
      },
    });
    if (!response.ok) return {};
    const json = (await response.json()) as { data?: unknown };
    const list = Array.isArray(json.data) ? (json.data as KimiServerModel[]) : [];
    const preferred = list.find((m) => typeof m.id === "string" && m.id === "kimi-for-coding");
    if (!preferred || typeof preferred.id !== "string") return {};
    const extras: KimiOAuthExtras = { wireModelId: preferred.id };
    if (typeof preferred.display_name === "string") extras.modelDisplay = preferred.display_name;
    if (typeof preferred.context_length === "number" && preferred.context_length > 0) {
      extras.contextLength = preferred.context_length;
    }
    const thinkingType = parseSupportsThinkingType(preferred.supports_thinking_type);
    if (thinkingType) {
      extras.supportsThinkingType = thinkingType;
    } else if (typeof preferred.supports_reasoning === "boolean") {
      extras.supportsReasoning = preferred.supports_reasoning;
    }
    if (typeof preferred.supports_image_in === "boolean") {
      extras.supportsImageIn = preferred.supports_image_in;
    }
    if (typeof preferred.supports_video_in === "boolean") {
      extras.supportsVideoIn = preferred.supports_video_in;
    }
    return extras;
  } catch {
    return {};
  }
}

export function applyKimiOAuthExtrasToModel(
  model: Model<Api>,
  extras: KimiOAuthExtras,
): Model<Api> {
  const next: Model<Api> & { wireModelId?: string; supportsThinkingType?: "only" | "no" | "both" } =
    { ...model };
  if (typeof extras.modelDisplay === "string" && extras.modelDisplay) {
    next.name = extras.modelDisplay;
  }
  if (typeof extras.contextLength === "number" && extras.contextLength > 0) {
    next.contextWindow = extras.contextLength;
  }
  if (typeof extras.wireModelId === "string" && extras.wireModelId) {
    next.wireModelId = extras.wireModelId;
  }
  if (typeof extras.supportsThinkingType === "string") {
    next.reasoning = extras.supportsThinkingType !== "no";
    next.supportsThinkingType = extras.supportsThinkingType;
  } else if (typeof extras.supportsReasoning === "boolean") {
    next.reasoning = extras.supportsReasoning;
    next.supportsThinkingType = undefined;
  }
  if (typeof extras.supportsImageIn === "boolean" || typeof extras.supportsVideoIn === "boolean") {
    const input = ["text"];
    if (extras.supportsImageIn) input.push("image");
    if (extras.supportsVideoIn) input.push("video");
    (next as unknown as { input: string[] }).input = input;
  }
  return next;
}
