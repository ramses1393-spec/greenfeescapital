#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
#  publish-drop.sh — Green Fees Capital
#
#  THE ONE JOB: take a freshly written article file and get it live
#  on greenfeescapital.com within seconds, reliably, every time.
#
#  Usage:
#    bash publish-drop.sh <slug>
#
#  Example:
#    bash publish-drop.sh driving-range
#    bash publish-drop.sh 19th-hole
#
#  What it does:
#    1. Reads the GitHub token from .gfc-token
#    2. Finds the article file for today's slug
#    3. Fetches the live index.html from GitHub (with SHA)
#    4. Checks idempotency — exits cleanly if already published
#    5. Prepends the article at <!-- POSTS: newest first -->
#    6. PUTs the updated file back to GitHub (3x retry on 409)
#    7. Verifies the article anchor is live
#    8. Appends an entry to archive/index.html
#    9. Reports success with commit SHA
#
#  Dependencies: bash, curl, python3 (all pre-installed on macOS)
# ════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────
REPO="ramses1393-spec/greenfeescapital"
BRANCH="main"
BLOG_PATH="greenfeescapital-blog"
DRAFTS_DIR="$HOME/Downloads/greenfeescapital-drafts"
TOKEN_FILE="$DRAFTS_DIR/.gfc-token"
API="https://api.github.com/repos/${REPO}/contents/${BLOG_PATH}"

# ── Validate args ────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "❌ Usage: bash publish-drop.sh <slug>"
  echo "   e.g.   bash publish-drop.sh driving-range"
  exit 1
fi

SLUG="$1"
TODAY=$(TZ=America/Los_Angeles date "+%Y-%m-%d")
ARTICLE_FILE="$DRAFTS_DIR/${TODAY}-${SLUG}-article.html"

# ── Read token ───────────────────────────────────────────────────────
if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "❌ Token file not found at $TOKEN_FILE"
  echo "   Create it with: echo 'YOUR_GITHUB_PAT' > $TOKEN_FILE"
  exit 1
fi

TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')

if [[ -z "$TOKEN" ]]; then
  echo "❌ Token file is empty: $TOKEN_FILE"
  exit 1
fi

# ── Check article file exists ────────────────────────────────────────
if [[ ! -f "$ARTICLE_FILE" ]]; then
  echo "❌ Article file not found: $ARTICLE_FILE"
  echo "   The task must write this file before calling publish-drop.sh"
  exit 1
fi

ARTICLE_CONTENT=$(cat "$ARTICLE_FILE")
ANCHOR="${TODAY}-${SLUG}"

echo "📋 Publishing: $ANCHOR"
echo "📄 Article file: $ARTICLE_FILE"

# ── Fetch live index.html from GitHub ───────────────────────────────
echo "🔄 Fetching live index.html..."

FETCH_RESPONSE=$(curl -sf \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "${API}/index.html")

if [[ $? -ne 0 ]]; then
  echo "❌ Failed to fetch index.html from GitHub"
  exit 1
fi

