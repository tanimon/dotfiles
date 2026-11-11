"""Human Touchpoint の棚卸しの集計(docs/research/human-touchpoint-inventory.md の数値の出どころ)。

使い方: python3 -I docs/research/human-touchpoint-inventory.py <out.json> [START] [END]
  START / END は UTC の ISO 形式(既定は 2026-10-12T00:00:00 〜 2026-11-12T00:00:00)。

読むもの: ~/.claude/projects/*/*.jsonl のトップレベルのファイル(メインのセッション)。subagent の
transcript は各セッションのサブディレクトリにあり、glob に掛からないので数えない。
対象のセッション: 最初に記録された cwd が個人リポジトリ(origin の owner が tanimon)か、
PERSONAL_PREFIXES のどれかで始まるもの。それ以外(仕事のリポジトリ、どのリポジトリか決められない
ディレクトリ)はすべて除外し、件数だけを scope に出す。
期間: record の timestamp が START 以上 END 未満のものだけを数える(期間をまたぐセッションは一部だけ入る)。

標準出力には件数だけを出し、典型例の抜粋は <out.json> の examples にだけ書く(transcript の本文を
画面やファイルの外に出さないため)。
"""
import collections
import glob
import json
import os
import re
import statistics
import subprocess
import sys
from datetime import datetime

out_path = sys.argv[1]
START = sys.argv[2] if len(sys.argv) > 2 else "2026-10-12T00:00:00"
END = sys.argv[3] if len(sys.argv) > 3 else "2026-11-12T00:00:00"
HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
# ~/.claude/harness は週次ジョブ(dotfiles の harness ループ)の作業場所。worktree が消えたディレクトリは
# origin を引けないので、ディレクトリ名で個人リポジトリと決める。
PERSONAL_PREFIXES = [
    ("~/orca/workspaces/chezmoi/", "dotfiles"),
    ("~/.local/share/chezmoi", "dotfiles"),
    ("~/.claude/harness", "dotfiles(週次ジョブ)"),
    ("~/orca/workspaces/software-factory-engineering/", "software-factory-engineering"),
    ("~/orca/workspaces/tanimon/", "tanimon/*"),
    ("~/ghq/github.com/tanimon/", "tanimon/*"),
]


def origin_url(cwd):
    d = cwd
    while d and d != "/":
        dotgit = os.path.join(d, ".git")
        cfg = None
        if os.path.isfile(dotgit):
            gd = open(dotgit).read().strip().split("gitdir:")[-1].strip()
            if not os.path.isabs(gd):
                gd = os.path.normpath(os.path.join(d, gd))
            common = os.path.join(gd, "commondir")
            base = os.path.normpath(os.path.join(gd, open(common).read().strip())) if os.path.exists(common) else gd
            cfg = os.path.join(base, "config")
        elif os.path.isdir(dotgit):
            cfg = os.path.join(dotgit, "config")
        if cfg:
            if not os.path.exists(cfg):
                return None
            m = re.search(r'\[remote "origin"\][^\[]*url = (\S+)', open(cfg).read())
            return m.group(1) if m else None
        d = os.path.dirname(d)
    return None


def scope_of(cwd):
    """(personal|excluded, リポジトリ名)。personal は許可リストで決め、それ以外は理由を問わず除外する。"""
    if not cwd:
        return "excluded", None
    url = origin_url(cwd) if os.path.exists(cwd) else None
    if url:
        m = re.search(r"[/:]tanimon/([^/]+?)(\.git)?/?$", url)
        return ("personal", m.group(1)) if m else ("excluded", None)
    rel = cwd.replace(HOME, "~", 1)
    for pre, name in PERSONAL_PREFIXES:
        if rel.startswith(pre):
            return "personal", name
    return "excluded", None


def ts(d):
    return (d.get("timestamp") or "")[:19]


def secs(a, b):
    try:
        return (datetime.fromisoformat(b) - datetime.fromisoformat(a)).total_seconds()
    except ValueError:
        return None


def week_of(t):
    return datetime.fromisoformat(t).strftime("%G-W%V")


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def cmd_head(cmd):
    c = re.sub(r"^(cd \S+ (&&|;) *)+", "", cmd.strip())
    c = re.sub(r"^([A-Z_]+=\S* )+", "", c)
    toks = c.split()
    if not toks:
        return "?"
    return " ".join(toks[:3 if toks[0] == "gh" else 2]) if toks[0] in ("git", "gh", "just", "pnpm", "mise", "npm") else toks[0]


