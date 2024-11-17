#!/bin/bash

# Error function to display error messages and exit
err() {
    echo
    echo -e "\e[97m\e[101m[ERROR]\e[0m ${1}"; shift
    echo
    for msg in "$@"; do
        echo "    $msg"
    done
    echo
    exit 1
}

# Success function to display messages or "ok" by default
ok() {
    local msg="${1:-ok}"
    echo " ${msg}"
}

# Function to prompt user before continuing if confirmation is needed
check_if_we_can_continue() {
    if [[ "${YES}" != "yes" ]]; then
        echo
        for msg in "$@"; do
            echo "[NOTE] $msg"
        done
        read -rp "Press [Enter] to continue, [Ctrl]+C to abort: "
    fi
}

# Download function with caching and retry logic
download() {
    local cmd="${1}"
    local file="${2}"
    local url="${3}"

    # Validate inputs
    [[ -z "${cmd}" || -z "${file}" || -z "${url}" ]] && err "Usage: download <check|get> <filename> <url>"

    # Create cache directory if not exists
    mkdir -p "${CACHE_DIR}"

    case "${cmd}" in
        check)
            if [[ -f "${CACHE_DIR}/${file}" ]]; then
                echo "(reusing cached file ${file})"
            else
                if timeout 10 curl -s --head --fail "${url}" >/dev/null; then
                    ok "URL reachable"
                else
                    err "URL ${url} not reachable"
                fi
            fi
            ;;
        get)
            # Remove cached file if FRESH_DOWN is set
            if [[ "${FRESH_DOWN}" == "yes" && -f "${CACHE_DIR}/${file}" ]]; then
                rm -f "${CACHE_DIR}/${file}" || err "Error removing cached file ${CACHE_DIR}/${file}"
            fi
            if [[ -f "${CACHE_DIR}/${file}" ]]; then
                echo "(reusing cached file ${file})"
            else
                echo "Downloading ${file}..."
                # wget -q --show-progress --progress=bar:force "${url}" -O "${CACHE_DIR}/${file}" || err "Error downloading ${file} from ${url}"
                wget -q --show-progress --progress=bar:force "${url}" -O "${CACHE_DIR}/${file}.part" || err "Error downloading ${file} from ${url}"
                mv "${CACHE_DIR}/${file}.part" "${CACHE_DIR}/${file}" || err "Error finalizing download for ${file}"
            fi
            ;;
        *)
            err "Invalid download command: ${cmd}. Use 'check' or 'get'."
            ;;
    esac
}
