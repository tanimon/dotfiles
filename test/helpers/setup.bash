# Shared bats-support/bats-assert loader for every suite under test/.
# `load` always resolves relative to $BATS_TEST_DIRNAME (the directory of the
# .bats file that started the load chain), which is `test/` for every suite
# in this repo — so `../node_modules/...` is correct here even though this
# file itself lives in test/helpers/.
load '../node_modules/bats-support/load'
load '../node_modules/bats-assert/load'
