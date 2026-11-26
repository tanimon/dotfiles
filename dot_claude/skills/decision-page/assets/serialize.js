// 貼り戻すテキストを組み立てる。読み手は会話の文脈を失った AI でもよいように、各行に選んだ案と推奨案の
// ラベルまで載せる。末尾の「回答 n/m 問」は貼り付けが途中で切れていないかの照合に使う。
// answers: { [questionId]: { choice?: optionId | "other", text?: string, note?: string } }
// text は他の案へ選び直しても残す(画面の記述欄に残っている文字と一致させる)。出力に使うのは choice が "other" のときだけ。

// 記述が空の「その他」は回答に数えない。貼り戻しを読む側が聞き直すべき問いを見落とさないようにするため。
function isAnswered(answer) {
  if (!answer || !answer.choice) return false;
  return answer.choice !== "other" || String(answer.text || "").trim() !== "";
}

function countAnswered(data, answers) {
  return data.questions.filter((q) => isAnswered(answers[q.id])).length;
}

function serializeDecision(data, answers) {
  const block = (head, txt) => {
    const lines = String(txt || "")
      .trim()
      .split(/\r?\n/);
    return [`  ${head}: ${lines[0]}`, ...lines.slice(1).map((l) => `    ${l}`)];
  };
  const recNote = (rec, chosenId) => {
    if (!rec) return "";
    return rec.id === chosenId ? " (推奨どおり)" : ` (推奨は ${rec.id}「${rec.label}」)`;
  };
  const out = [`判断結果 ${data.id}「${data.title}」(${data.source})`];
  for (const q of data.questions) {
    const a = answers[q.id] || {};
    const rec = q.options.find((o) => o.recommended);
    if (!isAnswered(a)) {
      out.push(`${q.id} ${q.label} → 未回答${recNote(rec, null)}`);
    } else if (a.choice === "other") {
      out.push(`${q.id} ${q.label} → その他(自由記述)${recNote(rec, "other")}`);
      out.push(...block("記述", a.text));
    } else {
      const o = q.options.find((x) => x.id === a.choice);
      out.push(`${q.id} ${q.label} → ${o.id}「${o.label}」${recNote(rec, o.id)}`);
    }
    if (a.note && a.note.trim()) out.push(...block("補足", a.note));
  }
  out.push(`回答 ${countAnswered(data, answers)}/${data.questions.length} 問`);
  return out.join("\n");
}
// ブラウザでは module が無いので何もしない。Node のテストはこの行から読み込む。
if (typeof module !== "undefined") module.exports = { serializeDecision, countAnswered };
