#!/usr/bin/env bats

load test_helper

setup() {
  load_whisper_stream

  BACKEND="api"
  MODEL="gpt-4o-mini-transcribe"
  MODEL_PATH=""
  API_URL=""
  DIARIZE=false
  REGISTER_SPEAKERS=false
  TRANSLATE=""
  AUDIO_FILE=""
  CHUNKING_STRATEGY=""
  JSONL_MODE=false
  LANGUAGE=""
  KEYWORDS=()
}

# --- model recognition -------------------------------------------------------

@test "accepts gpt-transcribe (the default) silently" {
  MODEL="gpt-transcribe"
  run validate_config
  [ "$status" -eq 0 ]
  [[ "$output" != *"Warning"* ]]
}

@test "accepts a gpt-transcribe dated snapshot silently" {
  MODEL="gpt-transcribe-2027-03-01"
  run validate_config
  [ "$status" -eq 0 ]
  [[ "$output" != *"Warning"* ]]
}

@test "the built-in default model is gpt-transcribe" {
  # setup() overrides MODEL; read the default straight from the script.
  run grep -E '^MODEL="gpt-transcribe"' "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

@test "gpt-4o-mini-transcribe works but warns about OpenAI's removal date" {
  MODEL="gpt-4o-mini-transcribe"
  run validate_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"2027-02-26"* ]]
  [[ "$output" == *"gpt-transcribe"* ]]
}

@test "gpt-4o-transcribe works but warns about OpenAI's removal date" {
  MODEL="gpt-4o-transcribe"
  run validate_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"2027-02-26"* ]]
}

@test "gpt-4o-mini-transcribe-2025-03-20 warns about its earlier removal date" {
  MODEL="gpt-4o-mini-transcribe-2025-03-20"
  run validate_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"2027-01-20"* ]]
}

@test "gpt-4o-transcribe-diarize warns that speaker labels have no replacement" {
  MODEL="gpt-4o-transcribe-diarize"
  run validate_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"2027-02-26"* ]]
  [[ "$output" == *"speaker labels"* ]]
}

@test "warns on unrecognized model but does not exit" {
  MODEL="some-future-model-v9"
  run validate_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning"* ]]
}

@test "rejects whisper-1 without claiming OpenAI already retired it" {
  MODEL="whisper-1"
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"since v3.0"* ]]
  [[ "$output" == *"2027-02-26"* ]]
  [[ "$output" != *"2026-06-01"* ]]
}

@test "rejects Realtime-only models on the OpenAI endpoint" {
  for m in gpt-live-transcribe gpt-realtime-whisper; do
    MODEL="$m"
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"Realtime"* ]]
  done
}

@test "OpenAI model rules are skipped for a self-hosted --api-url" {
  API_URL="http://127.0.0.1:2022/v1/audio/transcriptions"
  for m in whisper-1 gpt-4o-mini-transcribe some-local-model; do
    MODEL="$m"
    run validate_config
    [ "$status" -eq 0 ]
    [[ "$output" != *"Warning"* ]]
    [[ "$output" != *"Error"* ]]
  done
}

@test "an explicit api.openai.com --api-url still gets OpenAI's rules" {
  API_URL="https://api.openai.com/v1/audio/transcriptions"
  MODEL="whisper-1"
  run validate_config
  [ "$status" -ne 0 ]
}

# --- --language lists ---------------------------------------------------------

@test "gpt-transcribe accepts several language codes" {
  MODEL="gpt-transcribe"
  LANGUAGE="en, ja"
  validate_config 2>/dev/null
  [ "${#LANGUAGES[@]}" -eq 2 ]
  [ "${LANGUAGES[0]}" = "en" ]
  [ "${LANGUAGES[1]}" = "ja" ]
}

@test "gpt-4o-* models reject several language codes" {
  MODEL="gpt-4o-mini-transcribe"
  LANGUAGE="en,ja"
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"accepts one"* ]]
}

@test "a language list with an empty entry is rejected" {
  MODEL="gpt-transcribe"
  for l in "en,,ja" "en," ",en" "en, ,ja"; do
    LANGUAGE="$l"
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid --language list"* ]]
  done
}

@test "a language list with a line break is rejected, not truncated" {
  # `read` stops at the first newline, so "en,\nja" used to become just "en"
  # and slip past the one-language checks.
  MODEL="gpt-4o-mini-transcribe"
  for l in $'en,\nja' $'\nen,ja' $'en\nja' $'en\r'; do
    LANGUAGE="$l"
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid --language list"* ]]
  done
}

# --- --keyword ----------------------------------------------------------------

@test "gpt-transcribe accepts keywords, including ones with commas" {
  MODEL="gpt-transcribe"
  KEYWORDS=("ACME, Inc." "AC-42")
  run validate_config
  [ "$status" -eq 0 ]
}

@test "gpt-4o-* models reject keywords" {
  MODEL="gpt-4o-transcribe"
  KEYWORDS=("Kyoto")
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"require gpt-transcribe"* ]]
}

