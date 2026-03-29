import { execFile } from "child_process";
import { readFileSync, writeFileSync, statSync, mkdirSync } from "fs";
import { homedir } from "os";
import { basename, join } from "path";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

// --- Types ---

interface RateLimitBucket {
  used_percentage: number;
  resets_at: number; // Unix epoch seconds
}

interface StatusLineInput {
  model?: { display_name?: string };
  workspace?: { current_dir?: string; added_dirs?: string[] };
  session_id?: string;
  context_window?: { remaining_percentage?: number };
  transcript_path?: string;
  rate_limits?: {
    five_hour?: RateLimitBucket;
    seven_day?: RateLimitBucket;
  };
}

// --- Constants ---

const CACHE_DIR = join(homedir(), ".claude", "cache");
const DIFF_CACHE_FILE = join(CACHE_DIR, "git-diff.json");
const DIFF_CACHE_TTL = 10; // 10 seconds — avoid repeated git diff on heavy repos
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

function formatResetTime(epochSec: number, label: "5h" | "7d"): string {
  const d = new Date(epochSec * 1000);
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

function formatUsageLine(
  icon: string,
  label: string,
  bucket: RateLimitBucket | undefined,
  resetLabel: "5h" | "7d",
): string {
  if (
    bucket &&
    typeof bucket.used_percentage === "number" &&
    typeof bucket.resets_at === "number"
  ) {
    const pct = Math.round(bucket.used_percentage);
    const col = colorForPct(pct);
    const bar = progressBar(pct);
    const reset = bucket.resets_at > 0 ? formatResetTime(bucket.resets_at, resetLabel) : "";
    return `${icon} ${label}  ${col}${bar}  ${pct}%${RESET}${reset ? `  ${reset}` : ""}`;
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

    // Run git commands in parallel
    const [branch, changes] = await Promise.all([getGitBranch(cwd), getLineChanges(cwd)]);

    const { added, deleted } = changes;
    const rateLimits = data.rate_limits;

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

    const line2 = formatUsageLine("⏱", "5h", rateLimits?.five_hour, "5h");
    const line3 = formatUsageLine("📅", "7d", rateLimits?.seven_day, "7d");

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
