#!/usr/bin/env bash

export exit_code=0
# Use trap to call cleanup when the script exits or errors out
trap 'cleanup' EXIT TERM ERR
cleanup() { exit "$exit_code"; }

## Logging Functions
now(){ date '+%d/%m/%Y-%H:%M:%S'; }
err() { >&2 printf '%s %b%s %s\e[0m\n' "$(now)" "${RED}[ERROR]${RESET} ${DIM}" "$@"; exit_code=1; }
warn() { >&2 printf '%s %b%s %s\e[0m\n' "$(now)" "${INTENSE_YELLOW}[WARN]${RESET} ${DIM}" "$@"; }
info() { printf '%s %b%s %s\e[0m\n' "$(now)" "${LIGHT_CYAN}[INFO]${RESET} ${DIM}" "$@"; }
prompt() { printf '%s %b%s %s\e[0m' "$(now)" "${INTENSE_YELLOW}[USER]${RESET} ${DIM}${BLINK}" "$@"; }
# Helper function to extract the value from the command line argument
# It handles both "--key value" and "--key=value" formats
extract_value() {
  local arg="$1"
  local next_arg="$2"
  if [[ "$arg" == *"="* ]]; then
    echo "${arg#*=}"  # Returns value after '='
  else
    echo "$next_arg"  # Returns the next argument
  fi
}

# Define the function to handle print messages with advanced formatting
print_msg() {
    local msg

    # Print the initial message with timestamp
    printf '%s %b%s %s\e[0m\n' "$(now)" "${LIGHT_CYAN}[INFO]${RESET} ${DIM}" "$1"
    shift # Remove the initial message from the parameters

    # Loop through the remaining arguments to print additional messages
    for msg in "$@"; do
        printf '%*s%b%s %s\e[0m\n' 27 '' "${LIGHT_GREEN}*==>${RESET} ${DIM}" "$msg"
    done
}

# Define the function to handle print messages with advanced formatting
print_msg_highlight() {
    local highlight="$2"
    local msg highlighted_msg

    # Print the initial message with timestamp
    printf '%s %b%s %b\e[0m\n' "$(now)" "${LIGHT_CYAN}[INFO]${RESET} ${DIM}Highlighting: $highlight " "$1" "${RESET}"
    shift 2 # Remove the initial message from the parameters

    # Loop through the remaining arguments to print additional messages
    for msg in "$@"; do
        # Highlight the specified parameter in the message
        highlighted_msg="${msg//${highlight}/${RESET}${LIGHT_RED}${highlight}${RESET}${DIM}}"
        printf '%*s %b%b %b \e[0m\n' 27 '' "${LIGHT_GREEN}*==>${RESET}" "${DIM}" "$highlighted_msg"
    done
}