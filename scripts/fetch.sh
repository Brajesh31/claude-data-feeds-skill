#!/usr/bin/env bash
# Trigger a Bright Data dataset job, poll it, and print the resulting snapshot.
set -Eeuo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/fetch.sh <dataset_id> '<input-json>'

<input-json> may be one input object, an array of input objects, or a full
request object containing an "input" array. The script requires curl and jq.

Environment:
  BRIGHTDATA_API_KEY            Required API token.
  BRIGHTDATA_POLLING_TIMEOUT    Maximum wait in seconds (default: 600).
  BRIGHTDATA_POLL_INTERVAL      Seconds between progress checks (default: 10).
  BRIGHTDATA_API_BASE           API base URL (default: https://api.brightdata.com).
USAGE
  exit 2
}

[[ $# -eq 2 ]] || usage
command -v curl >/dev/null || { echo "error: curl is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 2; }
: "${BRIGHTDATA_API_KEY:?Set BRIGHTDATA_API_KEY in the environment}"
dataset_id=$1
raw_input=$2
api_base=${BRIGHTDATA_API_BASE:-https://api.brightdata.com}
timeout_seconds=${BRIGHTDATA_POLLING_TIMEOUT:-600}
poll_interval=${BRIGHTDATA_POLL_INTERVAL:-10}

[[ "$dataset_id" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "error: invalid dataset_id" >&2; exit 2; }
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( timeout_seconds > 0 )) || { echo "error: BRIGHTDATA_POLLING_TIMEOUT must be a positive integer" >&2; exit 2; }
[[ "$poll_interval" =~ ^[0-9]+$ ]] && (( poll_interval > 0 )) || { echo "error: BRIGHTDATA_POLL_INTERVAL must be a positive integer" >&2; exit 2; }

if ! jq -e 'type == "object" or type == "array"' >/dev/null 2>&1 <<<"$raw_input"; then
  echo "error: input must be a valid JSON object or array" >&2
  exit 2
fi

# Normalize single records and arrays into the Web Scraper API request envelope.
if jq -e 'type == "object" and (.input | type == "array")' >/dev/null 2>&1 <<<"$raw_input"; then
  payload=$raw_input
elif jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw_input"; then
  payload=$(jq -cn --argjson input "$raw_input" '{input:$input}')
else
  payload=$(jq -cn --argjson record "$raw_input" '{input:[$record]}')
fi

encoded_dataset=$(jq -rn --arg v "$dataset_id" '$v|@uri')
trigger_url="$api_base/datasets/v3/trigger?dataset_id=$encoded_dataset&format=json&include_errors=true"
trigger_response=$(curl --fail-with-body --silent --show-error \
  --request POST "$trigger_url" \
  --header "Authorization: Bearer $BRIGHTDATA_API_KEY" \
  --header "Content-Type: application/json" \
  --data "$payload") || {
    echo "error: Bright Data trigger request failed" >&2
    exit 3
  }

snapshot_id=$(jq -er '.snapshot_id // empty' <<<"$trigger_response") || {
  echo "error: trigger response did not contain snapshot_id" >&2
  jq . <<<"$trigger_response" >&2 || true
  exit 3
}
[[ "$snapshot_id" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "error: invalid snapshot_id returned by API" >&2; exit 3; }

echo "Snapshot: $snapshot_id" >&2
start_time=$(date +%s)
while true; do
  progress=$(curl --fail-with-body --silent --show-error \
    --header "Authorization: Bearer $BRIGHTDATA_API_KEY" \
    "$api_base/datasets/v3/progress/$snapshot_id") || {
      echo "error: unable to read snapshot progress; snapshot_id=$snapshot_id" >&2
      exit 3
    }
  status=$(jq -er '.status // empty' <<<"$progress") || {
    echo "error: progress response has no status; snapshot_id=$snapshot_id" >&2
    jq . <<<"$progress" >&2 || true
    exit 3
  }

  case "$status" in
    ready) break ;;
    failed)
      echo "error: Bright Data job failed; snapshot_id=$snapshot_id" >&2
      jq . <<<"$progress" >&2 || true
      exit 4
      ;;
    starting|running|building)
      now=$(date +%s)
      if (( now - start_time >= timeout_seconds )); then
        echo "error: polling timed out after ${timeout_seconds}s; job continues remotely; snapshot_id=$snapshot_id" >&2
        exit 5
      fi
      sleep "$poll_interval"
      ;;
    *)
      echo "error: unexpected snapshot status '$status'; snapshot_id=$snapshot_id" >&2
      jq . <<<"$progress" >&2 || true
      exit 3
      ;;
  esac
done

curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer $BRIGHTDATA_API_KEY" \
  "$api_base/datasets/v3/snapshot/$snapshot_id?format=json"
echo
