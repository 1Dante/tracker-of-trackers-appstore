#!/usr/bin/env bash
# Builds data/site.json: a slim, site-only view of data/apps.json
#   - only the fields the page needs (short keys keep the file small)
#   - niche per app (stats are computed in the page)
set -euo pipefail

TODAY="${TODAY:-$(date -u +%F)}"

jq --arg today "$TODAY" '
  # Niche by app name; first match wins, order matters
  def niche:
    (.trackName // "" | ascii_downcase) as $n
    | if   ($n | test("subscription"))                                   then "subs"
      elif ($n | test("habit|streak|звич"))                              then "habits"
      elif ($n | test("budget|expense|spending|money|finance|wallet|витрат|бюджет")) then "money"
      elif ($n | test("calorie|diet|meal|food|fasting|калор"))           then "food"
      elif ($n | test("period|cycle|ovulat|pregnan"))                    then "cycle"
      elif ($n | test("water|drink|вода|води"))                          then "water"
      elif ($n | test("sleep|\\bсон\\b|сну"))                            then "sleep"
      elif ($n | test("mood|настр|journal|diary|щоденн"))                then "mood"
      elif ($n | test("workout|gym|fitness|steps?\\b|walk|run|тренув"))  then "fitness"
      elif ($n | test("routine|goal|daily|self.?care"))                  then "routine"
      else "other" end;

  [ .[]
    | select(.genre != "Games")                       # "Water Sort" etc. are not trackers
    | {
        id: .trackId,
        n:  .trackName,
        s:  .sellerName,
        # icon host+path without "https://" and the size suffix; the page adds both back
        ic: ((.icon // "") | sub("^https://"; "") | sub("/512x512bb\\.(jpg|png)$"; "")),
        r:  ((.rating // 0) * 10 | round / 10),
        c:  (.ratingCount // 0),
        d:  ((.releaseDate // "")[:10]),
        u:  ((.currentVersionReleaseDate // "")[:10]),
        v:  .version,
        ua: (if .hasUA then 1 else 0 end),
        # business model: paid upfront wins; otherwise a description hint means "probably freemium"
        m:  (if (.price // 0) > 0 then "paid" elif .iapHint == true then "freemium" else "free" end),
        fp: (if (.price // 0) > 0 then .formattedPrice else null end),
        k:  niche,
        g:  .goneSince,
        f:  .firstSeen
      }
  ] as $apps

  # Summary numbers are computed in the page, so it can switch between UA-only and all
  | {
      updated: $today,
      total:   ($apps | length),
      gone:    ($apps | map(select(.g)) | length),
      apps:    ($apps | sort_by(.d) | reverse)
    }
' data/apps.json > data/site.json

echo "site.json: $(jq '.apps | length' data/site.json) apps, $(du -h data/site.json | cut -f1)"
