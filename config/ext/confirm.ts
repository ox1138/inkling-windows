// Ask before the local model runs anything that changes files, uses the network, or
// touches things outside the current folder. Read-only commands run without a prompt.
import { type ExtensionAPI, isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { resolve, sep } from "node:path";

const SAFE = new Set([
  "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "fd", "find", "pwd", "echo", "printf",
  "which", "type", "whoami", "date", "file", "stat", "du", "df", "tree", "sort", "uniq", "cut", "tr", "nl",
  "diff", "cmp", "basename", "dirname", "realpath", "env", "uname", "ps", "true", "false", "test", "[",
  "cd", "jq", "column", "sed", "awk", "less", "hostname", "sw_vers", "id",
]);
const SAFE_GIT = new Set(["status", "diff", "log", "show", "blame", "ls-files", "rev-parse", "describe", "grep", "shortlog"]);
const sessionAllowed = new Set<string>();

// Returns the reason a command needs a yes, or null if it is read-only.
function risk(command: string): { reason: string; key: string } | null {
  if (/\$\(|`|<\(|\beval\b|\bexec\b|\bsudo\b/.test(command)) return { reason: "runs nested or elevated commands", key: "" };
  if (/(^|[^0-9&>])>{1,2}(?!&)\s*(?!\/dev\/null)\S/.test(command)) return { reason: "writes to a file", key: "" };
  // Drop harmless redirections (2>&1, >&2, >/dev/null) so they aren't read as commands.
  const bare = command.replace(/\d*>&\d+/g, " ").replace(/\d*>{1,2}\s*\/dev\/null/g, " ");
  for (const raw of bare.split(/\|\||&&|[|;\n&]/)) {
    const words = raw.trim().replace(/^(\w+=\S*\s+)+/, "").split(/\s+/).filter(Boolean);
    if (!words.length) continue;
    const cmd = words[0].replace(/^.*\//, "");
    const key = cmd === "git" || cmd === "npm" || cmd === "uv" || cmd === "cargo" ? `${cmd} ${words[1] ?? ""}`.trim() : cmd;
    if (sessionAllowed.has(key)) continue;
    if (cmd === "git" && SAFE_GIT.has(words[1] ?? "")) continue;
    if (cmd === "sed" && words.some((w) => /^-[a-zA-Z]*i/.test(w))) return { reason: "edits files in place", key };
    if (cmd === "find" && words.some((w) => /^-(delete|exec|execdir|ok)$/.test(w))) return { reason: "find with an action", key: "" };
    if (SAFE.has(cmd)) continue;
    return { reason: `runs \`${key}\``, key };
  }
  return null;
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    let title: string | null = null;
    let detail = "";
    let key = "";

    if (isToolCallEventType("bash", event)) {
      const r = risk(event.input.command);
      if (!r) return;
      title = `Run this command? (${r.reason})`;
      detail = event.input.command;
      key = r.key;
    } else if (isToolCallEventType("write", event) || isToolCallEventType("edit", event)) {
      const target = resolve(ctx.cwd, event.input.path);
      // Windows paths are case-insensitive (d:\x and D:\X are the same file).
      const fold = (p: string) => (process.platform === "win32" ? p.toLowerCase() : p);
      const t = fold(target), cwd = fold(resolve(ctx.cwd));
      if (t === cwd || t.startsWith(cwd + sep)) return;
      title = "Change a file outside this folder?";
      detail = target;
    } else {
      return;
    }

    if (!ctx.hasUI) return { block: true, reason: "Needs user approval, and no one is here to approve it. Skip this step or find a read-only way." };

    const once = "Yes, once";
    const always = key ? `Yes, and don't ask again for \`${key}\` this session` : "";
    const no = "No";
    const choice = await ctx.ui.select(`${title}\n\n${detail}\n`, [once, ...(always ? [always] : []), no]);
    if (choice === always && key) sessionAllowed.add(key);
    if (choice === once || (always && choice === always)) return;
    return { block: true, reason: "The user declined this. Ask them what they would like instead." };
  });
}
