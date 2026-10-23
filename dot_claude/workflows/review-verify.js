export const meta = {
  name: "review-verify",
  description:
    "既存のブランチに、要件文書を基準にしたレビュー修正ループと動作確認をかけて人間への報告を作る。実装・push・PR の作成はしない",
  whenToUse: "入口 skill /review-verify から起動する。直接起動しない",
  phases: [{ title: "Review" }, { title: "Verify" }],
};

// 判定はここに置いたコードで行い、agent にはさせない(ADR 0007)。
// 公開するかは、報告とローカルのコミットを見た人間が決める(ADR 0019)。
const DEFAULTS = { maxReviewRounds: 3, maxVerifyRetries: 2 };
// validateArgs が受け付ける引数のすべて。mode は持たない(ADR 0019)。
const ARG_KEYS = [
  "requirementsPath",
  "baseRef",
  "checkCommands",
  "verifySkill",
  "verifyArgs",
  "maxReviewRounds",
  "maxVerifyRetries",
];
const BUDGET_FLOOR = 100000;

// mattpocock の code-review は対話と issue tracker を前提にした手順なので、Workflow の中で止まる箇所を上書きする。
// 2 軸を 1 体に実行させないのは、skill が中で起動するサブエージェントが Workflow のエージェントから動くか
// 確かめていないため(ADR 0020)。軸ごとに別のレビュアーにして、並列化と軸の分離を Workflow 側で持つ。
const mattpocockNote = (axis) =>
  `この skill の手順のうち、${axis} 軸だけを自分で実行する。手順 1 の固定点は差分の基点で、尋ねない。手順 2 の issue tracker の検索と /setup-matt-pocock-skills の案内はせず、spec は要件文書とする。手順 4 のサブエージェントの起動と手順 5 の集約はせず、${axis} 軸の brief を自分で実行する。brief の語数制限は無視し、全ての指摘を返す。`;

// built-in の code-review は fork 型の skill で、Workflow のエージェントから Skill で呼ぶと
// 本文が返らず別エージェントとして起動するだけなので使えない(2026-09-25 実測。spec の「試作で実測すること」)。
// 構成の理由は ADR 0020。mattpocock の 2 軸はバグもセキュリティも探さないので、ecc と silent-failure がその枠を持つ。
const REVIEWERS = [
  {
    id: "mattpocock-standards",
    skill: "mattpocock-skills:code-review",
    severities: ["hard", "judgement"],
    blocking: ["hard"],
    reportsSmells: true,
    // ユーザーのグローバル規約(~/.claude など)は、リポジトリの規約ではないので含めない。
    note: `${mattpocockNote("Standards")}規約の出所は、リポジトリにある CODING_STANDARDS.md・CONTRIBUTING.md・CLAUDE.md・AGENTS.md・.claude/rules/ の配下と、サブディレクトリの CLAUDE.md / AGENTS.md とする。文書化された規約への違反は severity="hard"、判断の分かれるものは "judgement" にする。smell の基準で挙げた指摘は、smell にその名前(例: Feature Envy)を入れ、severity="judgement" にする。規約違反の指摘では smell を空にする。`,
  },
  {
    id: "mattpocock-spec",
    skill: "mattpocock-skills:code-review",
    severities: ["hard", "judgement"],
    blocking: ["hard"],
    // scope creep を修正エージェントに渡すと、要件文書に書かれていないだけの、人間が意図した機能を消しうる。
    note: `${mattpocockNote("Spec")}要件文書とのずれを指摘する。実装が要件文書と食い違う・欠けているものは severity="hard"、判断の分かれるものは "judgement" にする。要件文書に書かれていない振る舞い(scope creep)は、コードを消す指摘にせず target="requirements"・requirementsBreaking=false にする。`,
  },
  {
    id: "ecc",
    skill: "ecc-code-review",
    severities: ["CRITICAL", "HIGH", "MEDIUM", "LOW"],
    blocking: ["CRITICAL", "HIGH"],
    note: "見るのは正しさとセキュリティだけにする。Security Issues の節と Code Quality の Missing error handling に加えて、差分が誤動作する箇所(条件の取り違え、境界値、例外、回帰)を指摘する。Code Quality のそれ以外の項目(行数、ネスト、console.log、TODO/FIXME、JSDoc)と Best Practices の節は、規約を見るレビュアーが別にいるので指摘しない。",
  },
  {
    id: "silent-failure",
    agentType: "pr-review-toolkit:silent-failure-hunter",
    severities: ["CRITICAL", "HIGH", "MEDIUM"],
    blocking: ["CRITICAL", "HIGH"],
  },
];

