#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_ROOT="$SCRIPT_DIR/reviews"
OUTPUT="$REPORT_ROOT/index.html"
OPEN_BROWSER="true"
[[ "${1:-}" != "--no-open" ]] || OPEN_BROWSER="false"

mkdir -p "$REPORT_ROOT"
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

{
  cat <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>Local AI PR Reviewer</title><style>
body{font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:1100px;margin:40px auto;padding:0 24px;background:#f6f8fb;color:#172033}header,.card{background:#fff;border-radius:12px;padding:24px;box-shadow:0 1px 4px #0002;margin:16px 0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}.card h2{margin-top:0}.links a{display:inline-block;margin:8px 12px 0 0;color:#0756b8;text-decoration:none}.empty{color:#667085}
</style></head><body><header><h1>Local AI PR Reviewer</h1><p>Saved reviews, reports, and diagnostic logs.</p></header><main class="grid">
HTML
  found="false"
  for report_dir in "$REPORT_ROOT"/pr-*; do
    [[ -d "$report_dir" ]] || continue
    found="true"
    name="$(basename "$report_dir")"
    relative="${report_dir#$REPORT_ROOT/}"
    printf '<article class="card"><h2>%s</h2><p>Folder: %s</p><div class="links">' "$(printf '%s' "$name" | html_escape)" "$(printf '%s' "$relative" | html_escape)"
    for file in review.html review.md review.log agent.log proposed-pr-comments.html proposed-pr-comments.tsv review-baseline.html review-guided.html review-comparison.html proposed-pr-comments-baseline.html proposed-pr-comments-guided.html; do
      [[ -f "$report_dir/$file" ]] || continue
      printf '<a href="%s/%s">%s</a>' "$relative" "$file" "$file"
    done
    printf '</div></article>\n'
  done
  if [[ "$found" == "false" ]]; then
    printf '<p class="empty">No completed reviews yet. Run a PR review, then refresh this page.</p>'
  fi
  printf '%s\n' '</main></body></html>'
} > "$OUTPUT"

echo "Dashboard: $OUTPUT"
if [[ "$OPEN_BROWSER" == "true" && "$(uname)" == "Darwin" ]]; then open "$OUTPUT"; fi
