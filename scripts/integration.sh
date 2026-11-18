#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${AGENTBOARD_OUTPUT_DIR:-$ROOT/build}"
"$ROOT/scripts/build.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentboard-integration.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

DATA="$WORK/data"
mkdir -p "$DATA"
"$OUTPUT/AgentBoard.app/Contents/MacOS/AgentBoard" \
    --ingest-once \
    --codex-home "$ROOT/fixtures/codex-home" \
    --data-dir "$DATA" \
    --report-helper /trusted/fixture/agentboard

DB="$DATA/agentboard.sqlite3"
CARD_COUNT="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM cards;')"
PROVIDERS="$(sqlite3 -separator ',' "$DB" 'SELECT group_concat(provider, ",") FROM (SELECT provider FROM cards ORDER BY provider);')"
GPT_STATE="$(sqlite3 "$DB" "SELECT state FROM cards WHERE id='11111111-1111-4111-8111-111111111111';")"
DEEPSEEK_STATE="$(sqlite3 "$DB" "SELECT state FROM cards WHERE id='33333333-3333-4333-8333-333333333333';")"
DEEPSEEK_REPORTED_STATE="$(sqlite3 "$DB" "SELECT json_extract(payload, '$.reportedState') FROM cards WHERE id='33333333-3333-4333-8333-333333333333';")"
EVENTS="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM report_events;')"

[[ "$CARD_COUNT" == "2" ]]
[[ "$PROVIDERS" == "deepseek,openai" ]]
[[ "$GPT_STATE" == "running" ]]
[[ "$DEEPSEEK_STATE" == "responseEnded" ]]
[[ "$DEEPSEEK_REPORTED_STATE" == "waiting" ]]
[[ "$EVENTS" == "2" ]]

echo "fixture ingestion: cards=$CARD_COUNT providers=$PROVIDERS states=$GPT_STATE/$DEEPSEEK_STATE reported=$DEEPSEEK_REPORTED_STATE reports=$EVENTS"
