#!/usr/bin/env bash
# Collects tracker apps from the Ukrainian App Store -> data/apps.json
#   Step 1: many narrow search queries (EN + UA)
#   Step 2: expand via developers of new apps (lookup by artistId)
#
# Env options:
#   SKIP_SEARCH=1     reuse search results from the previous run (tmp/)
#   LIMIT_ARTISTS=N   expand only the first N developers (0 = all)
set -euo pipefail

COUNTRY="ua"
SLEEP=3                 # ~20 requests/min, Apple's rate limit
NEW_SINCE="2025-01-01"  # expand developers of apps released after this date
MAX_RATINGS=100         # ...and only "small" ones (fewer ratings than this)
SKIP_SEARCH="${SKIP_SEARCH:-0}"
LIMIT_ARTISTS="${LIMIT_ARTISTS:-0}"
DIR="$(cd "$(dirname "$0")" && pwd)"

terms=(
  # general
  "habit tracker" "habit" "streak" "daily routine" "routine planner" "goal tracker"
  "habit ai" "minimal tracker" "daily check in" "self care" "journal" "diary"
  # money
  "expense tracker" "budget" "money manager" "spending" "personal finance" "subscription tracker"
  # health
  "water tracker" "drink reminder" "sleep tracker" "mood tracker" "calorie tracker"
  "calorie counter ai" "fasting tracker" "period tracker" "cycle tracker"
  "workout tracker" "step counter" "weight tracker" "medication tracker"
  # Ukrainian
  "трекер" "трекер звичок" "звички" "витрати" "бюджет" "облік витрат" "гроші"
  "вода" "сон" "настрій" "щоденник" "калорії" "тренування" "цикл"
)

mkdir -p data tmp

if [[ "$SKIP_SEARCH" == "1" ]] && ls tmp/search_*.json >/dev/null 2>&1; then
  echo "Skipping search, reusing results from the previous run"
  rm -f tmp/artist_*.json
  terms=()
else
  rm -f tmp/*.json
fi

# ---------- Step 1: search ----------
i=0
for term in "${terms[@]+"${terms[@]}"}"; do
  i=$((i+1))
  enc=$(jq -rn --arg t "$term" '$t | @uri')
  printf "[%2d/%d] %s\n" "$i" "${#terms[@]}" "$term"
  curl -s "https://itunes.apple.com/search?term=${enc}&country=${COUNTRY}&entity=software&limit=200" \
  | jq -L "$DIR" --arg q "$term" 'include "map"; [(.results // [])[] | to_app("search"; $q)]' \
  > "tmp/search_$i.json" || echo "   ⚠️  request failed, skipping"
  sleep "$SLEEP"
done

if ! ls tmp/search_*.json >/dev/null 2>&1; then
  echo "No search results in tmp/, run without SKIP_SEARCH"; exit 1
fi

# Recompute isTrackerLike so the current regex also applies to cached results
jq -L "$DIR" -s 'include "map"; add | unique_by(.trackId) | map(.isTrackerLike = tracker_like)' \
  tmp/search_*.json > tmp/step1.json
echo "After search: $(jq 'length' tmp/step1.json) unique," \
     "tracker-like: $(jq '[.[] | select(.isTrackerLike)] | length' tmp/step1.json)"

# ---------- Step 2: developers of new "small" trackers ----------
artists=()
while IFS= read -r a; do artists+=("$a"); done < <(jq -r --arg d "$NEW_SINCE" --argjson m "$MAX_RATINGS" \
  '[.[] | select(.releaseDate >= $d and .isTrackerLike and .ratingCount < $m) | .artistId]
   | unique | .[]' tmp/step1.json)

if (( LIMIT_ARTISTS > 0 && ${#artists[@]} > LIMIT_ARTISTS )); then
  echo "Sampling $LIMIT_ARTISTS of ${#artists[@]} developers"
  artists=("${artists[@]:0:LIMIT_ARTISTS}")
fi
echo "Expanding ${#artists[@]} developers (~$(( ${#artists[@]} * SLEEP / 60 )) min)…"

j=0
for aid in "${artists[@]+"${artists[@]}"}"; do
  j=$((j+1))
  curl -s "https://itunes.apple.com/lookup?id=${aid}&entity=software&country=${COUNTRY}&limit=200" \
  | jq -L "$DIR" 'include "map";
      [(.results // [])[] | select(.wrapperType == "software") | to_app("artist"; null)]' \
  > "tmp/artist_$j.json" || true
  if (( j % 20 == 0 )); then echo "   $j/${#artists[@]}"; fi
  sleep "$SLEEP"
done

# ---------- Merge ----------
# Dedupe by trackId, keeping every query/source an app was found by
jq -L "$DIR" -s 'include "map";
  add
  | map(.isTrackerLike = tracker_like)
  | group_by(.trackId)
  | map(.[0] + {
      queries: (map(.query) | map(select(. != null)) | unique),
      sources: (map(.source) | unique)
    } | del(.query, .source))
  | sort_by(.releaseDate) | reverse
' tmp/search_*.json $(ls tmp/artist_*.json 2>/dev/null) > data/apps.json

total=$(jq 'length' data/apps.json)
onlyArtist=$(jq '[.[] | select(.sources == ["artist"])] | length' data/apps.json)
onlyArtistTr=$(jq '[.[] | select(.sources == ["artist"] and .isTrackerLike)] | length' data/apps.json)

echo
echo "Total unique:                $total"
echo "Found only via developers:   $onlyArtist (tracker-like: $onlyArtistTr)"
echo "Tracker-like overall:        $(jq '[.[] | select(.isTrackerLike)] | length' data/apps.json)"
echo
echo "New trackers per month (since 2024):"
jq -r '.[] | select(.isTrackerLike and .releaseDate >= "2024") | .releaseDate[:7]' data/apps.json \
  | sort | uniq -c
