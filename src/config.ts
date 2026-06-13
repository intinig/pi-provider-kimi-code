import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export const KIMI_TOOL_NAMES = ["moonshot_search", "moonshot_fetch", "kimi_datasource"] as const;

export type KimiToolName = (typeof KIMI_TOOL_NAMES)[number];

export type KimiConfigSource = "project" | "home" | "default";

export interface KimiCodeConfig {
  tools: Record<KimiToolName, { enabled: boolean; default_collapsed: boolean }>;
}

export interface KimiCodeConfigSources {
  tools: Record<KimiToolName, { enabled: KimiConfigSource; default_collapsed: KimiConfigSource }>;
}

export interface LoadKimiCodeConfigOptions {
  cwd: string;
  home: string;
}

function makeDefaultTools(): KimiCodeConfig["tools"] {
  const tools = {} as KimiCodeConfig["tools"];
  for (const name of KIMI_TOOL_NAMES) {
    tools[name] = { enabled: false, default_collapsed: true };
  }
  return tools;
}

export const DEFAULT_KIMI_CODE_CONFIG: KimiCodeConfig = {
  tools: makeDefaultTools(),
};

export function getGlobalKimiCodeConfigPath(home: string): string {
  return join(home, ".pi", "pi-provider-kimi-code.json");
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

function readConfigFileQuiet(path: string): Record<string, unknown> {
  try {
    if (!existsSync(path)) return {};
    const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
    return isRecord(parsed) ? parsed : {};
  } catch {
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

function hasToolField(
  config: Record<string, unknown>,
  toolName: KimiToolName,
  field: "enabled" | "default_collapsed",
): boolean {
  const tools = config.tools;
  if (!isRecord(tools)) return false;
  const tool = tools[toolName];
  if (!isRecord(tool)) return false;
  return Object.hasOwn(tool, field);
}

function readToolConfig(
  config: Record<string, unknown>,
  toolName: KimiToolName,
): { enabled: boolean; default_collapsed: boolean } {
  return {
    enabled: readEnabled(config, toolName),
    default_collapsed: readDefaultCollapsed(config, toolName),
  };
}

export function loadKimiCodeConfig(options: LoadKimiCodeConfigOptions): KimiCodeConfig {
  const globalConfig = readConfigFile(getGlobalKimiCodeConfigPath(options.home));
  const projectConfig = readConfigFile(getProjectKimiCodeConfigPath(options.cwd));
  const merged = mergeConfig(globalConfig, projectConfig);

  const tools = {} as KimiCodeConfig["tools"];
  for (const name of KIMI_TOOL_NAMES) {
    tools[name] = readToolConfig(merged, name);
  }
  return { tools };
}

export function loadKimiCodeConfigSources(
  options: LoadKimiCodeConfigOptions,
): KimiCodeConfigSources {
  const homeConfig = readConfigFileQuiet(getGlobalKimiCodeConfigPath(options.home));
  const projectConfig = readConfigFileQuiet(getProjectKimiCodeConfigPath(options.cwd));
  const tools = {} as KimiCodeConfigSources["tools"];
  for (const name of KIMI_TOOL_NAMES) {
    tools[name] = {
      enabled: hasToolField(projectConfig, name, "enabled")
        ? "project"
        : hasToolField(homeConfig, name, "enabled")
          ? "home"
          : "default",
      default_collapsed: hasToolField(projectConfig, name, "default_collapsed")
        ? "project"
        : hasToolField(homeConfig, name, "default_collapsed")
          ? "home"
          : "default",
    };
  }
  return { tools };
}

export function loadProjectKimiCodeConfig(cwd: string): KimiCodeConfig {
  return loadKimiCodeConfigFile(getProjectKimiCodeConfigPath(cwd));
}

export function loadHomeKimiCodeConfig(home: string): KimiCodeConfig {
  return loadKimiCodeConfigFile(getGlobalKimiCodeConfigPath(home));
}

function loadKimiCodeConfigFile(path: string): KimiCodeConfig {
  const projectConfig = readConfigFileQuiet(path);
  const tools = {} as KimiCodeConfig["tools"];
  for (const name of KIMI_TOOL_NAMES) {
    tools[name] = readToolConfig(projectConfig, name);
  }
  return { tools };
}

export function saveProjectKimiCodeConfig(cwd: string, config: KimiCodeConfig): void {
  saveKimiCodeConfigFile(getProjectKimiCodeConfigPath(cwd), config);
}

export function saveHomeKimiCodeConfig(home: string, config: KimiCodeConfig): void {
  saveKimiCodeConfigFile(getGlobalKimiCodeConfigPath(home), config);
}

function saveKimiCodeConfigFile(path: string, config: KimiCodeConfig): void {
  const raw = readConfigFileQuiet(path);
  const tools: Record<string, unknown> = {
    ...(isRecord(raw.tools) ? raw.tools : {}),
  };
  for (const name of KIMI_TOOL_NAMES) {
    tools[name] = { ...config.tools[name] };
  }
  const next = {
    ...raw,
    tools,
  };
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(next, null, 2)}\n`, "utf8");
}