const STOP_REASONS = {
  "checks-failing": "テスト/lint が通らないままになった",
  "reviewers-failed": "レビュアーが全員結果を返さなかった",
  "merge-failed": "指摘の統合に失敗した",
  "fixer-failed": "修正エージェントが結果を返さなかった",
  "requirements-breaking": "要件文書どおりに作ると壊れる Requirements Concern が出た",
  "verify-unfixed": "動作確認の失敗を修正エージェントが直せなかったため、再確認しなかった",
  "verify-blocked": "動作確認がブランチのコードの外にある原因で実施できなかった",
  budget: "トークン予算の残りが下限を割ったため、次の段階に進まなかった",
  error: "エージェントの実行中に例外が発生した",
};

const STRINGS = { type: "array", items: { type: "string" } };

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
          ...(reviewer.reportsSmells && { smell: { type: "string" } }),
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
          members: STRINGS,
        },
        required: ["key", "file", "summary", "members"],
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
  properties: {
    passed: { type: "boolean" },
    blocked: { type: "boolean" },
    summary: { type: "string" },
    observations: STRINGS,
  },
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

function validateArgs(input) {
  const a = input || {};
  const missing = [];
  if (typeof a.requirementsPath !== "string" || a.requirementsPath === "")
    missing.push("requirementsPath");
  if (typeof a.baseRef !== "string" || a.baseRef === "") missing.push("baseRef");
  if (!Array.isArray(a.checkCommands) || a.checkCommands.length === 0)
    missing.push("checkCommands");
  if (typeof a.verifySkill !== "string" || a.verifySkill === "") missing.push("verifySkill");
  if (missing.length > 0) {
    throw new Error(
      `review-verify: 必須の引数がありません: ${missing.join(", ")}(入口 skill /review-verify から起動してください)`,
    );
  }
  // 上限はループを止める唯一の保証なので、不正な値を既定値で黙って置き換えずに拒否する。
  const invalid = ["maxReviewRounds", "maxVerifyRetries"].filter(
    (k) => a[k] !== undefined && !(Number.isInteger(a[k]) && a[k] >= 0),
  );
  if (invalid.length > 0) {
    throw new Error(`review-verify: 0 以上の整数が必要です: ${invalid.join(", ")}`);
  }
  if (a.verifyArgs !== undefined && typeof a.verifyArgs !== "string") {
    throw new Error("review-verify: verifyArgs は文字列で渡してください");
  }
  // 知らないキーは黙って受け取らずに拒否する。綴りを誤った上限や、どの機能にも使われない引数(ADR 0015 の prBase など)を、
  // 効くと思ったまま走らせないため。
  const unknown = Object.keys(a).filter((k) => !ARG_KEYS.includes(k));
  if (unknown.length > 0) {
    throw new Error(`review-verify: 知らない引数があります: ${unknown.join(", ")}`);
  }
  // 値が undefined のキーを spread すると既定値を消し、上限が黙って外れるので、先に除く。
  const given = Object.fromEntries(Object.entries(a).filter(([, v]) => v !== undefined));
  return { ...DEFAULTS, ...given };
}

