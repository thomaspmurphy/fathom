#!/usr/bin/env bash
#
# Checks Fathom's references against `mix xref callers`, for one module.
#
#     bench/verify_against_xref.sh <repo> <program.db> <Module>
#
# `mix xref` is the right oracle here. It reads the same compiler output
# Fathom does, but through an entirely separate code path — Mix's own manifest
# rather than a tracer — so agreement is evidence about the tracer rather than
# a tautology.
#
# It reports any reference to the module, where Fathom separates calls from
# bare references, so the comparison is against the union of `calls` and
# `alias_refs`. Fathom additionally keeps self-references, which xref drops, so
# the module's own file is expected to appear only on Fathom's side.

set -euo pipefail

# `comm` compares under the current collation and silently produces nonsense if
# its inputs were ordered under a different one, so fix the locale for the
# whole script rather than per-command.
export LC_ALL=C

repo="${1:?usage: verify_against_xref.sh <repo> <program.db> <Module>}"
db="$(cd "$(dirname "${2:?}")" && pwd)/$(basename "${2}")"
module="${3:?}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

(cd "$repo" && mix xref callers "$module" 2>/dev/null) \
  | grep -oE '^lib/[^ ]+' | sort -u > "$work/xref.txt"

sqlite3 "$db" "
  SELECT DISTINCT file FROM alias_refs WHERE module = '$module'
  UNION
  SELECT DISTINCT file FROM calls WHERE callee_module = '$module';
" | sort -u > "$work/fathom.txt"

printf 'module:  %s\n' "$module"
printf 'xref:    %s files\n' "$(wc -l < "$work/xref.txt" | tr -d ' ')"
printf 'fathom:  %s files\n\n' "$(wc -l < "$work/fathom.txt" | tr -d ' ')"

missed="$(comm -23 "$work/xref.txt" "$work/fathom.txt")"

if [ -n "$missed" ]; then
  echo "FAIL — xref found references Fathom did not:"
  echo "$missed"
  exit 1
fi

echo "OK — Fathom found every reference xref did."

extra="$(comm -13 "$work/xref.txt" "$work/fathom.txt")"
if [ -n "$extra" ]; then
  echo
  echo "Additionally found by Fathom (self-references are expected here):"
  echo "$extra"
fi
