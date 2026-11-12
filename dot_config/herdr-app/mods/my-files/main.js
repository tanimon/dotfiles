// フォーカス中のペインの作業フォルダと、space ごとにピン留めしたフォルダをタブで切り替えて表示するファイルブラウザ。
// 同梱の files mod を複製したもの(同梱側の更新はこちらに届かない)。プレビューは読み取り専用で上限付き。
// ピンは shared("my-files.pins") に { [space id]: [絶対パス, ...] } で保存する。
// pickFolder と watchFolder はこのマシンでしか動かないため、ピンは常にローカルのフォルダとして扱う。
import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex, Editor, EditorState } from "gpui-base";
import {
  spaces,
  panes,
  focused,
  exec,
  readTextFile,
  watchFolder,
  theme,
  settings,
  window,
  shared,
  setShared,
  pickFolder,
} from "herdr";

const PINS = "my-files.pins";
const CWD = "cwd";
// 表示から外れたルートの展開状態を何個まで覚えておくか。cd やフォーカス移動のたびに作業フォルダのルートが替わるため上限を置く。
const CACHE = 24;
const LANG = {
  ts: "js",
  tsx: "js",
  mts: "js",
  cts: "js",
  jsx: "js",
  mjs: "js",
  toml: "yaml",
  jsonc: "json",
  svelte: "html",
  vue: "html",
};
const PER_FOLDER = 500,
  TOTAL = 5000;

function location() {
  const space = spaces().find((s) => s.active),
    f = focused();
  const pane = f?.pane ? panes().find((p) => p.pane === f.pane) : null;
  const on =
    f?.pane === null
      ? f.terminal?.includes("/")
        ? f.terminal.split("/")[0]
        : null
      : (space?.machine ?? null);
  return { cwd: pane?.cwd || f?.cwd || space?.folder, on, space: space?.id };
}

function pinsOf(space) {
  const all = shared(PINS);
  const list = space && all && typeof all === "object" ? all[space] : null;
  return Array.isArray(list) ? list.filter((p) => typeof p === "string") : [];
}

function setPins(space, list) {
  const all = { ...shared(PINS) };
  if (list.length) all[space] = list;
  else delete all[space];
  setShared(PINS, all);
}

// タブの一覧。作業フォルダ(id は CWD)が先頭、ピン(id はそのパス)がその右。作業フォルダと同じピンは 1 つにまとめる。
function wanted() {
  const loc = location(),
    pins = pinsOf(loc.space),
    list = [];
  const cwdIsPin = Boolean(loc.cwd) && !loc.on && pins.includes(loc.cwd);
  if (loc.cwd) list.push({ id: CWD, path: loc.cwd, on: loc.on ?? null, pinned: cwdIsPin });
  for (const p of pins)
    if (!(cwdIsPin && p === loc.cwd)) list.push({ id: p, path: p, on: null, pinned: true });
  return { space: loc.space, list };
}

const rootKey = (path, on) => `${on ?? ""}:${path}`;
const baseName = (path) =>
  path
    .replace(/[\\/]+$/, "")
    .split(/[\\/]/)
    .pop() || path;

