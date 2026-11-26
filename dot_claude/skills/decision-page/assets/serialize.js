// 貼り戻すテキストを組み立てる。読み手は会話の文脈を失った AI でもよいように、各行に選んだ案と推奨案の
// ラベルまで載せる。末尾の「回答 n/m 問」は貼り付けが途中で切れていないかの照合に使う。
// answers: { [questionId]: { choice?: optionId | "other", text?: string, note?: string } }
function serializeDecision(data, answers) {
  const block = (head, txt) => {
    const ls = String(txt || "")
      .trim()
      .split(/\r?\n/);
    return [`  ${head}: ${ls[0]}`, ...ls.slice(1).map((l) => `    ${l}`)];
  };
  const recOf = (q) => q.options.find((o) => o.recommended);
  const recNote = (r, chosenId) => {
    if (!r) return "";
    return r.id === chosenId ? " (推奨どおり)" : ` (推奨は ${r.id}「${r.label}」)`;
  };
  const answered = data.questions.filter((q) => answers[q.id] && answers[q.id].choice).length;
  const out = [`判断結果 ${data.id}「${data.title}」(${data.source})`];
  for (const q of data.questions) {
    const a = answers[q.id] || {};
    const r = recOf(q);
    if (!a.choice) {
      out.push(`${q.id} ${q.label} → 未回答${recNote(r, null)}`);
    } else if (a.choice === "other") {
      out.push(`${q.id} ${q.label} → その他(自由記述)${recNote(r, "other")}`);
      out.push(...block("記述", a.text));
    } else {
      const o = q.options.find((x) => x.id === a.choice);
      out.push(`${q.id} ${q.label} → ${o.id}「${o.label}」${recNote(r, o.id)}`);
    }
    if (a.note && a.note.trim()) out.push(...block("補足", a.note));
  }
  out.push(`回答 ${answered}/${data.questions.length} 問`);
  return out.join("\n");
}
if (typeof module !== "undefined") module.exports = { serializeDecision };
