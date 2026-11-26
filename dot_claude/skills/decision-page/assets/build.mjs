// 使い方: node build.mjs <data.json> <出力ディレクトリ>
// <id>.html は Artifact に公開する本文(Artifact が doctype・charset・viewport を被せる)。
// <id>.local.html は同じ本文に最小限の骨格(doctype・charset・viewport)を被せたもので、ローカルで開く・撮影するときに使う。
// 骨格が無いままローカルで開くと quirks mode になり、文字化けとスマホ幅の崩れが起きる。
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [dataPath, outDir] = process.argv.slice(2);
if (!dataPath || !outDir) {
  console.error("usage: node build.mjs <data.json> <out-dir>");
  process.exit(2);
}
const assetsDir = path.dirname(fileURLToPath(import.meta.url));
const template = fs.readFileSync(path.join(assetsDir, "template.html"), "utf8");
const serializeSrc = fs.readFileSync(path.join(assetsDir, "serialize.js"), "utf8");
const data = JSON.parse(fs.readFileSync(dataPath, "utf8"));

// テンプレートの実行時には検査しないので、壊れたデータはここで日本語の理由つきで止める。
function validate(data) {
  const missing = ["id", "title", "source", "context", "questions"].filter((k) => !data[k]);
  if (missing.length) return [`data に必須のキーがありません: ${missing.join(", ")}`];
  if (!Array.isArray(data.questions) || data.questions.length === 0)
    return ["questions は 1 つ以上の問いの配列にする"];
  const errors = [];
  const questionIds = new Set();
  const optionIds = new Map();
  for (const q of data.questions) {
    if (questionIds.has(q.id)) errors.push(`${q.id}: 問いの id が重複している`);
    questionIds.add(q.id);
    if (!Array.isArray(q.options) || q.options.length === 0) {
      errors.push(`${q.id}: options は 1 つ以上の選択肢の配列にする`);
      continue;
    }
    const ids = q.options.map((o) => o.id);
    optionIds.set(q.id, new Set(ids));
    if (new Set(ids).size !== ids.length) errors.push(`${q.id}: 選択肢の id が重複している`);
    // "other" はテンプレートが足す「その他(自由記述)」の id
    if (ids.includes("other")) errors.push(`${q.id}: 選択肢の id に other は使えない`);
    if (q.options.filter((o) => o.recommended).length > 1)
      errors.push(`${q.id}: 推奨は 1 問に 1 つまで`);
  }
  const html = `${data.diagram || ""}${data.evidence || ""}`;
  for (const [, , when] of html.matchAll(/data-when=(["'])(.*?)\1/g)) {
    for (const cond of when.split(/\s+/).filter(Boolean)) {
      const [qid, oid] = cond.split(":");
      if (!optionIds.get(qid)?.has(oid))
        errors.push(`data-when の ${cond} が、どの問いの選択肢も指していない`);
    }
  }
  return errors;
}
const errors = validate(data);
if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
// script 要素の中身は </script> や <!-- で途中から解釈が変わるので、< をすべて JSON の escape にする
const page = template
  .replace("/*TITLE*/", () => esc(data.title))
  .replace("/*DATA*/", () => JSON.stringify(data).replace(/</g, "\\u003c"))
  .replace("/*SERIALIZE*/", () => serializeSrc);
const skeleton = (body) =>
  `<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><style>:root{color-scheme:light}body{margin:0}[hidden]{display:none!important}</style>\n${body}\n</body></html>`;

fs.mkdirSync(outDir, { recursive: true });
const artifact = path.join(outDir, `${data.id}.html`);
const local = path.join(outDir, `${data.id}.local.html`);
fs.writeFileSync(artifact, page);
fs.writeFileSync(local, skeleton(page));
console.log(`${artifact}\n${local}`);
