/**
 * Kimi Code Provider Extension
 *
 * Provides access to Kimi models via OAuth device code flow.
 * API endpoint: https://api.kimi.com/coding (Anthropic Messages compatible)
 *
 * Usage:
 *   pi -e ~/workshop/pi-provider-kimi-code
 *   # Then /login kimi-coding, or set KIMI_API_KEY=...
 *
 * Source layout:
 *   src/constants.ts  — module-level consts + env-driven configuration
 *   src/device.ts     — device id + kimi-cli-compatible request headers
 *   src/oauth.ts      — device flow, token refresh, kimi-cli reuse,
 *                       login/refresh handlers, stream-level auth refresh
 *   src/models.ts     — /v1/models discovery + extras-merging helpers
 *   src/payload.ts    — payload pipeline + file upload + transforms
 *   src/project-trust.ts — project config approval compatibility helpers
 *   src/stream.ts     — empty-response filter + streamSimpleKimi orchestrator
 */

import {
  type ExtensionAPI,
  type ExtensionCommandContext,
  type ExtensionFactory,
} from "@earendil-works/pi-coding-agent";
import os from "node:os";
import { relative } from "node:path";

import {
  type KimiCodeConfig,
  type KimiCodeConfigPatch,
  KIMI_TOOL_NAMES,
  getProjectKimiCodeConfigPath,
  getGlobalKimiCodeConfigPath,
  loadHomeKimiCodeConfig,
  loadKimiCodeConfig,
  loadKimiCodeConfigSources,
  loadProjectKimiCodeConfig,
  saveHomeKimiCodeConfig,
  saveProjectKimiCodeConfig,
  type KimiToolName,
} from "./src/config.ts";
import { PROVIDER_ID, PROVIDER_VERSION, getBaseUrl, getKimiApiType } from "./src/constants.ts";
import {
  type KimiOAuthCredentials,
  type KimiOAuthExtras,
  buildKimiModelFromConfig,
  applyKimiOAuthExtrasToModel,
  discoverKimiModelMetadata,
  resolveKimiModelConfig,
} from "./src/models.ts";
import { loginKimiCode, refreshKimiCodeToken } from "./src/oauth.ts";
import { isKimiProjectConfigApproved } from "./src/project-trust.ts";
import { setStoreResolvedKimiConfig, streamSimpleKimi } from "./src/stream.ts";
import { fetchKimiUsageSummary, getKimiUsageToken } from "./src/usage.ts";
import { buildMoonshotFetchTool, buildMoonshotSearchTool } from "./src/tools/moonshot.ts";
import { buildKimiDatasourceTool } from "./src/tools/datasource.ts";
type KimiConfigScope = "project" | "home";
interface KimiRuntimeState {
  cwd: string;
  config: KimiCodeConfig;
  modelExtras: KimiOAuthExtras;
  projectTrusted: boolean;
  overrides?: KimiCodeConfigPatch;
}

function buildKimiTool(toolName: KimiToolName, config: KimiCodeConfig) {
  const opts = { defaultCollapsed: config.tools[toolName].default_collapsed };
  if (toolName === "moonshot_search") return buildMoonshotSearchTool(opts);
  if (toolName === "moonshot_fetch") return buildMoonshotFetchTool(opts);
  if (toolName === "kimi_datasource") return buildKimiDatasourceTool(opts);
  return undefined;
}

function registerConfiguredMoonshotTools(
  pi: ExtensionAPI,
  config: KimiCodeConfig,
  options: { updateActiveTools: boolean },
): void {
  for (const toolName of KIMI_TOOL_NAMES) {
    if (config.tools[toolName].enabled) {
      const tool = buildKimiTool(toolName, config);
      if (tool) pi.registerTool(tool);
    }
  }

  if (!options.updateActiveTools) return;

  const activeTools = new Set(pi.getActiveTools());
  for (const toolName of KIMI_TOOL_NAMES) {
    if (config.tools[toolName].enabled) {
      activeTools.add(toolName);
    } else {
      activeTools.delete(toolName);
    }
  }
  pi.setActiveTools([...activeTools]);
}

