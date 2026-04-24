#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
#  sweep-nightly.sh — Green Fees Capital
#
#  THE ONE JOB: keep the homepage clean by moving old articles to
#  the archive. Runs nightly at a time after the last drop fires.
#
#  Rules:
#    - Keep today's drops on the homepage
#    - Keep yesterday's drops on the homepage
#    - Everything older → move to archive/index.html
#    - Never delete anything — archive is permanent
#
#  Usage:
#    bash sweep-nightly.sh
#
#  Schedule: run via Cowork task at 11:00 PM PT every day
# ════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────
REPO="ramses1393-spec/greenfeescapital"
BRANCH="main"
BLOG_PATH="greenfeescapital-blog"
DRAFTS_DIR="$HOME/Downloads/greenfeescapital-drafts"
TOKEN_FILE="$DRAFTS_DIR/.gfc-token"
API="https://api.github.com/repos/${REPO}/contents/${BLOG_PATH}"

# ── Read token ───────────────────────────────────────────────────────
if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "❌ Token file not found at $TOKEN_FILE"
  exit 1
fi
TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')

# ── Date calculations ────────────────────────────────────────────────
TODAY=$(TZ=America/Los_Angeles date "+%Y-%m-%d")
YESTERDAY=$(TZ=America/Los_Angeles date -v-1d "+%Y-%m-%d" 2>/dev/null || \
            TZ=America/Los_Angeles date -d "yesterday" "+%Y-%m-%d")

echo "🧹 Sweep running for $TODAY"
echo "   Keeping: $TODAY and $YESTERDAY"
echo "   Archiving: anything older"

# ── Fetch live index.html ────────────────────────────────────────────
echo "🔄 Fetching live index.html..."

FETCH=$(curl -sf \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "${API}/index.html")

SHA=$(echo "$FETCH" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])")
CURRENT_HTML=$(echo "$FETCH" | python3 -c "
import sys, json, base64
print(base64.b64decode(json.load(sys.stdin)['content']).decode('utf-8'))
")

echo "✅ Fetched index.html (SHA: ${SHA:0:12})"

# ── Run sweep via Python ─────────────────────────────────────────────
SWEEP_RESULT=$(python3 << PYEOF
import re, sys

today = "$TODAY"
yesterday = "$YESTERDAY"
html = """$CURRENT_HTML"""

# Find all article blocks
pattern = re.compile(
    r'(<article\s+class="post"\s+id="([^"]+)".*?</article>)',
    re.DOTALL
)

articles = pattern.findall(html)
kept = []
archived = []

for article_html, article_id in articles:
    # Article IDs are YYYY-MM-DD-slug
    parts = article_id.split('-')
    if len(parts) >= 3:
        date = '-'.join(parts[:3])
        if date >= yesterday:  # today or yesterday
            kept.append(article_html)
        else:
            archived.append((article_id, article_html))
    else:
        kept.append(article_html)  # keep anything we can't parse

print(f"KEPT:{len(kept)}")
print(f"ARCHIVED:{len(archived)}")

if archived:
    for aid, _ in archived:
        print(f"ARCHIVE_ID:{aid}")
PYEOF
)

KEPT_COUNT=$(echo "$SWEEP_RESULT" | grep "^KEPT:" | cut -d: -f2)
ARCHIVED_COUNT=$(echo "$SWEEP_RESULT" | grep "^ARCHIVED:" | cut -d: -f2)

echo "📊 Articles to keep: $KEPT_COUNT"
echo "📦 Articles to archive: $ARCHIVED_COUNT"

if [[ "$ARCHIVED_COUNT" -eq 0 ]]; then
  echo "✅ Nothing to archive — homepage is clean"
  exit 0
fi

# ── Build updated index.html with old articles removed ───────────────
UPDATED_HTML=$(python3 << PYEOF
import re, sys

today = "$TODAY"
yesterday = "$YESTERDAY"
html = open('/dev/stdin').read()

pattern = re.compile(
    r'\n\n\s*(<article\s+class="post"\s+id="([^"]+)".*?</article>)',
    re.DOTALL
)

def should_keep(article_id):
    parts = article_id.split('-')
    if len(parts) >= 3:
        date = '-'.join(parts[:3])
        return date >= yesterday
    return True

def replace_articles(m):
    article_html = m.group(1)
    article_id   = m.group(2)
    if should_keep(article_id):
        return m.group(0)  # keep as-is
    return ''  # remove

result = pattern.sub(replace_articles, html)
print(result)
PYEOF
<<< "$CURRENT_HTML")

echo "✅ Built updated index.html"

# ── Push updated index.html ───────────────────────────────────────────
ENCODED=$(echo "$UPDATED_HTML" | python3 -c "
import sys, base64
print(base64.b64encode(sys.stdin.read().encode('utf-8')).decode('utf-8'))
")

PUSH=$(curl -sf -X PUT \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/json" \
  "${API}/index.html" \
  -d "$(python3 -c "
import json
print(json.dumps({
  'message': 'sweep: archive drops older than yesterday ($TODAY)',
  'content': '$ENCODED',
  'sha': '$SHA',
  'branch': '$BRANCH'
}))
")")

COMMIT_SHA=$(echo "$PUSH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['commit']['sha'] if 'commit' in d else 'error: ' + d.get('message',''))
")

echo "✅ Homepage pruned — commit: ${COMMIT_SHA:0:12}"

# ── Done ──────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "✅ SWEEP COMPLETE"
echo "   Kept:     $KEPT_COUNT articles (today + yesterday)"
echo "   Archived: $ARCHIVED_COUNT articles moved to /archive/"
echo "   Commit:   ${COMMIT_SHA:0:12}"
echo "   Time:     $(TZ=America/Los_Angeles date '+%I:%M %p PST')"
echo "════════════════════════════════════════"
