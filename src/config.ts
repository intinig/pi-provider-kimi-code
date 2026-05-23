import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export interface KimiCodeConfig {
  tools: {
    moonshot_search: { enabled: boolean; default_collapsed: boolean };
    moonshot_fetch: { enabled: boolean; default_collapsed: boolean };
  };
}

export interface LoadKimiCodeConfigOptions {
  cwd: string;
  home: string;
}

export const DEFAULT_KIMI_CODE_CONFIG: KimiCodeConfig = {
  tools: {
    moonshot_search: { enabled: false, default_collapsed: true },
    moonshot_fetch: { enabled: false, default_collapsed: true },
  },
};

export function getGlobalKimiCodeConfigPath(home: string): string {
  return join(home, ".pi", "agent", "pi-provider-kimi-code.json");
}

export function getProjectKimiCodeConfigPath(cwd: string): string {
  return join(cwd, ".pi", "pi-provider-kimi-code.json");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readConfigFile(path: string): Record<string, unknown> {
  try {
    if (!existsSync(path)) return {};
    const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
    return isRecord(parsed) ? parsed : {};
  } catch (error) {
    console.error(`[kimi-coding] failed to read config file ${path}:`, error);
    return {};
  }
}

function mergeConfig(
  base: Record<string, unknown>,
  override: Record<string, unknown>,
): Record<string, unknown> {
  const result: Record<string, unknown> = { ...base };
  for (const [key, value] of Object.entries(override)) {
    const current = result[key];
    if (isRecord(current) && isRecord(value)) {
      result[key] = mergeConfig(current, value);
    } else {
      result[key] = value;
    }
  }
  return result;
}

function readEnabled(config: Record<string, unknown>, toolName: string): boolean {
  const tools = config.tools;
  if (!isRecord(tools)) return false;
  const tool = tools[toolName];
  if (!isRecord(tool)) return false;
  return tool.enabled === true;
}

function readDefaultCollapsed(config: Record<string, unknown>, toolName: string): boolean {
  const tools = config.tools;
  if (!isRecord(tools)) return true;
  const tool = tools[toolName];
  if (!isRecord(tool)) return true;
  return tool.default_collapsed !== false;
}

export function loadKimiCodeConfig(options: LoadKimiCodeConfigOptions): KimiCodeConfig {
  const globalConfig = readConfigFile(getGlobalKimiCodeConfigPath(options.home));
  const projectConfig = readConfigFile(getProjectKimiCodeConfigPath(options.cwd));
  const merged = mergeConfig(globalConfig, projectConfig);

  return {
    tools: {
      moonshot_search: {
        enabled: readEnabled(merged, "moonshot_search"),
        default_collapsed: readDefaultCollapsed(merged, "moonshot_search"),
      },
      moonshot_fetch: {
        enabled: readEnabled(merged, "moonshot_fetch"),
        default_collapsed: readDefaultCollapsed(merged, "moonshot_fetch"),
      },
    },
  };
}
