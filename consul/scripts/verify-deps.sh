#!/usr/bin/env bash

eval "$(cat ../env)"
eval "$(cat scripts/formatting.env)"

exit_code=0
err() { >&2 printf '%s %b%s %s\e[0m\n' "$(now)" "   ${RED}[ERROR]${RESET} >- ${DIM}" "$@"; exit_code=1; }
# Use trap to call cleanup when the script exits or errors out
trap 'cleanup' EXIT TERM ERR
# Cleanup resources
cleanup() { exit "$exit_code"; }
now(){ date '+%d/%m/%Y-%H:%M:%S'; }
warn() { >&2 printf '%s %b%s %s\e[0m\n' "$(now)" "    ${INTENSE_YELLOW}[WARN]${RESET} >- ${DIM}" "$@"; }
info() { printf '%s %b%s %s\e[0m\n' "$(now)" "    ${LIGHT_CYAN}[INFO]${RESET} >- ${DIM}" "$@"; }

# Define the banner function
display_banner() {
    echo -e "${LIGHT_CYAN}${BOLD}Consul on OpenShift | Libvirt UPI (Baremetal)${RESET}${LIGHT_CYAN}${RESET}"
    echo -e "${DIM}::Dependency validation script::${RESET}"
    printf '\n' # New line for better readability
}

declare -A tools=(
    ["jq"]="https://formulae.brew.sh/formula/jq"
    ["wget"]="https://formulae.brew.sh/formula/wget"
    ["helm"]="https://github.com/helm/helm"
    ["envsubst"]="https://www.gnu.org/software/gettext/"
)

# Function to install a tool
install_tool() {
    local tool_name="$1"
    local github_url="${tools[$tool_name]}"

    if [ -n "$github_url" ]; then
        if [ "$tool_name" = envsubst ]; then
          info "installing envsubst (gettext) via homebrew ..."
          brew install gettext 1>/dev/null
          brew link --force gettext
        else
          info "installing $tool_name via homebrew ..."
          brew install "$tool_name" 1>/dev/null
          if [ "$tool_name" = jq ]; then
              warn "jq install was required, resource your shell and re-run make target or script. run: source ~/.zshrc"
              return 1
          fi
        fi
    else
        err "cannot install $tool_name. please install it manually."
    fi
}

# Function to check if a tool is installed
check_tool_installed() {
    local tool_name="$1"
    local confirm_install
    if command -v "$tool_name" >/dev/null 2>&1; then
        info "$tool_name installed"
    else
        warn "$tool_name not installed."
        printf '%b%s' "                        ${GREEN}[USER]${RESET} >- install $tool_name now? (y/n): "
        read -n 1 -r confirm_install </dev/tty; printf '\n';
        if [[ "$confirm_install" =~ ^[Yy]$ ]]; then
            install_tool "$tool_name" || {
              return 1
            }
            if command -v "$tool_name" >/dev/null 2>&1; then
              info "$tool_name installed"
            else
              err "$tool_name installation failed. install manually."
            fi
        fi
    fi
}

display_banner
# Loop through the tools and check if they are installed
for tool in "${!tools[@]}"; do
    check_tool_installed "$tool" || {
      warn "dependent tooling verification for $tool returned non-zero exit"
      exit
    }
done

if [ -z "$CONSUL_LICENSE" ]; then
  err "enterprise-licensing error. \$CONSUL_LICENSE not set, ensure you set this to a valid ent license prior to running"
  exit
fi

if { ! test -f /root/pull-secret.yaml; } && { ! test -f openshift/pull-secret.yaml; }; then
  err "Pull secret not found at /root/pull-secret.yaml, please download and place in $HOME/"
  exit
fi

info "Prerequisite software, licensing, and ssh key(s) validated!"