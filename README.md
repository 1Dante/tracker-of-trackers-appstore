# Tracker of Trackers

Everyone is building a tracker. This repo counts them.

A daily GitHub Actions job collects tracker apps (habits, money, water, sleep, mood, calories, …) from the Ukrainian App Store via the public iTunes Search API and saves them to [`data/apps.json`](data/apps.json).

## How it works

1. **Search:** 45 narrow queries (EN + UA), top 200 results each (Apple's limit)
2. **Expand:** for developers of new, low-rated trackers, fetch all their other apps
3. **Merge:** dedupe by `trackId`, keep which queries found each app

The data is a lower bound: apps that never show up in search results are invisible to this method.

## Run locally

Requires `bash`, `curl`, `jq`.

```bash
bash collect.sh                         # full run
LIMIT_ARTISTS=20 bash collect.sh        # quick run, expand only 20 developers
SKIP_SEARCH=1 bash collect.sh           # reuse search results from the last run
```
