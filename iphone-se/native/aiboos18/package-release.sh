#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
PIN=cca2f2356008a89c7165501fe8249e7f5554ac0f
OUT="${1:?usage: package-release.sh output-directory}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
test ! -e "$OUT/web"
git -C "$ROOT" cat-file -e "$PIN^{commit}"
git -C "$ROOT" archive "$PIN" AiboOS/Web | tar -x -C "$OUT"
mv "$OUT/AiboOS/Web" "$OUT/web"
rmdir "$OUT/AiboOS"
grep -Fq "const VERSION = '1.8';" "$OUT/web/index.html"
grep -Fq "https://aibomesgsystem.wwoolf21963.workers.dev" "$OUT/web/index.html"
printf '%s\n' "$PIN" > "$OUT/source-commit.txt"
cp "$ROOT/iphone-se/native/aiboos18/system-shell.py" "$OUT/"
(cd "$OUT" && find web -type f -print0 | sort -z | xargs -0 sha256sum > WEB-SHA256SUMS && sha256sum -c WEB-SHA256SUMS)
