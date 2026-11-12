#!/usr/bin/env bash
# Resolve a dataset type to an account-specific Bright Data dataset ID.
set -Eeuo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/datasets.sh <dataset_type> <url> [field=value ...]
  scripts/datasets.sh amazon_product_search <keyword> <domain_url> [field=value ...]

Dataset IDs are account-specific. Configure them using either:
  BRIGHTDATA_DATASET_IDS_JSON='{"amazon_product":"gd_...","linkedin_person_profile":"gd_..."}'
or:
  BRIGHTDATA_DATASET_AMAZON_PRODUCT=gd_...

The JSON environment value may also be a path to a JSON file mapping dataset
names to IDs. See scripts/fetch.sh for polling and timeout settings.
USAGE
  exit 2
}

[[ $# -ge 2 ]] || usage
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 2; }
dataset_type=$1
shift
[[ "$dataset_type" =~ ^[a-z0-9_]+$ ]] || { echo "error: invalid dataset type" >&2; exit 2; }

# Keep the accepted names aligned with the skill's documented dataset catalog.
case "$dataset_type" in
  amazon_product|amazon_product_reviews|amazon_product_search|walmart_product|walmart_seller|ebay_product|homedepot_products|zara_products|etsy_products|bestbuy_products|linkedin_person_profile|linkedin_company_profile|linkedin_job_listings|linkedin_posts|linkedin_people_search|crunchbase_company|zoominfo_company_profile|instagram_profiles|instagram_posts|instagram_reels|instagram_comments|facebook_posts|facebook_marketplace_listings|facebook_company_reviews|facebook_events|tiktok_profiles|tiktok_posts|tiktok_shop|tiktok_comments|youtube_profiles|youtube_videos|youtube_comments|x_posts|reddit_posts|google_maps_reviews|google_shopping|google_play_store|apple_app_store|reuter_news|github_repository_file|yahoo_finance_business|zillow_properties_listing|booking_hotel_listings)
    ;;
  *)
    echo "error: unsupported dataset_type '$dataset_type'" >&2
    echo "See SKILL.md for the supported dataset names." >&2
    exit 2
    ;;
esac

key=$(tr '[:lower:]' '[:upper:]' <<<"$dataset_type")
key=${key//[^A-Z0-9]/_}
var_name="BRIGHTDATA_DATASET_$key"
dataset_id=$(printenv "$var_name" 2>/dev/null || true)

if [[ -z "$dataset_id" && -n "${BRIGHTDATA_DATASET_IDS_JSON:-}" ]]; then
  mapping=$BRIGHTDATA_DATASET_IDS_JSON
  if [[ -f "$mapping" ]]; then
    dataset_id=$(jq -er --arg key "$dataset_type" '.[$key] // empty' "$mapping" 2>/dev/null || true)
  else
    dataset_id=$(jq -er --arg key "$dataset_type" '.[$key] // empty' <<<"$mapping" 2>/dev/null || true)
  fi
fi

if [[ -z "$dataset_id" ]]; then
  echo "error: no Bright Data dataset ID configured for '$dataset_type'." >&2
  echo "Set $var_name or add '$dataset_type' to BRIGHTDATA_DATASET_IDS_JSON." >&2
  exit 2
fi

if [[ "$dataset_type" == "amazon_product_search" ]]; then
  [[ $# -ge 2 ]] || usage
  keyword=$1
  domain_url=$2
  shift 2
  input=$(jq -cn --arg keyword "$keyword" --arg domain_url "$domain_url" '{input:[{keyword:$keyword,domain_url:$domain_url}]}')
else
  [[ $# -ge 1 ]] || usage
  url=$1
  shift
  [[ "$url" =~ ^https?:// ]] || { echo "error: URL must start with http:// or https://" >&2; exit 2; }
  input=$(jq -cn --arg url "$url" '{input:[{url:$url}]}')
fi

# Extra parameters are passed as key=value strings and remain JSON strings.
for pair in "$@"; do
  [[ "$pair" == *=* ]] || { echo "error: additional parameters must use key=value format: $pair" >&2; exit 2; }
  field=${pair%%=*}
  value=${pair#*=}
  [[ "$field" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "error: invalid input field name '$field'" >&2; exit 2; }
  input=$(jq --arg field "$field" --arg value "$value" '.input[0][$field]=$value' <<<"$input")
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$script_dir/fetch.sh" "$dataset_id" "$input"
