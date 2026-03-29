import { execFile } from "child_process";
import { readFileSync, writeFileSync, statSync, mkdirSync, unlinkSync } from "fs";
import { homedir } from "os";
import { basename, join } from "path";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

// --- Types ---

interface StatusLineInput {
  model?: { display_name?: string };
  workspace?: { current_dir?: string; added_dirs?: string[] };
  session_id?: string;
  context_window?: { remaining_percentage?: number };
  transcript_path?: string;
}

interface UsageBucket {
  utilization: number;
  resets_at: string;
}

interface UsageResponse {
  five_hour?: UsageBucket;
  seven_day?: UsageBucket;
}

type FetchResult = { ok: true; data: UsageResponse } | { ok: false; authError: boolean };

// --- Constants ---

const CACHE_DIR = join(homedir(), ".claude", "cache");
const CACHE_FILE = join(CACHE_DIR, "usage.json");
const CACHE_TTL = 360; // 6 minutes
const NEG_CACHE_FILE = join(CACHE_DIR, "usage-neg.json");
const NEG_CACHE_TTL = 30; // 30 seconds — avoid retry storms on API failure
const DIFF_CACHE_FILE = join(CACHE_DIR, "git-diff.json");
const DIFF_CACHE_TTL = 10; // 10 seconds — avoid repeated git diff on heavy repos
const KEYCHAIN_SERVICE = "Claude Code-credentials";
const USAGE_API = "https://api.anthropic.com/api/oauth/usage";
const BETA_HEADER = "oauth-2025-04-20";
const TZ = "Asia/Tokyo";

// Colors (true-color ANSI)
const GREEN = "\x1b[38;2;151;201;195m";
const YELLOW = "\x1b[38;2;229;192;123m";
const RED = "\x1b[38;2;224;108;117m";
const GREY = "\x1b[38;2;74;88;92m";
const RESET = "\x1b[0m";

// --- Helpers ---

function colorForPct(pct: number): string {
  if (pct >= 80) return RED;
  if (pct >= 50) return YELLOW;
  return GREEN;
}

function progressBar(pct: number): string {
  const filled = Math.round(Math.min(100, Math.max(0, pct)) / 10);
  return "▰".repeat(filled) + "▱".repeat(10 - filled);
}

function formatResetTime(isoStr: string, label: "5h" | "7d"): string {
  const d = new Date(isoStr);
  const opts: Intl.DateTimeFormatOptions = { timeZone: TZ };

  if (label === "5h") {
    const hour = d.toLocaleString("en-US", { ...opts, hour: "numeric", hour12: true });
    return `Resets ${hour} (${TZ})`;
  }
  const formatted = d.toLocaleString("en-US", {
    ...opts,
    month: "short",
    day: "numeric",
    hour: "numeric",
    hour12: true,
  });
  return `Resets ${formatted} (${TZ})`;
}

async function getGitBranch(cwd: string): Promise<string> {
  try {
    const { stdout } = await execFileAsync("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
      cwd,
      timeout: 500,
    });
    return stdout.trim();
  } catch {
    return "";
  }
}

async function getLineChanges(cwd: string): Promise<{ added: number; deleted: number }> {
  // Short-lived file cache to avoid running git diff on every statusline refresh
  try {
    const st = statSync(DIFF_CACHE_FILE);
    if ((Date.now() - st.mtimeMs) / 1000 <= DIFF_CACHE_TTL) {
      const cached = JSON.parse(readFileSync(DIFF_CACHE_FILE, "utf8"));
      if (cached.cwd === cwd) return { added: cached.added, deleted: cached.deleted };
    }
  } catch {
    /* cache miss — proceed to git */
  }

  try {
    const { stdout } = await execFileAsync("git", ["diff", "--numstat", "--no-renames", "HEAD"], {
      cwd,
      timeout: 1000,
    });
    let added = 0;
    let deleted = 0;
    for (const line of stdout.trim().split("\n")) {
      if (!line) continue;
      const [a, d] = line.split("\t");
      if (a !== "-") added += parseInt(a, 10) || 0;
      if (d !== "-") deleted += parseInt(d, 10) || 0;
    }
    try {
      mkdirSync(CACHE_DIR, { recursive: true, mode: 0o700 });
      writeFileSync(DIFF_CACHE_FILE, JSON.stringify({ cwd, added, deleted }), { mode: 0o600 });
    } catch {
      /* best effort */
    }
    return { added, deleted };
  } catch {
    return { added: 0, deleted: 0 };
  }
}

async function getOAuthToken(): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(
      "security",
      ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
      { timeout: 1000 },
    );
    let creds: unknown;
    try {
      creds = JSON.parse(stdout.trim());
    } catch {
      process.stderr.write(`[statusline] Keychain entry contains invalid JSON\n`);
      return null;
    }
    const tok = (creds as Record<string, unknown>)?.claudeAiOauth;
    const accessToken = (tok as Record<string, unknown>)?.accessToken;
    return typeof accessToken === "string" ? accessToken : null;
  } catch {
    // Keychain item not found — expected when not authenticated
    return null;
  }
}

function readCache(): UsageResponse | null {
  try {
    const st = statSync(CACHE_FILE);
    if ((Date.now() - st.mtimeMs) / 1000 > CACHE_TTL) return null;
    return JSON.parse(readFileSync(CACHE_FILE, "utf8")) as UsageResponse;
  } catch {
    try {
      unlinkSync(CACHE_FILE);
    } catch {
      /* file may not exist */
    }
    return null;
  }
}

