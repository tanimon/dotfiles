import fs from "node:fs";
import path from "node:path";
import { selectFeatures } from "../support/run";

export interface SeedModule {
  setup?: () => Promise<void>;
  cleanup?: () => Promise<void>;
}

const featuresDir = path.join(__dirname, "features");

function availableFeatures(): string[] {
  if (!fs.existsSync(featuresDir)) return [];
  return fs
    .readdirSync(featuresDir)
    .filter((file) => file.endsWith(".ts"))
    .map((file) => file.slice(0, -".ts".length))
    .sort();
}

// 向き先ガード。seed はデータを作成・削除するため、既定ではローカル以外を拒否する。
// シナリオの誤りは再実行で直るが、共有環境のデータを壊すと復旧できないため、
// リモートへ向けるのはユーザーが承認した明示的な opt-in(VERIFY_ALLOW_REMOTE=1)に限る。
// globalSetup で throw しても Playwright は globalTeardown を実行するので、setup.ts ではなく
// setup と cleanup の両方が通る loadSeedModules() で判定する
function assertLocalTarget(): void {
  const baseUrl = process.env.VERIFY_BASE_URL ?? "";
  // "localhost:8080" のようにスキームを省くと "localhost:" がスキームとして解釈され例外にならないため、
  // http(s) 以外も解釈できなかったものとして扱う
  let url: URL | undefined;
  try {
    url = new URL(baseUrl);
  } catch {
    url = undefined;
  }
  if (url?.protocol !== "http:" && url?.protocol !== "https:") {
    throw new Error(
      `VERIFY_BASE_URL が URL として解釈できません(http:// か https:// から指定してください): ${baseUrl}`,
    );
  }
  const hostname = url.hostname;
  const isLocal =
    hostname === "localhost" ||
    hostname === "127.0.0.1" ||
    hostname === "[::1]" ||
    hostname.endsWith(".localhost");
  if (!isLocal && process.env.VERIFY_ALLOW_REMOTE !== "1") {
    throw new Error(
      `VERIFY_BASE_URL がローカル以外(${hostname})を向いています。` +
        `このスイートはデータを変更します。共有環境に対して実行する意図がある場合のみ VERIFY_ALLOW_REMOTE=1 を設定してください`,
    );
  }
}

// seed/common.ts と、今回の機能の seed/features/<feature>.ts をこの順で返す。
// 機能ごとに分けるのは、未マージの別機能の seed(まだ無いテーブルやカラムを前提にする)を
// 今のブランチで流さないため
export async function loadSeedModules(): Promise<SeedModule[]> {
  assertLocalTarget();
  const modules: SeedModule[] = [(await import("./common")) as SeedModule];
  for (const name of selectFeatures(availableFeatures())) {
    const file = path.join(featuresDir, `${name}.ts`);
    if (fs.existsSync(file)) modules.push((await import(file)) as SeedModule);
  }
  return modules;
}
