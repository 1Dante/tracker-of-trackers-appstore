#!/usr/bin/env bash
# Collects tracker apps from the Ukrainian App Store -> data/apps.json
#   Step 1: many narrow search queries (EN + UA)
#   Step 2: expand via developers of new apps (lookup by artistId)
#   Step 3: refresh known trackers not seen today (batch lookup by trackId)
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

# ---------- Merge today's results ----------
# Dedupe by trackId, keeping every query/source an app was found by
jq -L "$DIR" -s 'include "map";
  add
  | map(.isTrackerLike = tracker_like)
  | group_by(.trackId)
  | map(.[0] + {
      queries: (map(.query) | map(select(. != null)) | unique),
      sources: (map(.source) | unique)
    } | del(.query, .source, .releaseNotes))
' tmp/search_*.json $(ls tmp/artist_*.json 2>/dev/null) > tmp/today.json

# ---------- Accumulate with previous data ----------
# Apps seen before but missing today are kept (search results fluctuate).
# firstSeen = first day we ever saw the app, lastSeen = last day it showed up.
TODAY="${TODAY:-$(date -u +%F)}"
[[ -s data/apps.json ]] || echo "[]" > data/apps.json
[[ -s data/other_apps.json ]] || echo "[]" > data/other_apps.json

jq -L "$DIR" -n --arg today "$TODAY" \
  --slurpfile trk data/apps.json \
  --slurpfile oth data/other_apps.json \
  --slurpfile cur tmp/today.json 'include "map";
  ($trk[0] + $oth[0]) as $prev
  | ($prev | map({key: (.trackId | tostring), value: .}) | from_entries) as $old
  | ($cur[0] | map(. + {
        firstSeen: ($old[.trackId | tostring].firstSeen // $today),
        lastSeen: $today
      })) as $fresh
  | ($fresh | map(.trackId | tostring) | map({key: ., value: true}) | from_entries) as $seen
  # recompute the flag so a regex change can move apps between the two files
  | ($prev | map(select($seen[.trackId | tostring] | not)
                 | del(.releaseNotes)
                 | .isTrackerLike = tracker_like)) as $missing
  | ($fresh + $missing) | sort_by(.releaseDate) | reverse
' > tmp/merged.json

# ---------- Step 3: refresh known trackers that weren't seen today ----------
# Lookup accepts many ids per request, so the whole base costs only a few dozen calls.
# Apps the lookup doesn't return are gone from the UA store -> goneSince.
# Apps that come back later lose the goneSince mark.
LOOKUP_BATCH=150
missing_ids=()
while IFS= read -r id; do missing_ids+=("$id"); done < <(jq -r --arg t "$TODAY" \
  '.[] | select(.isTrackerLike and .lastSeen != $t) | .trackId' tmp/merged.json)
echo "Refreshing ${#missing_ids[@]} trackers via lookup…"

rm -f tmp/lookup_*.json
b=0
for ((k=0; k<${#missing_ids[@]}; k+=LOOKUP_BATCH)); do
  b=$((b+1))
  chunk=("${missing_ids[@]:k:LOOKUP_BATCH}")
  ids=$(IFS=,; echo "${chunk[*]}")
  # requested ids are stored with the response, so a failed request never marks apps as gone
  if curl -sf "https://itunes.apple.com/lookup?id=${ids}&country=${COUNTRY}" > tmp/raw.json \
     && jq -e 'has("results")' tmp/raw.json >/dev/null 2>&1; then
    jq -L "$DIR" --arg ids "$ids" 'include "map";
      { requested: ($ids | split(",") | map(tonumber)),
        apps: [(.results // [])[] | select(.wrapperType == "software") | to_app("lookup"; null)] }' \
      tmp/raw.json > "tmp/lookup_$b.json"
  else
    echo "   ⚠️  lookup batch $b failed, skipping"
  fi
  sleep "$SLEEP"
done

if ls tmp/lookup_*.json >/dev/null 2>&1; then
  jq -n --arg today "$TODAY" --slurpfile m tmp/merged.json '
    [inputs] as $batches
    | ($batches | map(.apps) | add | map({key: (.trackId | tostring), value: .}) | from_entries) as $got
    | ($batches | map(.requested) | add | map({key: tostring, value: true}) | from_entries) as $asked
    | $m[0] | map(
        (.trackId | tostring) as $id
        | if $got[$id] then
            # fresh data, but keep our own bookkeeping fields
            $got[$id] + {firstSeen, queries, sources, lastSeen: $today}
            | del(.query, .source, .releaseNotes, .goneSince)
          elif $asked[$id] then
            .goneSince = (.goneSince // $today)
          else . end)
  ' tmp/lookup_*.json > tmp/refreshed.json
  mv tmp/refreshed.json tmp/merged.json
fi

# ---------- Split: trackers vs everything else ----------
# apps.json        full records, trackers only (what the site uses)
# other_apps.json  minimal records for non-trackers (kept for re-classification)
jq '[.[] | select(.isTrackerLike)]' tmp/merged.json > data/apps.json
jq '[.[] | select(.isTrackerLike | not)
     | {trackId, trackName, sellerName, artistId, genre, releaseDate,
        isTrackerLike, firstSeen, lastSeen}]' tmp/merged.json > data/other_apps.json

# ---------- Daily snapshot (history) ----------
# One compact line per tracker seen today: d=date, id, r=rating, n=ratingCount, v=version.
# Re-running on the same day replaces that day's lines instead of duplicating them.
SNAP="data/snapshots/${TODAY:0:7}.jsonl"
mkdir -p data/snapshots
touch "$SNAP"
grep -v "\"d\":\"$TODAY\"" "$SNAP" > tmp/snap.jsonl || true
jq -c --arg today "$TODAY" '.[]
  | select(.lastSeen == $today)
  | {d: $today, id: .trackId, r: .rating, n: .ratingCount, v: .version}
' data/apps.json >> tmp/snap.jsonl
mv tmp/snap.jsonl "$SNAP"
echo "Snapshot: $(grep -c "\"d\":\"$TODAY\"" "$SNAP") rows -> $SNAP"

# ---------- Summary ----------
echo
echo "Trackers (apps.json):        $(jq 'length' data/apps.json)"
echo "  new today:                 $(jq --arg t "$TODAY" '[.[] | select(.firstSeen == $t)] | length' data/apps.json)"
echo "  not confirmed today:       $(jq --arg t "$TODAY" '[.[] | select(.lastSeen != $t)] | length' data/apps.json)"
echo "  gone from the store:       $(jq '[.[] | select(.goneSince)] | length' data/apps.json)"
echo "Other apps (other_apps.json): $(jq 'length' data/other_apps.json)"
echo
echo "New trackers per month (since 2024):"
jq -r '.[] | select(.releaseDate >= "2024") | .releaseDate[:7]' data/apps.json | sort | uniq -c
