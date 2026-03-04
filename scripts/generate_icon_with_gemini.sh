#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  echo "Error: GEMINI_API_KEY is not set." >&2
  echo "Fix: export GEMINI_API_KEY=... and run again." >&2
  exit 1
fi

MODEL="${GEMINI_MODEL:-gemini-2.5-flash-image}"
OUTPUT_PNG="${1:-$REPO_ROOT/.generated/icon_1024_source.png}"
PROMPT="${2:-Create a macOS app icon for 'RiverDrop'. Use a single water droplet containing a clean bidirectional transfer motif. Flat/minimal style, strong silhouette, high contrast, blue-cyan palette, no text, no border, no mockup background, centered composition, production-ready icon artwork only.}"

mkdir -p "$(dirname "$OUTPUT_PNG")"

request_body="$(jq -n --arg prompt "$PROMPT" '{contents:[{parts:[{text:$prompt}]}]}')"
response_file="$(mktemp)"
status_code="$(
  curl -sS \
    -o "$response_file" \
    -w "%{http_code}" \
    -X POST \
    -H 'Content-Type: application/json' \
    "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${GEMINI_API_KEY}" \
    -d "$request_body"
)"

if [[ "$status_code" -lt 200 || "$status_code" -ge 300 ]]; then
  echo "Error: Gemini API request failed (HTTP $status_code)." >&2
  jq -r '.error.message // .error // .' "$response_file" >&2 || true
  rm -f "$response_file"
  exit 1
fi

image_b64="$(jq -r 'first([.candidates[]?.content.parts[]? | (.inlineData.data // .inline_data.data // empty)][]) // empty' "$response_file")"

if [[ -z "$image_b64" ]]; then
  echo "Error: Gemini response did not include image bytes." >&2
  echo "Response excerpt:" >&2
  jq -r '.candidates[]?.content.parts[]? | .text? // empty' "$response_file" | sed '/^$/d' >&2 || true
  rm -f "$response_file"
  exit 1
fi

if base64 --help 2>&1 | rg -q -- '--decode'; then
  printf '%s' "$image_b64" | base64 --decode >"$OUTPUT_PNG"
else
  printf '%s' "$image_b64" | base64 -D >"$OUTPUT_PNG"
fi

rm -f "$response_file"

# Normalize to 1024x1024 for AppIcon source consistency.
sips -s format png -z 1024 1024 "$OUTPUT_PNG" --out "$OUTPUT_PNG" >/dev/null

echo "Wrote icon source: $OUTPUT_PNG"