function reloadEffectiveKimiRuntimeConfig(
  state: KimiRuntimeState,
  cwd: string,
  projectTrusted: boolean,
): KimiCodeConfig {
  const config = loadKimiCodeConfig(
    { cwd, home: os.homedir(), includeProject: projectTrusted },
    state.overrides,
  );
  state.cwd = cwd;
  state.config = config;
  state.projectTrusted = projectTrusted;
  setStoreResolvedKimiConfig({
    model: resolveKimiModelConfig(config.model, state.modelExtras),
    protocol: config.protocol,
    uploads: config.uploads,
  });
  return config;
}

function applyEffectiveKimiRuntimeConfig(
  pi: ExtensionAPI,
  state: KimiRuntimeState,
  cwd: string,
  options: { updateActiveTools: boolean; projectTrusted: boolean },
): KimiCodeConfig {
  const config = reloadEffectiveKimiRuntimeConfig(state, cwd, options.projectTrusted);
  registerConfiguredMoonshotTools(pi, config, options);
  return config;
}

function moonshotStatus(config: KimiCodeConfig): string {
  return KIMI_TOOL_NAMES.map((toolName) => {
    const tool = config.tools[toolName];
    const enabled = tool.enabled ? "enabled" : "disabled";
    const collapsed = tool.default_collapsed ? "collapsed" : "expanded";
    return `${toolName}: ${enabled}, default ${collapsed}`;
  }).join("\n");
}

function toggleEnabled(config: KimiCodeConfig, toolName: KimiToolName): KimiCodeConfig {
  return {
    ...config,
    tools: {
      ...config.tools,
      [toolName]: {
        ...config.tools[toolName],
        enabled: !config.tools[toolName].enabled,
      },
    },
  };
}

function toggleCollapsed(config: KimiCodeConfig, toolName: KimiToolName): KimiCodeConfig {
  return {
    ...config,
    tools: {
      ...config.tools,
      [toolName]: {
        ...config.tools[toolName],
        default_collapsed: !config.tools[toolName].default_collapsed,
      },
    },
  };
}

function setProtocol(config: KimiCodeConfig, protocol: KimiCodeConfig["protocol"]): KimiCodeConfig {
  return { ...config, protocol };
}

function setUploadThreshold(config: KimiCodeConfig, thresholdBytes: number): KimiCodeConfig {
  return { ...config, uploads: { ...config.uploads, thresholdBytes } };
}

async function refreshModelExtras(state: KimiRuntimeState): Promise<void> {
  const token = getKimiUsageToken();
  if (!token) return;
  const extras = await discoverKimiModelMetadata(token, state.config.protocol);
  if (Object.keys(extras).length > 0) {
    Object.assign(state.modelExtras, extras);
  }
}

async function runKimiCommand(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  state: KimiRuntimeState,
): Promise<void> {
  const projectTrusted = await isKimiProjectConfigApproved(ctx, ctx.cwd);
  let config = applyEffectiveKimiRuntimeConfig(pi, state, ctx.cwd, {
    updateActiveTools: true,
    projectTrusted,
  });
  let [usage] = await Promise.all([fetchKimiUsageSummary(), refreshModelExtras(state)]);
  ctx.ui.notify(usage);

  while (true) {
    const projectConfigChoice = projectTrusted
      ? `Edit project config (${relative(ctx.cwd, getProjectKimiCodeConfigPath(ctx.cwd))})`
      : "Project config unavailable (project not trusted)";
    const choice = await ctx.ui.select(
      buildKimiMainTitle(config, ctx.cwd, state.modelExtras, projectTrusted),
      [
        projectConfigChoice,
        `Edit home config (${homeRelative(getGlobalKimiCodeConfigPath(os.homedir()))})`,
        "Refresh usage",
        "Done",
      ],
    );

    if (!choice || choice === "Done") return;
    if (choice === "Refresh usage") {
      usage = await fetchKimiUsageSummary();
      ctx.ui.notify(usage);
      continue;
    }
    if (choice.startsWith("Project config unavailable")) {
      ctx.ui.notify("Project config is unavailable until this project is trusted", "warning");
      continue;
    }
    if (choice.startsWith("Edit project config")) {
      config = await editConfigScope(pi, ctx, state, "project");
    } else if (choice.startsWith("Edit home config")) {
      config = await editConfigScope(pi, ctx, state, "home");
    }
  }
}