def load_ask_rules():
    """現行の settings.json.tmpl の permissions.ask にある Bash の前方一致。古い record にも今の一覧を当てるので推定。"""
    here = os.path.dirname(os.path.abspath(__file__))
    tmpl = open(os.path.join(here, "..", "..", "dot_claude", "settings.json.tmpl")).read()
    m = re.search(r'"ask"\s*:\s*\[(.*?)\]', tmpl, re.S)
    return [r.rstrip(":*") for r in re.findall(r'"Bash\(([^)]*?)\)"', m.group(1))] if m else []


ASK_RULES = load_ask_rules()


GUARDS = ["git-push-guard", "curl-localhost-guard", "issue-linkage-guard"]


def replay_guards(cmd, cwd):
    """transcript はどのフックが ask を返したかを残さないので、今デプロイされている guard に同じコマンドを
    渡し直して ask を返したものを答える。guard は当時から変わっているので推定。"""
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "hook_event_name": "PreToolUse",
                          "cwd": cwd})
    hits = []
    for g in GUARDS:
        p = os.path.join(HOME, ".claude", "scripts", g + ".sh")
        if not os.path.exists(p):
            continue
        r = subprocess.run([p], input=payload, capture_output=True, text=True, timeout=20)
        if re.search(r'"permissionDecision"\s*:\s*"ask"', r.stdout):
            hits.append(g)
    return "+".join(hits) or "今の guard はどれも ask を返さない"


def approval_trigger(cmd, pd, inp, cwd):
    rc = pd.get("reasonCode") or ""
    if "create-issue.sh" in cmd:
        return "issue 作成スクリプト create-issue.sh"
    if inp.get("dangerouslyDisableSandbox"):
        return "サンドボックス外での実行"
    if rc.startswith("hook"):
        return "フック: " + replay_guards(cmd, cwd) + "(推定)"
    if rc.startswith("safetyCheck"):
        return "組込みの安全確認(safetyCheck)"
    for a in ASK_RULES:
        if re.search(r"(^|[;&|(]\s*|\s)" + re.escape(a) + r"\b", cmd):
            return "ask ルール: " + a + "(推定)"
    return "不明"


def classify_prompt(t, is_slash):
    """起動の後に人が打った prompt の分類。字面だけで決めるので、訂正は下限。"""
    if t.startswith("<bash-") or t.startswith("<local-command"):
        return "手でのシェル実行(! コマンド)"
    if re.search(r"(^|\s)Q\d+\s*[:：]", t) or re.fullmatch(r"[0-9０-９ ,、と+.]+", t) \
            or re.search(r"(全部|すべて)?推奨(案|方針)|その(案|方針)で", t):
        return "テキストの質問への回答"
    if re.search(r"マージ(した|しました)|merge \+ apply|apply.*再起動|再起動した", t):
        return "PR マージ・apply の報告"
    if re.search(r"日本語で|いや|違う|ではなく|じゃなく|やめて|戻して|間違|追加要望|ごめん、", t):
        return "訂正・追加要望"
    if re.search(r"PR(を)?(作|作成)|PR作成|push|commit|pr-body-review|マージして|PR ?を更新", t, re.I):
        return "PR 作成・push の指示"
    if is_slash:
        return "スラッシュコマンドで次の段を起動"
    if re.fullmatch(r"(OK|ok|はい|お願い|進めて|続けて|問題なし|retry|ごめん続けて|OK\. 進めて|全部はい|はい、お願い|付けて|修正お願い)[。!！]?", t):
        return "続行の合図"
    if re.search(r"[?？]\s*$|(いい|べき|できる|ある)[?？]", t):
        return "ユーザーからの質問"
    return "その他の指示"


def is_pure_acceptance(t):
    """テキストの質問への回答のうち、推奨案か「はい」を選んだだけで情報を足していないもの。"""
    if re.fullmatch(r"((全部|すべて)?推奨(案|方針)で(進めて|修正して|修正お願い|OK)?|その(案|方針)で(ok|進めて)?)[。!！]?", t, re.I):
        return True
    answers = re.findall(r"Q\d+\s*[:：]\s*([^Q]+)", t)
    return bool(answers) and all(re.fullmatch(r"(はい|推奨案で)\s*", a) for a in answers)


