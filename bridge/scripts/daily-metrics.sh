#!/usr/bin/env bash
# daily-metrics.sh - Fetch daily metrics and post to Discord
#
# Required env:
#   DISCORD_WEBHOOK_URL - Discord webhook URL
#
# Optional env:
#   DRY_RUN=1 - Print payload without posting
#
# Store metrics env (optional, gracefully degrades to N/A):
#   APP_STORE_CONNECT_PRIVATE_KEY, APP_STORE_CONNECT_KEY_IDENTIFIER,
#   APP_STORE_CONNECT_ISSUER_ID
#   GCLOUD_SERVICE_ACCOUNT_CREDENTIALS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="K9i-0/ccpocket"
NPM_PACKAGE="@ccpocket/bridge"
BUNDLE_ID="com.k9i.ccpocket"
TODAY=$(date -u +"%Y-%m-%d")

# ── npm downloads (yesterday) ─────────────────────────────────
npm_response=$(curl -sf "https://api.npmjs.org/downloads/point/last-day/${NPM_PACKAGE}" || echo '{}')
npm_downloads=$(echo "$npm_response" | jq -r '.downloads // 0')

# ── GitHub stats ──────────────────────────────────────────────
gh_response=$(curl -sf "https://api.github.com/repos/${REPO}" || echo '{}')
gh_stars=$(echo "$gh_response" | jq -r '.stargazers_count // 0')
gh_forks=$(echo "$gh_response" | jq -r '.forks_count // 0')
gh_open_issues=$(echo "$gh_response" | jq -r '.open_issues_count // 0')

# ── Open PRs (open_issues_count includes PRs, so fetch PR count separately) ──
gh_prs_response=$(curl -sf "https://api.github.com/repos/${REPO}/pulls?state=open&per_page=1" \
  -I 2>/dev/null | grep -i '^link:' || echo '')
# Simple approach: just count open PRs via search API
gh_prs_count=$(curl -sf "https://api.github.com/search/issues?q=repo:${REPO}+type:pr+state:open" \
  | jq -r '.total_count // 0' || echo '0')
gh_issues_count=$((gh_open_issues - gh_prs_count))

# ── App Store Connect (ratings/reviews) ───────────────────────
ios_rating="N/A"
ios_review_count="N/A"

if [[ -n "${APP_STORE_CONNECT_PRIVATE_KEY:-}" && \
      -n "${APP_STORE_CONNECT_KEY_IDENTIFIER:-}" && \
      -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "Fetching App Store Connect metrics..."
  apple_token=$(python3 "${SCRIPT_DIR}/generate-jwt.py" apple \
    "$APP_STORE_CONNECT_KEY_IDENTIFIER" \
    "$APP_STORE_CONNECT_ISSUER_ID" \
    "$APP_STORE_CONNECT_PRIVATE_KEY" 2>/dev/null || echo "")

  if [[ -n "$apple_token" ]]; then
    # Resolve App Store app ID from bundle ID
    app_id_response=$(curl -sf \
      -H "Authorization: Bearer $apple_token" \
      "https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=${BUNDLE_ID}&fields[apps]=bundleId" || echo '{}')
    app_id=$(echo "$app_id_response" | jq -r '.data[0].id // empty')

    if [[ -n "$app_id" ]]; then
      # Fetch recent reviews
      reviews_response=$(curl -sf \
        -H "Authorization: Bearer $apple_token" \
        "https://api.appstoreconnect.apple.com/v1/apps/${app_id}/customerReviews?sort=-createdDate&limit=200" || echo '{}')
      ios_rating=$(echo "$reviews_response" | jq \
        '[.data[]?.attributes.rating // empty] | if length > 0 then (add / length * 10 | round / 10) else "N/A" end')
      ios_review_count=$(echo "$reviews_response" | jq \
        '[.data[]?.attributes.rating // empty] | length')
      if [[ "$ios_review_count" == "0" ]]; then
        ios_rating="N/A"
        ios_review_count="N/A"
      fi
    fi
  fi
else
  echo "Skipping App Store Connect (credentials not set)"
fi

# ── Google Play (ratings/reviews) ─────────────────────────────
gp_rating="N/A"
gp_review_count="N/A"

if [[ -n "${GCLOUD_SERVICE_ACCOUNT_CREDENTIALS:-}" ]]; then
  echo "Fetching Google Play metrics..."
  google_assertion=$(python3 "${SCRIPT_DIR}/generate-jwt.py" google \
    "$GCLOUD_SERVICE_ACCOUNT_CREDENTIALS" \
    "https://www.googleapis.com/auth/androidpublisher" 2>/dev/null || echo "")

  if [[ -n "$google_assertion" ]]; then
    # Exchange JWT assertion for access token
    google_token=$(curl -sf -X POST "https://oauth2.googleapis.com/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=urn:ietf:params:oauth:grant_type:jwt-bearer&assertion=${google_assertion}" \
      | jq -r '.access_token // empty' || echo "")

    if [[ -n "$google_token" ]]; then
      # Fetch reviews
      gp_reviews=$(curl -sf \
        -H "Authorization: Bearer $google_token" \
        "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${BUNDLE_ID}/reviews" || echo '{}')
      gp_rating=$(echo "$gp_reviews" | jq \
        '[.reviews[]?.comments[]?.userComment?.starRating // empty] | if length > 0 then (add / length * 10 | round / 10) else "N/A" end')
      gp_review_count=$(echo "$gp_reviews" | jq \
        '[.reviews[]?.comments[]?.userComment?.starRating // empty] | length')
      if [[ "$gp_review_count" == "0" ]]; then
        gp_rating="N/A"
        gp_review_count="N/A"
      fi
    fi
  fi
else
  echo "Skipping Google Play (credentials not set)"
fi

# ── Build Discord Embed ──────────────────────────────────────
# Format store ratings
if [[ "$ios_rating" != "N/A" ]]; then
  ios_line="🍎 **App Store**: ⭐**${ios_rating}** (${ios_review_count} reviews)"
else
  ios_line="🍎 **App Store**: N/A"
fi

if [[ "$gp_rating" != "N/A" ]]; then
  gp_line="🤖 **Google Play**: ⭐**${gp_rating}** (${gp_review_count} reviews)"
else
  gp_line="🤖 **Google Play**: N/A"
fi

description=$(cat <<EOF
📦 **npm** (\`${NPM_PACKAGE}\`): **${npm_downloads}** downloads (yesterday)
⭐ **GitHub**: **${gh_stars}** stars / **${gh_forks}** forks
🔧 **Open Issues**: ${gh_issues_count} / **Open PRs**: ${gh_prs_count}
${ios_line}
${gp_line}
EOF
)

payload=$(jq -n \
  --arg title "📊 ccpocket Daily Report (${TODAY})" \
  --arg description "$description" \
  --argjson color 5814783 \
  '{
    embeds: [{
      title: $title,
      description: $description,
      color: $color,
      footer: { text: "ccpocket metrics bot" },
      timestamp: (now | todate)
    }]
  }')

# ── Post or dry-run ──────────────────────────────────────────
if [[ "${DRY_RUN:-}" == "1" ]]; then
  echo "=== DRY RUN ==="
  echo "$payload" | jq .
  exit 0
fi

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  echo "Error: DISCORD_WEBHOOK_URL is not set" >&2
  exit 1
fi

http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  "$DISCORD_WEBHOOK_URL")

if [[ "$http_code" =~ ^2 ]]; then
  echo "✅ Posted daily metrics to Discord (HTTP ${http_code})"
else
  echo "❌ Failed to post to Discord (HTTP ${http_code})" >&2
  exit 1
fi