async function editConfigScope(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  state: KimiRuntimeState,
  scope: KimiConfigScope,
): Promise<KimiCodeConfig> {
  let current = loadScopeKimiCodeConfig(scope, ctx.cwd);
  while (true) {
    const items = KIMI_TOOL_NAMES.map((name) => toolMenuItem(current, name));
    items.push(protocolMenuItem(current), uploadThresholdMenuItem(current), "Back");
    const choice = await ctx.ui.select(buildConfigScopeTitle(scope, current, ctx.cwd), items);
    if (!choice || choice === "Back") {
      return loadKimiCodeConfig({
        cwd: ctx.cwd,
        home: os.homedir(),
        includeProject: state.projectTrusted,
      });
    }
    const toolName = KIMI_TOOL_NAMES.find((name) => choice.startsWith(name));
    if (toolName) {
      current = await editMoonshotTool(pi, ctx, state, scope, current, toolName);
    } else if (choice.startsWith("Protocol")) {
      current = await editProtocol(pi, ctx, state, scope, current);
    } else if (choice.startsWith("Upload threshold")) {
      current = await editUploadThreshold(pi, ctx, state, scope, current);
    }
  }
}

async function editProtocol(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  state: KimiRuntimeState,
  scope: KimiConfigScope,
  config: KimiCodeConfig,
): Promise<KimiCodeConfig> {
  const choice = await ctx.ui.select(`Edit protocol\n\n${formatProtocolStatus(config)}`, [
    "Use openai protocol",
    "Use anthropic protocol",
    "Back",
  ]);
  if (!choice || choice === "Back") return config;
  const protocol = choice.includes("anthropic") ? "anthropic" : "openai";
  const current = setProtocol(config, protocol);
  saveAndApplyKimiCodeConfig(pi, ctx, state, scope, current);
  ctx.ui.notify("Saved protocol config", "info");
  return current;
}

async function editUploadThreshold(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  state: KimiRuntimeState,
  scope: KimiConfigScope,
  config: KimiCodeConfig,
): Promise<KimiCodeConfig> {
  const input = await ctx.ui.input(
    "Edit upload threshold\n\nExamples: 512 KiB, 2 MiB, 1.5 MB. Plain numbers are MiB.",
    formatByteSize(config.uploads.thresholdBytes),
  );
  if (input === undefined) return config;
  const thresholdBytes = parseByteSizeInput(input);
  if (thresholdBytes === undefined || thresholdBytes <= 0) {
    ctx.ui.notify("Upload threshold must be a positive size, for example 2 MiB", "error");
    return config;
  }
  const current = setUploadThreshold(config, thresholdBytes);
  saveAndApplyKimiCodeConfig(pi, ctx, state, scope, current);
  ctx.ui.notify("Saved upload threshold config", "info");
  return current;
}

async function editMoonshotTool(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  state: KimiRuntimeState,
  scope: KimiConfigScope,
  config: KimiCodeConfig,
  toolName: KimiToolName,
): Promise<KimiCodeConfig> {
  let current = config;
  while (true) {
    const tool = current.tools[toolName];
    const choice = await ctx.ui.select(
      `Edit ${toolName}\n\n${formatToolStatus(current, toolName)}`,
      [
        tool.enabled ? `Disable ${toolName}` : `Enable ${toolName}`,
        tool.default_collapsed ? "Expand previews by default" : "Collapse previews by default",
        "Back",
      ],
    );
    if (!choice || choice === "Back") return current;
    if (choice.startsWith("Enable") || choice.startsWith("Disable")) {
      current = toggleEnabled(current, toolName);
    } else if (choice.endsWith("previews by default")) {
      current = toggleCollapsed(current, toolName);
    }
    saveAndApplyKimiCodeConfig(pi, ctx, state, scope, current);
    ctx.ui.notify(`Saved ${toolName} config`, "info");
    return current;
  }
}

