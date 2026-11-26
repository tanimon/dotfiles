// decision-page skill の貼り戻しの形(SKILL.md の「貼り戻しを読む」が前提にしているもの)と、
// build.mjs のデータ検査を確かめる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ASSETS = fileURLToPath(
  new URL("../dot_claude/skills/decision-page/assets/", import.meta.url),
);
const { serializeDecision } = createRequire(import.meta.url)(path.join(ASSETS, "serialize.js"));
const example = JSON.parse(readFileSync(path.join(ASSETS, "example.json"), "utf8"));

const data = {
  id: "t-1",
  title: "題",
  source: "#1",
  context: "前提",
  questions: [
    {
      id: "Q1",
      label: "一",
      options: [
        { id: "A", label: "甲", recommended: true },
        { id: "B", label: "乙" },
      ],
    },
    {
      id: "Q2",
      label: "二",
      options: [
        { id: "A", label: "丙" },
        { id: "B", label: "丁", recommended: true },
      ],
    },
    {
      id: "Q3",
      label: "三",
      options: [
        { id: "A", label: "戊" },
        { id: "B", label: "己" },
      ],
    },
  ],
};

test("各行に選んだ案と推奨案のラベルが載り、末尾に回答数が付く", () => {
  const out = serializeDecision(data, {
    Q1: { choice: "B" },
    Q2: { choice: "B" },
    Q3: { choice: "other", text: "一行目\n二行目", note: "補足" },
  });
  assert.equal(
    out,
    [
      "判断結果 t-1「題」(#1)",
      "Q1 一 → B「乙」 (推奨は A「甲」)",
      "Q2 二 → B「丁」 (推奨どおり)",
      "Q3 三 → その他(自由記述)",
      "  記述: 一行目",
      "    二行目",
      "  補足: 補足",
      "回答 3/3 問",
    ].join("\n"),
  );
});

test("記述が空の「その他」は未回答として出て、回答数に数えない", () => {
  const out = serializeDecision(data, { Q1: { choice: "other", text: "  " }, Q2: { choice: "A" } });
  assert.match(out, /^Q1 一 → 未回答 \(推奨は A「甲」\)$/m);
  assert.match(out, /^Q3 三 → 未回答$/m);
  assert.match(out, /回答 1\/3 問$/);
});

test("他の案を選んでいるあいだは、残っている記述を出さない", () => {
  const out = serializeDecision(data, { Q1: { choice: "A", text: "前に書いた記述" } });
  assert.doesNotMatch(out, /前に書いた記述/);
});

function build(input, dir = mkdtempSync(path.join(tmpdir(), "decision-page-"))) {
  const dataPath = path.join(dir, "data.json");
  writeFileSync(dataPath, JSON.stringify(input));
  const r = spawnSync(
    process.execPath,
    [path.join(ASSETS, "build.mjs"), dataPath, path.join(dir, "out")],
    {
      encoding: "utf8",
    },
  );
  return { ...r, out: path.join(dir, "out") };
}

test("見本のデータから Artifact 用とローカル用の 2 ページを作る", () => {
  const r = build(example);
  assert.equal(r.status, 0, r.stderr);
  const artifact = readFileSync(path.join(r.out, `${example.id}.html`), "utf8");
  assert.match(artifact, /^<title>/);
  assert.ok(
    !/<(html|head|body)[\s>]/.test(artifact),
    "Artifact 用に html/head/body の開始タグがある",
  );
  assert.match(
    readFileSync(path.join(r.out, `${example.id}.local.html`), "utf8"),
    /^<!doctype html>/,
  );
});

test("埋め込んだデータは </script> や <!-- を含んでも元のまま読み戻せる", () => {
  const input = { ...example, evidence: "<!--<script></script>--><table></table>" };
  const r = build(input);
  assert.equal(r.status, 0, r.stderr);
  const html = readFileSync(path.join(r.out, `${example.id}.html`), "utf8");
  const json = html.match(
    /<script id="decision-data" type="application\/json">(.*?)<\/script>/s,
  )[1];
  // HTML の構文解析は script の中身でも <!-- と </script で状態を変えるので、< が 1 つでも残ると途中で切れうる
  assert.ok(!json.includes("<"), "埋め込んだデータに < が残っている");
  assert.deepEqual(JSON.parse(json), input);
});

test("空白を含むパスに置いた skill でも組み立てられる", () => {
  const root = mkdtempSync(path.join(tmpdir(), "decision page "));
  cpSync(ASSETS, path.join(root, "assets"), { recursive: true });
  const dataPath = path.join(root, "data.json");
  writeFileSync(dataPath, JSON.stringify(example));
  const r = spawnSync(
    process.execPath,
    [path.join(root, "assets", "build.mjs"), dataPath, path.join(root, "out")],
    {
      encoding: "utf8",
    },
  );
  assert.equal(r.status, 0, r.stderr);
});

const q = (id, options) => ({ id, label: id, options });
const broken = [
  [
    "推奨が 2 つある",
    {
      questions: [
        q("Q1", [
          { id: "A", recommended: true },
          { id: "B", recommended: true },
        ]),
      ],
    },
    /推奨は 1 問に 1 つまで/,
  ],
  [
    "選択肢の id が other",
    { questions: [q("Q1", [{ id: "A" }, { id: "other" }])] },
    /other は使えない/,
  ],
  [
    "問いの id が重複",
    { questions: [q("Q1", [{ id: "A" }]), q("Q1", [{ id: "A" }])] },
    /問いの id が重複/,
  ],
  ["選択肢が無い", { questions: [{ id: "Q1", label: "Q1" }] }, /options は 1 つ以上/],
  [
    "data-when が無い選択肢を指す",
    { questions: [q("Q1", [{ id: "A" }])], diagram: '<path data-when="Q1:A Q2:B"/>' },
    /Q2:B が、どの問いの選択肢も指していない/,
  ],
];
for (const [name, patch, message] of broken) {
  test(`壊れたデータは理由を出して止める: ${name}`, () => {
    const r = build({ ...example, diagram: undefined, ...patch });
    assert.equal(r.status, 1);
    assert.match(r.stderr, message);
    assert.doesNotMatch(r.stderr, /TypeError/);
  });
}
