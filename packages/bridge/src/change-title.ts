import {
  createSdkMcpServer,
  tool,
  type McpSdkServerConfigWithInstance,
} from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

/**
 * [Model self-title] In-process MCP server exposing the `change_title` tool.
 *
 * The model calls this tool to set or refine the session's display title
 * (mirrors Happy Coder's mcp__happy__change_title). The call surfaces here
 * as a `title_change` event on SdkProcess; SessionManager decides whether
 * to apply it (dedup / user-override guard / throttle) and broadcasts the
 * new name via the regular session_list path.
 */

export const CHANGE_TITLE_TOOL_NAME = "change_title";

/** System prompt appended to Claude Code's preset (preset + append form). */
export const TITLE_SYSTEM_PROMPT =
  "When you start a new conversation, you MUST call the `change_title` tool " +
  "to set a concise title for this session. Call the tool again if the topic " +
  "shifts significantly or the current title can be made more specific. " +
  "Write a natural, specific noun phrase — 2-8 words. Output only the title " +
  "as the tool argument: no quotes, no markdown, no explanation. " +
  "Match the primary language of the user's first message; never translate it.";

/**
 * Pure decision: should a model-initiated title change be applied?
 * Guard order: empty → dedup → user-override → throttle.
 * Exported for unit testing.
 */
export function shouldApplyModelTitle(
  current: {
    name?: string;
    isUserNamed?: boolean;
    lastModelTitleChangeAt?: number;
  },
  newTitle: string,
  now: number,
  throttleMs = 8000,
): boolean {
  const trimmed = newTitle.trim();
  if (!trimmed) return false;
  if (current.name === trimmed) return false;
  if (current.isUserNamed) return false;
  if (
    current.lastModelTitleChangeAt != null &&
    now - current.lastModelTitleChangeAt < throttleMs
  ) {
    return false;
  }
  return true;
}

/**
 * Create the in-process MCP server for `change_title`.
 * Zero stdio subprocesses — the tool handler runs inside this process.
 */
export function createTitleMcpServer(
  onTitleChange: (title: string) => void,
): McpSdkServerConfigWithInstance {
  return createSdkMcpServer({
    name: "claudio-title",
    version: "1.0.0",
    // Always present in the prompt — title setting must never be deferred
    // behind tool search, or the model cannot call it on turn one.
    alwaysLoad: true,
    tools: [
      tool(
        CHANGE_TITLE_TOOL_NAME,
        "Set or update the display title for this coding-agent session",
        {
          title: z
            .string()
            .describe(
              "The new session title — a natural, specific noun phrase, 2-8 words, in the user's language",
            ),
        },
        async (args) => {
          onTitleChange(args.title);
          return {
            content: [
              { type: "text" as const, text: `Title set to: "${args.title}"` },
            ],
          };
        },
      ),
    ],
  });
}
