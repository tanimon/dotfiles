#!/usr/bin/env node
// git 管理下の Markdown の相対リンクが、git 管理下のファイルかディレクトリを指していなければ落とす。
//
// 見るリンク: インラインリンク `[t](dest)`(`<dest>` の形と、括弧 1 段を含む dest を含む)と、
// 参照形式の定義 `[label]: dest`。HTML の `<a href>` と脚注の定義(`[^n]:`)は見ない。
// リンク先の解決:
//   - `/` で始まるリンクはリポジトリルートから(GitHub の表示と同じ)
//   - harness/modules/ の下のファイルはリポジトリルートから。モジュールはルートの CLAUDE.md / AGENTS.md に
//     合成される前提で書かれているため(harness/project.json)
//   - それ以外はリンクを書いたファイルのディレクトリから
// 「git 管理下」は index にあって作業ツリーからも消していないもの。リポジトリルート自体も含む。
// URL(`https:` など scheme 付き)、ページ内アンカー(`#...`)、コードスパンとコードブロック(リストの中で
// インデントしたフェンスを含む)の中は見ない。アンカーの見出しが実在するかは見ない。
//
// 使い方: check-md-links.mjs [dir]
//   dir を省くとカレントディレクトリの git リポジトリを検査する。dir は git リポジトリのルートであること。
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";

const root = path.resolve(process.argv[2] ?? ".");
function gitFiles(...args) {
  return execFileSync("git", ["-C", root, "ls-files", "-z", ...args], { encoding: "utf8" })
    .split("\0")
    .filter(Boolean);
}
// 作業ツリーから消したが index に残っているファイルは、リンク元からもリンク先からも外す。
// 消したファイルへのリンクを、git rm の前でも落とすため。
const deleted = new Set(gitFiles("--deleted"));
const tracked = gitFiles().filter((f) => !deleted.has(f));

const known = new Set(["."]);
for (const file of tracked) {
  known.add(file);
  for (let dir = path.posix.dirname(file); dir !== "."; dir = path.posix.dirname(dir)) {
    known.add(dir);
  }
}

const ROOT_RELATIVE_PREFIX = "harness/modules/";

const INLINE_LINK =
  /\]\(\s*(?:<([^>\n]*)>|((?:[^()\s]|\([^()\s]*\))+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/g;
const REFERENCE_DEFINITION = /^ {0,3}\[(?!\^)[^\]\n]+\]:[ \t]*(?:<([^>\n]*)>|(\S+))/gm;

function stripCode(text) {
  return text
    .replace(/^[ \t]*(`{3,}|~{3,})[^\n]*\n[\s\S]*?^[ \t]*\1[^\n]*$/gm, "")
    .replace(/`[^`\n]*`/g, "");
}

// `%` の後が 16 進でない dest(`50%-off.md`)は decodeURI が投げるので、書かれたままのパスとして扱う
function decodePath(target) {
  try {
    return decodeURI(target);
  } catch {
    return target;
  }
}

function resolveTarget(file, target) {
  const decoded = decodePath(target);
  if (decoded.startsWith("/")) return path.posix.normalize(decoded.slice(1));
  if (file.startsWith(ROOT_RELATIVE_PREFIX)) return path.posix.normalize(decoded);
  return path.posix.normalize(path.posix.join(path.posix.dirname(file), decoded));
}

const broken = [];
for (const file of tracked.filter((f) => f.endsWith(".md"))) {
  const text = stripCode(readFileSync(path.join(root, file), "utf8"));
  const matches = [...text.matchAll(INLINE_LINK), ...text.matchAll(REFERENCE_DEFINITION)];
  for (const match of matches) {
    const dest = match[1] ?? match[2];
    const target = dest.split("#")[0];
    if (target === "" || /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(target)) continue;
    const resolved = resolveTarget(file, target).replace(/\/$/, "");
    if (!known.has(resolved)) broken.push(`${file}: ${dest} -> ${resolved}`);
  }
}

if (broken.length > 0) {
  console.log(
    "FAIL: Markdown links point to paths that are not tracked by git (fix the link, or restore the file it names):",
  );
  for (const line of broken) console.log(`  ${line}`);
  process.exit(1);
}
console.log("PASS: every relative Markdown link points to a tracked path");
