export const meta = {
  name: "deliver",
  description:
    "plan を実装し、レビュー修正ループと動作確認を経て draft PR と人間への報告を作る(mode=review-verify なら既存のブランチにレビュー修正ループと動作確認だけをかけて報告する)",
  whenToUse: "入口 skill /deliver または /review-verify から起動する。直接起動しない",
  phases: [
    { title: "Plan" },
    { title: "Implement" },
    { title: "Review" },
    { title: "Verify" },
    { title: "Publish" },
  ],
};

// 判定はここに置いたコードで行い、agent にはさせない(ADR 0007)。
// mode には既定値を置かない。既定を deliver にすると、mode を渡し忘れた Review-Verify が黙って実装・push・PR 作成まで進む。
const DEFAULTS = { maxReviewRounds: 3, maxVerifyRetries: 2 };
// mode ごとに持つ機能をここで一覧にし、分岐する箇所は mode 名ではなく機能名で見る。
// mode を足すときはここに 1 行足せば、どの機能を持つかを全箇所で漏れなく決めたことになる。
// - label: 報告で mode を示すときの名前
// - implement: plan のタスクを実装する
// - publish: push して draft PR を作る(PR 向けの報告の体裁もこれに従う)
// - branchScope: 要件文書のうちブランチが未着手の項目を範囲外として prompt で限る。plan の
//   タスク分解で範囲が決まっていない入力の性質(ADR 0010)
const MODES = {
  deliver: { label: "Deliver", implement: true, publish: true, branchScope: false },
  // review-verify は実装も公開もしない(ADR 0010)。
  "review-verify": {
    label: "Review-Verify",
    implement: false,
    publish: false,
    branchScope: true,
  },
};
const BUDGET_FLOOR = 100000;