function newState(config) {
  return {
    config,
    rounds: [],
    // reviewLoop の 1 回の呼び出し(初回と、動作確認の失敗による再入)ごとの終わり方。
    reviewPasses: [],
    unresolved: [],
    unresolvedKeys: new Set(),
    deferred: [],
    deferredKeys: new Set(),
    requirementsConcerns: [],
    advisory: [],
    smells: [],
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

// budget.total は hard ceiling で、達すると以後の agent() はすべて throw する。エージェントが編集の途中で
// 打ち切られて未コミットの変更を残すことを減らすため、agent を呼ぶループの各周回の先頭で下限を割っていないか確かめる。
// BUDGET_FLOOR は次の周回の agent() 呼び出しに足りるだろうという目安で、1 回の呼び出しの使用量に上限は無いので、
// 下限を割っていなくても周回の途中で打ち切られることはある。
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

// smell は判断の分かれる指摘なので、申告された重大度にかかわらず修正必須にしない(ADR 0020)。
const isSmell = (finding) => typeof finding.smell === "string" && finding.smell !== "";

function isBlocking(finding) {
  if (isSmell(finding)) return false;
  const reviewer = REVIEWERS.find((r) => r.id === finding.reviewer);
  return Boolean(reviewer && reviewer.blocking.includes(finding.severity));
}

// target と requirementsBreaking は元の指摘(members)から導く。merge に任せるのは重複をまとめることだけで、
// merge の出力には判定の入力になる値を持たせない(ADR 0007)。
// closedKeys(Deferred / Unresolved 済み)に統合された修正必須指摘は、判定から外すが報告には残す。
function classifyRound(clusters, findingsById, previousBlockingKeys, closedKeys) {
  const out = {
    blocking: [],
    repeated: [],
    requirementsConcerns: [],
    requirementsBreaking: [],
    advisory: [],
    smells: [],
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
    // 元の指摘がすべて smell なら Smell Finding にし、修正にも収束の判定にも入れない。
    // 他のレビュアーの指摘と統合されていれば、その重大度でいつもどおり判定する。
    if (codeMembers.every(isSmell)) {
      out.smells.push(item);
      continue;
    }
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

// 要件文書は spec でもよく、ブランチの範囲より広いことがある。そのままだと「要件文書とのずれ」として
// 未着手の要件が修正必須になり、修正エージェントがそれを実装してしまう。この経路はプロンプトでしか塞げない(ADR 0019)。
// 逆に「未着手」を口実にブランチ自身の不具合を見送らせないよう、歯止めの文も必ず添える。
const unstartedScope = (rule) =>
  `\n- 要件文書のうち、このブランチがまだ着手していない項目は範囲外である。この規則は、要件文書とのずれを直す指示より優先する。${rule}ただし、このブランチが追加・変更したコードの不具合(例外、誤動作、着手済みの項目とのずれ)は、未着手の項目に関わっていても範囲外にしない。`;

const reportChanges =
  "- コードを変更したら、変更したファイルごとに、リポジトリルートからの相対パスを file に、何をなぜ変えたかを summary に書いて changes に入れる。変更しなければ空配列にする。";

function checksPrompt(config) {
  // 人間が書いたブランチに最初に触れるのがこのエージェントなので、未着手の項目を
  // 検査するテストが落ちていても、それを実装して通させない(ADR 0019)。
  // 通るように直した変更は、通った場合も報告に出す。人間のコードをレビューの前に変えているため。
  return `次のコマンドを全て実行せよ: ${commands(config)}
- 失敗があれば原因を直してコミットし(push はしない)、全て成功するまで繰り返す。
- テストを消す・スキップする・lint を無効化するなど、検査そのものを弱める変更はしない。
${reportChanges}
- 3回試しても直らなければ、passed=false と失敗内容を返す。${keepRequirements(config)}${unstartedScope("それを実装しない。未着手の項目を実装しないと通らない場合は、passed=false とし、その旨を details に書く。")}`;
}

function reviewPrompt(reviewer, config) {
  // ブランチの変更と修正は毎回コミットされるので、未コミットの変更だけを集める skill の手順では差分が空になる。
  const note = reviewer.note ? `\n- ${reviewer.note}` : "";
  const start = reviewer.skill
    ? `Skill ツールで「${reviewer.skill}」を読み込み、その手順に従って「${config.baseRef}...HEAD」の差分をレビューせよ。`
    : `あなたの役割の手順に従って「${config.baseRef}...HEAD」の差分をレビューせよ。`;
  return `${start}
- 差分の収集だけは手順を上書きする: 対象ファイルは「git diff --name-only ${config.baseRef}...HEAD」、差分は「git diff ${config.baseRef}...HEAD」で集める。変更はコミット済みなので、未コミットの変更が無くても「Nothing to review」で止まらない。
- 要件文書は ${config.requirementsPath}。
- ファイルの修正、コミット、PR へのコメント投稿、ReportFindings ツールの呼び出しはしない。結果は StructuredOutput だけで返す。
- severity には skill 自身の尺度をそのまま使う: ${reviewer.severities.join(" / ")}
- 指摘が実装ではなく要件文書そのものに向く場合は target="requirements" とし、要件文書どおりに作ると壊れる場合だけ requirementsBreaking=true にする。
- レビューの範囲外で気づいた問題は observations に書く。${unstartedScope("それが無いことを修正必須として指摘せず、observations に書く。未着手の項目だけに向く Requirements Concern は、requirementsBreaking=false にする(作業を止める理由にしない)。")}${note}`;
}

function mergePrompt(findings, knownClusters) {
  return `複数のレビュアーの指摘を統合せよ。指摘(JSON): ${JSON.stringify(findings)}
- 同じ問題を指す指摘は1つの cluster にまとめ、members に元の id を全て入れる。どの指摘も必ずちょうど1つの cluster に入れる。
- key は「ファイルパス::問題の種類を表す英小文字の短いスラッグ」とする(例: src/a.ts::missing-null-check)。
- 過去のラウンドに同じ問題があれば、その key をそのまま使う。過去の cluster(JSON): ${JSON.stringify(knownClusters)}
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
- 指摘の範囲外で気づいた問題は observations に書く。${unstartedScope("それを実装しない。実装しないと解消しない指摘は、要件文書の範囲外として propose-defer にする。")}`;
}

function deferPrompt(item, reason, config) {
  return `あなたは独立した検証者である。修正エージェントは、次の指摘を修正せずに見送ることを提案している。
指摘(JSON): ${JSON.stringify(item)}
修正エージェントの理由: ${reason}
要件文書は ${config.requirementsPath}、差分は「${config.baseRef}...HEAD」。コードと要件文書を自分で読み、見送りが妥当か判断せよ。妥当なのは、指摘が偽陽性であるか、要件文書の範囲外である場合だけ。判断に迷うなら agree=false とする。${unstartedScope("その項目が差分で本当に未着手であることを自分で確かめ、そのうえでその項目を実装しないと解消しない指摘に限り、要件文書の範囲外として見送ってよい。")}`;
}

// verifyArgs は入口 skill が人間に確かめた、動作確認 skill への起動時の明示指定(web-verify の保存場所など)。
// パスにユーザー名や組織名が入りうるので、統計には入れない。
function verifyPrompt(config) {
  const given = config.verifyArgs ? `\n- 起動時の明示指定: ${config.verifyArgs}` : "";
  return `Skill ツールで「${config.verifySkill}」を読み込み、その手順に従って、要件文書 ${config.requirementsPath} に書かれた意図どおりに変更が動くことを確認せよ。${given}
- この実行中は人間に質問できない。skill の手順が質問を求める箇所は、手順に質問できない場合の扱いが書かれていればそれに従い、書かれておらず明示指定と設定でも決められなければ確認に進まず、passed=false・blocked=true にして、決められなかった事項を summary に書く。
- 確認した操作と観察した結果を summary に書き、意図どおりに動けば passed=true にする。
- ブランチのコードの外にある原因(保存場所が決まらない、書き込みが拒否された、資格情報が無い、ポートを別のプロセスが握っているなど)で確認できなかったときは、passed=false・blocked=true にし、原因と人間が取るべき手順を summary に書く。ブランチのコードが原因でアプリが起動しない場合は blocked にしない。
- コードは修正しない。範囲外で気づいた問題は observations に書く。${unstartedScope("確認するのはこのブランチの差分が実装した範囲だけで、未着手の項目が動かないことを失敗にしない。")}`;
}

function fixVerifyPrompt(result, config) {
  return `動作確認が失敗した。結果(JSON): ${JSON.stringify(result)}
Skill ツールで「mattpocock-skills:diagnosing-bugs」を読み込み、その手順で原因を調べて直し、次のコマンドを全て成功させてから1コミットにせよ(push はしない): ${commands(config)}
- この実行は非対話で、人間に質問できない。skill が人間に相談するとする場面(失敗を再現する手順が作れない、人間の操作が要る)では、直さずに fixed=false とし、試したことを summary に書く。仮説の一覧は人間に見せず、自分の順位どおりに確かめる。
- 回帰テストを追加してよい。
${reportChanges}${keepRequirements(config)}${unstartedScope("それを実装しない。未着手の項目を実装しないと直らない場合は、fixed=false とし、その旨を summary に書く。")}`;
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
    `- 上限: maxReviewRounds ${config.maxReviewRounds} / maxVerifyRetries ${config.maxVerifyRetries}`,
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
      `  - ラウンド ${r.round}: 修正必須 ${r.blocking} / 再出現 ${r.repeated} / 参考 ${r.advisory}(修正に回した ${r.advisorySent}: 修正 ${r.advisoryFixed} / 見送り ${r.advisoryDeclined}、報告のみ ${r.advisoryReportOnly}) / Smell ${r.smells}`,
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
        lines.push(
          `- 試行 ${i + 1}: ${v.passed ? "成功" : v.blocked ? "検証できず" : "失敗"} — ${v.summary}`,
        ),
      );
    lines.push("");
  };
  const last = state.verification[state.verification.length - 1];
  const verificationFailed = Boolean(last && !last.passed);

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
  pushSection("Smell Finding", uniqueByKey(state.smells), formatItem);
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

  lines.push(renderStats(state));
  return lines.join("\n");
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
          ...(r.agentType && { agentType: r.agentType }),
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
    // 参考指摘を修正に回すのは実行全体の最初のラウンドだけ(ADR 0016)。以降に出たものは修正で生まれた
    // nit が多く、回し続けるとループが上限まで回りやすい。再入後のパスでも数え直さない。
    const advisoryToFix = roundNo === 1 ? pendingAdvisory : [];
    const converged = result.blocking.length === 0 && advisoryToFix.length === 0;
    const capped = !converged && fixRound >= state.config.maxReviewRounds;
    const runsFix = result.requirementsBreaking.length === 0 && !converged && !capped;
    const advisorySent = runsFix ? advisoryToFix.length : 0;
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
      advisorySent,
      advisoryReportOnly: pendingAdvisory.length - advisorySent,
      advisoryFixed: 0,
      advisoryDeclined: 0,
      smells: result.smells.length,
      missingReviewers: state.lastMissingReviewers,
    });
    if (result.closedRepeats.length > 0)
      log(
        `閉じた key に統合された修正必須指摘: ${result.closedRepeats.map((i) => i.key).join(", ")}`,
      );
    state.closedRepeats.push(...result.closedRepeats);
    markUnresolved(state, result.repeated);
    state.advisory.push(...advisory);
    state.smells.push(...result.smells);
    state.requirementsConcerns.push(...result.requirementsConcerns);
    if (result.requirementsBreaking.length > 0) {
      markUnresolved(state, result.blocking);
      state.stopReason = "requirements-breaking";
      return;
    }
    if (converged) {
      pass.outcome = "converged";
      return;
    }
    if (capped) {
      pass.outcome = "capped";
      log(
        `修正ラウンドの上限 ${state.config.maxReviewRounds} に達した。残り ${result.blocking.length} 件を Unresolved にし、修正に回していない参考指摘 ${pendingAdvisory.length} 件を参考指摘として報告する`,
      );
      markUnresolved(state, result.blocking);
      return;
    }
    // runFix の途中で throw しても finally が Unresolved に残せるよう、修正に回す前に記録する。
    tracker.unverified = result.blocking;
    tracker.unverifiedAdvisory = advisoryToFix;
    const { firstRejections, rejected, advisoryFixed } = await runFix(
      state,
      roundNo,
      result.blocking,
      advisoryToFix,
    );
    // 結果が返らなかった修正は、どの参考指摘を直したか分からないので、渡した全件を未確認として扱う。
    tracker.unverifiedAdvisory = advisoryFixed ?? advisoryToFix;
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
    // コードの外の原因は修正エージェントでは直らず、直そうとするとブランチを無関係に書き換える。
    if (result && result.blocked) {
      state.stopReason = "verify-blocked";
      return;
    }
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

const config = validateArgs(args);
const state = newState(config);
// 例外(budget の上限到達など)で報告ごと失わないよう、ここまでの状態で必ず報告を組み立てる。
try {
  await reviewLoop(state);
  if (!state.stopReason) await verify(state);
} catch (error) {
  state.stopReason = "error";
  state.stopDetail = String(error && error.message ? error.message : error);
}
state.outputTokens = budget.spent();
const report = renderReport(state);
const stats = renderStats(state);
const ledger = ledgerJson(state);
return {
  stopReason: state.stopReason,
  report,
  // 入口 skill が、引数で渡された Issue に投稿する(報告の「統計」節と同じ内容)。
  stats,
  // 入口 skill が report と一緒に ledger.json に書き出す(Workflow のスクリプトには fs が無い)。
  ledger,
};