function saveAndApplyKimiCodeConfig(
  pi: ExtensionAPI,
  ctx: ExtensionCommandContext,
  state: KimiRuntimeState,
  scope: KimiConfigScope,
  config: KimiCodeConfig,
): void {
  saveScopeKimiCodeConfig(scope, ctx.cwd, config);
  applyEffectiveKimiRuntimeConfig(pi, state, ctx.cwd, {
    updateActiveTools: true,
    projectTrusted: scope === "project" ? true : state.projectTrusted,
  });
}

function loadScopeKimiCodeConfig(scope: KimiConfigScope, cwd: string): KimiCodeConfig {
  if (scope === "project") return loadProjectKimiCodeConfig(cwd);
  return loadHomeKimiCodeConfig(os.homedir());
}

function saveScopeKimiCodeConfig(
  scope: KimiConfigScope,
  cwd: string,
  config: KimiCodeConfig,
): void {
  if (scope === "project") {
    saveProjectKimiCodeConfig(cwd, config);
  } else {
    saveHomeKimiCodeConfig(os.homedir(), config);
  }
}

function buildKimiMainTitle(
  config: KimiCodeConfig,
  cwd: string,
  extras: KimiOAuthExtras,
  projectTrusted: boolean,
): string {
  const sources = loadKimiCodeConfigSources({
    cwd,
    home: os.homedir(),
    includeProject: projectTrusted,
  });
  const modelName = extras.modelDisplay || "kimi-for-coding";
  return [
    `Kimi settings (provider v${PROVIDER_VERSION})`,
    "",
    `Model: ${modelName}`,
    `Protocol: ${config.protocol} (${sources.protocol})`,
    `Upload threshold: ${formatByteSize(config.uploads.thresholdBytes)} (${sources.uploads.thresholdBytes})`,
    "",
    "Effective tools:",
    ...KIMI_TOOL_NAMES.map((toolName) => {
      const enabled = config.tools[toolName].enabled ? "enabled" : "disabled";
      return `- ${toolName}: ${enabled} (${sources.tools[toolName].enabled})`;
    }),
  ].join("\n");
}

function buildConfigScopeTitle(
  scope: KimiConfigScope,
  config: KimiCodeConfig,
  cwd: string,
): string {
  const path =
    scope === "project"
      ? relative(cwd, getProjectKimiCodeConfigPath(cwd))
      : homeRelative(getGlobalKimiCodeConfigPath(os.homedir()));
  return [
    `Edit ${scope} config`,
    `File: ${path}`,
    "",
    formatProtocolStatus(config),
    formatUploadThresholdStatus(config),
    "",
    moonshotStatus(config),
  ].join("\n");
}

function homeRelative(filePath: string): string {
  const home = os.homedir();
  return filePath.startsWith(`${home}/`) ? `~/${filePath.slice(home.length + 1)}` : filePath;
}

function toolMenuItem(config: KimiCodeConfig, toolName: KimiToolName): string {
  return `${toolName} -> ${formatToolStatus(config, toolName)}`;
}

function protocolMenuItem(config: KimiCodeConfig): string {
  return `Protocol -> ${config.protocol}`;
}

function uploadThresholdMenuItem(config: KimiCodeConfig): string {
  return `Upload threshold -> ${formatByteSize(config.uploads.thresholdBytes)}`;
}

function formatByteSize(bytes: number): string {
  const units = [
    { suffix: "GiB", size: 1024 ** 3 },
    { suffix: "MiB", size: 1024 ** 2 },
    { suffix: "KiB", size: 1024 },
  ];
  for (const unit of units) {
    if (bytes >= unit.size && bytes % unit.size === 0) {
      return `${bytes / unit.size} ${unit.suffix}`;
    }
  }
  for (const unit of units) {
    if (bytes >= unit.size) {
      return `${(bytes / unit.size).toFixed(2).replace(/\.00$/, "")} ${unit.suffix}`;
    }
  }
  return `${bytes} B`;
}

