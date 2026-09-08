import { describe, expect, it } from "vitest";

import { normalizePushLocale, t } from "./push-i18n.js";

describe("push i18n", () => {
  it("returns zh for simplified Chinese locale tags", () => {
    expect(normalizePushLocale("zh-CN")).toBe("zh");
    expect(normalizePushLocale("zh_Hans")).toBe("zh");
  });

  it("returns ko for Korean locale tags", () => {
    expect(normalizePushLocale("ko")).toBe("ko");
    expect(normalizePushLocale("ko-KR")).toBe("ko");
  });

  it("falls back to en for unsupported locales", () => {
    expect(normalizePushLocale("fr")).toBe("en");
  });

  it("returns Chinese translations with placeholders resolved", () => {
    expect(t("zh", "approval_body", { toolName: "apply_patch" })).toBe(
      "请批准执行 apply_patch",
    );
  });

  it("returns Korean translations with placeholders resolved", () => {
    expect(t("ko", "approval_body", { toolName: "apply_patch" })).toBe(
      "apply_patch 실행을 승인하세요",
    );
  });
});
