#!/usr/bin/env bash
# Regenerates src/scripts/startup.sh from the template + canonical sources.
#
# The VM's provisioning entrypoint must be a single file (GCE metadata
# startup_script limit), but the scripts it embeds are maintained as real,
# testable files. This build is the seam: edit the sources, run this, commit
# the generated startup.sh. Drift is caught in CI by re-running this and
# checking `git diff --exit-code`.
#
# Template tokens (one per line):
#   @@EMBED:<source>:<heredoc-delimiter>:<install-path>@@
#     -> writes <source> verbatim to <install-path> via a quoted heredoc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$ROOT/startup.sh.tmpl"
OUTPUT="$ROOT/startup.sh"

[ -f "$TEMPLATE" ] || { echo "missing template: $TEMPLATE" >&2; exit 1; }

while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*@@EMBED:([^:]+):([^:]+):([^@]+)@@$ ]]; then
    src="${BASH_REMATCH[1]}"
    delim="${BASH_REMATCH[2]}"
    dest="${BASH_REMATCH[3]}"

    file="$ROOT/$src"
    [ -f "$file" ] || { echo "missing embed source: $src" >&2; exit 1; }

    printf "  cat > %s <<'%s'\n" "$dest" "$delim"
    cat "$file"
    printf '%s\n' "$delim"
  else
    printf '%s\n' "$line"
  fi
done < "$TEMPLATE" > "$OUTPUT"

chmod 755 "$OUTPUT"
echo "regenerated: $OUTPUT"