function parseByteSizeInput(input: string): number | undefined {
  const match = input.trim().match(/^(\d+(?:\.\d+)?)\s*(b|bytes?|kib|kb|mib|mb|gib|gb)?$/i);
  if (!match) return undefined;
  const value = Number(match[1]);
  if (!Number.isFinite(value) || value <= 0) return undefined;
  const unit = (match[2] ?? "mib").toLowerCase();
  const multipliers: Record<string, number> = {
    b: 1,
    byte: 1,
    bytes: 1,
    kib: 1024,
    kb: 1000,
    mib: 1024 ** 2,
    mb: 1000 ** 2,
    gib: 1024 ** 3,
    gb: 1000 ** 3,
  };
  const multiplier = multipliers[unit];
  if (!multiplier) return undefined;
  const bytes = Math.round(value * multiplier);
  return Number.isSafeInteger(bytes) && bytes > 0 ? bytes : undefined;
}

function formatProtocolStatus(config: KimiCodeConfig): string {
  return `protocol: ${config.protocol}`;
}

function formatUploadThresholdStatus(config: KimiCodeConfig): string {
  return `upload threshold: ${formatByteSize(config.uploads.thresholdBytes)}`;
}

function formatToolStatus(config: KimiCodeConfig, toolName: KimiToolName): string {
  const tool = config.tools[toolName];
  const enabled = tool.enabled ? "enabled" : "disabled";
  const collapsed = tool.default_collapsed ? "default collapsed" : "default expanded";
  return `${enabled}, ${collapsed}`;
}

function registerKimiProvider(pi: ExtensionAPI, state: KimiRuntimeState): void {
  const model = applyKimiOAuthExtrasToModel(
    buildKimiModelFromConfig(state.config.model),
    state.modelExtras,
  );

  pi.registerProvider(PROVIDER_ID, {
    baseUrl: getBaseUrl(state.config.protocol),
    apiKey: "$KIMI_API_KEY",
    api: getKimiApiType(state.config.protocol),
    streamSimple: streamSimpleKimi,

    models: [model],

    oauth: {
      name: "Kimi Code (OAuth)",
      login: loginKimiCode,
      refreshToken: refreshKimiCodeToken,
      getApiKey: (cred) => cred.access,
      // Reflect server-side model identity on the registered model after login
      // / refresh. We never rewrite the model id (pi-side `/model` selections
      // and persisted sessions reference it); only the human-facing name, the
      // context window, and an out-of-band `wireModelId` carried into the
      // request payload by streamSimpleKimi.
      modifyModels: (models, cred) => {
        const extras = cred as KimiOAuthCredentials;
        state.modelExtras = extras;
        reloadEffectiveKimiRuntimeConfig(state, state.cwd, state.projectTrusted);
        return models.map((model) => {
          if (model.id !== "kimi-for-coding") return model;
          return applyKimiOAuthExtrasToModel(model, extras);
        });
      },
    },
  });
}

export function KimiCode(overrides?: KimiCodeConfigPatch): ExtensionFactory {
  return async (pi: ExtensionAPI) => {
    const cwd = process.cwd();
    const config = loadKimiCodeConfig(
      { cwd, home: os.homedir(), includeProject: false },
      overrides,
    );
    const discoveryToken = getKimiUsageToken();
    const discovered = discoveryToken
      ? await discoverKimiModelMetadata(discoveryToken, config.protocol)
      : {};
    const state: KimiRuntimeState = {
      cwd,
      config,
      modelExtras: discovered,
      projectTrusted: false,
      overrides,
    };
    reloadEffectiveKimiRuntimeConfig(state, cwd, false);
    registerKimiProvider(pi, state);

    registerConfiguredMoonshotTools(pi, state.config, { updateActiveTools: false });

    pi.on("session_start", async (_event, ctx) => {
      const projectTrusted = await isKimiProjectConfigApproved(ctx, ctx.cwd);
      applyEffectiveKimiRuntimeConfig(pi, state, ctx.cwd, {
        updateActiveTools: true,
        projectTrusted,
      });
      registerKimiProvider(pi, state);
    });

    pi.registerCommand("kimi-settings", {
      description: "Show Kimi usage and configure optional Kimi tools",
      handler: async (_args, ctx) => {
        await runKimiCommand(pi, ctx, state);
      },
    });
  };
}

export default KimiCode();
