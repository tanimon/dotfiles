# 照合モードの kind ごとの修正案

`audit.sh` の出力 `<kind> <issue> <根拠>` から修正案を作る手順。張るコマンドは [relationship-api.md](relationship-api.md) にある。

- `parent-missing` / `blocked-by-missing`: native に張る。
- `parent-mismatch`: 本文と API で親が違う。どちらが正しいかは人が決める。本文が正しければ親の付け替えのコマンドで直し、API が正しければ本文の Parent 節を直す。
- `open-after-merge`: `gh issue close <issue> --reason completed --comment "PR #<n> のマージで解決済み(Closes による自動 close が効かなかった)"`。
- `mentioned-by-merged`: Closes を書き忘れた PR の候補にすぎない。PR の本文と差分(`gh pr view <n> --json body,files`)と issue の AC を読み、解決したと言える場合だけ close の候補にする。言えなければ「言及のみ」として報告に載せ、操作は提案しない。
- `ac-unchecked`: 根拠のマージ済み PR(複数あればすべて)の本文(`gh pr view <n> --json body`)の AC 対応表で、その項目を満たしたと書いてあるものだけを `[x]` にする候補にする。対応表に無い項目や、理由を書いて意図的に `[ ]` のまま残した項目は触らず、報告に載せる。

## AC を `[x]` にする適用の手順

`gh issue view <issue> --json body --jq .body > <scratchpad>/issue-<issue>.md` で本文を保存し、Edit ツールで該当行の `- [ ]` だけを `- [x]` に直してから `gh issue edit <issue> --body-file <scratchpad>/issue-<issue>.md` で戻す。

- `<scratchpad>` はセッションの scratchpad ディレクトリの展開済みの絶対パス。`$TMPDIR` は使わない(sandbox の外で動く gh と内側とで指す場所が変わりうるうえ、Edit ツールは展開できない)。
- `gh issue edit` は ticket-guard の対象外なので、`.git` の下に置かなくてよい(`.git` の下は sandbox で書けないことがある)。