# Extract SHA and decode content using Python
READ_RESULT=$(echo "$FETCH_RESPONSE" | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
sha = data['sha']
content = base64.b64decode(data['content']).decode('utf-8')
print(sha)
print('---CONTENT---')
print(content)
")

SHA=$(echo "$READ_RESULT" | head -1)
CURRENT_HTML=$(echo "$READ_RESULT" | tail -n +3)

echo "✅ Fetched index.html (SHA: ${SHA:0:12})"

# ── Idempotency check ────────────────────────────────────────────────
if echo "$CURRENT_HTML" | grep -q "id=\"${ANCHOR}\""; then
  echo "⏭️  Already published: $ANCHOR — skipping (idempotent)"
  exit 0
fi

# ── Prepend article at the POSTS marker ─────────────────────────────
MARKER="<!-- POSTS: newest first -->"

if ! echo "$CURRENT_HTML" | grep -q "$MARKER"; then
  echo "❌ POSTS marker not found in index.html — cannot publish"
  exit 1
fi

UPDATED_HTML=$(echo "$CURRENT_HTML" | python3 -c "
import sys
marker = '<!-- POSTS: newest first -->'
article = open('$ARTICLE_FILE').read().strip()
html = sys.stdin.read()
# Prepend article right after the marker with clean spacing
updated = html.replace(marker, marker + '\n\n  ' + article + '\n', 1)
print(updated)
")

echo "✅ Article prepended at POSTS marker"

# ── Encode and push to GitHub (3x retry on 409) ──────────────────────
push_to_github() {
  local attempt=$1
  local backoff=$((attempt * 5))

  echo "🚀 Push attempt ${attempt}/3..."

  ENCODED=$(echo "$UPDATED_HTML" | python3 -c "
import sys, base64
content = sys.stdin.read()
print(base64.b64encode(content.encode('utf-8')).decode('utf-8'))
")

  PUSH_RESPONSE=$(curl -sf -X PUT \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.github.v3+json" \
    "${API}/index.html" \
    -d "$(python3 -c "
import json, sys
print(json.dumps({
  'message': 'drop($SLUG): $TODAY — auto-published by publish-drop.sh',
  'content': '''$ENCODED''',
  'sha': '$SHA',
  'branch': '$BRANCH'
}))
")" 2>&1)

  local exit_code=$?
  local http_status=$(echo "$PUSH_RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'commit' in d:
        print('201')
    elif d.get('message','').startswith('conflict'):
        print('409')
    else:
        print('error:' + d.get('message','unknown'))
except:
    print('parse_error')
" 2>/dev/null)

  if [[ "$http_status" == "201" ]]; then
    COMMIT_SHA=$(echo "$PUSH_RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['commit']['sha'])
")
    echo "✅ Pushed successfully — commit: ${COMMIT_SHA:0:12}"
    echo "$COMMIT_SHA"
    return 0
  elif [[ "$http_status" == "409" ]]; then
    echo "⚠️  409 conflict on attempt $attempt — waiting ${backoff}s then retrying..."
    sleep $backoff
    return 1
  else
    echo "❌ Push failed: $http_status"
    echo "$PUSH_RESPONSE"
    return 2
  fi
}

COMMIT_SHA=""
for attempt in 1 2 3; do
  result=$(push_to_github $attempt) && {
    COMMIT_SHA=$(echo "$result" | tail -1)
    break
  } || {
    exit_val=$?
    if [[ $exit_val -eq 2 ]]; then
      echo "❌ Fatal error on push — aborting"
      exit 1
    fi
    if [[ $attempt -eq 3 ]]; then
      echo "❌ All 3 push attempts failed (409 conflicts)"
      exit 1
    fi
  }
done

# ── Verify article is live ────────────────────────────────────────────
echo "🔍 Verifying article is live..."
sleep 3

VERIFY=$(curl -sf "https://greenfeescapital.com/" | grep -c "id=\"${ANCHOR}\"" || true)

if [[ "$VERIFY" -gt 0 ]]; then
  echo "✅ Verified live: https://greenfeescapital.com/#${ANCHOR}"
else
  echo "⚠️  Not yet visible at greenfeescapital.com (CDN may still be propagating)"
  echo "   Expected anchor: #${ANCHOR}"
fi

# ── Write archive entry ───────────────────────────────────────────────
echo "📁 Writing archive entry..."

KICKER=$(echo "$ARTICLE_CONTENT" | python3 -c "
import sys, re
html = sys.stdin.read()
m = re.search(r'<span class=\"kicker\">(.*?)</span>', html)
print(m.group(1) if m else 'Drop')
")

HEADLINE=$(echo "$ARTICLE_CONTENT" | python3 -c "
import sys, re
html = sys.stdin.read()
m = re.search(r'<h2>(.*?)<a class=\"permalink\"', html, re.DOTALL)
if m:
    # Strip any HTML tags from headline
    text = re.sub(r'<[^>]+>', '', m.group(1)).strip()
    print(text)
else:
    print('Market Brief')
")

DROP_TIME=$(echo "$ARTICLE_CONTENT" | python3 -c "
import sys, re
html = sys.stdin.read()
m = re.search(r'·\s*(\d+:\d+\s*[AP]M)', html)
print(m.group(1) if m else '')
")

DAY_HUMAN=$(TZ=America/Los_Angeles date "+%a, %b %-d, %Y")

ARCHIVE_ENTRY="
    <div class=\"date-group\" id=\"archive-${ANCHOR}\">
      <div class=\"date-label\">${DAY_HUMAN}</div>
      <a class=\"drop-row\" href=\"/#${ANCHOR}\">
        <span class=\"kicker\">${KICKER}</span>
        <span class=\"time\">${DROP_TIME}</span>
        <span class=\"headline\">${HEADLINE}</span>
      </a>
    </div>"

# Fetch archive index.html
ARCHIVE_FETCH=$(curl -sf \
  -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "${API}/archive/index.html")

ARCHIVE_SHA=$(echo "$ARCHIVE_FETCH" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])")
ARCHIVE_HTML=$(echo "$ARCHIVE_FETCH" | python3 -c "
import sys, json, base64
print(base64.b64decode(json.load(sys.stdin)['content']).decode('utf-8'))
")

ARCHIVE_MARKER="<!-- ARCHIVE: newest first -->"

# Only add to archive if not already there
if ! echo "$ARCHIVE_HTML" | grep -q "archive-${ANCHOR}"; then
  UPDATED_ARCHIVE=$(echo "$ARCHIVE_HTML" | python3 -c "
import sys
marker = '<!-- ARCHIVE: newest first -->'
entry = '''$ARCHIVE_ENTRY'''
html = sys.stdin.read()
# Remove empty state paragraph once first entry added
import re
html = re.sub(r'\s*<p class=\"empty\">.*?</p>', '', html, flags=re.DOTALL)
updated = html.replace(marker, marker + entry, 1)
print(updated)
")

  ARCHIVE_ENCODED=$(echo "$UPDATED_ARCHIVE" | python3 -c "
import sys, base64
print(base64.b64encode(sys.stdin.read().encode('utf-8')).decode('utf-8'))
")

  curl -sf -X PUT \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/json" \
    "${API}/archive/index.html" \
    -d "$(python3 -c "
import json
print(json.dumps({
  'message': 'archive($SLUG): add $TODAY entry',
  'content': '$ARCHIVE_ENCODED',
  'sha': '$ARCHIVE_SHA',
  'branch': '$BRANCH'
}))
")" > /dev/null

  echo "✅ Archive entry written"
else
  echo "⏭️  Archive entry already exists — skipping"
fi

# ── Done ──────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "✅ DROP LIVE: $ANCHOR"
echo "   URL:    https://greenfeescapital.com/#${ANCHOR}"
echo "   Commit: ${COMMIT_SHA:0:12}"
echo "   Time:   $(TZ=America/Los_Angeles date '+%I:%M %p PST')"
echo "════════════════════════════════════════"
