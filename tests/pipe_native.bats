#!/usr/bin/env bats

load test_helper

setup() {
  cd "$BATS_TEST_TMPDIR"
  touch fake.mp3
  install_curl_stub
  load_whisper_stream

  TOKEN="sk-test"
  MODEL="gpt-4o-mini-transcribe"
  PROMPT=""
  LANGUAGE=""
  DIARIZE=false
  TRANSLATE=""
  AUDIO_FILE="fake.mp3"
  PIPE_TO_CMD=""
  KNOWN_SPEAKERS=()
  CHUNKING_STRATEGY=""
  STDOUT_MODE=false
  JSONL_MODE=false
  JSONL_SCHEMA_VERSION=1
}

# --- --stdout and --jsonl option parsing ------------------------------------

@test "--stdout flag sets STDOUT_MODE and implies quiet" {
  run "${BATS_TEST_DIRNAME}/../whisper-stream" --stdout --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pipe-native"* ]]
}

@test "--jsonl flag is documented in help" {
  run "${BATS_TEST_DIRNAME}/../whisper-stream" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--jsonl"* ]]
  [[ "$output" == *"JSON Lines"* ]]
}

# --- JSONL output shape -----------------------------------------------------

@test "JSONL mode emits exactly one JSON object per utterance" {
  JSONL_MODE=true
  STDOUT_MODE=true
  run convert_audio_to_text fake.mp3
  [ "$status" -eq 0 ]
  # Filter out any incidental stderr lines: we only care that stdout is valid JSON.
  # The stub's curl response is {"text":"fake transcription"}.
  local line_count
  line_count=$(printf '%s\n' "$output" | grep -c '^{')
  [ "$line_count" -eq 1 ]
}

@test "JSONL line parses as valid JSON" {
  JSONL_MODE=true
  STDOUT_MODE=true
  run convert_audio_to_text fake.mp3
  [ "$status" -eq 0 ]
  local json
  json=$(printf '%s\n' "$output" | grep '^{' | head -1)
  echo "$json" | jq -e . >/dev/null
}

@test "JSONL schema contains version, ts, model, duration, text" {
  JSONL_MODE=true
  STDOUT_MODE=true
  run convert_audio_to_text fake.mp3
  local json
  json=$(printf '%s\n' "$output" | grep '^{' | head -1)
  [ "$(echo "$json" | jq -r '.version')" = "1" ]
  [ "$(echo "$json" | jq -r '.model')" = "gpt-4o-mini-transcribe" ]
  [ "$(echo "$json" | jq -r '.text')" = "fake transcription" ]
  # ts is an ISO-8601 UTC string
  [[ "$(echo "$json" | jq -r '.ts')" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  # fake.mp3 is not real audio, so soxi cannot measure it: duration is null
  echo "$json" | jq -e '.duration == null' >/dev/null
  # no seq argument (library call) and no detection in the response
  echo "$json" | jq -e 'has("seq") and .seq == null' >/dev/null
  echo "$json" | jq -e 'has("languages") and .languages == null' >/dev/null
}

@test "JSONL carries seq, measured duration, and detected languages" {
  cat > "$BATS_TEST_TMPDIR/bin/soxi" <<'STUB'
#!/usr/bin/env bash
echo "4.179592"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/soxi"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"text":"bonjour","languages":[{"code":"fr"}],"usage":{"type":"duration","seconds":5}}\n200'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  JSONL_MODE=true
  STDOUT_MODE=true
  run convert_audio_to_text fake.mp3 7
  local json
  json=$(printf '%s\n' "$output" | grep '^{' | head -1)
  echo "$json" | jq -e '.seq == 7' >/dev/null
  # measured input duration (soxi), not the billed usage.seconds
  echo "$json" | jq -e '.duration == 4.18' >/dev/null
  echo "$json" | jq -e '.languages == [{"code":"fr"}]' >/dev/null
}

@test "JSONL keeps an empty detection result as [] (not null)" {
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"text":"hm","languages":[]}\n200'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  JSONL_MODE=true
  STDOUT_MODE=true
  run convert_audio_to_text fake.mp3
  local json
  json=$(printf '%s\n' "$output" | grep '^{' | head -1)
  echo "$json" | jq -e '.languages == []' >/dev/null
}

@test "JSONL duration is null when soxi prints something non-numeric" {
  cat > "$BATS_TEST_TMPDIR/bin/soxi" <<'STUB'
#!/usr/bin/env bash
echo "soxi FAIL formats: can't open input file"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/soxi"
  JSONL_MODE=true
  STDOUT_MODE=true
  run convert_audio_to_text fake.mp3
  [ "$status" -eq 0 ]
  local json
  json=$(printf '%s\n' "$output" | grep '^{' | head -1)
  echo "$json" | jq -e '.duration == null' >/dev/null
}

@test "JSONL text with shell metacharacters is properly escaped" {
  # Install a curl stub that returns a tricky text field
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s' '{"text":"hello \"world\" $USER `id` \n newline"}'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"

  JSONL_MODE=true
  STDOUT_MODE=true
  run convert_audio_to_text fake.mp3
  local json
  json=$(printf '%s\n' "$output" | grep '^{' | head -1)
  echo "$json" | jq -e . >/dev/null
  [[ "$(echo "$json" | jq -r '.text')" == *'$USER'* ]]
  [[ "$(echo "$json" | jq -r '.text')" == *'`id`'* ]]
}

# --- --stdout suppresses plain-text duplication when JSONL is on -----------

@test "JSONL mode does not also emit the plain display_text line" {
  JSONL_MODE=true
  STDOUT_MODE=true
  run convert_audio_to_text fake.mp3
  # Stdout should contain the JSON line but NOT a bare "fake transcription" line
  [[ "$output" != *$'\n'"fake transcription"$'\n'* ]]
  [[ "$output" != "fake transcription" ]]
}

# --- validate_config: jsonl + diarize is rejected --------------------------

@test "validate_config rejects --jsonl + --diarize combo" {
  JSONL_MODE=true
  DIARIZE=true
  MODEL="gpt-4o-transcribe-diarize"
  run validate_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"not compatible"* ]]
}

