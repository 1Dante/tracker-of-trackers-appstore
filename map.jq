# Shared mapping: iTunes Search/Lookup API result -> our app record

# Tracker keywords, matched against the app NAME only
# (descriptions are too noisy: "track", "log", "goal" appear almost everywhere)
def tracker_re:
  "track|habit|streak|\\blog(book)?\\b|journal|diary|budget|expense|spending|money|water|drink|sleep|mood|calorie|diet|fasting|period|cycle|workout|steps?\\b|routine|counter|звич|витрат|бюджет|вода|води|\\bсон\\b|сну|настр|трекер|щоденн";

def tracker_like: (.trackName // "") | test(tracker_re; "i");

# $src: how the app was found ("search" | "artist")
# $q:   search term that returned it (null for artist lookups)
def to_app($src; $q):
  {
    trackId,
    trackName,
    sellerName,
    artistId,
    rating: (.averageUserRating // 0),
    ratingCount: (.userRatingCount // 0),
    hasUA: ((.languageCodesISO2A // []) | index("UK") != null),  # Ukrainian localization
    genre: .primaryGenreName,
    version,                                                     # free-form string, not always semver
    releaseDate,                                                 # first release
    currentVersionReleaseDate,                                   # latest update
    minimumOsVersion,
    fileSizeBytes: ((.fileSizeBytes // "0") | tonumber),
    price,
    releaseNotes,
    icon: .artworkUrl512,
    url: .trackViewUrl,
    isTrackerLike: tracker_like,
    source: $src,
    query: $q
  };
