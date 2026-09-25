export const meta = {
  name: "deliver",
  description: "plan を実装し、レビュー修正ループと動作確認を経て draft PR と人間への報告を作る",
  whenToUse: "入口 skill /deliver から起動する。直接起動しない",
  phases: [
    { title: "Plan" },
    { title: "Implement" },
    { title: "Review" },
    { title: "Verify" },
    { title: "Publish" },
  ],
};

// 判定はここに置いたコードで行い、agent にはさせない(ADR 0007)。
const DEFAULTS = { maxReviewRounds: 3, maxVerifyRetries: 2 };
const BUDGET_FLOOR = 100000;

// built-in の code-review は fork 型の skill で、Workflow のエージェントから Skill で呼ぶと
// 本文が返らず別エージェントとして起動するだけなので使えない(2026-09-25 実測。spec の「試作で実測すること」)。
const REVIEWERS = [
  {
    id: "ecc",
    skill: "ecc-code-review",
    severities: ["CRITICAL", "HIGH", "MEDIUM", "LOW"],
    blocking: ["CRITICAL", "HIGH"],
  },
  {
    id: "requesting",
    skill: "superpowers:requesting-code-review",
    severities: ["Critical", "Important", "Minor"],
    blocking: ["Critical", "Important"],
  },
];

const STOP_REASONS = {
  "plan-unreadable": "plan からタスクを抽出できなかった",
  "implement-blocked": "実装タスクが続行不能になった",
  "checks-failing": "テスト/lint が通らないままになった",
  "reviewers-failed": "レビュアーが全員結果を返さなかった",
  "merge-failed": "指摘の統合に失敗した",
  "fixer-failed": "修正エージェントが結果を返さなかった",
  "plan-breaking": "plan どおりに作ると壊れる Plan Concern が出た",
  budget: "トークン予算の残りが少ないため、次のラウンドに入らなかった",
  error: "エージェントの実行中に例外が発生した",
};

const STRINGS = { type: "array", items: { type: "string" } };

const PLAN_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string" },
    tasks: {
      type: "array",
      items: {
        type: "object",
        properties: { title: { type: "string" }, summary: { type: "string" } },
        required: ["title", "summary"],
      },
    },
  },
  required: ["title", "tasks"],
};

const IMPLEMENT_SCHEMA = {
  type: "object",
  properties: {
    status: { type: "string", enum: ["done", "blocked"] },
    reason: { type: "string" },
    commit: { type: "string" },
    observations: STRINGS,
  },
  required: ["status"],
};

const CHECKS_SCHEMA = {
  type: "object",
  properties: { passed: { type: "boolean" }, details: { type: "string" }, observations: STRINGS },
  required: ["passed"],
};

const reviewSchema = (reviewer) => ({
  type: "object",
  properties: {
    findings: {
      type: "array",
      items: {
        type: "object",
        properties: {
          file: { type: "string" },
          line: { type: "integer" },
          summary: { type: "string" },
          severity: { type: "string", enum: reviewer.severities },
          target: { type: "string", enum: ["code", "plan"] },
          planBreaking: { type: "boolean" },
        },
        required: ["file", "summary", "severity", "target"],
      },
    },
    observations: STRINGS,
  },
  required: ["findings"],
});

const MERGE_SCHEMA = {
  type: "object",
  properties: {
    clusters: {
      type: "array",
      items: {
        type: "object",
        properties: {
          key: { type: "string" },
          file: { type: "string" },
          line: { type: "integer" },
          summary: { type: "string" },
          target: { type: "string", enum: ["code", "plan"] },
          planBreaking: { type: "boolean" },
          members: STRINGS,
        },
        required: ["key", "file", "summary", "target", "members"],
      },
    },
  },
  required: ["clusters"],
};

const FIX_SCHEMA = {
  type: "object",
  properties: {
    results: {
      type: "array",
      items: {
        type: "object",
        properties: {
          key: { type: "string" },
          action: { type: "string", enum: ["fixed", "propose-defer"] },
          reason: { type: "string" },
        },
        required: ["key", "action"],
      },
    },
    observations: STRINGS,
  },
  required: ["results"],
};

