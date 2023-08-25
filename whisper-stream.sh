#!/bin/bash

VERSION="1.0.1"

# Set the default sensitivity values
MIN_VOLUME=1%
SILENCE_LENGTH=1.5
ONESHOOT=false
DURATION=0
TOKEN=""
OUTPUT_DIR=""
PROMPT=""
LANGUAGE=""

# Function to display the help message
function display_help() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -v, --volume <value>     Set the minimum volume threshold (default: 1%)"
  echo "  -s, --silence <value>    Set the minimum silence length (default: 1.5)"
  echo "  -o, --oneshot            Enable one-shot mode"
  echo "  -d, --duration <value>   Set the recording duration in seconds (default: 0, continuous)"
  echo "  -t, --token <value>      Set the OpenAI API token"
  echo "  -p, --path <value>       Set the output directory path"
  echo "  -r, --prompt <value>     Set the prompt for the API call"
  echo "  -l, --language <value>   Set the language in ISO-639-1 format"
  echo "  -h, --help               Display this help message"
  echo "To stop the app, press Ctrl+C"
  exit 0
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -v|--volume)
      MIN_VOLUME="$2"
      shift
      shift
      ;;
    -s|--silence)
      SILENCE_LENGTH="$2"
      shift
      shift
      ;;
    -o|--oneshot)
      ONESHOOT=true
      shift
      ;;
    -d|--duration)
      DURATION="$2"
      shift
      shift
      ;;
    -t|--token)
      TOKEN="$2"
      shift
      shift
      ;;
    -p|--path)
      OUTPUT_DIR="$2"
      shift
      shift
      ;;
    -r|--prompt)
      PROMPT="$2"
      shift
      shift
      ;;
    -l|--language)
      LANGUAGE="$2"
      shift
      shift
      ;;
    -h|--help)
      display_help
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# If no output directory is provided as an argument, set it to the current directory
if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="."
fi

# If no token is provided as an argument, try to get it from the environment variable
if [ -z "$TOKEN" ]; then
  TOKEN="${OPENAI_API_KEY:-}"
fi

# If no token is provided as an argument or environment variable, exit the script
if [ -z "$TOKEN" ]; then
  echo "No OpenAI API key provided. Please provide it as an argument or environment variable."
  exit 1
fi

# Set the model for audio transcription
MODEL="whisper-1"

# Set the maximum number of retries
MAX_RETRIES=3

# Set the timeout duration in seconds
TIMEOUT_SECONDS=5

# Array to store the output file names
output_files=()

# Variable to store the accumulated text
accumulated_text=""

# Function to display current settings
function display_settings() {
  echo ""
  echo $'\e[1;34m'Whisper Stream Transcriber$'\e[0m' ${VERSION}
  echo $'\e[1;33m'---------------------------------$'\e[0m'
  echo "Current settings:"
  echo "  Minimum volume: $MIN_VOLUME"
  echo "  Silence length: $SILENCE_LENGTH seconds"
  echo "  Input language: ${LANGUAGE:-Not specified}"
  echo $'\e[1;33m'---------------------------------$'\e[0m'
  echo "To stop the app, press Ctrl+C"
  echo ""
}

# Call the functions to display current settings
display_settings

# Spinner
function spinner() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\\'
  while kill -0 $pid 2>/dev/null; do
    local temp=${spinstr#?}
    printf "\r\e[1;31m%c\e[0m" "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
  done
}

# Function to convert audio to text using the Whisper API
function convert_audio_to_text() {
  local output_file=$1
  local curl_command="curl -s --request POST \
    --url https://api.openai.com/v1/audio/transcriptions \
    --header \"Authorization: Bearer $TOKEN\" \
    --header \"Content-Type: multipart/form-data\" \
    --form \"file=@$output_file\" \
    --form \"model=$MODEL\" \
    --form \"response_format=json\""

  if [ -n "$PROMPT" ]; then
    curl_command+=" --form \"prompt=$PROMPT\""
  fi

  if [ -n "$LANGUAGE" ]; then
    curl_command+=" --form \"language=$LANGUAGE\""
  fi

  response=$(eval $curl_command)
  # Check if the curl command was successful
  if [ $? -ne 0 ]; then
    echo "API call failed."
    return 1
  fi

  transcription=$(echo "$response" | jq -r '.text')
  
  # Check if the transcription was successful
  if [ $? -ne 0 ]; then
    echo "Failed to parse the response."
    return 1
  fi

  echo -n -e '\r'
  echo "$transcription"
  
  # Remove the output audio file
  rm -f "$output_file"
  
  # Accumulate the transcribed text
  echo "$transcription" >> temp_transcriptions.txt
}

