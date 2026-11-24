#!/usr/bin/env bash
# apply-defense.sh - apply (or revert) the josev defense prototype patch on
# the honest stack used by scripts/40 and scripts/80.
#
#   defense/apply-defense.sh [WORKDIR]            apply   (default ~/pnc-relay)
#   defense/apply-defense.sh [WORKDIR] --revert   back to pristine 676b315
#
# The patch is applied to the honest/ clone AND copied into the installed
# package inside venv-honest, because the run scripts execute the
# pip-installed copy (see the comments in scripts/40-relay-attack-josev.sh).
# The patched behavior is gated on the DEFENDED environment variable, so
# once the patch is applied, baseline and defended runs differ only by that
# env var - no code changes between modes.
set -euo pipefail

SCAFFOLD="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$HOME/pnc-relay}"
REVERT="${2:-}"
JOSEV_COMMIT="676b315"
PATCH="$SCAFFOLD/defense/josev-defense.patch"
FILES="iso15118/shared/defense.py
iso15118/evcc/states/iso15118_2_states.py
iso15118/secc/states/iso15118_2_states.py"

HONEST="$WORK/honest"
[[ -d "$HONEST/.git" ]] || {
  echo "no josev clone at $HONEST - run scripts/40-relay-attack-josev.sh first" >&2
  exit 1
}
[[ -x "$WORK/venv-honest/bin/python" ]] || {
  echo "no venv-honest at $WORK - run scripts/40-relay-attack-josev.sh first" >&2
  exit 1
}

if [[ "$REVERT" == "--revert" ]]; then
  git -C "$HONEST" checkout -q "$JOSEV_COMMIT" -- iso15118/
  rm -f "$HONEST/iso15118/shared/defense.py"
  echo "reverted $HONEST to pristine $JOSEV_COMMIT"
else
  # Clean base, then verify the patch applies before touching anything.
  git -C "$HONEST" checkout -q "$JOSEV_COMMIT" -- iso15118/
  git -C "$HONEST" apply --check "$PATCH"
  git -C "$HONEST" apply "$PATCH"
  echo "applied $(basename "$PATCH") to $HONEST"
fi

# Sync the installed copy the scripts actually execute.
PKG_DIR="$("$WORK/venv-honest/bin/python" -c \
  'import os, iso15118; print(os.path.dirname(iso15118.__file__))')"
echo "$FILES" | while read -r f; do
  [[ -n "$f" ]] || continue
  dest="$PKG_DIR/${f#iso15118/}"
  if [[ -f "$HONEST/$f" ]]; then
    cp "$HONEST/$f" "$dest"
  else
    rm -f "$dest"
  fi
done

if [[ "$REVERT" == "--revert" ]]; then
  echo "venv-honest: restored pristine modules"
else
  "$WORK/venv-honest/bin/python" -c "import iso15118.shared.defense" \
    && echo "venv-honest: defense module importable"
fi