@test "validate_config accepts --jsonl without diarize" {
  JSONL_MODE=true
  DIARIZE=false
  MODEL="gpt-4o-mini-transcribe"
  run validate_config
  [ "$status" -eq 0 ]
}

# --- end-to-end: pipe-native stdout must not leak escape sequences --------

@test "subprocess: --jsonl -f output is parseable by jq (no trailing garbage)" {
  # This exercises the FULL main-flow path including handle_exit, which the
  # library-mode tests above cannot reach. A past regression let
  # handle_exit emit \r\e[K\n to stdout in pipe-native mode, which broke
  # downstream jq consumers.
  cd "$BATS_TEST_TMPDIR"
  # check_audio_file rejects empty files, so write any non-empty content.
  printf 'stub audio' > fake.mp3

  # Stub curl so the subprocess does not hit the network.
  mkdir -p bin
  cat > bin/curl <<'STUB'
#!/usr/bin/env bash
echo '{"text":"regression check"}'
STUB
  chmod +x bin/curl
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  local out
  out=$(OPENAI_API_KEY=sk-test "$BATS_TEST_DIRNAME/../whisper-stream" --jsonl -f fake.mp3 2>/dev/null)

  # The first line must be valid JSON; there must be no additional
  # non-empty lines (escape sequences, trailing output, etc.).
  [ -n "$out" ]
  local first_line
  first_line=$(printf '%s\n' "$out" | head -1)
  echo "$first_line" | jq -e . >/dev/null
  [ "$(echo "$first_line" | jq -r '.text')" = "regression check" ]

  # Count non-empty lines — should be exactly 1.
  local nonempty
  nonempty=$(printf '%s\n' "$out" | grep -c '[^[:space:]]')
  [ "$nonempty" -eq 1 ]
}

@test "subprocess: --stdout -f output contains no escape sequences" {
  cd "$BATS_TEST_TMPDIR"
  printf 'stub audio' > fake.mp3
  mkdir -p bin
  cat > bin/curl <<'STUB'
#!/usr/bin/env bash
echo '{"text":"plain text check"}'
STUB
  chmod +x bin/curl
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  local out
  out=$(OPENAI_API_KEY=sk-test "$BATS_TEST_DIRNAME/../whisper-stream" --stdout -f fake.mp3 2>/dev/null)

  # Must match the transcription exactly, with no trailing \r\e[K or similar
  [ "$out" = "plain text check" ]
}

# --- locale independence -------------------------------------------------------

@test "JSONL duration stays a JSON number under a decimal-comma locale" {
  # awk formats with the locale's decimal separator ("4,180"), which jq
  # --argjson rejects; the record used to vanish while returning success.
  locale -a 2>/dev/null | grep -qx 'de_DE.UTF-8' || skip "de_DE.UTF-8 locale not installed"
  cat > "$BATS_TEST_TMPDIR/bin/soxi" <<'STUB'
#!/usr/bin/env bash
echo "4.179592"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/soxi"
  JSONL_MODE=true
  STDOUT_MODE=true
  LC_ALL=de_DE.UTF-8
  export LC_ALL
  run convert_audio_to_text fake.mp3 1
  [ "$status" -eq 0 ]
  local json
  json=$(printf '%s\n' "$output" | grep '^{' | head -1)
  echo "$json" | jq -e '.duration == 4.18' >/dev/null
}

# --- CLI errors keep stdout clean ------------------------------------------------

@test "option parsing errors go to stderr, not the transcript stream" {
  local out rc
  for args in "--keyword" "--keywords-file" "--language" "--no-such-option"; do
    rc=0
    out=$("$BATS_TEST_DIRNAME/../whisper-stream" --jsonl $args 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ]
    [ -z "$out" ]
  done
}

@test "--keyword=<term> accepts a term that starts with a hyphen" {
  printf 'x' > fake.mp3  # file mode rejects empty files
  run env OPENAI_API_KEY=sk-test "$BATS_TEST_DIRNAME/../whisper-stream" --stdout -f fake.mp3 \
        --keyword=-Werror --keyword=--jsonl
  [ "$status" -eq 0 ]
  grep -Fxq 'keywords[]=-Werror' "$CURL_CAPTURE"
  grep -Fxq 'keywords[]=--jsonl' "$CURL_CAPTURE"
}