# Function to handle script termination
function handle_exit() {
  # Wait for all background jobs to finish
  wait

  # Kill all child processes
  pkill -P $$

  # Remove all output audio files
  for file in "${output_files[@]}"; do
    rm -f "$file"
  done

  # Remove temp transcriptions file
  rm -f temp_transcriptions.txt

  # Create a text file with the accumulated text in the specified directory
  timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
  echo "$accumulated_text" > "$OUTPUT_DIR/transcription_$timestamp.txt"

  # Copy the accumulated text to the clipboard
  case "$(uname -s)" in
    Darwin)
      echo "$accumulated_text" > temp.txt
      cat temp.txt | pbcopy
      rm temp.txt
      ;;
    Linux)
      echo "$accumulated_text" | xclip -selection clipboard >&1
      ;;
    CYGWIN*|MINGW32*|MSYS*|MINGW*)
      # This is a rough guess that you're on Windows Subsystem for Linux
      echo "$accumulated_text" | clip.exe >&1
      ;;
    *)
      echo "Unknown OS, cannot copy to clipboard"
      ;;
  esac

  exit
}

# Function to retry API call
function retry_api_call() {
  local retries=0
  local response=""
  local output_file=$1
  
  while [ $retries -lt $MAX_RETRIES ]; do
    echo "Attempt $((retries+1))..."
    response=$(custom_timeout "$TIMEOUT_SECONDS" convert_audio_to_text "$output_file")
    
    if [ $? -eq 0 ]; then
      echo "$response"
      return 0
    else
      retries=$((retries + 1))
      sleep 1
    fi
  done
  
  echo "API call failed after $MAX_RETRIES retries."
  return 1
}

# Custom timeout function
function custom_timeout() {
  local timeout=$1
  shift
  
  # Run the command in the background
  "$@" &
  local pid=$!
  
  # Wait for the command to finish or timeout
  ( sleep "$timeout" && kill -9 "$pid" ) 2>/dev/null &
  local watchdog=$!
  
  # Wait for the command or watchdog to finish
  wait "$pid" 2>/dev/null
  local result=$?
  
  # Clean up the watchdog process
  kill -9 "$watchdog" 2>/dev/null
  
  return $result
}

# Trap SIGINT (Ctrl+C), SIGTSTP (Ctrl+Z) and call handle_exit()
trap handle_exit SIGINT SIGTSTP

# Start recording audio using SoX and detect silence
while true; do
  # Set the path to the output audio file
  OUTPUT_FILE="output_$(date +%s).mp3"
  
  # Add the output file to the array
  output_files+=("$OUTPUT_FILE")

  echo -n $'\e[1;32m'▶ $'\e[0m'

  # Record audio in raw format then convert to mp3
  if [ "$DURATION" -gt 0 ]; then
    rec -q -V0 -e signed -L -c 1 -b 16 -r 44100 -t raw \
      - trim 0 "$DURATION" silence 1 0.1 "$MIN_VOLUME" 1 "$SILENCE_LENGTH" "$MIN_VOLUME" | \
      sox -t raw -r 44100 -b 16 -e signed -c 1 - "$OUTPUT_FILE"
  else
    rec -q -V0 -e signed -L -c 1 -b 16 -r 44100 -t raw \
      - silence 1 0.1 "$MIN_VOLUME" 1 "$SILENCE_LENGTH" "$MIN_VOLUME" | \
      sox -t raw -r 44100 -b 16 -e signed -c 1 - "$OUTPUT_FILE"
  fi
  
  # Check if the audio file is created successfully
  if [ -s "$OUTPUT_FILE" ]; then
    # Convert the MP3 audio to text using the Whisper API in the background
    convert_audio_to_text "$OUTPUT_FILE" &

    # Captures the process ID of the last executed background command.
    pid=$!
    spinner $pid
    # wait $pid
    # Read the transcriptions into the accumulated_text variable
    while IFS= read -r line; do
      if [ -z "$accumulated_text" ]; then
        accumulated_text="$line"
      else
        accumulated_text+="
$line"
      fi
    done < temp_transcriptions.txt
    # Clear the temporary transcriptions file
    > temp_transcriptions.txt
  else
    echo "No audio recorded."
  fi

  if [ "$ONESHOOT" = true ]; then
    break
  fi
done

handle_exit
