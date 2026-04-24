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

echo "📋 Publishing: ${TODAY}-${SLUG}"
echo "📄 Article file: $ARTICLE_FILE"

# ── All GitHub operations delegated to Python (safe with large files) ──
python3 - "$TOKEN_FILE" "$API" "$ARTICLE_FILE" "$SLUG" "$TODAY" "$BRANCH" << 'PYEOF'
import json, base64, urllib.request, urllib.error, re, sys, time, subprocess

token_file, api, article_file, slug, today, branch = sys.argv[1:7]
token  = open(token_file).read().strip()
anchor = f"{today}-{slug}"

headers_ro = {"Authorization": f"token {token}", "Accept": "application/vnd.github.v3+json"}
headers_rw = {**headers_ro, "Content-Type": "application/json"}

def gh_get(path):
    req = urllib.request.Request(f"{api}/{path}", headers=headers_ro)
    with urllib.request.urlopen(req) as r:
        return json.load(r)

def gh_put(path, sha, content_str, message, attempt=1):
    encoded = base64.b64encode(content_str.encode("utf-8")).decode("utf-8")
    payload = json.dumps({"message": message, "content": encoded, "sha": sha, "branch": branch}).encode("utf-8")
    req = urllib.request.Request(f"{api}/{path}", data=payload, headers=headers_rw, method="PUT")
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)["commit"]["sha"]
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        err  = json.loads(body) if body else {}
        if e.code == 409 or "conflict" in err.get("message", "").lower():
            if attempt <= 3:
                wait = attempt * 5
                print(f"  ⚠️  409 conflict — waiting {wait}s (attempt {attempt}/3)...")
                time.sleep(wait)
                fresh     = gh_get(path)
                fresh_sha = fresh["sha"]
                fresh_html = base64.b64decode(fresh["content"]).decode("utf-8")
                if f'id="{anchor}"' in fresh_html:
                    print("  ✅ Already live after re-fetch — idempotent")
                    return fresh_sha
                marker  = "<!-- POSTS: newest first -->"
                article = open(article_file).read().strip()
                updated = fresh_html.replace(marker, marker + "\n\n  " + article + "\n", 1)
                return gh_put(path, fresh_sha, updated, message, attempt + 1)
            print("❌ All 3 push attempts failed (409 conflicts)"); sys.exit(1)
        print(f"❌ Push failed {e.code}: {body}"); sys.exit(1)

# Fetch index.html
print("🔄 Fetching live index.html...")
data    = gh_get("index.html")
sha     = data["sha"]
current = base64.b64decode(data["content"]).decode("utf-8")
print(f"✅ Fetched index.html (SHA: {sha[:12]})")

# Idempotency
if f'id="{anchor}"' in current:
    print(f"⏭️  Already published: {anchor} — skipping (idempotent)")
    sys.exit(0)

# Prepend article
marker = "<!-- POSTS: newest first -->"
if marker not in current:
    print("❌ POSTS marker not found in index.html — cannot publish"); sys.exit(1)
article = open(article_file).read().strip()
updated = current.replace(marker, marker + "\n\n  " + article + "\n", 1)
print("✅ Article prepended at POSTS marker")

# Push index.html
print("🚀 Pushing to GitHub...")
commit_sha = gh_put("index.html", sha, updated, f"drop({slug}): {today} — auto-published by publish-drop.sh")
print(f"✅ Pushed successfully — commit: {commit_sha[:12]}")

# Verify live
print("🔍 Verifying article is live...")
time.sleep(3)
try:
    with urllib.request.urlopen("https://greenfeescapital.com/") as r:
        if f'id="{anchor}"' in r.read().decode("utf-8", errors="replace"):
            print(f"✅ Verified live: https://greenfeescapital.com/#{anchor}")
        else:
            print(f"⚠️  Not yet visible (CDN propagating) — expected: #{anchor}")
except Exception as ex:
    print(f"⚠️  Could not verify live: {ex}")

# Archive entry
print("📁 Writing archive entry...")
kicker_m  = re.search(r'<span class="kicker">(.*?)</span>', article)
kicker    = kicker_m.group(1) if kicker_m else "Drop"
head_m    = re.search(r'<h2>(.*?)<a class="permalink"', article, re.DOTALL)
headline  = re.sub(r'<[^>]+>', '', head_m.group(1)).strip() if head_m else "Market Brief"
time_m    = re.search(r'·\s*(\d+:\d+\s*[AP]M)', article)
drop_time = time_m.group(1) if time_m else ""
day_human = subprocess.check_output(["bash", "-c", 'TZ=America/Los_Angeles date "+%a, %b %-d, %Y"']).decode().strip()

archive_entry = (
    f'\n    <div class="date-group" id="archive-{anchor}">'
    f'\n      <div class="date-label">{day_human}</div>'
    f'\n      <a class="drop-row" href="/#{anchor}">'
    f'\n        <span class="kicker">{kicker}</span>'
    f'\n        <span class="time">{drop_time}</span>'
    f'\n        <span class="headline">{headline}</span>'
    f'\n      </a>'
    f'\n    </div>'
)

arch_data = gh_get("archive/index.html")
arch_sha  = arch_data["sha"]
arch_html = base64.b64decode(arch_data["content"]).decode("utf-8")

if f"archive-{anchor}" in arch_html:
    print("⏭️  Archive entry already exists — skipping")
else:
    arch_marker  = "<!-- ARCHIVE: newest first -->"
    arch_html    = re.sub(r'\s*<p class="empty">.*?</p>', '', arch_html, flags=re.DOTALL)
    updated_arch = arch_html.replace(arch_marker, arch_marker + archive_entry, 1)
    gh_put("archive/index.html", arch_sha, updated_arch, f"archive({slug}): add {today} entry")
    print("✅ Archive entry written")

t = subprocess.check_output(["bash", "-c", 'TZ=America/Los_Angeles date "+%I:%M %p PST"']).decode().strip()
print("")
print("════════════════════════════════════════")
print(f"✅ DROP LIVE: {anchor}")
print(f"   URL:    https://greenfeescapital.com/#{anchor}")
print(f"   Commit: {commit_sha[:12]}")
print(f"   Time:   {t}")
print("════════════════════════════════════════")
PYEOF
