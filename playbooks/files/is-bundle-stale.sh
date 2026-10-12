#!/usr/bin/env bash
# Helper: detect if a Vite app's source is newer than its dist/ (stale build).
# Usage: is-bundle-stale.sh <app_path>
# Output: "missing" if dist/index.html doesn't exist, "stale" if any source is
#         newer than dist/index.html, "fresh" if dist is up-to-date.
set -e
app="$1"
if [ ! -f "$app/dist/index.html" ]; then
  echo "missing"
  exit 0
fi
# Newest source: src/, index.html, package.json
newest_src=$(find "$app/src" "$app/index.html" "$app/package.json" -type f \
  -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
newest_src=${newest_src:-0}
newest_dist=$(stat -c '%Y' "$app/dist/index.html")
# Compare as integers (truncate float)
newest_src_int=$(printf "%.0f" "$newest_src")
if [ "$newest_src_int" -gt "$newest_dist" ]; then
  echo "stale"
else
  echo "fresh"
fi
