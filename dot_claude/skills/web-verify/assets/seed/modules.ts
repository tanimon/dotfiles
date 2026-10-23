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
  const baseUrl = process.env.VERIFY_BASE_URL;
  // setup.ts の未設定検出で止まった後も globalTeardown はここを通るため、同じ文言で止める
  // (「URL として解釈できません」を出すと原因を取り違える)
  if (!baseUrl) {
    throw new Error("VERIFY_BASE_URL を .env に設定するか、実行時に渡してください");
  }
  // "localhost:8080" のようにスキームを省くと "localhost:" がスキームとして解釈され例外にならないため、
  // http(s) 以外も解釈できなかったものとして扱う
  let url: URL | undefined;
  try {
    url = new URL(baseUrl);
  } catch {
    // 解釈できなかったものは url が undefined のまま次の検査で止める
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
// 今のブランチで流さないため。
// import() ではなく require() で読む: module.registerHooks の無い Node(22.15.0 / 23.5.0 より前)では Playwright が
// 非同期の ESM ローダーで TS を変換し、"type" 指定の無いこのスイートの .ts を import() すると変換されずに
// 読まれて SyntaxError になる。require() は同期・非同期どちらのローダーの経路でも Playwright の CJS 側の変換を通る
export async function loadSeedModules(): Promise<SeedModule[]> {
  assertLocalTarget();
  const modules: SeedModule[] = [require("./common") as SeedModule];
  for (const name of selectFeatures(availableFeatures())) {
    const file = path.join(featuresDir, `${name}.ts`);
    if (fs.existsSync(file)) modules.push(require(file) as SeedModule);
  }
  return modules;
}
