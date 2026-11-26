// 使い方: node build.mjs <data.json> <出力ディレクトリ>
// <id>.html は Artifact に公開する本文(Artifact が doctype・charset・viewport を被せる)。
// <id>.local.html は同じ本文に同等の骨格を被せたもので、ローカルで開く・撮影するときに使う。
// 骨格が無いままローカルで開くと quirks mode になり、文字化けとスマホ幅の崩れが起きる。
import fs from "node:fs";
import path from "node:path";

const [dataPath, outDir] = process.argv.slice(2);
if (!dataPath || !outDir) {
  console.error("usage: node build.mjs <data.json> <out-dir>");
  process.exit(2);
}
const here = path.dirname(new URL(import.meta.url).pathname);
const tpl = fs.readFileSync(path.join(here, "template.html"), "utf8");
const ser = fs
  .readFileSync(path.join(here, "serialize.js"), "utf8")
  .replace(/^if \(typeof module.*$/m, "");
const data = JSON.parse(fs.readFileSync(dataPath, "utf8"));

const missing = ["id", "title", "source", "context", "questions"].filter((k) => !data[k]);
if (missing.length) {
  console.error(`data に必須のキーがありません: ${missing.join(", ")}`);
  process.exit(1);
}
for (const q of data.questions) {
  if (q.options.filter((o) => o.recommended).length > 1) {
    console.error(`${q.id}: 推奨は 1 問に 1 つまで`);
    process.exit(1);
  }
}

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
const page = tpl
  .replace("/*TITLE*/", () => esc(data.title))
  .replace("/*DATA*/", () => JSON.stringify(data).replace(/<\//g, "<\\/"))
  .replace("/*SERIALIZE*/", () => ser);
const skeleton = (body) =>
  `<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><style>:root{color-scheme:light}body{margin:0}[hidden]{display:none!important}</style>\n${body}\n</body></html>`;

fs.mkdirSync(outDir, { recursive: true });
const artifact = path.join(outDir, `${data.id}.html`);
const local = path.join(outDir, `${data.id}.local.html`);
fs.writeFileSync(artifact, page);
fs.writeFileSync(local, skeleton(page));
console.log(`${artifact}\n${local}`);