const VERDICT_SCHEMA = {
  type: "object",
  properties: { agree: { type: "boolean" }, reason: { type: "string" } },
  required: ["agree", "reason"],
};

const VERIFY_SCHEMA = {
  type: "object",
  properties: { passed: { type: "boolean" }, summary: { type: "string" }, observations: STRINGS },
  required: ["passed", "summary"],
};

const FIX_VERIFY_SCHEMA = {
  type: "object",
  properties: { fixed: { type: "boolean" }, summary: { type: "string" }, observations: STRINGS },
  required: ["fixed", "summary"],
};

const PUBLISH_SCHEMA = {
  type: "object",
  properties: {
    pushed: { type: "boolean" },
    prUrl: { type: "string" },
    ledgerPath: { type: "string" },
    error: { type: "string" },
  },
  required: ["pushed"],
};

function validateArgs(input) {
  const a = input || {};
  const missing = [];
  if (typeof a.planPath !== "string" || a.planPath === "") missing.push("planPath");
  if (typeof a.baseRef !== "string" || a.baseRef === "") missing.push("baseRef");
  if (!Array.isArray(a.checkCommands) || a.checkCommands.length === 0)
    missing.push("checkCommands");
  if (typeof a.verifySkill !== "string" || a.verifySkill === "") missing.push("verifySkill");
  if (missing.length > 0) {
    throw new Error(
      `deliver: 必須の引数がありません: ${missing.join(", ")}(入口 skill /deliver から起動してください)`,
    );
  }
  // 上限はループを止める唯一の保証なので、不正な値を既定値で黙って置き換えずに拒否する。
  const invalid = ["maxReviewRounds", "maxVerifyRetries"].filter(
    (k) => a[k] !== undefined && !(Number.isInteger(a[k]) && a[k] >= 0),
  );
  if (invalid.length > 0) {
    throw new Error(`deliver: 0 以上の整数が必要です: ${invalid.join(", ")}`);
  }
  const config = { ...DEFAULTS, ...a };
  if (!config.prBase) config.prBase = config.baseRef.replace(/^origin\//, "");
  return config;
}

function newState(config) {
  return {
    config,
    title: "",
    rounds: [],
    unresolved: [],
    unresolvedKeys: new Set(),
    deferred: [],
    deferredKeys: new Set(),
    planConcerns: [],
    advisory: [],
    knownClusters: [],
    rejectedDeferrals: {},
    closedRepeats: [],
    lastMissingReviewers: [],
    verification: [],
    observations: [],
    reviewerFailures: [],
    stopReason: null,
    stopDetail: "",
    outputTokens: 0,
  };
}

function collectObservations(state, source, result) {
  if (!result || !Array.isArray(result.observations)) return;
  for (const o of result.observations) state.observations.push(`${source}: ${o}`);
}

function isBlocking(finding) {
  const reviewer = REVIEWERS.find((r) => r.id === finding.reviewer);
  return Boolean(reviewer && reviewer.blocking.includes(finding.severity));
}

// target と planBreaking は merge の申告ではなく元の指摘(members)から導く。merge に任せるのは
// 重複をまとめることだけで、判定の入力にはしない(ADR 0007)。
// closedKeys(Deferred / Unresolved 済み)に統合された修正必須指摘は、判定から外すが報告には残す。
function classifyRound(clusters, findingsById, previousBlockingKeys, closedKeys) {
  const out = {
    blocking: [],
    repeated: [],
    planConcerns: [],
    planBreaking: [],
    advisory: [],
    closedRepeats: [],
    dropped: [],
  };
  for (const c of clusters) {
    const members = c.members.map((id) => findingsById[id]).filter(Boolean);
    if (members.length === 0) {
      out.dropped.push(c.key);
      continue;
    }
    const toItem = (key, ms) => ({
      key,
      file: c.file,
      line: c.line,
      summary: c.summary,
      severities: ms.map((m) => `${m.reviewer}:${m.severity}`),
      findings: ms.map((m) => m.summary),
    });
    const planMembers = members.filter((m) => m.target === "plan");
    const codeMembers = members.filter((m) => m.target !== "plan");
    if (planMembers.length > 0) {
      const item = toItem(codeMembers.length > 0 ? `${c.key}::plan` : c.key, planMembers);
      out.planConcerns.push(item);
      if (planMembers.some((m) => m.planBreaking)) out.planBreaking.push(item);
    }
    if (codeMembers.length === 0) continue;
    const item = toItem(c.key, codeMembers);
    if (closedKeys.has(c.key)) {
      if (codeMembers.some(isBlocking)) out.closedRepeats.push(item);
      continue;
    }
    if (!codeMembers.some(isBlocking)) out.advisory.push(item);
    else if (previousBlockingKeys.has(c.key)) out.repeated.push(item);
    else out.blocking.push(item);
  }
  return out;
}

function uniqueByKey(items) {
  const seen = new Set();
  return items.filter((i) => (seen.has(i.key) ? false : (seen.add(i.key), true)));
}

function markUnresolved(state, items) {
  for (const item of items) {
    if (state.unresolvedKeys.has(item.key)) continue;
    state.unresolvedKeys.add(item.key);
    state.unresolved.push(item);
  }
}

const commands = (config) => config.checkCommands.map((c) => `「${c}」`).join("、");

function planPrompt(config) {
  return `plan ファイル ${config.planPath} を読み、実装タスクの一覧を抽出せよ。
- plan の順序どおりに、plan の1タスクを1要素とする。独自に分割・統合しない。
- title は、この plan 全体を表す PR タイトルとして使える短い日本語にする。
- plan が実装計画でない(タスク分解が無い)なら、tasks を空配列で返す。`;
}

function implementPrompt(task, index, total, config) {
  return `plan ${config.planPath} のタスク ${index + 1}/${total}「${task.title}」を実装せよ。plan を読み、このタスクの範囲だけを実装する。
- TDD で進める。失敗するテストを先に書き、失敗を確認してから実装する。
- 完了する前に、次のコマンドを全て実行して全て成功させる: ${commands(config)}
- 完了したら変更をコミットする(push はしない)。コミットメッセージはリポジトリの既存の規約に従う。
- plan どおりに進められない(前提が崩れている、plan が矛盾している)場合は、推測で埋めずに status="blocked" と理由を返す。
- タスクの範囲外で気づいた問題は observations に書く(直さない)。`;
}

function checksPrompt(config) {
  return `次のコマンドを全て実行せよ: ${commands(config)}
- 失敗があれば原因を直してコミットし(push はしない)、全て成功するまで繰り返す。
- テストを消す・スキップする・lint を無効化するなど、検査そのものを弱める変更はしない。
- 3回試しても直らなければ、passed=false と失敗内容を返す。`;
}

function reviewPrompt(reviewer, config) {
  return `Skill ツールで「${reviewer.skill}」を読み込み、その手順に従って「${config.baseRef}...HEAD」の差分をレビューせよ。
- 要件は plan ${config.planPath}。plan とのずれも指摘の対象にする。
- ファイルの修正、コミット、PR へのコメント投稿、ReportFindings ツールの呼び出しはしない。結果は StructuredOutput だけで返す。
- severity には skill 自身の尺度をそのまま使う: ${reviewer.severities.join(" / ")}
- 指摘が実装ではなく plan そのものに向く場合は target="plan" とし、plan どおりに作ると壊れる場合だけ planBreaking=true にする。
- レビューの範囲外で気づいた問題は observations に書く。`;
}

function mergePrompt(findings, knownClusters) {
  return `複数のレビュアーの指摘を統合せよ。指摘(JSON): ${JSON.stringify(findings)}
- 同じ問題を指す指摘は1つの cluster にまとめ、members に元の id を全て入れる。どの指摘も必ずちょうど1つの cluster に入れる。
- key は「ファイルパス::問題の種類を表す英小文字の短いスラッグ」とする(例: src/a.ts::missing-null-check)。
- 過去のラウンドに同じ問題があれば、その key をそのまま使う。過去の cluster(JSON): ${JSON.stringify(knownClusters)}
- target は、members のいずれかが "plan" なら "plan"、それ以外は "code"。planBreaking は、members のいずれかが true なら true。
- summary は日本語の1文で書く。`;
}

function fixPrompt(items, config) {
  return `次の修正必須の指摘に対応せよ。plan は ${config.planPath}、対象の差分は「${config.baseRef}...HEAD」。
指摘(JSON): ${JSON.stringify(items)}
- 指摘ごとに、修正したら action="fixed"、修正すべきでない(偽陽性、または plan の範囲外)と判断したら action="propose-defer" と具体的な理由を返す。直すのが大変だという理由では見送らない。
- deferralRejectedReason がある指摘は、見送りの提案が検証者に却下されている。その理由を読んだうえで修正する。
- 修正した後、次のコマンドを全て成功させる: ${commands(config)}
- 修正をまとめて1コミットにする(push はしない)。
- 指摘の範囲外で気づいた問題は observations に書く。`;
}

function deferPrompt(item, reason, config) {
  return `あなたは独立した検証者である。実装者は、次の指摘を修正せずに見送ることを提案している。
指摘(JSON): ${JSON.stringify(item)}
実装者の理由: ${reason}
plan は ${config.planPath}、差分は「${config.baseRef}...HEAD」。コードと plan を自分で読み、見送りが妥当か判断せよ。妥当なのは、指摘が偽陽性であるか、plan の範囲外である場合だけ。判断に迷うなら agree=false とする。`;
}

function verifyPrompt(config) {
  return `Skill ツールで「${config.verifySkill}」を読み込み、その手順に従って、plan ${config.planPath} の変更が意図どおりに動くことを確認せよ。
- 確認した操作と観察した結果を summary に書き、意図どおりに動けば passed=true にする。
- コードは修正しない。範囲外で気づいた問題は observations に書く。`;
}

function fixVerifyPrompt(result, config) {
  return `動作確認が失敗した。結果(JSON): ${JSON.stringify(result)}
plan は ${config.planPath}。原因を調べて直し、次のコマンドを全て成功させてから1コミットにせよ(push はしない): ${commands(config)}`;
}

function ledgerJson(state) {
  return JSON.stringify(
    { ...state, unresolvedKeys: [...state.unresolvedKeys], deferredKeys: [...state.deferredKeys] },
    null,
    2,
  );
}

function publishPrompt(state, report) {
  return `次の手順で公開せよ。
1. 「git rev-parse --absolute-git-dir」の出力を D とする。D/deliver/ を作り、下の REPORT を D/deliver/pr-body.md に、下の LEDGER を D/deliver/ledger.json に、そのまま書き出す。
2. 現在のブランチを push する(force push はしない)。
3. このブランチの PR が無ければ「gh pr create --draft --base ${state.config.prBase} --title <TITLE> --body-file D/deliver/pr-body.md」で作る。既にあれば「gh pr edit --body-file D/deliver/pr-body.md」で本文を更新する。
4. PR の URL と ledger の絶対パスを返す。どこかで失敗したら pushed=false と error を返す。

TITLE: ${state.title || "deliver"}

REPORT:
<<<REPORT
${report}
REPORT

LEDGER:
<<<LEDGER
${ledgerJson(state)}
LEDGER`;
}

function formatItem(item) {
  const location = item.line ? `${item.file}:${item.line}` : item.file;
  return `\`${location}\` ${item.summary} [${item.severities.join(", ")}]`;
}

function renderReport(state) {
  const lines = [];
  const pushSection = (title, items, format) => {
    lines.push(`## ${title}`, "");
    if (items.length === 0) lines.push("なし");
    else for (const item of items) lines.push(`- ${format(item)}`);
    lines.push("");
  };
  const pushVerification = () => {
    lines.push("## 動作確認", "");
    if (state.config.verifySkill === "none") lines.push("指定なし(テスト/lint のみ)");
    else if (state.verification.length === 0) lines.push("未実施(停止したため)");
    else
      state.verification.forEach((v, i) =>
        lines.push(`- 試行 ${i + 1}: ${v.passed ? "成功" : "失敗"} — ${v.summary}`),
      );
    lines.push("");
  };
  const last = state.verification[state.verification.length - 1];
  const verificationFailed = Boolean(last && !last.passed);

  const lastRound = state.rounds[state.rounds.length - 1];
  if (lastRound && lastRound.missingReviewers.length > 0) {
    lines.push(
      `> **注意**: 最後のレビューラウンドで結果を返さなかったレビュアーがいる(${lastRound.missingReviewers.join(", ")})。収束の根拠が不完全`,
      "",
    );
  }
  if (state.stopReason) {
    const detail = state.stopDetail ? `(${state.stopDetail})` : "";
    lines.push(`> **停止**: ${STOP_REASONS[state.stopReason]}${detail}`, "");
  }
  if (verificationFailed) pushVerification();
  pushSection("Unresolved Finding", uniqueByKey(state.unresolved), formatItem);
  pushSection("Plan Concern", uniqueByKey(state.planConcerns), formatItem);
  if (state.closedRepeats.length > 0) {
    pushSection(
      "閉じた指摘に統合された修正必須指摘",
      state.closedRepeats,
      (i) => `${formatItem(i)} — 元の指摘: ${i.findings.join(" / ")}`,
    );
  }
  if (!verificationFailed) pushVerification();
  pushSection(
    "Deferred Finding",
    state.deferred,
    (d) => `${formatItem(d)} — 見送り理由: ${d.reason} / 検証者: ${d.verifierReason}`,
  );
  pushSection("参考指摘(修正必須ではない)", uniqueByKey(state.advisory), formatItem);
  pushSection("Observations", state.observations, (o) => o);

  lines.push("## 統計", "");
  lines.push(`- レビューラウンド: ${state.rounds.length}`);
  for (const r of state.rounds) {
    lines.push(
      `  - ラウンド ${r.round}: 修正必須 ${r.blocking} / 再出現 ${r.repeated} / 参考 ${r.advisory}`,
    );
  }
  if (state.reviewerFailures.length > 0)
    lines.push(`- 結果を返さなかったレビュアー: ${state.reviewerFailures.join(", ")}`);
  lines.push(`- 出力トークン: ${state.outputTokens}`, "");
  lines.push("🤖 Generated with [Claude Code](https://claude.com/claude-code)");
  return lines.join("\n");
}

async function implement(state) {
  const { config } = state;
  phase("Plan");
  const parsed = await agent(planPrompt(config), {
    label: "plan",
    phase: "Plan",
    schema: PLAN_SCHEMA,
  });
  if (!parsed || parsed.tasks.length === 0) {
    state.stopReason = "plan-unreadable";
    return;
  }
  state.title = parsed.title;
  phase("Implement");
  for (let i = 0; i < parsed.tasks.length; i++) {
    const task = parsed.tasks[i];
    const label = `implement:${i + 1}`;
    const result = await agent(implementPrompt(task, i, parsed.tasks.length, config), {
      label,
      phase: "Implement",
      schema: IMPLEMENT_SCHEMA,
    });
    collectObservations(state, label, result);
    if (!result || result.status !== "done") {
      state.stopReason = "implement-blocked";
      state.stopDetail = `タスク ${i + 1}「${task.title}」: ${result ? result.reason || "理由なし" : "エージェントが結果を返さなかった"}`;
      return;
    }
  }
}

async function runChecks(state, roundNo) {
  const label = `checks:${roundNo}`;
  const result = await agent(checksPrompt(state.config), {
    label,
    phase: "Review",
    schema: CHECKS_SCHEMA,
  });
  collectObservations(state, label, result);
  if (result && result.passed) return true;
  state.stopReason = "checks-failing";
  state.stopDetail = result ? result.details || "" : "エージェントが結果を返さなかった";
  return false;
}

async function runReviewers(state, roundNo) {
  const results = await parallel(
    REVIEWERS.map(
      (r) => () =>
        agent(reviewPrompt(r, state.config), {
          label: `review:${r.id}`,
          phase: "Review",
          schema: reviewSchema(r),
        }),
    ),
  );
  const findings = [];
  state.lastMissingReviewers = REVIEWERS.filter((r, i) => !results[i]).map((r) => r.id);
  results.forEach((result, i) => {
    const reviewer = REVIEWERS[i];
    if (!result) {
      state.reviewerFailures.push(`${reviewer.id}(ラウンド ${roundNo})`);
      return;
    }
    collectObservations(state, `review:${reviewer.id}`, result);
    result.findings.forEach((f, j) =>
      findings.push({ ...f, reviewer: reviewer.id, id: `${reviewer.id}#${j}` }),
    );
  });
  if (results.every((r) => !r)) {
    state.stopReason = "reviewers-failed";
    return null;
  }
  return findings;
}

async function mergeFindings(state, findings) {
  if (findings.length === 0) return [];
  const result = await agent(mergePrompt(findings, state.knownClusters), {
    label: "merge",
    phase: "Review",
    schema: MERGE_SCHEMA,
  });
  if (!result) {
    state.stopReason = "merge-failed";
    return null;
  }
  // merge が落とした指摘を黙って消さない(消えると修正必須ゼロとしてループを抜けてしまう)。
  const covered = new Set(result.clusters.flatMap((c) => c.members));
  const clusters = [...result.clusters];
  for (const f of findings) {
    if (covered.has(f.id)) continue;
    log(`merge がどの cluster にも入れなかった指摘を単独で扱う: ${f.id}`);
    clusters.push({
      key: `${f.file}::unmerged:${f.summary}`,
      file: f.file,
      line: f.line,
      summary: f.summary,
      target: f.target,
      planBreaking: Boolean(f.planBreaking),
      members: [f.id],
    });
  }
  for (const c of clusters) {
    if (!state.knownClusters.some((k) => k.key === c.key))
      state.knownClusters.push({ key: c.key, summary: c.summary });
  }
  return clusters;
}

async function runFix(state, roundNo, blocking) {
  const label = `fix:${roundNo}`;
  const items = blocking.map((b) =>
    state.rejectedDeferrals[b.key]
      ? { ...b, deferralRejectedReason: state.rejectedDeferrals[b.key] }
      : b,
  );
  const fix = await agent(fixPrompt(items, state.config), {
    label,
    phase: "Review",
    schema: FIX_SCHEMA,
  });
  if (!fix) {
    markUnresolved(state, blocking);
    state.stopReason = "fixer-failed";
    return new Set();
  }
  collectObservations(state, label, fix);
  const byKey = Object.fromEntries(blocking.map((b) => [b.key, b]));
  const proposals = fix.results.filter((r) => r.action === "propose-defer" && byKey[r.key]);
  const verdicts = await parallel(
    proposals.map(
      (p) => () =>
        agent(deferPrompt(byKey[p.key], p.reason || "", state.config), {
          label: `defer-verify:${p.key}`,
          phase: "Review",
          schema: VERDICT_SCHEMA,
        }).then((verdict) => ({ proposal: p, verdict })),
    ),
  );
  // 初めて却下された見送りは、次のラウンドで再出現扱いにせず、却下理由を添えてもう1回修正に回す。
  const firstRejections = new Set();
  for (const v of verdicts) {
    if (!v) continue;
    if (!v.verdict || !v.verdict.agree) {
      const key = v.proposal.key;
      if (!state.rejectedDeferrals[key]) firstRejections.add(key);
      state.rejectedDeferrals[key] = v.verdict ? v.verdict.reason : "検証者が結果を返さなかった";
      continue;
    }
    state.deferred.push({
      ...byKey[v.proposal.key],
      reason: v.proposal.reason || "",
      verifierReason: v.verdict.reason,
    });
    state.deferredKeys.add(v.proposal.key);
  }
  return firstRejections;
}

// 修正した後、再レビューで確かめる前に止まった(停止・例外)指摘は、直ったと扱わずに Unresolved に残す。
async function reviewLoop(state) {
  const tracker = { unverified: [] };
  try {
    await reviewRounds(state, tracker);
  } finally {
    markUnresolved(
      state,
      tracker.unverified.map((i) => ({
        ...i,
        summary: `${i.summary}(修正後に再レビューされていない)`,
      })),
    );
  }
}

async function reviewRounds(state, tracker) {
  let previousBlockingKeys = new Set();
  for (let fixRound = 0; ; fixRound++) {
    if (budget.total && budget.remaining() < BUDGET_FLOOR) {
      state.stopReason = "budget";
      return;
    }
    const roundNo = state.rounds.length + 1;
    phase("Review");
    if (!(await runChecks(state, roundNo))) return;
    const findings = await runReviewers(state, roundNo);
    if (findings === null) return;
    const clusters = await mergeFindings(state, findings);
    if (clusters === null) return;
    const byId = Object.fromEntries(findings.map((f) => [f.id, f]));
    const closedKeys = new Set([...state.deferredKeys, ...state.unresolvedKeys]);
    const result = classifyRound(clusters, byId, previousBlockingKeys, closedKeys);
    tracker.unverified = [];
    if (result.dropped.length > 0)
      log(`有効な指摘を含まない cluster を捨てた: ${result.dropped.join(", ")}`);
    state.rounds.push({
      round: roundNo,
      blocking: result.blocking.length,
      repeated: result.repeated.length,
      advisory: result.advisory.length,
      missingReviewers: state.lastMissingReviewers,
    });
    if (result.closedRepeats.length > 0)
      log(
        `閉じた key に統合された修正必須指摘: ${result.closedRepeats.map((i) => i.key).join(", ")}`,
      );
    state.closedRepeats.push(...result.closedRepeats);
    markUnresolved(state, result.repeated);
    state.advisory.push(...result.advisory);
    state.planConcerns.push(...result.planConcerns);
    if (result.planBreaking.length > 0) {
      state.stopReason = "plan-breaking";
      return;
    }
    if (result.blocking.length === 0) return;
    if (fixRound >= state.config.maxReviewRounds) {
      log(
        `修正ラウンドの上限 ${state.config.maxReviewRounds} に達した。残り ${result.blocking.length} 件を Unresolved にする`,
      );
      markUnresolved(state, result.blocking);
      return;
    }
    const firstRejections = await runFix(state, roundNo, result.blocking);
    if (state.stopReason) return;
    tracker.unverified = result.blocking.filter((b) => !state.deferredKeys.has(b.key));
    previousBlockingKeys = new Set(
      result.blocking.map((b) => b.key).filter((k) => !firstRejections.has(k)),
    );
  }
}

async function verify(state) {
  const { config } = state;
  if (config.verifySkill === "none") return;
  for (let attempt = 1; ; attempt++) {
    phase("Verify");
    const label = `verify:${attempt}`;
    const result = await agent(verifyPrompt(config), {
      label,
      phase: "Verify",
      schema: VERIFY_SCHEMA,
    });
    collectObservations(state, label, result);
    state.verification.push(
      result || { passed: false, summary: "動作確認エージェントが結果を返さなかった" },
    );
    if (result && result.passed) return;
    if (attempt > config.maxVerifyRetries) return;
    const fixLabel = `fix-verify:${attempt}`;
    const fix = await agent(fixVerifyPrompt(result, config), {
      label: fixLabel,
      phase: "Verify",
      schema: FIX_VERIFY_SCHEMA,
    });
    collectObservations(state, fixLabel, fix);
    await reviewLoop(state);
    if (state.stopReason) return;
  }
}

async function publish(state, report) {
  phase("Publish");
  return agent(publishPrompt(state, report), {
    label: "publish",
    phase: "Publish",
    schema: PUBLISH_SCHEMA,
  });
}

const config = validateArgs(args);
const state = newState(config);
// 例外(budget の上限到達など)で報告ごと失わないよう、ここまでの状態で必ず報告を組み立てる。
try {
  await implement(state);
  if (!state.stopReason) await reviewLoop(state);
  if (!state.stopReason) await verify(state);
} catch (error) {
  state.stopReason = "error";
  state.stopDetail = String(error && error.message ? error.message : error);
}
state.outputTokens = budget.spent();
const report = renderReport(state);
let published = null;
try {
  published = await publish(state, report);
} catch (error) {
  log(`公開に失敗した: ${error && error.message ? error.message : error}`);
}
return {
  prUrl: published && published.prUrl ? published.prUrl : null,
  published: Boolean(published && published.pushed),
  stopReason: state.stopReason,
  report,
};
