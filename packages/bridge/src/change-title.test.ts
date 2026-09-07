import { describe, expect, it } from "vitest";
import { shouldApplyModelTitle } from "./change-title.js";

describe("shouldApplyModelTitle", () => {
  const NOW = 1_000_000;

  it("applies a fresh title to an unnamed session", () => {
    expect(shouldApplyModelTitle({}, "重构登录模块", NOW)).toBe(true);
  });

  it("applies an updated (different) title", () => {
    expect(
      shouldApplyModelTitle({ name: "重构登录模块" }, "登录模块重构与测试", NOW),
    ).toBe(true);
  });

  it("rejects empty / whitespace-only titles", () => {
    expect(shouldApplyModelTitle({}, "", NOW)).toBe(false);
    expect(shouldApplyModelTitle({}, "   ", NOW)).toBe(false);
  });

  it("rejects a duplicate title (dedup)", () => {
    expect(
      shouldApplyModelTitle({ name: "重构登录模块" }, "重构登录模块", NOW),
    ).toBe(false);
    // Trimming counts: same name after trim is still a dup.
    expect(
      shouldApplyModelTitle({ name: "重构登录模块" }, "  重构登录模块  ", NOW),
    ).toBe(false);
  });

  it("never overrides a user-assigned name", () => {
    expect(
      shouldApplyModelTitle(
        { name: "我的项目", isUserNamed: true },
        "模型想改的名字",
        NOW,
      ),
    ).toBe(false);
  });

  it("throttles rapid successive changes", () => {
    const last = NOW - 3_000; // 3s ago
    expect(
      shouldApplyModelTitle(
        { name: "旧标题", lastModelTitleChangeAt: last },
        "新标题",
        NOW,
      ),
    ).toBe(false);
  });

  it("applies changes after the throttle window", () => {
    const last = NOW - 9_000; // 9s ago
    expect(
      shouldApplyModelTitle(
        { name: "旧标题", lastModelTitleChangeAt: last },
        "新标题",
        NOW,
      ),
    ).toBe(true);
  });

  it("applies when lastModelTitleChangeAt is undefined", () => {
    expect(shouldApplyModelTitle({ name: "旧标题" }, "新标题", NOW)).toBe(true);
  });
});