function writeCache(data: UsageResponse): void {
  try {
    mkdirSync(CACHE_DIR, { recursive: true, mode: 0o700 });
    writeFileSync(CACHE_FILE, JSON.stringify(data), { mode: 0o600 });
  } catch (err: unknown) {
    process.stderr.write(
      `[statusline] Cache write failed: ${err instanceof Error ? err.message : err}\n`,
    );
  }
}

function isNegCached(): boolean {
  try {
    const st = statSync(NEG_CACHE_FILE);
    return (Date.now() - st.mtimeMs) / 1000 <= NEG_CACHE_TTL;
  } catch {
    return false;
  }
}

function writeNegCache(authError: boolean): void {
  try {
    mkdirSync(CACHE_DIR, { recursive: true, mode: 0o700 });
    writeFileSync(NEG_CACHE_FILE, JSON.stringify({ authError }), { mode: 0o600 });
  } catch {
    /* best effort */
  }
}

async function fetchUsage(): Promise<FetchResult> {
  const cached = readCache();
  if (cached) return { ok: true, data: cached };

  // Negative cache: skip API call if recent failure
  if (isNegCached()) {
    try {
      const neg = JSON.parse(readFileSync(NEG_CACHE_FILE, "utf8"));
      return { ok: false, authError: !!neg.authError };
    } catch {
      return { ok: false, authError: false };
    }
  }

  const token = await getOAuthToken();
  if (!token) return { ok: false, authError: false };

  try {
    const resp = await fetch(USAGE_API, {
      headers: {
        Authorization: `Bearer ${token}`,
        "anthropic-beta": BETA_HEADER,
      },
      signal: AbortSignal.timeout(1500),
    });
    if (!resp.ok) {
      const authError = resp.status === 401 || resp.status === 403;
      if (authError) {
        process.stderr.write(
          `[statusline] Usage API returned ${resp.status}: token may be expired\n`,
        );
      }
      writeNegCache(authError);
      return { ok: false, authError };
    }
    const data = (await resp.json()) as UsageResponse;
    if (data.five_hour || data.seven_day) writeCache(data);
    return { ok: true, data };
  } catch (err: unknown) {
    if (err instanceof SyntaxError) {
      process.stderr.write(`[statusline] Usage API returned invalid JSON\n`);
    }
    writeNegCache(false);
    return { ok: false, authError: false };
  }
}

function formatUsageLine(
  icon: string,
  label: string,
  bucket: UsageBucket | undefined,
  resetLabel: "5h" | "7d",
  authError: boolean,
): string {
  if (bucket) {
    const pct = Math.round(bucket.utilization);
    const col = colorForPct(pct);
    const bar = progressBar(pct);
    const reset = formatResetTime(bucket.resets_at, resetLabel);
    return `${icon} ${label}  ${col}${bar}  ${pct}%${RESET}  ${reset}`;
  }
  if (authError) {
    return `${icon} ${label}  ${RED}${progressBar(0)}  ⚠ Auth${RESET}`;
  }
  return `${icon} ${label}  ${GREY}${progressBar(0)}  N/A${RESET}`;
}

// --- Main ---

async function main(): Promise<void> {
  const timeout = setTimeout(() => {
    process.stderr.write("[statusline] Timed out after 2500ms\n");
    console.log("🤖 Claude");
    process.exit(0);
  }, 2500);

  process.stdin.setEncoding("utf8");
  let input = "";
  process.stdin.on("data", (chunk: string) => (input += chunk));

  await new Promise<void>((resolve) => process.stdin.on("end", resolve));

  try {
    const data: StatusLineInput = JSON.parse(input);
    const model = data.model?.display_name ?? "Claude";
    const cwd = data.workspace?.current_dir ?? ".";

    // Context usage (remaining -> used)
    const remaining = data.context_window?.remaining_percentage ?? 100;
    const contextPct = Math.max(0, 100 - remaining);

    // Run git commands and usage fetch in parallel
    const [branch, changes, usageResult] = await Promise.all([
      getGitBranch(cwd),
      getLineChanges(cwd),
      fetchUsage(),
    ]);

    const { added, deleted } = changes;
    const usage = usageResult.ok ? usageResult.data : undefined;
    const authError = !usageResult.ok && usageResult.authError;

    // --- Build Lines ---
    const sep = `${GREY} │ ${RESET}`;
    const ctxColor = colorForPct(contextPct);

    const dirName = basename(cwd);

    let line1 = `🤖 ${model}`;
    line1 += `${sep}📁 ${dirName}`;
    line1 += `${sep}${ctxColor}📊 ${contextPct}%${RESET}`;
    line1 += `${sep}✏️  +${added}/-${deleted}`;
    if (branch) {
      line1 += `${sep}🔀 ${branch}`;
    }

    const line2 = formatUsageLine("⏱", "5h", usage?.five_hour, "5h", authError);
    const line3 = formatUsageLine("📅", "7d", usage?.seven_day, "7d", authError);

    console.log(`${line1}\n${line2}\n${line3}`);
    clearTimeout(timeout);
    process.exit(0);
  } catch (err: unknown) {
    process.stderr.write(
      `[statusline] Error: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    console.log("🤖 Claude");
    clearTimeout(timeout);
    process.exit(0);
  }
}

main();
