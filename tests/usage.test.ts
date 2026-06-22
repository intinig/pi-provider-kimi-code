import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  buildKimiUsageUrl,
  formatUsageRow,
  parseMembership,
  parseUsageRow,
  parseUsageSummary,
} from "../src/usage.ts";

describe("buildKimiUsageUrl", () => {
  it("uses /usages under v1 base URLs", () => {
    assert.equal(
      buildKimiUsageUrl("https://api.kimi.com/coding/v1"),
      "https://api.kimi.com/coding/v1/usages",
    );
    assert.equal(
      buildKimiUsageUrl("https://proxy.example/kimi/v1/"),
      "https://proxy.example/kimi/v1/usages",
    );
  });

  it("adds /v1/usages under non-v1 base URLs", () => {
    assert.equal(
      buildKimiUsageUrl("https://api.kimi.com/coding"),
      "https://api.kimi.com/coding/v1/usages",
    );
    assert.equal(
      buildKimiUsageUrl("https://proxy.example/kimi"),
      "https://proxy.example/kimi/v1/usages",
    );
  });
});

describe("parseUsageSummary", () => {
  it("formats membership, weekly usage, and limit details", () => {
    const summary = parseUsageSummary({
      user: { membership: { level: "LEVEL_ADVANCED" } },
      usage: { name: "Weekly requests", limit: 100, used: 25 },
      limits: [{ detail: { limit: 10, remaining: 3 } }, { title: "Daily", limit: 5, used: 6 }],
    });

    assert.equal(
      summary,
      [
        "Membership: Allegro (LEVEL_ADVANCED)",
        "Weekly requests: [###############-----] 75% left (75/100)",
        "5h rate limit: [######--------------] 30% left (3/10)",
        "Daily: [--------------------] 0% left (0/5)",
      ].join("\n"),
    );
  });

  it("reports unavailable and empty payloads with existing messages", () => {
    assert.equal(parseUsageSummary(null), "Usage: unavailable");
    assert.equal(parseUsageSummary([]), "Usage: unavailable");
    assert.equal(parseUsageSummary({}), "Usage: no usage data");
  });
});

describe("parseMembership", () => {
  it("keeps unknown membership levels readable", () => {
    assert.equal(
      parseMembership({ user: { membership: { level: "LEVEL_UNKNOWN" } } }),
      "Membership: LEVEL_UNKNOWN",
    );
  });
});

describe("parseUsageRow", () => {
  it("derives used value from remaining when used is absent", () => {
    assert.deepEqual(parseUsageRow({ title: "Window", limit: "20", remaining: "8" }, "Fallback"), {
      label: "Window",
      used: 12,
      limit: 20,
    });
  });

  it("returns null when neither limit nor used can be parsed", () => {
    assert.equal(parseUsageRow({ name: "Empty" }, "Fallback"), null);
  });
});

describe("formatUsageRow", () => {
  it("formats rows without a positive limit as used-only", () => {
    assert.equal(formatUsageRow({ label: "Tokens", used: 12, limit: 0 }), "Tokens: 12 used");
  });

  it("caps remaining quota at the row limit", () => {
    assert.equal(
      formatUsageRow({ label: "Weekly", used: -10, limit: 100 }),
      "Weekly: [####################] 100% left (100/100)",
    );
  });
});