// built-in の code-review は fork 型の skill で、Workflow のエージェントから Skill で呼ぶと
// 本文が返らず別エージェントとして起動するだけなので使えない(2026-09-25 実測。spec の「試作で実測すること」)。
const REVIEWERS = [
  {
    id: "ecc",
    skill: "ecc-code-review",
    severities: ["CRITICAL", "HIGH", "MEDIUM", "LOW"],
    blocking: ["CRITICAL", "HIGH"],
    // ecc の「Code Quality (HIGH)」は行数・console.log などの機械的な基準を含み、そのままだと修正必須になって
    // 指示の無いリファクタリングを招くので、不具合に繋がるもの以外は MEDIUM 以下で報告させる。
    note: "ecc の「Code Quality (HIGH)」のうち、関数の行数・ファイルの行数・ネストの深さ・console.log・TODO/FIXME・JSDoc の欠落といった機械的な基準は、それ自体が不具合に繋がる場合を除き MEDIUM 以下で報告する。",
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
  "requirements-breaking": "要件文書どおりに作ると壊れる Requirements Concern が出た",
  "verify-unfixed": "動作確認の失敗を修正エージェントが直せなかったため、再確認しなかった",
  budget: "トークン予算の残りが下限を割ったため、次の段階に進まなかった",
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

// changes は必須にし、変えなかったことも空配列で明示させる(省略を「変更なし」と読まない)。
// file を分けて持つのは、入口 skill が git の差分と照合するため(review-verify の手順8)。
const CHANGES = {
  type: "array",
  items: {
    type: "object",
    properties: { file: { type: "string" }, summary: { type: "string" } },
    required: ["file", "summary"],
  },
};

const CHECKS_SCHEMA = {
  type: "object",
  properties: {
    passed: { type: "boolean" },
    details: { type: "string" },
    changes: CHANGES,
    observations: STRINGS,
  },
  required: ["passed", "changes"],
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
          target: { type: "string", enum: ["code", "requirements"] },
          requirementsBreaking: { type: "boolean" },
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
          target: { type: "string", enum: ["code", "requirements"] },
          requirementsBreaking: { type: "boolean" },
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
    changes: CHANGES,
    observations: STRINGS,
  },
  required: ["results", "changes"],
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
  properties: {
    fixed: { type: "boolean" },
    summary: { type: "string" },
    changes: CHANGES,
    observations: STRINGS,
  },
  required: ["fixed", "summary", "changes"],
};

const WRITE_SCHEMA = {
  type: "object",
  properties: {
    dir: { type: "string" },
    bodyLines: { type: "integer" },
    bodyBytes: { type: "integer" },
    ledgerLines: { type: "integer" },
    ledgerBytes: { type: "integer" },
  },
  required: ["dir", "bodyLines", "bodyBytes", "ledgerLines", "ledgerBytes"],
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
  if (typeof a.requirementsPath !== "string" || a.requirementsPath === "")
    missing.push("requirementsPath");
  if (typeof a.baseRef !== "string" || a.baseRef === "") missing.push("baseRef");
  if (!Array.isArray(a.checkCommands) || a.checkCommands.length === 0)
    missing.push("checkCommands");
  if (typeof a.verifySkill !== "string" || a.verifySkill === "") missing.push("verifySkill");
  // 欠落は他の必須引数と同じ段で挙げる(別に throw すると、直して再実行するまで mode の欠落が見えない)。
  if (a.mode === undefined) missing.push("mode");
  if (missing.length > 0) {
    throw new Error(
      `deliver: 必須の引数がありません: ${missing.join(", ")}(入口 skill /deliver か /review-verify から起動してください)`,
    );
  }
  // 上限はループを止める唯一の保証なので、不正な値を既定値で黙って置き換えずに拒否する。
  const invalid = ["maxReviewRounds", "maxVerifyRetries"].filter(
    (k) => a[k] !== undefined && !(Number.isInteger(a[k]) && a[k] >= 0),
  );
  if (invalid.length > 0) {
    throw new Error(`deliver: 0 以上の整数が必要です: ${invalid.join(", ")}`);
  }
  if (!Object.keys(MODES).includes(a.mode)) {
    throw new Error(`deliver: mode は ${Object.keys(MODES).join(" / ")} のいずれか: ${a.mode}`);
  }
  // 値が undefined のキーを spread すると既定値を消し、上限が黙って外れるので、先に除く。
  const given = Object.fromEntries(Object.entries(a).filter(([, v]) => v !== undefined));
  const config = { ...DEFAULTS, ...given };
  config.features = MODES[config.mode];
  if (config.features.publish && !config.prBase)
    config.prBase = config.baseRef.replace(/^origin\//, "");
  return config;
}

function newState(config) {
  return {
    config,
    title: "",
    rounds: [],
    // reviewLoop の 1 回の呼び出し(初回と、動作確認の失敗による再入)ごとの終わり方。
    reviewPasses: [],
    unresolved: [],
    unresolvedKeys: new Set(),
    deferred: [],
    deferredKeys: new Set(),
    requirementsConcerns: [],
    advisory: [],
    advisoryClosedKeys: new Set(),
    advisoryReappearedKeys: new Set(),
    advisoryEscalatedKeys: new Set(),
    advisoryDeclined: [],
    advisoryUnverified: [],
    knownClusters: [],
    rejectedDeferrals: {},
    unansweredFixes: new Set(),
    closedRepeats: [],
    lastMissingReviewers: [],
    verification: [],
    observations: [],
    checksChanges: [],
    fixed: [],
    fixChanges: [],
    verifyFixChanges: [],
    reviewerFailures: [],
    stopReason: null,
    stopDetail: "",
    outputTokens: 0,
  };
}

// budget.total は hard ceiling で、達すると以後の agent() はすべて throw する。公開の分を残すため、
// agent を呼ぶループの各周回の先頭で下限を割っていないか確かめる。
function budgetExhausted(state, next) {
  if (!budget.total || budget.remaining() >= BUDGET_FLOOR) return false;
  state.stopReason = "budget";
  state.stopDetail = `${next}の前で停止`;
  return true;
}

function collectObservations(state, source, result) {
  if (!result || !Array.isArray(result.observations)) return;
  for (const o of result.observations) state.observations.push(`${source}: ${o}`);
}

function isBlocking(finding) {
  const reviewer = REVIEWERS.find((r) => r.id === finding.reviewer);
  return Boolean(reviewer && reviewer.blocking.includes(finding.severity));
}

// target と requirementsBreaking は merge の申告ではなく元の指摘(members)から導く。merge に任せるのは
// 重複をまとめることだけで、判定の入力にはしない(ADR 0007)。
// closedKeys(Deferred / Unresolved 済み)に統合された修正必須指摘は、判定から外すが報告には残す。
function classifyRound(clusters, findingsById, previousBlockingKeys, closedKeys) {
  const out = {
    blocking: [],
    repeated: [],
    requirementsConcerns: [],
    requirementsBreaking: [],
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
    const requirementsMembers = members.filter((m) => m.target === "requirements");
    const codeMembers = members.filter((m) => m.target !== "requirements");
    if (requirementsMembers.length > 0) {
      const item = toItem(
        codeMembers.length > 0 ? `${c.key}::requirements` : c.key,
        requirementsMembers,
      );
      out.requirementsConcerns.push(item);
      if (requirementsMembers.some((m) => m.requirementsBreaking))
        out.requirementsBreaking.push(item);
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

// 要件文書は人間が書いた意図の出所なので、コードを編集するエージェントに書き換えさせない。
// コードとのずれを要件文書の側で「直す」と、意図が黙って変わる。要件文書に向く指摘は
// Requirements Concern として人間に返し、修正エージェントには渡さない(classifyRound)。
const keepRequirements = (config) =>
  `\n- 要件文書 ${config.requirementsPath} は変更しない。コードと要件文書がずれていたら、コードの側を直す。`;

// Review-Verify の要件文書は spec でもよく、ブランチの範囲より広いことがある。そのままだと
// 「要件文書とのずれ」として未着手の要件が修正必須になり、修正エージェントがそれを実装してしまう。
// 実装の経路は mode の分岐で塞いでいるが、この経路はプロンプトでしか塞げない(ADR 0010)。
// 逆に「未着手」を口実にブランチ自身の不具合を見送らせないよう、歯止めの文も必ず添える。
const unstartedScope = (config, rule) =>
  config.features.branchScope
    ? `\n- 要件文書のうち、このブランチがまだ着手していない項目は範囲外である。この規則は、要件文書とのずれを直す指示より優先する。${rule}ただし、このブランチが追加・変更したコードの不具合(例外、誤動作、着手済みの項目とのずれ)は、未着手の項目に関わっていても範囲外にしない。`
    : "";

function planPrompt(config) {
  return `plan ファイル ${config.requirementsPath} を読み、実装タスクの一覧を抽出せよ。
- plan の順序どおりに、plan の1タスクを1要素とする。独自に分割・統合しない。
- title は、この plan 全体を表す PR タイトルとして使える短い日本語にする。
- plan が実装計画でない(タスク分解が無い)なら、tasks を空配列で返す。`;
}

function implementPrompt(task, index, total, config) {
  return `plan ${config.requirementsPath} のタスク ${index + 1}/${total}「${task.title}」を実装せよ。plan を読み、このタスクの範囲だけを実装する。
- TDD で進める。失敗するテストを先に書き、失敗を確認してから実装する。
- 完了する前に、次のコマンドを全て実行して全て成功させる: ${commands(config)}
- 完了したら変更をコミットする(push はしない)。コミットメッセージはリポジトリの既存の規約に従う。
- plan どおりに進められない(前提が崩れている、plan が矛盾している)場合は、推測で埋めずに status="blocked" と理由を返す。
- タスクの範囲外で気づいた問題は observations に書く(直さない)。`;
}

const reportChanges =
  "- コードを変更したら、変更したファイルごとに、リポジトリルートからの相対パスを file に、何をなぜ変えたかを summary に書いて changes に入れる。変更しなければ空配列にする。";

function checksPrompt(config) {
  // Review-Verify では人間が書いたブランチに最初に触れるのがこのエージェントなので、未着手の項目を
  // 検査するテストが落ちていても、それを実装して通させない(ADR 0010)。
  // 通るように直した変更は、通った場合も報告に出す。人間のコードをレビューの前に変えているため。
  return `次のコマンドを全て実行せよ: ${commands(config)}
- 失敗があれば原因を直してコミットし(push はしない)、全て成功するまで繰り返す。
- テストを消す・スキップする・lint を無効化するなど、検査そのものを弱める変更はしない。
${reportChanges}
- 3回試しても直らなければ、passed=false と失敗内容を返す。${keepRequirements(config)}${unstartedScope(config, "それを実装しない。未着手の項目を実装しないと通らない場合は、passed=false とし、その旨を details に書く。")}`;
}

function reviewPrompt(reviewer, config) {
  // 実装と修正は毎回コミットするので、未コミットの変更だけを集める skill の手順では差分が空になる。
  const note = reviewer.note ? `\n- ${reviewer.note}` : "";
  return `Skill ツールで「${reviewer.skill}」を読み込み、その手順に従って「${config.baseRef}...HEAD」の差分をレビューせよ。
- 差分の収集だけは skill の手順を上書きする: 対象ファイルは「git diff --name-only ${config.baseRef}...HEAD」、差分は「git diff ${config.baseRef}...HEAD」で集める。変更はコミット済みなので、未コミットの変更が無くても「Nothing to review」で止まらない。
- 要件は要件文書 ${config.requirementsPath}。要件文書とのずれも指摘の対象にする。
- ファイルの修正、コミット、PR へのコメント投稿、ReportFindings ツールの呼び出しはしない。結果は StructuredOutput だけで返す。
- severity には skill 自身の尺度をそのまま使う: ${reviewer.severities.join(" / ")}
- 指摘が実装ではなく要件文書そのものに向く場合は target="requirements" とし、要件文書どおりに作ると壊れる場合だけ requirementsBreaking=true にする。
- レビューの範囲外で気づいた問題は observations に書く。${unstartedScope(config, "それが無いことを修正必須として指摘せず、observations に書く。未着手の項目だけに向く Requirements Concern は、requirementsBreaking=false にする(作業を止める理由にしない)。")}${note}`;
}

function mergePrompt(findings, knownClusters) {
  return `複数のレビュアーの指摘を統合せよ。指摘(JSON): ${JSON.stringify(findings)}
- 同じ問題を指す指摘は1つの cluster にまとめ、members に元の id を全て入れる。どの指摘も必ずちょうど1つの cluster に入れる。
- key は「ファイルパス::問題の種類を表す英小文字の短いスラッグ」とする(例: src/a.ts::missing-null-check)。
- 過去のラウンドに同じ問題があれば、その key をそのまま使う。過去の cluster(JSON): ${JSON.stringify(knownClusters)}
- target は、members のいずれかが "requirements" なら "requirements"、それ以外は "code"。requirementsBreaking は、members のいずれかが true なら true。
- summary は日本語の1文で書く。`;
}

function fixPrompt(items, advisory, config) {
  return `次のレビュー指摘に対応せよ。要件文書は ${config.requirementsPath}、対象の差分は「${config.baseRef}...HEAD」。
修正必須の指摘(JSON): ${JSON.stringify(items)}
参考指摘(JSON): ${JSON.stringify(advisory)}
- Skill ツールで「superpowers:receiving-code-review」を読み込み、その手順で各指摘を評価してから対応する。
- この実行は非対話で、人間に質問できない。skill が人間に聞く・止まって相談するとする場面(指摘が不明確、人間の過去の判断や要件文書と衝突する、アーキテクチャに関わる)では、その指摘を action="propose-defer" とし、その旨を reason に書く。他の指摘への対応は止めない。
- 全ての指摘(修正必須・参考の両方)について、修正したら action="fixed"、修正すべきでないと判断したら action="propose-defer" と具体的な理由を返す。
- 修正必須の指摘を propose-defer にしてよいのは、偽陽性か要件文書の範囲外の場合と、上の非対話の読み替えに当たる場合だけ。直すのが大変だという理由では見送らない。
- 参考指摘は、技術的に正しく要件文書と衝突しないなら直す。見送るのは、偽陽性・この差分の範囲外・要件文書との衝突・上の非対話の読み替えに当たる場合だけ。
- deferralRejectedReason がある指摘は、見送りの提案が検証者に却下されている。その理由を読んだうえで修正する。
- unansweredBefore が true の指摘は、前回の修正で対応結果が返らなかった。
- 修正した後、次のコマンドを全て成功させる: ${commands(config)}
- 修正をまとめて新しい1コミットにする(push はしない)。${keepRequirements(config).trimStart()}
${reportChanges}
- 指摘の範囲外で気づいた問題は observations に書く。${unstartedScope(config, "それを実装しない。実装しないと解消しない指摘は、要件文書の範囲外として propose-defer にする。")}`;
}

function deferPrompt(item, reason, config) {
  return `あなたは独立した検証者である。実装者は、次の指摘を修正せずに見送ることを提案している。
指摘(JSON): ${JSON.stringify(item)}
実装者の理由: ${reason}
要件文書は ${config.requirementsPath}、差分は「${config.baseRef}...HEAD」。コードと要件文書を自分で読み、見送りが妥当か判断せよ。妥当なのは、指摘が偽陽性であるか、要件文書の範囲外である場合だけ。判断に迷うなら agree=false とする。${unstartedScope(config, "その項目が差分で本当に未着手であることを自分で確かめ、そのうえでその項目を実装しないと解消しない指摘に限り、要件文書の範囲外として見送ってよい。")}`;
}

function verifyPrompt(config) {
  return `Skill ツールで「${config.verifySkill}」を読み込み、その手順に従って、要件文書 ${config.requirementsPath} に書かれた意図どおりに変更が動くことを確認せよ。
- 確認した操作と観察した結果を summary に書き、意図どおりに動けば passed=true にする。
- コードは修正しない。範囲外で気づいた問題は observations に書く。${unstartedScope(config, "確認するのはこのブランチの差分が実装した範囲だけで、未着手の項目が動かないことを失敗にしない。")}`;
}

function fixVerifyPrompt(result, config) {
  return `動作確認が失敗した。結果(JSON): ${JSON.stringify(result)}
原因を調べて直し、次のコマンドを全て成功させてから1コミットにせよ(push はしない): ${commands(config)}
${reportChanges}${keepRequirements(config)}${unstartedScope(config, "それを実装しない。未着手の項目を実装しないと直らない場合は、fixed=false とし、その旨を summary に書く。")}`;
}

function ledgerJson(state) {
  return JSON.stringify(
    {
      ...state,
      unresolvedKeys: [...state.unresolvedKeys],
      deferredKeys: [...state.deferredKeys],
      unansweredFixes: [...state.unansweredFixes],
      advisoryClosedKeys: [...state.advisoryClosedKeys],
      advisoryReappearedKeys: [...state.advisoryReappearedKeys],
      advisoryEscalatedKeys: [...state.advisoryEscalatedKeys],
    },
    null,
    2,
  );
}

function writePrompt(report, ledger) {
  return `次の2つのファイルを書き出せ。push や PR の作成はしない。
1. 「git rev-parse --absolute-git-dir」の出力を D とし、D/deliver/ を作る。
2. 下の REPORT を D/deliver/pr-body.md に、下の LEDGER を D/deliver/ledger.json に、1文字も変えずに Write ツールで書き出す。要約・省略・整形はしない。
3. それぞれのファイルについて「grep -c '' <file>」の行数と「wc -c < <file>」のバイト数を返す。dir には D/deliver の絶対パスを返す。

REPORT:
<<<REPORT
${report}
REPORT

LEDGER:
<<<LEDGER
${ledger}
LEDGER`;
}

function publishPrompt(state, dir) {
  return `次の手順で公開せよ。本文のファイルは書き出し済みなので、内容を変えない。
1. 「git rev-list --count ${state.config.baseRef}..HEAD」が 0 なら、push も PR の作成もせず、pushed=false と error「${state.config.baseRef} との差分コミットが無いため PR を作らなかった」を返す。
2. 現在のブランチを push する(force push はしない)。
3. このブランチの PR が無ければ「gh pr create --draft --base ${state.config.prBase} --title <TITLE> --body-file ${dir}/pr-body.md」で作る。既にあれば「gh pr edit --body-file ${dir}/pr-body.md」で本文を更新する。
4. PR の URL と ledger の絶対パス(${dir}/ledger.json)を返す。どこかで失敗したら pushed=false と error を返す。

TITLE: ${state.title || "deliver"}`;
}

// Workflow のスクリプトには TextEncoder が有るとは限らない(JS の組込みではない)ので、UTF-8 のバイト数を自前で数える。
function utf8Length(text) {
  let n = 0;
  for (const ch of text) {
    const c = ch.codePointAt(0);
    n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
  }
  return n;
}

// 書き出しはエージェントに委譲するしかない(スクリプトに fs が無い)ので、行数とバイト数で書き写しを確かめる。
// 末尾に改行が1つ付くことだけは許す。
function faithful(text, lines, bytes) {
  const expected = utf8Length(text);
  return lines === text.split("\n").length && (bytes === expected || bytes === expected + 1);
}

function formatItem(item) {
  const location = item.line ? `${item.file}:${item.line}` : item.file;
  return `\`${location}\` ${item.summary} [${item.severities.join(", ")}]`;
}

const formatChange = (c) => `${c.label}: \`${c.file}\` ${c.summary}`;

const PASS_OUTCOMES = {
  converged: "収束した",
  capped: "修正ラウンドの上限に達した",
  stopped: "停止した",
};

// 入口 skill が報告とは別に外部(Issue など)へ投稿する。リポジトリ名・ブランチ名・エージェントの自由記述
// (stopDetail や指摘の本文)は入れない。仕事のリポジトリでの実行を public な Issue に投稿しうるため。
function renderStats(state) {
  const { config } = state;
  const lines = ["## 統計", ""];
  lines.push(
    `- mode: ${config.features.label}(maxReviewRounds ${config.maxReviewRounds} / maxVerifyRetries ${config.maxVerifyRetries})`,
  );
  lines.push(`- 停止: ${state.stopReason ? STOP_REASONS[state.stopReason] : "なし"}`);
  lines.push(
    `- レビューの実行: ${state.reviewPasses.length}(動作確認の失敗による再入 ${Math.max(state.reviewPasses.length - 1, 0)})`,
  );
  state.reviewPasses.forEach((p, i) => {
    const rounds = state.rounds.filter((r) => r.pass === i + 1).map((r) => r.round);
    const range =
      rounds.length === 0 ? "ラウンドなし" : `ラウンド ${rounds[0]}〜${rounds[rounds.length - 1]}`;
    lines.push(`  - 実行 ${i + 1}: ${PASS_OUTCOMES[p.outcome]}(${range})`);
  });
  lines.push(`- レビューラウンド: ${state.rounds.length}`);
  for (const r of state.rounds) {
    lines.push(
      `  - ラウンド ${r.round}: 修正必須 ${r.blocking} / 再出現 ${r.repeated} / 参考 ${r.advisory}(修正に回した ${r.advisorySent}: 修正 ${r.advisoryFixed} / 見送り ${r.advisoryDeclined})`,
    );
  }
  lines.push(
    `- 動作確認の試行: ${config.verifySkill === "none" ? "指定なし" : state.verification.length}`,
  );
  if (state.reviewerFailures.length > 0)
    lines.push(`- 結果を返さなかったレビュアー: ${state.reviewerFailures.join(", ")}`);
  lines.push(`- 出力トークン: ${state.outputTokens}`);
  return lines.join("\n");
}

function renderReport(state) {
  const lines = [];
  const pushSection = (title, items, format, empty = "なし") => {
    lines.push(`## ${title}`, "");
    if (items.length === 0) lines.push(empty);
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

  const { features } = state.config;
  if (!features.publish) {
    // mode 名や「実装しない」を決め打ちせず、MODES の宣言から導く(mode を足しても嘘にならないように)。
    const skipped = features.implement ? "PR の作成" : "実装と PR の作成";
    lines.push(
      `> **${features.label}**: ${skipped}をしない mode で実行した。Workflow が作ったコミット(作っていれば)はローカルにだけあり、push していない`,
      "",
    );
  }
  // 途中のラウンドで欠けても、その前の修正を片方のレビュアーしか確かめていないので、収束の根拠が欠ける。
  const incomplete = state.rounds.filter((r) => r.missingReviewers.length > 0);
  if (incomplete.length > 0) {
    const detail = incomplete
      .map((r) => `ラウンド ${r.round}: ${r.missingReviewers.join(", ")}`)
      .join(" / ");
    lines.push(`> **注意**: 結果を返さなかったレビュアーがいる(${detail})。収束の根拠が不完全`, "");
  }
  if (state.stopReason) {
    const detail = state.stopDetail ? `(${state.stopDetail})` : "";
    lines.push(`> **停止**: ${STOP_REASONS[state.stopReason]}${detail}`, "");
  }
  if (verificationFailed) pushVerification();
  // 1回もレビューしていないのに「なし」と出すと、収束したように読めてしまう。
  pushSection(
    "Unresolved Finding",
    uniqueByKey(state.unresolved),
    formatItem,
    state.rounds.length === 0 ? "未レビュー(レビューラウンドが1回も完了していない)" : "なし",
  );
  pushSection("Requirements Concern", uniqueByKey(state.requirementsConcerns), formatItem);
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
  const unverifiedAdvisoryKeys = new Set(state.advisoryUnverified.map((i) => i.key));
  if (state.advisoryUnverified.length > 0)
    pushSection(
      "修正に回した後、再レビューされていない参考指摘",
      state.advisoryUnverified,
      formatItem,
    );
  const reappeared = state.advisoryReappearedKeys;
  const escalated = state.advisoryEscalatedKeys;
  // 修正必須の重大度で出直した key は、修正必須の側(Unresolved / Deferred / 修正した指摘)で報告する。
  pushSection(
    "参考指摘(修正必須ではない)",
    uniqueByKey(state.advisory).filter(
      (i) =>
        (!state.advisoryClosedKeys.has(i.key) || reappeared.has(i.key)) &&
        !escalated.has(i.key) &&
        !unverifiedAdvisoryKeys.has(i.key),
    ),
    (i) =>
      reappeared.has(i.key)
        ? `${formatItem(i)}(直したと回答した後、再レビューで再指摘された)`
        : formatItem(i),
  );
  pushSection(
    "見送った参考指摘",
    state.advisoryDeclined.filter((d) => !escalated.has(d.key)),
    (d) => `${formatItem(d)} — 見送り理由: ${d.reason}`,
  );
  // 修正エージェントは人間が書いたブランチにもコミットを足すので、何を直したかを残す。
  // 直したと申告しても後で Unresolved / Deferred になった指摘、再レビューされていない参考指摘、
  // 再レビューで(参考・修正必須のどちらの重大度でも)再指摘された参考指摘は、直ったと確かめていないので出さない。
  // 修正必須として直し直した key は、修正必須としての要素だけが残る。
  pushSection(
    "修正した指摘",
    uniqueByKey(
      state.fixed.filter((i) => !(i.advisory && (reappeared.has(i.key) || escalated.has(i.key)))),
    ).filter(
      (i) =>
        !state.unresolvedKeys.has(i.key) &&
        !state.deferredKeys.has(i.key) &&
        !unverifiedAdvisoryKeys.has(i.key),
    ),
    (i) => (i.advisory ? `[参考] ${formatItem(i)}` : formatItem(i)),
  );
  pushSection("テスト/lint を通すための変更", state.checksChanges, formatChange);
  pushSection("レビュー指摘を直すための変更", state.fixChanges, formatChange);
  pushSection("動作確認を通すための変更", state.verifyFixChanges, formatChange);
  pushSection("Observations", state.observations, (o) => o);

  lines.push(renderStats(state), "");
  // PR 本文にしない報告には、PR 向けの帰属行を付けない。
  if (features.publish)
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
    if (budgetExhausted(state, `タスク ${i + 1}/${parsed.tasks.length}「${task.title}」`)) return;
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
  if (result && Array.isArray(result.changes))
    for (const c of result.changes)
      state.checksChanges.push({ label, file: c.file, summary: c.summary });
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
      requirementsBreaking: Boolean(f.requirementsBreaking),
      members: [f.id],
    });
  }
  for (const c of clusters) {
    if (!state.knownClusters.some((k) => k.key === c.key))
      state.knownClusters.push({ key: c.key, summary: c.summary });
  }
  return clusters;
}

async function runFix(state, roundNo, blocking, advisory) {
  const label = `fix:${roundNo}`;
  const items = blocking.map((b) => ({
    ...b,
    ...(state.rejectedDeferrals[b.key] && {
      deferralRejectedReason: state.rejectedDeferrals[b.key],
    }),
    ...(state.unansweredFixes.has(b.key) && { unansweredBefore: true }),
  }));
  const fix = await agent(fixPrompt(items, advisory, state.config), {
    label,
    phase: "Review",
    schema: FIX_SCHEMA,
  });
  if (!fix) {
    markUnresolved(state, blocking);
    state.stopReason = "fixer-failed";
    return { firstRejections: new Set(), rejected: new Set(), advisoryFixed: null };
  }
  collectObservations(state, label, fix);
  if (Array.isArray(fix.changes))
    for (const c of fix.changes) state.fixChanges.push({ label, file: c.file, summary: c.summary });
  const byKey = Object.fromEntries(blocking.map((b) => [b.key, b]));
  // 参考指摘かどうかは、エージェントの申告ではなく、その key を参考指摘として渡したかで決める(ADR 0014)。
  // 参考指摘の見送りには検証者を付けない。回答した key は閉じ、再出現しても修正に回さない。
  const advisoryByKey = Object.fromEntries(advisory.map((a) => [a.key, a]));
  const advisoryFixed = [];
  const round = state.rounds[state.rounds.length - 1];
  for (const r of fix.results) {
    const item = advisoryByKey[r.key];
    if (!item || state.advisoryClosedKeys.has(r.key)) continue;
    state.advisoryClosedKeys.add(r.key);
    if (r.action === "fixed") {
      state.fixed.push({ ...item, advisory: true });
      advisoryFixed.push(item);
      round.advisoryFixed++;
    } else {
      state.advisoryDeclined.push({ ...item, reason: r.reason || "" });
      round.advisoryDeclined++;
    }
  }
  for (const r of fix.results)
    if (r.action === "fixed" && byKey[r.key]) state.fixed.push(byKey[r.key]);
  // 対応結果の無い指摘は直したとは言っていないので、見送りを却下された指摘と同じく次のラウンドで確かめる。
  const firstRejections = new Set();
  const rejected = new Set();
  const answered = new Set(fix.results.map((r) => r.key));
  for (const b of blocking) {
    if (answered.has(b.key)) continue;
    rejected.add(b.key);
    if (!state.unansweredFixes.has(b.key)) firstRejections.add(b.key);
    state.unansweredFixes.add(b.key);
  }
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
  // 検証者が throw した提案(parallel が null を返す)も、同意が無いので却下として扱う。
  for (const [i, p] of proposals.entries()) {
    const v = verdicts[i] ?? { proposal: p, verdict: null };
    if (!v.verdict || !v.verdict.agree) {
      const key = v.proposal.key;
      rejected.add(key);
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
  return { firstRejections, rejected, advisoryFixed };
}

// 修正に回した後、再レビューで確かめる前に止まった(停止・例外)指摘は、直ったと扱わずに Unresolved に残す。
async function reviewLoop(state) {
  const tracker = { unverified: [], unverifiedAdvisory: [] };
  try {
    await reviewRounds(state, tracker);
  } finally {
    markUnresolved(
      state,
      tracker.unverified.map((i) => ({
        ...i,
        summary: `${i.summary}(修正に回した後、再レビューされていない)`,
      })),
    );
    // 参考指摘は Unresolved にしないが、修正のコミットは残っているので人間に見せる。
    for (const item of tracker.unverifiedAdvisory)
      if (!state.advisoryUnverified.some((u) => u.key === item.key))
        state.advisoryUnverified.push(item);
  }
}

async function reviewRounds(state, tracker) {
  let previousBlockingKeys = new Set();
  // 見送りを却下された指摘は修正されていないので、次のラウンドで再指摘されなくても直ったとはみなさない。
  let previousRejections = { items: [], first: new Set() };
  // 収束・上限以外の抜け方(停止・例外)は、すべて stopped のまま残る。
  const pass = { outcome: "stopped" };
  state.reviewPasses.push(pass);
  const passNo = state.reviewPasses.length;
  for (let fixRound = 0; ; fixRound++) {
    const roundNo = state.rounds.length + 1;
    if (budgetExhausted(state, `レビューラウンド ${roundNo}`)) return;
    phase("Review");
    if (!(await runChecks(state, roundNo))) return;
    const findings = await runReviewers(state, roundNo);
    if (findings === null) return;
    const clusters = await mergeFindings(state, findings);
    if (clusters === null) return;
    const byId = Object.fromEntries(findings.map((f) => [f.id, f]));
    const closedKeys = new Set([...state.deferredKeys, ...state.unresolvedKeys]);
    const result = classifyRound(clusters, byId, previousBlockingKeys, closedKeys);
    // 修正必須として判定された key だけを「再指摘された」とみなす。中身の無い cluster(dropped)、
    // 修正必須でない重大度(advisory)、要件文書向けの指摘だけでの再報告では、直ったことにならない。
    const reportedKeys = new Set(
      [...result.blocking, ...result.repeated, ...result.closedRepeats].map((i) => i.key),
    );
    const carried = new Set();
    for (const item of previousRejections.items) {
      if (reportedKeys.has(item.key)) continue;
      carried.add(item.key);
      if (previousRejections.first.has(item.key)) result.blocking.push(item);
      else result.repeated.push(item);
    }
    result.advisory = result.advisory.filter((i) => !carried.has(i.key));
    // merge が同じ key の cluster を複数返すと、同じ key が修正必須と参考の両方に入りうる。
    // 修正必須として渡した key の見送りは検証者を通すので、参考指摘からは外す。
    const blockingKeys = new Set([...result.blocking, ...result.repeated].map((i) => i.key));
    const advisory = uniqueByKey(result.advisory).filter((i) => !blockingKeys.has(i.key));
    // 直したと回答した参考指摘が再指摘されたら、修正には回さないが、直ったとは報告しない。
    const declinedKeys = new Set(state.advisoryDeclined.map((d) => d.key));
    for (const i of advisory)
      if (state.advisoryClosedKeys.has(i.key) && !declinedKeys.has(i.key))
        state.advisoryReappearedKeys.add(i.key);
    // 修正必須の重大度で出直したら、直した・見送ったという参考指摘としての回答では報告しない。
    // こちらは修正必須として修正に回り、その結果で報告する。
    for (const key of blockingKeys)
      if (state.advisoryClosedKeys.has(key)) state.advisoryEscalatedKeys.add(key);
    const pendingAdvisory = advisory.filter((i) => !state.advisoryClosedKeys.has(i.key));
    tracker.unverified = [];
    tracker.unverifiedAdvisory = [];
    if (result.dropped.length > 0)
      log(`有効な指摘を含まない cluster を捨てた: ${result.dropped.join(", ")}`);
    state.rounds.push({
      round: roundNo,
      pass: passNo,
      blocking: result.blocking.length,
      repeated: result.repeated.length,
      advisory: advisory.length,
      advisorySent: pendingAdvisory.length,
      advisoryFixed: 0,
      advisoryDeclined: 0,
      missingReviewers: state.lastMissingReviewers,
    });
    if (result.closedRepeats.length > 0)
      log(
        `閉じた key に統合された修正必須指摘: ${result.closedRepeats.map((i) => i.key).join(", ")}`,
      );
    state.closedRepeats.push(...result.closedRepeats);
    markUnresolved(state, result.repeated);
    state.advisory.push(...advisory);
    state.requirementsConcerns.push(...result.requirementsConcerns);
    if (result.requirementsBreaking.length > 0) {
      markUnresolved(state, result.blocking);
      state.stopReason = "requirements-breaking";
      return;
    }
    if (result.blocking.length === 0 && pendingAdvisory.length === 0) {
      pass.outcome = "converged";
      return;
    }
    if (fixRound >= state.config.maxReviewRounds) {
      pass.outcome = "capped";
      log(
        `修正ラウンドの上限 ${state.config.maxReviewRounds} に達した。残り ${result.blocking.length} 件を Unresolved にし、修正に回していない参考指摘 ${pendingAdvisory.length} 件を参考指摘として報告する`,
      );
      markUnresolved(state, result.blocking);
      return;
    }
    // runFix の途中で throw しても finally が Unresolved に残せるよう、修正に回す前に記録する。
    tracker.unverified = result.blocking;
    tracker.unverifiedAdvisory = pendingAdvisory;
    const { firstRejections, rejected, advisoryFixed } = await runFix(
      state,
      roundNo,
      result.blocking,
      pendingAdvisory,
    );
    // 結果が返らなかった修正は、どの参考指摘を直したか分からないので、渡した全件を未確認として扱う。
    tracker.unverifiedAdvisory = advisoryFixed ?? pendingAdvisory;
    if (state.stopReason) return;
    previousRejections = {
      items: result.blocking.filter((b) => rejected.has(b.key)),
      first: firstRejections,
    };
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
    if (budgetExhausted(state, `動作確認 ${attempt} 回目`)) return;
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
    if (budgetExhausted(state, `動作確認の失敗の修正 ${attempt} 回目`)) return;
    const fixLabel = `fix-verify:${attempt}`;
    const fix = await agent(fixVerifyPrompt(result, config), {
      label: fixLabel,
      phase: "Verify",
      schema: FIX_VERIFY_SCHEMA,
    });
    collectObservations(state, fixLabel, fix);
    // 動作確認の修正も人間のブランチを変えるので、checks と同じく直った場合も報告に出す。
    if (fix && Array.isArray(fix.changes))
      for (const c of fix.changes)
        state.verifyFixChanges.push({ label: fixLabel, file: c.file, summary: c.summary });
    // 直せなかった場合も途中までのコミットが残りうるので、レビューは回す。再確認はしない。
    await reviewLoop(state);
    if (state.stopReason) return;
    if (!fix || !fix.fixed) {
      state.stopReason = "verify-unfixed";
      state.stopDetail = fix ? fix.summary : "エージェントが結果を返さなかった";
      return;
    }
  }
}

async function publish(state, report, ledger) {
  phase("Publish");
  for (let attempt = 1; attempt <= 2; attempt++) {
    const written = await agent(writePrompt(report, ledger), {
      label: `publish-write:${attempt}`,
      phase: "Publish",
      schema: WRITE_SCHEMA,
    });
    if (!written) return { pushed: false, error: "書き出しのエージェントが結果を返さなかった" };
    const body = faithful(report, written.bodyLines, written.bodyBytes);
    const led = faithful(ledger, written.ledgerLines, written.ledgerBytes);
    if (body && led) {
      return agent(publishPrompt(state, written.dir), {
        label: "publish",
        phase: "Publish",
        schema: PUBLISH_SCHEMA,
      });
    }
    const broken = [!body && "pr-body.md", !led && "ledger.json"].filter(Boolean).join(", ");
    log(`書き出した ${broken} の行数・バイト数が元と一致しない(試行 ${attempt})`);
    if (attempt === 2) {
      return {
        pushed: false,
        error: `${broken} を元のとおりに書き出せなかったため、PR を作らなかった`,
      };
    }
  }
}

const config = validateArgs(args);
const state = newState(config);
// 例外(budget の上限到達など)で報告ごと失わないよう、ここまでの状態で必ず報告を組み立てる。
try {
  if (config.features.implement) await implement(state);
  if (!state.stopReason) await reviewLoop(state);
  if (!state.stopReason) await verify(state);
} catch (error) {
  state.stopReason = "error";
  state.stopDetail = String(error && error.message ? error.message : error);
}
state.outputTokens = budget.spent();
const report = renderReport(state);
const stats = renderStats(state);
const ledger = ledgerJson(state);
let published = null;
try {
  if (config.features.publish) published = await publish(state, report, ledger);
} catch (error) {
  published = { pushed: false, error: String(error && error.message ? error.message : error) };
  log(`公開に失敗した: ${published.error}`);
}
return {
  prUrl: published && published.prUrl ? published.prUrl : null,
  published: Boolean(published && published.pushed),
  publishError: published && !published.pushed ? published.error || "理由なし" : null,
  stopReason: state.stopReason,
  report,
  // 入口 skill が、引数で渡された Issue に投稿する(報告の「統計」節と同じ内容)。
  stats,
  // 公開できなかったとき、入口 skill(agent() の上限の対象外)が pr-body.md / ledger.json を書き出すのに使う。
  ledger,
};