@test "keywords with characters the API rejects are caught before sending" {
  MODEL="gpt-transcribe"
  for kw in "a<b" "a>b" $'two\nlines' $'cr\r' ""; do
    KEYWORDS=("fine" "$kw")
    run validate_config
    [ "$status" -ne 0 ]
    [[ "$output" == *"keyword 2"* ]]
  done
}

@test "load_keywords_file trims, skips blank lines, and accepts CRLF" {
  printf '  Kyoto \r\n\r\nACME, Inc.\n\n  \nlast-without-newline' > "$BATS_TEST_TMPDIR/kw.txt"
  KEYWORDS=("from-cli")
  load_keywords_file "$BATS_TEST_TMPDIR/kw.txt"
  [ "${#KEYWORDS[@]}" -eq 4 ]
  [ "${KEYWORDS[0]}" = "from-cli" ]
  [ "${KEYWORDS[1]}" = "Kyoto" ]
  [ "${KEYWORDS[2]}" = "ACME, Inc." ]
  [ "${KEYWORDS[3]}" = "last-without-newline" ]
}

@test "load_keywords_file reports the offending line number" {
  printf 'ok\n<bad>\n' > "$BATS_TEST_TMPDIR/kw.txt"
  run load_keywords_file "$BATS_TEST_TMPDIR/kw.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 2"* ]]
}

@test "load_keywords_file errors on a missing file" {
  run load_keywords_file "$BATS_TEST_TMPDIR/nope.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read keywords file"* ]]
}

# --- diarization -------------------------------------------------------------

@test "rejects --diarize without diarize-capable model" {
  MODEL="gpt-4o-mini-transcribe"
  DIARIZE=true
  run validate_config
  [ "$status" -ne 0 ]
}

@test "accepts --diarize with diarize-capable model" {
  MODEL="gpt-4o-transcribe-diarize"
  DIARIZE=true
  run validate_config
  [ "$status" -eq 0 ]
}

@test "accepts --diarize with diarize snapshot model" {
  MODEL="gpt-4o-transcribe-diarize-2025-12-15"
  DIARIZE=true
  run validate_config
  [ "$status" -eq 0 ]
}

@test "sets chunking_strategy=auto when diarize enabled" {
  MODEL="gpt-4o-transcribe-diarize"
  DIARIZE=true
  validate_config
  [ "$CHUNKING_STRATEGY" = "auto" ]
}

# --- --translate (local backend only since v3.0) ----------------------------

@test "rejects --translate on api backend regardless of model" {
  BACKEND="api"
  MODEL="gpt-4o-mini-transcribe"
  TRANSLATE=true
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"--translate"* ]]
  [[ "$output" == *"local"* ]]
}

@test "rejects --translate on api backend with gpt-4o-transcribe" {
  BACKEND="api"
  MODEL="gpt-4o-transcribe"
  TRANSLATE=true
  run validate_config
  [ "$status" -ne 0 ]
}

# --- --api-url notes --------------------------------------------------------

@test "warns when --api-url is set with local backend" {
  BACKEND="local"
  # Provide a fake model so we get past the existence check.
  FAKE_MODEL="$BATS_TEST_TMPDIR/fake.bin"
  : > "$FAKE_MODEL"
  MODEL_PATH="$FAKE_MODEL"
  API_URL="http://localhost:2022/v1/audio/transcriptions"
  # whisper-cli must exist for validate_config to return 0; skip if absent.
  if ! command -v whisper-cli >/dev/null 2>&1; then
    skip "whisper-cli not installed"
  fi
  run validate_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"--api-url is ignored"* ]]
}

# --- external dependency checks ----------------------------------------------
#
# validate_config must verify the external commands the chosen mode actually
# needs, and no more: jq always, curl for the api backend, rec/sox only for
# real-time recording (file mode must keep working on machines with no mic).

# Build a directory containing symlinks to only the named commands, so the
# dependency checks can be exercised with a controlled PATH.
make_dep_path() {
  local dir="$BATS_TEST_TMPDIR/depbin"
  mkdir -p "$dir"
  local c
  for c in "$@"; do
    ln -sf "$(command -v "$c")" "$dir/$c"
  done
  echo "$dir"
}

@test "validate_config errors when jq is missing" {
  local d
  d=$(make_dep_path curl rec sox)
  PATH="$d" run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]]
}

@test "validate_config errors when curl is missing for the api backend" {
  local d
  d=$(make_dep_path jq rec sox)
  PATH="$d" run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"curl"* ]]
}

@test "validate_config errors when rec/sox are missing in real-time mode" {
  local d
  d=$(make_dep_path jq curl)
  PATH="$d" run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"rec"* ]] || [[ "$output" == *"sox"* ]]
}

@test "file mode (-f) does not require rec/sox" {
  AUDIO_FILE="fake.mp3"
  local d
  d=$(make_dep_path jq curl)
  PATH="$d" run validate_config
  [ "$status" -eq 0 ]
}

# --- -p2 / --pipe-to combined with pipe-native output ------------------------

@test "validate_config warns when --pipe-to is combined with pipe-native output" {
  PIPE_TO_CMD="wc -c"
  STDOUT_MODE=true
  run validate_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"pipe-to"* ]]
}
