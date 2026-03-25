#!/bin/sh
set -eu

d="$1"
[ -f "$d" ] && d=$(dirname "$d")

g="$(basename "$(dirname "$d")")-$(basename "$d")"
exec mo -w "$d/**/*.md" -t "$g" --foreground