def classify_ask(q):
    if re.search(r"次に何|どこまで|進めますか|始めますか|コミットしますか|commit|push|PR ?を(作|出)|書き戻しますか|マージ|どこから", q, re.I):
        return "次の段・どこまで進めるか"
    if re.search(r"指摘|所見|Finding|直しますか|修正しますか", q):
        return "レビュー指摘の取捨"
    if re.search(r"削除|消し|片付け|残しますか", q):
        return "後始末・削除の可否"
    return "設計・方針の判断"


C = collections.Counter()
scope = collections.Counter()
by_repo = collections.defaultdict(collections.Counter)
by_launch = collections.defaultdict(collections.Counter)
prompt_kind = collections.Counter()
ask_kind = collections.Counter()
approve_trigger = collections.Counter()
approve_trigger_since_1101 = collections.Counter()
approve_trigger_last = {}
denial_kind = collections.Counter()
launch_kind = collections.Counter()
slash_later = collections.Counter()
week = collections.defaultdict(collections.Counter)
approve_lat, ask_lat = [], []
examples = collections.defaultdict(list)


def ex(key, value, limit=25):
    if len(examples[key]) < limit:
        examples[key].append(value)


for f in sorted(glob.glob(os.path.join(PROJECTS, "*", "*.jsonl"))):
    recs = []
    for line in open(f, errors="replace"):
        try:
            recs.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    if not any(START <= ts(d) < END for d in recs):
        continue
    cwd = next((d.get("cwd") for d in recs if d.get("cwd")), None)
    sc, repo = scope_of(cwd)
    scope[sc] += 1
    if sc != "personal":
        continue
    entry = next((d.get("entrypoint") for d in recs if d.get("entrypoint")), "?")
    C["session:" + entry] += 1
    by_repo[repo]["sessions"] += 1
    tool_name, tool_ts, tool_input = {}, {}, {}
    last_text = ""
    seen_first = False
    label = None
    sess = collections.Counter()
    for d in recs:
        t = d.get("type")
        if not START <= ts(d) < END:
            if t == "assistant":  # 期間前の tool_use も、期間内の結果の照合に使う
                for b in d.get("message", {}).get("content", []) or []:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        tool_name[b.get("id")] = b.get("name")
                        tool_ts[b.get("id")] = ts(d)
                        tool_input[b.get("id")] = b.get("input") or {}
            continue
        if t == "assistant":
            for b in d.get("message", {}).get("content", []) or []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use":
                    tool_name[b.get("id")] = b.get("name")
                    tool_ts[b.get("id")] = ts(d)
                    tool_input[b.get("id")] = b.get("input") or {}
                    if b.get("name") == "AskUserQuestion":
                        qs = (b.get("input") or {}).get("questions") or []
                        C["ask_tool_use"] += 1
                        C["ask_questions"] += len(qs)
                        sess["ask"] += 1
                        week[week_of(ts(d))]["ask"] += 1
                        for q in qs:
                            ask_kind[classify_ask(q.get("question", ""))] += 1
                            ex("ask", q.get("question", "")[:160], 60)
                elif b.get("type") == "text" and b.get("text", "").strip():
                    last_text = b["text"]
            continue
        if t == "system" and d.get("subtype") == "away_summary":
            C["away_summary"] += 1
            continue
        if t != "user":
            continue
        content = d.get("message", {}).get("content")
        pd = d.get("permissionDecision") or {}
        if d.get("toolDenialKind"):
            denial_kind[d["toolDenialKind"]] += 1
        if isinstance(content, list):
            for b in content:
                if not (isinstance(b, dict) and b.get("type") == "tool_result"):
                    continue
                tid = b.get("tool_use_id")
                name = tool_name.get(tid, "?")
                inp = tool_input.get(tid, {})
                if name == "Bash" and re.search(r"\bgh pr merge\b", inp.get("command", "")):
                    C["gh_pr_merge_attempt"] += 1
                    if not b.get("is_error"):
                        C["gh_pr_merge_ok"] += 1
                if d.get("toolDenialKind") == "user-rejected":
                    C["user_rejected:" + name] += 1
                    ex("user_rejected", {"tool": name, "text": str(b.get("content"))[:240]})
                src = pd.get("source")
                if src == "user_temporary":
                    lat = secs(tool_ts.get(tid, ""), ts(d))
                    if name == "AskUserQuestion":
                        C["ask_answered"] += 1
                        if lat is not None:
                            ask_lat.append(lat)
                        tur = d.get("toolUseResult") or {}
                        opts = {q.get("question"): [o.get("label", "") for o in q.get("options", [])]
                                for q in (tur.get("questions") or [])}
                        for q, a in (tur.get("answers") or {}).items():
                            C["ask_answer_items"] += 1
                            labels = opts.get(q, [])
                            if a not in labels:
                                C["ask_answer:自由記述か複数選択"] += 1
                            elif re.search(r"Recommended|推奨", a):
                                C["ask_answer:推奨の選択肢"] += 1
                            else:
                                C["ask_answer:推奨以外の選択肢"] += 1
                    elif name == "ExitPlanMode":
                        C["plan_approved"] += 1
                    else:
                        C["approve"] += 1
                        C["approve_tool:" + name] += 1
                        sess["approve"] += 1
                        week[week_of(ts(d))]["approve"] += 1
                        if lat is not None:
                            approve_lat.append(lat)
                        trig = approval_trigger(inp.get("command", ""), pd, inp, d.get("cwd")) if name == "Bash" else name
                        approve_trigger[trig] += 1
                        if ts(d) >= "2026-11-01":
                            approve_trigger_since_1101[trig] += 1
                        approve_trigger_last[trig] = max(approve_trigger_last.get(trig, ""), ts(d)[:10])
                        if name == "Bash":
                            ex("approve_cmd_head", cmd_head(inp.get("command", "")), 200)
                elif pd.get("decision") == "reject" and src != "user_reject":
                    C["auto_reject"] += 1
            if all(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
                continue
        txt = text_of(content).strip()
        if "[Request interrupted by user" in txt:
            C["interrupt:for_tool_use" if "for tool use" in txt else "interrupt:during_response"] += 1
            sess["interrupt"] += 1
            continue
        if d.get("isMeta"):
            continue
        human = ((d.get("origin") or {}).get("kind") == "human" or d.get("promptSource") == "typed"
                 or d.get("turnOrigin") == "human")
        if not human:
            continue
        C["prompt"] += 1
        sess["prompt"] += 1
        week[week_of(ts(d))]["prompt"] += 1
        m = re.search(r"<command-name>/?([^<]+)</command-name>", txt)
        if not seen_first:
            seen_first = True
            C["launch"] += 1
            label = "/" + m.group(1) if m else "自由記述"
            launch_kind[label] += 1
        else:
            if m:
                slash_later["/" + m.group(1)] += 1
            k = classify_prompt(txt, bool(m))
            prompt_kind[k] += 1
            if k == "テキストの質問への回答":
                C["text_answer_pure_acceptance" if is_pure_acceptance(txt) else "text_answer_with_content"] += 1
            ex("prompt:" + k, re.sub(r"\s+", " ", txt)[:140])
        last_text = ""
    for k, v in sess.items():
        by_repo[repo][k] += v
        if label:
            by_launch[label][k] += v
    if label:
        by_launch[label]["sessions"] += 1


def dist(xs):
    if not xs:
        return None
    xs = sorted(xs)
    return {"n": len(xs), "p50_sec": statistics.median(xs), "p90_sec": xs[max(0, int(len(xs) * 0.9) - 1)]}


summary = {
    "window": [START, END],
    "scope_sessions": scope,
    "counts": C,
    "by_repo": by_repo,
    "prompt_kind_after_launch": prompt_kind,
    "launch_kind": launch_kind,
    "slash_after_launch": slash_later,
    "by_launch": by_launch,
    "ask_kind": ask_kind,
    "approve_trigger": approve_trigger,
    "approve_trigger_since_2026-11-01": approve_trigger_since_1101,
    "approve_trigger_last_date": approve_trigger_last,
    "tool_denial_kind": denial_kind,
    "approve_latency": dist(approve_lat),
    "ask_latency": dist(ask_lat),
    "week": week,
}
json.dump({**summary, "examples": examples}, open(out_path, "w"), ensure_ascii=False, indent=1, default=dict)
print(json.dumps(summary, ensure_ascii=False, indent=1, default=dict))