async function directory(path, on) {
  const windowsDirectory = async () => {
    // Windows PowerShell otherwise uses the console code page; exec decodes UTF-8.
    // Links keep directory attributes even when dangling; check their target.
    // Other reparse points (OneDrive's folders) have no LinkType and are folders.
    // PowerShell reads curly single quotes as quotes too, so they're doubled like '.
    const r = await exec(
      "powershell",
      [
        "-NoProfile",
        "-Command",
        "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); & { param($p) @(Get-ChildItem -LiteralPath $p -Force -ErrorAction Stop | Where-Object Name -ne '.git' | Select-Object -First 501 | ForEach-Object { @{ name=$_.Name; dir=($_.PSIsContainer -and (-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $_.LinkType -or ($_.Target -and [IO.Directory]::Exists(([IO.Path]::Combine([IO.Path]::GetDirectoryName($_.FullName), $_.Target[0])))))) } }) | ConvertTo-Json -Compress } '" +
          path.replace(/['‘’‚‛]/g, "$&$&") +
          "'",
      ],
      { on },
    );
    if (r.code !== 0) throw new Error(r.stderr || "Cannot list this folder");
    const result = JSON.parse(r.stdout || "[]");
    return Array.isArray(result) ? result : [result];
  };
  if (!on && window()?.platform === "windows") return windowsDirectory();
  const script =
    'n=0; for p in "$1"/* "$1"/.[!.]* "$1"/..?*; do [ -e "$p" ] || [ -L "$p" ] || continue; name=${p##*/}; [ "$name" = .git ] && continue; if [ -d "$p" ]; then kind=d; else kind=f; fi; printf "%s\\0%s\\0" "$kind" "$name"; n=$((n+1)); [ "$n" -gt 500 ] && break; done; test -d "$1"';
  let r;
  try {
    r = await exec("sh", ["-c", script, "files", path], { on });
  } catch (e) {
    if (on && String(e).includes("cannot start sh: program not found")) return windowsDirectory();
    throw e;
  }
  if (r.code !== 0) throw new Error(r.stderr || "Cannot list this folder");
  const fields = r.stdout.split("\0"),
    out = [];
  for (let i = 0; i + 1 < fields.length; i += 2)
    out.push({ name: fields[i + 1], dir: fields[i] === "d" });
  return out;
}

// 1 つのルートフォルダの木と git の印。結果はこのオブジェクトに書くので、タブを切り替えても書き込み先は壊れない。
class Root {
  constructor(path, on) {
    this.path = path;
    this.on = on;
    this.key = rootKey(path, on);
    this.entries = new Map();
    this.folders = new Set();
    this.pending = new Set();
    this.marks = {};
    this.error = null;
    this.loading = false;
    this.limited = false;
    this.shown = false;
    this.watching = false;
    // 表示から外れたときに開いていたプレビューの相対パス。このルートに戻ったら開き直す。
    this.preview = null;
  }

  async loadFolder(path) {
    const entries = await directory(path ? `${this.path}/${path}` : this.path, this.on);
    if (path && !this.folders.has(path)) return;
    const used = [...this.entries.entries()]
      .filter(([p]) => p !== path)
      .reduce((n, [, e]) => n + e.length, 0);
    this.entries.set(
      path,
      entries
        .slice(0, Math.max(0, Math.min(PER_FOLDER, TOTAL - used)))
        .sort((a, b) => Number(b.dir) - Number(a.dir) || a.name.localeCompare(b.name)),
    );
    if (entries.length > PER_FOLDER || used + entries.length > TOTAL) this.limited = true;
  }

  refresh(cx) {
    if (this.loading || !this.shown) return;
    this.loading = true;
    this.limited = false;
    cx.spawn(async (cx) => {
      try {
        for (const path of ["", ...this.folders]) await this.loadFolder(path);
        const { path: cwd, on } = this;
        const top = await exec("git", ["rev-parse", "--show-toplevel"], { cwd, on }).catch(
          () => null,
        );
        const marks = {};
        if (top?.code === 0) {
          // Writes nothing under .git (index lock, fsmonitor cookie): the folder watch would refresh again.
          const status = await exec(
            "git",
            [
              "--no-optional-locks",
              "-c",
              "core.fsmonitor=false",
              "status",
              "--porcelain=v1",
              "-z",
              "--no-renames",
              "--untracked-files=all",
            ],
            { cwd, on },
          ).catch(() => null);
          if (status?.code === 0)
            for (const entry of status.stdout.split("\0").filter(Boolean).slice(0, TOTAL)) {
              const xy = entry.slice(0, 2);
              marks[`${top.stdout.trim()}/${entry.slice(3)}`] =
                xy === "??" || xy.includes("A")
                  ? "A"
                  : xy.includes("U")
                    ? "U"
                    : xy.includes("D")
                      ? "D"
                      : "M";
            }
        }
        this.marks = marks;
        this.error = null;
        this.watch(cx);
      } catch (e) {
        this.error = String(e);
      } finally {
        this.loading = false;
        cx.notify();
      }
    });
  }

  // 表示中のあいだだけ監視する。表示から外れたループは、次の変更で watchFolder が返ったところで抜ける。
  watch(cx) {
    if (this.on || this.watching || !this.shown) return;
    this.watching = true;
    cx.spawn(async (cx) => {
      try {
        while (this.shown) {
          await watchFolder(this.path);
          if (this.shown) this.refresh(cx);
        }
      } catch {
        /* 監視できないフォルダは 10 秒ごとの再読込だけで追う */
      } finally {
        this.watching = false;
      }
    });
  }

  toggle(path, cx) {
    if (this.folders.has(path)) {
      for (const folder of [...this.folders])
        if (folder === path || folder.startsWith(path + "/")) {
          this.folders.delete(folder);
          this.entries.delete(folder);
        }
    } else {
      this.folders.add(path);
      if (!this.entries.has(path) && !this.pending.has(path)) {
        this.pending.add(path);
        cx.spawn(async (cx) => {
          try {
            await this.loadFolder(path);
          } catch (e) {
            this.error = String(e);
          } finally {
            this.pending.delete(path);
            cx.notify();
          }
        });
      }
    }
    cx.notify();
  }
}

export default class Files extends View {
  init(_props, cx) {
    // selected: space id → 選んでいるタブの id。そのタブが一覧に無ければ先頭のタブ(作業フォルダがあればそれ)を表示する。
    this.cache = new Map();
    this.selected = new Map();
    this.tabs = [];
    this.space = null;
    this.root = null;
    this.shownKey = null;
    this.file = null;
    this.code = null;
    this.fileError = null;
    this.sync(cx);
    cx.timer.every(10000, (cx) => {
      this.sync(cx);
      this.root?.refresh(cx);
    });
  }

  // タブの一覧と選択中のルートを wanted() と選択に合わせ、新しく表示に入ったルートを読み込む。
  sync(cx) {
    const { space, list } = wanted();
    const want = this.selected.get(space) ?? CWD;
    const item = list.find((i) => i.id === want) ?? list[0] ?? null;
    const next = JSON.stringify([space, list, item?.id ?? null]);
    if (next === this.shownKey) return;
    this.shownKey = next;
    this.space = space;
    this.tabs = list;
    let root = null;
    if (item) {
      const k = rootKey(item.path, item.on);
      root = this.cache.get(k);
      if (!root) root = new Root(item.path, item.on);
      // 使った順に並べ直し、古いものから捨てる。
      this.cache.delete(k);
      this.cache.set(k, root);
      for (const [key] of this.cache) {
        if (this.cache.size <= CACHE) break;
        if (key !== k) this.cache.delete(key);
      }
    }
    if (this.root !== root) {
      if (this.root) {
        this.root.shown = false;
        this.root.preview = this.file?.root === this.root ? this.file.path : null;
      }
      this.root = root;
      if (root) {
        root.shown = true;
        root.refresh(cx);
      }
      if (this.file?.root !== root)
        this.show(root?.preview ? { root, path: root.preview } : null, cx);
    }
  }

  select(id, cx) {
    if (this.space) this.selected.set(this.space, id);
    this.sync(cx);
  }

  pin(path) {
    if (!this.space || !path) return;
    const pins = pinsOf(this.space);
    if (!pins.includes(path)) setPins(this.space, [...pins, path]);
  }

  unpin(path) {
    if (!this.space) return;
    // 選択を残すと、同じフォルダを後でピン留めし直したときにそのタブが勝手に選ばれる。
    if (this.selected.get(this.space) === path) this.selected.delete(this.space);
    setPins(
      this.space,
      pinsOf(this.space).filter((p) => p !== path),
    );
  }

  addPin(cx) {
    cx.spawn(async (cx) => {
      const picked = await pickFolder({ prompt: "Pin" });
      if (picked) {
        const path = picked.replace(/(.)[\\/]+$/, "$1");
        this.pin(path);
        this.select(path, cx);
      }
      cx.notify();
    });
  }

  show(file, cx) {
    this.code?.release();
    this.code = null;
    this.file = file;
    this.fileError = null;
    if (!file || !cx) return;
    const { root, path } = file;
    cx.spawn(async (cx) => {
      try {
        const text = await readTextFile(`${root.path}/${path}`, { on: root.on });
        if (this.file !== file) return;
        if (text === null) {
          this.fileError = "This file is no longer available";
          return;
        }
        if (text.includes("\0")) {
          this.fileError = "Binary file · no text preview";
          return;
        }
        const t = theme(),
          ext = path.includes(".") ? path.split(".").pop() : "txt";
        this.code = EditorState.new({
          language: LANG[ext] ?? ext,
          readonly: true,
          value: text.length > 400000 ? text.slice(0, 400000) + "\n… (file truncated)" : text,
          font_family: settings().font_family,
          font_size: 12,
          syntax: {
            keyword: t.ansi5,
            string: t.ansi2,
            comment: t.dim,
            function: t.ansi4,
            type: t.ansi3,
            number: t.ansi1,
            constant: t.ansi6,
          },
        });
      } catch {
        if (this.file === file)
          this.fileError = "Cannot preview this file (binary, too large, or unreadable)";
      } finally {
        cx.notify();
      }
    });
  }

  rows(root, prefix, depth, out, t) {
    if (out.length >= TOTAL || depth > 40) return out;
    for (const entry of root.entries.get(prefix) ?? []) {
      if (out.length >= TOTAL) break;
      const path = prefix ? `${prefix}/${entry.name}` : entry.name,
        open = root.folders.has(path),
        mark = root.marks[`${root.path}/${path}`];
      out.push(
        h_flex()
          .id(`file-${path}`)
          .h(28)
          .flex_none()
          .pl(8 + depth * 18)
          .pr(8)
          .gap(7)
          .items_center()
          .rounded(7)
          .cursor_pointer()
          .hover((s) => s.bg(t.hover))
          .on_click((_e, cx) => (entry.dir ? root.toggle(path, cx) : this.show({ root, path }, cx)))
          .child(
            entry.dir
              ? svg(`mods/my-files/chevron-${open ? "down" : "right"}.svg`)
                  .size(12)
                  .flex_none()
                  .text_color(t.dim)
              : div().w(12).flex_none(),
          )
          .child(
            svg(`mods/my-files/${entry.dir ? "folder" : "file"}.svg`)
              .size(14)
              .flex_none()
              .text_color(t.muted),
          )
          .child(div().flex_1().min_w(0).truncate().child(entry.name))
          .when(Boolean(mark), (el) =>
            el.child(
              div()
                .text_size(11)
                .text_color(
                  mark === "A" ? t.ansi2 : mark === "D" || mark === "U" ? t.ansi1 : t.blocked,
                )
                .child(mark),
            ),
          ),
      );
      if (entry.dir && open) this.rows(root, path, depth + 1, out, t);
    }
    return out;
  }

  tabStrip(t) {
    const active = this.root
      ? this.tabs.find((i) => rootKey(i.path, i.on) === this.root.key)
      : null;
    // タブの中のボタン。押下をタブまで伝えると、ボタンのつもりでタブが切り替わる。
    const action = (id, label, fn) =>
      div()
        .id(id)
        .px(4)
        .h(16)
        .flex_none()
        .rounded(4)
        .text_size(11)
        .text_color(t.dim)
        .cursor_pointer()
        .hover((s) => s.bg(t.raised).text_color(t.foreground))
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
        .on_click((_e, cx) => {
          cx.stop_propagation();
          fn(cx);
          cx.notify();
        })
        .child(label);
    const tab = (item, i) => {
      const isActive = item === active;
      return h_flex()
        .id(`tab-${i}`)
        .h(26)
        .max_w(180)
        .flex_none()
        .px(8)
        .gap(5)
        .items_center()
        .rounded(6)
        .cursor_pointer()
        .bg(isActive ? t.selected : t.background)
        .text_color(isActive ? t.foreground : t.muted)
        .hover((s) => s.bg(isActive ? t.selected : t.hover))
        .on_click((_e, cx) => {
          this.select(item.id, cx);
          cx.notify();
        })
        .child(
          svg("mods/my-files/folder.svg")
            .size(12)
            .flex_none()
            .text_color(item.id === CWD ? t.accent : t.dim),
        )
        .child(div().min_w(0).truncate().text_size(12).child(baseName(item.path)))
        .when(item.pinned, (el) =>
          el.child(action(`tab-${i}-unpin`, "×", () => this.unpin(item.path))),
        )
        .when(
          isActive && !item.pinned && item.id === CWD && !item.on && Boolean(this.space),
          (el) => el.child(action(`tab-${i}-pin`, "Pin", () => this.pin(item.path))),
        );
    };
    return h_flex()
      .h(36)
      .flex_none()
      .px(6)
      .gap(4)
      .items_center()
      .border_b(1)
      .border_color(t.border)
      .child(
        h_flex()
          .id("files-tabs")
          .flex_1()
          .min_w(0)
          .h_full()
          .gap(4)
          .items_center()
          .overflow_x_scrollbar()
          .children(this.tabs.map(tab)),
      )
      .when(Boolean(this.space), (el) =>
        el.child(
          h_flex()
            .id("files-add")
            .w(22)
            .h(22)
            .flex_none()
            .items_center()
            .justify_center()
            .rounded(5)
            .cursor_pointer()
            .text_color(t.muted)
            .hover((s) => s.bg(t.hover).text_color(t.foreground))
            .on_click((_e, cx) => this.addPin(cx))
            .child("+"),
        ),
      );
  }

  render(cx) {
    this.sync(cx);
    const t = theme(),
      root = this.root;
    const rows = root ? this.rows(root, "", 0, [], t) : [];
    const note = !root
      ? "No folder"
      : rows.length
        ? root.error
        : root.error || (root.loading ? "Loading files…" : "No files");
    const path = this.file
      ? `${baseName(this.file.root.path)}/${this.file.path}`
      : root
        ? `${root.on ? root.on + ":" : ""}${root.path}`
        : "";
    return v_flex()
      .id("files")
      .size_full()
      .min_h(0)
      .rounded(10)
      .overflow_hidden()
      .bg(t.background)
      .border_1()
      .border_color(t.border)
      .text_color(t.foreground)
      .text_size(13)
      .child(
        h_flex()
          .h(42)
          .flex_none()
          .px(14)
          .gap(8)
          .items_center()
          .border_b(1)
          .border_color(t.border)
          .when(Boolean(this.file), (el) =>
            el.child(
              div()
                .id("files-back")
                .w(20)
                .cursor_pointer()
                .text_color(t.muted)
                .on_click((_e, cx) => {
                  this.show(null);
                  cx.notify();
                })
                .child("←"),
            ),
          )
          .child(div().font_semibold().child("Files"))
          .child(
            div()
              .flex_1()
              .min_w(0)
              .truncate()
              .text_right()
              .text_size(12)
              .text_color(t.dim)
              .child(path),
          ),
      )
      .when(!this.file, (el) => el.child(this.tabStrip(t)))
      .when(!this.file, (el) =>
        el.child(
          v_flex()
            .id("files-tree")
            .flex_1()
            .min_h(0)
            .overflow_y_scrollbar()
            .p(6)
            .children(rows)
            .when(Boolean(note), (el) =>
              el.child(div().p(8).text_size(12).text_color(t.dim).child(note)),
            )
            .when(Boolean(root?.limited), (el) =>
              el.child(
                div()
                  .p(8)
                  .text_size(11)
                  .text_color(t.dim)
                  .child("File list limited to 500 entries per folder and 5,000 total"),
              ),
            ),
        ),
      )
      .when(Boolean(this.file), (el) =>
        el.child(
          this.code
            ? Editor.new(this.code).flex_1().min_h(0)
            : div()
                .p(12)
                .text_color(t.dim)
                .child(this.fileError || "Loading file…"),
        ),
      );
  }
}
