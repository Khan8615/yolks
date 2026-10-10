#!/bin/bash
set -euo pipefail
cd /home/container

# RustSentinel
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
BAR_WIDTH=32

info() { printf "${CYAN}[+]${RESET} %s\n" "$1"; }
success() { printf "${GREEN}[✓]${RESET} %s\n" "$1"; }
warning() { printf "${YELLOW}[!]${RESET} %s\n" "$1"; }
error() { printf "${RED}[✗]${RESET} %s\n" "$1"; }
section() { echo ""; printf "${BOLD}── %s ${RESET}\n" "$1"; }

# Consistent decimal byte formatting.
#
# SteamCMD reports byte counts. Use decimal units so:
#   6100000000 -> 6.1 GB
#
# This keeps the displayed current/total values based on the
# exact same byte values SteamCMD reports.
human_size() {
    local BYTES="${1:-0}"

    if ! [[ "${BYTES}" =~ ^[0-9]+$ ]]; then
        BYTES=0
    fi

    awk -v bytes="${BYTES}" '
        BEGIN {
            if (bytes < 1000) {
                printf "%d B", bytes
            } else if (bytes < 1000000) {
                printf "%.1f KB", bytes / 1000
            } else if (bytes < 1000000000) {
                printf "%.1f MB", bytes / 1000000
            } else if (bytes < 1000000000000) {
                printf "%.1f GB", bytes / 1000000000
            } else {
                printf "%.1f TB", bytes / 1000000000000
            }
        }
    '
}

# Progress bar
progress_bar() {
    local percent="${1:-0}"
    local label="${2:-Downloading}"
    local current="${3:-}"
    local total="${4:-}"

    if ! [[ "${percent}" =~ ^[0-9]+$ ]]; then
        percent=0
    fi

    (( percent < 0 )) && percent=0
    (( percent > 100 )) && percent=100

    local filled=$(( BAR_WIDTH * percent / 100 ))
    local empty=$(( BAR_WIDTH - filled ))
    local bar=""
    local i

    for ((i=0; i<filled; i++)); do
        bar+="█"
    done

    for ((i=0; i<empty; i++)); do
        bar+="░"
    done

    if [ -n "${current}" ] && [ -n "${total}" ]; then
        printf "\r    %-13s ${CYAN}%s${RESET} %3d%%  %s / %s\033[K" \
            "${label}" \
            "${bar}" \
            "${percent}" \
            "${current}" \
            "${total}"
    else
        printf "\r    %-13s ${CYAN}%s${RESET} %3d%%\033[K" \
            "${label}" \
            "${bar}" \
            "${percent}"
    fi
}

progress_finish() {
    local label="${1:-Downloading}"
    local current="${2:-}"
    local total="${3:-}"

    if [ -n "${total}" ] && [ "${total}" != "0 B" ]; then
        current="${total}"
    fi

    progress_bar 100 "${label}" "${current}" "${total}"
    printf "\n"
}

# Directory size
directory_size() {
    local DIR="$1"

    if [ ! -d "${DIR}" ]; then
        echo 0
        return
    fi

    du -sb "${DIR}" 2>/dev/null | awk '{print $1}' || echo 0
}

# SteamCMD runner
#
# Usage:
#   run_steamcmd <operation> <steamcmd arguments...>
#
# Operations:
#   sdk-install
#       Steam SDK installation.
#       Bootstrap/download progress is displayed.
#
#   rust-install
#       Fresh Rust installation.
#       Bootstrap/download progress is displayed.
#
#   rust-validate
#       Existing Rust installation validation.
#       SteamCMD bootstrap progress is intentionally hidden.
#       Only the actual Rust validation byte progress is displayed.
run_steamcmd() {
    local OPERATION="$1"
    shift

    local LOG_FILE
    local STEAM_STATUS
    local LINE

    LOG_FILE="$(mktemp /tmp/rustsentinel-steam.XXXXXX.log)"

    local DOWNLOAD_LABEL="Downloading"
    local HIDE_BOOTSTRAP=0

    case "${OPERATION}" in
        rust-validate)
            DOWNLOAD_LABEL="Validating"
            HIDE_BOOTSTRAP=1
            ;;

        rust-install|sdk-install)
            DOWNLOAD_LABEL="Downloading"
            HIDE_BOOTSTRAP=0
            ;;

        *)
            error "Unknown SteamCMD operation: ${OPERATION}"
            rm -f "${LOG_FILE}"
            return 1
            ;;
    esac

    # State
    local CURRENT_STAGE=""
    local BOOTSTRAP_PERCENT=0

    local DOWNLOAD_PERCENT=0
    local DOWNLOAD_CURRENT=0
    local DOWNLOAD_TOTAL=0
    local DOWNLOAD_SEEN=0
    local DOWNLOAD_DONE=0

    local APPLYING_DONE=0
    local EXTRACTING_DONE=0
    local INSTALLING_DONE=0
    local CLEANING_DONE=0

    local VERIFY_PERCENT=0
    local VERIFY_CURRENT=0
    local VERIFY_TOTAL=0
    local VERIFY_SEEN=0
    local VERIFYING_DONE=0

    local RUST_UPDATE_SEEN=0

    echo "    SteamCMD starting..."

    # Run SteamCMD
    set +e

    env -u LD_PRELOAD "${STEAMCMD}" "$@" 2>&1 |
    while IFS= read -r LINE || [ -n "${LINE}" ]; do
        printf '%s\n' "${LINE}" >> "${LOG_FILE}"
        LINE="${LINE//$'\r'/}"

        # Detect Rust application activity.
        if [[ "${LINE}" == *"AppID ${RUST_APPID}"* ]] ||
           [[ "${LINE}" == *"app '${RUST_APPID}'"* ]] ||
           [[ "${LINE}" == *"App '${RUST_APPID}'"* ]]; then
            RUST_UPDATE_SEEN=1
        fi

        # ------------------------------------------------------------
        # 1. REAL BYTE DOWNLOAD / VALIDATION PROGRESS
        # ------------------------------------------------------------
        #
        # Example:
        #
        # Update state ... progress: 53.19
        # (3250705728 / 6111751267)
        #
        # This is the important progress for Rust validation.
        # During validation SteamCMD may download/fix files. The UI
        # must continue to say "Validating", not "Downloading".
        #
        if [[ "${LINE}" =~ progress:[[:space:]]*([0-9]+([.][0-9]+)?)[[:space:]]*\(([0-9]+)[[:space:]]*/[[:space:]]*([0-9]+)\) ]]; then
            PERCENT="${BASH_REMATCH[1]}"
            CURRENT="${BASH_REMATCH[3]}"
            TOTAL="${BASH_REMATCH[4]}"
            INT_PERCENT="${PERCENT%.*}"

            # Prevent progress from moving backwards.
            if (( INT_PERCENT < DOWNLOAD_PERCENT )); then
                INT_PERCENT="${DOWNLOAD_PERCENT}"
            fi

            if (( CURRENT < DOWNLOAD_CURRENT )); then
                CURRENT="${DOWNLOAD_CURRENT}"
            fi

            if (( TOTAL > 0 )); then
                DOWNLOAD_TOTAL="${TOTAL}"
            fi

            DOWNLOAD_CURRENT="${CURRENT}"
            DOWNLOAD_PERCENT="${INT_PERCENT}"
            DOWNLOAD_SEEN=1
            RUST_UPDATE_SEEN=1
            CURRENT_STAGE="${DOWNLOAD_LABEL}"

            # The byte count is authoritative.
            # When current >= total, force the visual percentage to 100.
            if (( DOWNLOAD_TOTAL > 0 )) &&
               (( DOWNLOAD_CURRENT >= DOWNLOAD_TOTAL )); then
                DOWNLOAD_PERCENT=100
            fi

            progress_bar \
                "${DOWNLOAD_PERCENT}" \
                "${DOWNLOAD_LABEL}" \
                "$(human_size "${DOWNLOAD_CURRENT}")" \
                "$(human_size "${DOWNLOAD_TOTAL}")"

            continue
        fi

        # ------------------------------------------------------------
        # 2. GENERIC DOWNLOAD / VALIDATION PERCENTAGE
        # ------------------------------------------------------------
        if [[ "${LINE}" =~ [Pp]rogress:[[:space:]]*([0-9]+)% ]]; then
            PERCENT="${BASH_REMATCH[1]}"

            if (( PERCENT < DOWNLOAD_PERCENT )); then
                PERCENT="${DOWNLOAD_PERCENT}"
            fi

            DOWNLOAD_PERCENT="${PERCENT}"
            DOWNLOAD_SEEN=1
            RUST_UPDATE_SEEN=1
            CURRENT_STAGE="${DOWNLOAD_LABEL}"

            progress_bar \
                "${DOWNLOAD_PERCENT}" \
                "${DOWNLOAD_LABEL}"

            continue
        fi

        # ------------------------------------------------------------
        # 3. STEAMCMD BOOTSTRAP PROGRESS
        # ------------------------------------------------------------
        #
        # IMPORTANT:
        #
        # These messages are hidden during rust-validate.
        #
        # Existing Rust validation should not display:
        #
        #   Applying
        #   Extracting
        #   Installing
        #   Cleaning
        #   SteamCMD
        #
        # They are SteamCMD's own bootstrap/update activity and are
        # unrelated to the Rust validation progress shown to the user.
        #
        if [[ "${LINE}" =~ \[[[:space:]]*([0-9]+)%\][[:space:]]*Downloading ]]; then
            PERCENT="${BASH_REMATCH[1]}"

            if (( HIDE_BOOTSTRAP == 0 )); then
                if (( RUST_UPDATE_SEEN == 0 )); then
                    if (( PERCENT < BOOTSTRAP_PERCENT )); then
                        PERCENT="${BOOTSTRAP_PERCENT}"
                    fi

                    BOOTSTRAP_PERCENT="${PERCENT}"

                    progress_bar \
                        "${BOOTSTRAP_PERCENT}" \
                        "SteamCMD"
                fi
            fi

            continue
        fi

        # ------------------------------------------------------------
        # 4. BOOTSTRAP DOWNLOAD START
        # ------------------------------------------------------------
        if [[ "${LINE}" == *"[----] Downloading update"* ]]; then
            if (( HIDE_BOOTSTRAP == 0 )); then
                if (( RUST_UPDATE_SEEN == 0 )); then
                    CURRENT_STAGE="SteamCMD"

                    progress_bar \
                        "${BOOTSTRAP_PERCENT}" \
                        "SteamCMD"
                fi
            fi

            continue
        fi

        # ------------------------------------------------------------
        # 5. STEAMCMD BOOTSTRAP DOWNLOAD COMPLETE
        # ------------------------------------------------------------
        if [[ "${LINE}" == *"[----] Download Complete"* ]] ||
           [[ "${LINE}" == *"[----] Download complete"* ]]; then

            if (( HIDE_BOOTSTRAP == 0 )); then
                if (( RUST_UPDATE_SEEN == 0 )); then
                    BOOTSTRAP_PERCENT=100
                    progress_finish "SteamCMD"
                fi
            fi

            continue
        fi

        # ------------------------------------------------------------
        # 6. DOWNLOAD / VALIDATION COMPLETION
        # ------------------------------------------------------------
        if [[ "${LINE}" == *"[----] Update complete"* ]] ||
           [[ "${LINE}" == *"[----] Update Complete"* ]] ||
           [[ "${LINE}" == *"Update state"* && "${LINE}" == *"fully installed"* ]] ||
           [[ "${LINE}" == *"fully installed"* ]]; then

            if (( DOWNLOAD_SEEN == 1 )) &&
               (( DOWNLOAD_DONE == 0 )); then

                DOWNLOAD_DONE=1
                DOWNLOAD_PERCENT=100

                progress_finish \
                    "${DOWNLOAD_LABEL}" \
                    "$(human_size "${DOWNLOAD_CURRENT}")" \
                    "$(human_size "${DOWNLOAD_TOTAL}")"
            fi

            continue
        fi

        # ------------------------------------------------------------
        # 7. APPLYING
        # ------------------------------------------------------------
        if [[ "${LINE}" == *"[----] Applying update"* ]]; then

            if (( HIDE_BOOTSTRAP == 0 )); then
                if (( APPLYING_DONE == 0 )); then

                    if (( DOWNLOAD_SEEN == 1 )) &&
                       (( DOWNLOAD_DONE == 0 )); then

                        DOWNLOAD_DONE=1
                        DOWNLOAD_PERCENT=100

                        progress_finish \
                            "${DOWNLOAD_LABEL}" \
                            "$(human_size "${DOWNLOAD_CURRENT}")" \
                            "$(human_size "${DOWNLOAD_TOTAL}")"
                    fi

                    CURRENT_STAGE="Applying"
                    progress_finish "Applying"
                    APPLYING_DONE=1
                fi
            fi

            continue
        fi

        # ------------------------------------------------------------
        # 8. EXTRACTING
        # ------------------------------------------------------------
        if [[ "${LINE}" == *"[----] Extracting package"* ]]; then

            if (( HIDE_BOOTSTRAP == 0 )); then
                if (( EXTRACTING_DONE == 0 )); then

                    if (( APPLYING_DONE == 0 )); then
                        progress_finish "Applying"
                        APPLYING_DONE=1
                    fi

                    CURRENT_STAGE="Extracting"
                    progress_finish "Extracting"
                    EXTRACTING_DONE=1
                fi
            fi

            continue
        fi

        # ------------------------------------------------------------
        # 9. INSTALLING
        # ------------------------------------------------------------
        if [[ "${LINE}" == *"[----] Installing update"* ]]; then

            if (( HIDE_BOOTSTRAP == 0 )); then
                if (( INSTALLING_DONE == 0 )); then

                    if (( APPLYING_DONE == 0 )); then
                        progress_finish "Applying"
                        APPLYING_DONE=1
                    fi

                    if (( EXTRACTING_DONE == 0 )); then
                        progress_finish "Extracting"
                        EXTRACTING_DONE=1
                    fi

                    CURRENT_STAGE="Installing"
                    progress_finish "Installing"
                    INSTALLING_DONE=1
                fi
            fi

            continue
        fi

        # ------------------------------------------------------------
        # 10. CLEANING
        # ------------------------------------------------------------
        if [[ "${LINE}" == *"[----] Cleaning up"* ]]; then

            if (( HIDE_BOOTSTRAP == 0 )); then
                if (( CLEANING_DONE == 0 )); then

                    if (( APPLYING_DONE == 0 )); then
                        progress_finish "Applying"
                        APPLYING_DONE=1
                    fi

                    if (( EXTRACTING_DONE == 0 )); then
                        progress_finish "Extracting"
                        EXTRACTING_DONE=1
                    fi

                    if (( INSTALLING_DONE == 0 )); then
                        progress_finish "Installing"
                        INSTALLING_DONE=1
                    fi

                    CURRENT_STAGE="Cleaning"
                    progress_finish "Cleaning"
                    CLEANING_DONE=1
                fi
            fi

            continue
        fi

        # ------------------------------------------------------------
        # 11. VERIFICATION WITH BYTES
        # ------------------------------------------------------------
        if [[ "${LINE}" =~ [Vv]erifying:[[:space:]]*([0-9]+([.][0-9]+)?)[[:space:]]*\(([0-9]+)[[:space:]]*/[[:space:]]*([0-9]+)\) ]]; then
            PERCENT="${BASH_REMATCH[1]}"
            CURRENT="${BASH_REMATCH[3]}"
            TOTAL="${BASH_REMATCH[4]}"
            INT_PERCENT="${PERCENT%.*}"

            if (( INT_PERCENT < VERIFY_PERCENT )); then
                INT_PERCENT="${VERIFY_PERCENT}"
            fi

            if (( CURRENT < VERIFY_CURRENT )); then
                CURRENT="${VERIFY_CURRENT}"
            fi

            if (( TOTAL > 0 )); then
                VERIFY_TOTAL="${TOTAL}"
            fi

            VERIFY_CURRENT="${CURRENT}"
            VERIFY_PERCENT="${INT_PERCENT}"
            VERIFY_SEEN=1
            CURRENT_STAGE="Verifying"

            if (( VERIFY_TOTAL > 0 )) &&
               (( VERIFY_CURRENT >= VERIFY_TOTAL )); then
                VERIFY_PERCENT=100
            fi

            progress_bar \
                "${VERIFY_PERCENT}" \
                "Verifying" \
                "$(human_size "${VERIFY_CURRENT}")" \
                "$(human_size "${VERIFY_TOTAL}")"

            continue
        fi

        # ------------------------------------------------------------
        # 12. VERIFICATION PERCENTAGE
        # ------------------------------------------------------------
        if [[ "${LINE}" =~ [Vv]erif(y|ying|ication).*([0-9]+([.][0-9]+)?)% ]]; then
            PERCENT="${BASH_REMATCH[2]}"
            INT_PERCENT="${PERCENT%.*}"

            if (( INT_PERCENT < VERIFY_PERCENT )); then
                INT_PERCENT="${VERIFY_PERCENT}"
            fi

            VERIFY_PERCENT="${INT_PERCENT}"
            VERIFY_SEEN=1
            CURRENT_STAGE="Verifying"

            progress_bar \
                "${VERIFY_PERCENT}" \
                "Verifying"

            continue
        fi

        # ------------------------------------------------------------
        # 13. VERIFICATION STATE WITHOUT PROGRESS
        # ------------------------------------------------------------
        if [[ "${LINE}" == *"verifying installation"* ]] || \
           [[ "${LINE}" == *"Verifying installation"* ]] || \
           [[ "${LINE}" == *"verifying files"* ]] || \
           [[ "${LINE}" == *"Verifying files"* ]] || \
           [[ "${LINE}" == *"Update state"* && "${LINE}" == *"verifying"* ]]; then

            CURRENT_STAGE="Verifying"
            continue
        fi

        # ------------------------------------------------------------
        # 14. VERIFICATION COMPLETE
        # ------------------------------------------------------------
        if [[ "${LINE}" == *"Update state"* && "${LINE}" == *"fully installed"* ]] ||
           [[ "${LINE}" == *"Success! App '${RUST_APPID}' fully installed."* ]]; then

            if (( VERIFY_SEEN == 1 )) &&
               (( VERIFYING_DONE == 0 )); then

                VERIFYING_DONE=1
                VERIFY_PERCENT=100

                progress_finish \
                    "Verifying" \
                    "$(human_size "${VERIFY_CURRENT}")" \
                    "$(human_size "${VERIFY_TOTAL}")"
            fi

            # Do not print the raw SteamCMD installation line during
            # Rust validation. The user already has the clean validation
            # progress display.
            if (( HIDE_BOOTSTRAP == 0 )); then
                printf "\n    SteamCMD: %s\n" "${LINE}"
            fi

            continue
        fi

        # ------------------------------------------------------------
        # 15. CONNECTION STATUS
        # ------------------------------------------------------------
        case "${LINE}" in
            *"Connecting anonymously to Steam"*)
                printf "    SteamCMD: Connecting anonymously to Steam..."
                ;;

            *"Connecting to Steam"*)
                printf "\n"
                echo "    SteamCMD: Connecting to Steam..."
                ;;

            *"Logging in anonymously"*)
                printf "\n"
                echo "    SteamCMD: Logging in anonymously..."
                ;;

            *"Logged in"*)
                printf "\n"
                echo "    SteamCMD: Logged in."
                ;;

            *"Waiting for user info"*|*"Waiting for Steam"*)
                printf "\n    SteamCMD: Waiting for Steam...\n\n"
                ;;
        esac

        # ------------------------------------------------------------
        # 16. STEAMCMD ERRORS
        # ------------------------------------------------------------
        case "${LINE}" in
            *"Error"*|*"ERROR"*)
                printf "\n"
                echo "    SteamCMD: ${LINE}"
                ;;
        esac
    done

    # PIPESTATUS[0] is SteamCMD's real exit code.
    STEAM_STATUS="${PIPESTATUS[0]}"
    set -e

    # SteamCMD has fully exited.
    #
    # A successful operation finishes any progress bar that was still
    # visually below 100%.
    if [ "${STEAM_STATUS}" -eq 0 ]; then

        if (( DOWNLOAD_SEEN == 1 )) &&
           (( DOWNLOAD_DONE == 0 )); then

            DOWNLOAD_DONE=1
            DOWNLOAD_PERCENT=100

            progress_finish \
                "${DOWNLOAD_LABEL}" \
                "$(human_size "${DOWNLOAD_CURRENT}")" \
                "$(human_size "${DOWNLOAD_TOTAL}")"
        fi

        if (( VERIFY_SEEN == 1 )) &&
           (( VERIFYING_DONE == 0 )); then

            VERIFYING_DONE=1
            VERIFY_PERCENT=100

            progress_finish \
                "Verifying" \
                "$(human_size "${VERIFY_CURRENT}")" \
                "$(human_size "${VERIFY_TOTAL}")"
        fi
    fi

    printf "\n"

    # Failure
    if [ "${STEAM_STATUS}" -ne 0 ]; then
        echo ""
        error "SteamCMD failed with exit code ${STEAM_STATUS}."
        echo ""
        echo "SteamCMD output:"
        echo ""

        cat "${LOG_FILE}"
        rm -f "${LOG_FILE}"

        return "${STEAM_STATUS}"
    fi

    rm -f "${LOG_FILE}"
    return 0
}

# Header
clear 2>/dev/null || true

printf "${BOLD}${CYAN}"

cat <<'EOF'
╭──────────────────────────────────────────╮
│ RustSentinel • Pterodactyl • by cyber    │
╰──────────────────────────────────────────╯
EOF

printf "${RESET}"
echo ""

# SteamCMD
STEAMCMD="${STEAMCMD:-/opt/steamcmd/steamcmd.sh}"

if [ ! -x "${STEAMCMD}" ]; then
    error "SteamCMD was not found:"
    echo "    ${STEAMCMD}"
    exit 1
fi

# Architecture
ARCH="$(uname -m)"
echo "  Architecture    ${ARCH}"

if [ "${ARCH}" != "x86_64" ]; then
    warning "This image is intended for AMD64/x86_64."
    echo "    Detected architecture: ${ARCH}"
fi

# Rust
RUST_APPID="258550"
STEAM_SDK_APPID="1007"

# Pterodactyl / Rust variables
LEVEL="${LEVEL:-Procedural Map}"
WORLD_SIZE="${WORLD_SIZE:-6000}"
WORLD_SEED="${WORLD_SEED:-0}"
MAP_URL="${MAP_URL:-}"
HOSTNAME="${HOSTNAME:-A Rust Server}"
DESCRIPTION="${DESCRIPTION:-Powered by Pterodactyl}"
SERVER_TAGS="${SERVER_TAGS:-}"
SERVER_URL="${SERVER_URL:-}"
SERVER_IMG="${SERVER_IMG:-}"
SERVER_LOGO="${SERVER_LOGO:-}"
GAMEMODE="${GAMEMODE:-}"
FRAMEWORK="${FRAMEWORK:-vanilla}"
MAX_PLAYERS="${MAX_PLAYERS:-100}"
SAVEINTERVAL="${SAVEINTERVAL:-600}"
SERVER_PORT="${SERVER_PORT:-28015}"
QUERY_PORT="${QUERY_PORT:-28016}"
RCON_PORT="${RCON_PORT:-28017}"
RCON_PASS="${RCON_PASS:-}"
RCON_WEB="${RCON_WEB:-1}"
APP_PORT="${APP_PORT:-28082}"
BRANCH="${BRANCH:-public}"
BRANCH_PASSWORD="${BRANCH_PASSWORD:-}"
AUTO_VALIDATE="${AUTO_VALIDATE:-1}"
REGEN_SERVER="${REGEN_SERVER:-0}"
REMOVE_FILES="${REMOVE_FILES:-}"
LOGFILE="${LOGFILE:-}"
ADDITIONAL_ARGS="${ADDITIONAL_ARGS:-}"
SHOW_RCON_PASSWORD="${SHOW_RCON_PASSWORD:-0}"

# Normalize
BRANCH="$(printf '%s' "${BRANCH}" | tr '[:upper:]' '[:lower:]')"
FRAMEWORK="$(printf '%s' "${FRAMEWORK}" | tr '[:upper:]' '[:lower:]')"

# Basic information
echo "  Rust AppID      ${RUST_APPID}"
echo "  Steam SDK       ${STEAM_SDK_APPID}"
echo "  Branch          ${BRANCH}"
echo "  Framework       ${FRAMEWORK}"

# Validate framework
case "${FRAMEWORK}" in
    vanilla|carbon|oxide)
        ;;

    *)
        echo ""
        error "Invalid FRAMEWORK:"
        echo "    ${FRAMEWORK}"
        echo ""
        echo "Valid options:"
        echo "    vanilla"
        echo "    carbon"
        echo "    oxide"
        exit 1
        ;;
esac

# Branch
case "${BRANCH}" in
    public)
        STEAM_BETA=""
        ;;

    staging|aux01|aux02|aux03|aux04)
        STEAM_BETA="${BRANCH}"
        ;;

    *)
        STEAM_BETA="${BRANCH}"
        ;;
esac

if [ "${FRAMEWORK}" = "carbon" ]; then
    case "${BRANCH}" in
        public|staging|aux01|aux02|aux03|aux04)
            ;;

        *)
            error "Carbon does not have a supported build"
            echo "    for Rust branch: ${BRANCH}"
            exit 1
            ;;
    esac
fi

if [ "${FRAMEWORK}" = "oxide" ]; then
    case "${BRANCH}" in
        public|staging)
            ;;

        *)
            error "Oxide does not have a supported build"
            echo "    for Rust branch: ${BRANCH}"
            exit 1
            ;;
    esac
fi

echo ""

if [ -z "${STEAM_BETA}" ]; then
    echo "  Steam branch    public"
else
    echo "  Steam branch    ${BRANCH}"
    echo "  Beta            ${STEAM_BETA}"
fi

# RCON password
RCON_PASSWORD_FILE="/home/container/rcon-password.txt"

if [ -n "${RCON_PASS}" ]; then
    if [ "${#RCON_PASS}" -lt 8 ]; then
        error "RCON_PASS must be at least 8 characters."
        exit 1
    fi

    printf '%s\n' "${RCON_PASS}" > "${RCON_PASSWORD_FILE}"
    chmod 600 "${RCON_PASSWORD_FILE}"
    RCON_PASSWORD_SOURCE="configured"

elif [ -f "${RCON_PASSWORD_FILE}" ] && [ -s "${RCON_PASSWORD_FILE}" ]; then
    RCON_PASS="$(head -n 1 "${RCON_PASSWORD_FILE}")"

    if [ "${#RCON_PASS}" -lt 8 ]; then
        error "Saved RCON password is less than 8 characters."
        echo "    Delete ${RCON_PASSWORD_FILE} or set a new RCON_PASS."
        exit 1
    fi

    RCON_PASSWORD_SOURCE="saved"

else
    RCON_PASS=""
    RCON_CHARS='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'

    while [ "${#RCON_PASS}" -lt 12 ]; do
        RANDOM_BYTE="$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')"

        if [ -z "${RANDOM_BYTE}" ]; then
            continue
        fi

        CHAR_INDEX=$((RANDOM_BYTE % 62))
        RCON_PASS="${RCON_PASS}${RCON_CHARS:${CHAR_INDEX}:1}"
    done

    printf '%s\n' "${RCON_PASS}" > "${RCON_PASSWORD_FILE}"
    chmod 600 "${RCON_PASSWORD_FILE}"
    RCON_PASSWORD_SOURCE="generated"
fi

echo ""
echo "  RCON password   ${RCON_PASSWORD_SOURCE}"
echo "  Password file   ${RCON_PASSWORD_FILE}"

if [ "${SHOW_RCON_PASSWORD}" = "1" ]; then
    echo "  Password        ${RCON_PASS}"
fi

# World seed
if [ "${WORLD_SEED}" = "0" ]; then
    if [ -f "/home/container/seed.txt" ] && \
       [ -s "/home/container/seed.txt" ]; then
        WORLD_SEED="$(head -n 1 /home/container/seed.txt)"
    else
        WORLD_SEED="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
        WORLD_SEED=$((WORLD_SEED % 2147483648))
        printf '%s\n' "${WORLD_SEED}" > /home/container/seed.txt
    fi
fi

echo ""
echo "  World seed      ${WORLD_SEED}"

if ! [[ "${WORLD_SEED}" =~ ^[0-9]+$ ]]; then
    error "WORLD_SEED must be an integer between 0 and 2147483647."
    exit 1
fi

if [ "${WORLD_SEED}" -gt 2147483647 ]; then
    error "WORLD_SEED must be between 0 and 2147483647."
    exit 1
fi

# Regenerate
if [ "${REGEN_SERVER}" = "1" ]; then
    section "Server regeneration"

    if [ -z "${REMOVE_FILES}" ]; then
        warning "REGEN_SERVER=1 but REMOVE_FILES is empty."
        echo "    No files will be removed."
    else
        for FILE in ${REMOVE_FILES}; do
            if [[ "${FILE}" = /* ]]; then
                warning "Refusing absolute path: ${FILE}"
                continue
            fi

            echo "  Removing /home/container/${FILE}"
            rm -rf -- "/home/container/${FILE}"
        done
    fi
fi

# Steam 64-bit SDK
STEAM_SDK_DIR="/home/container/.steam/sdk64"
STEAM_CLIENT="${STEAM_SDK_DIR}/steamclient.so"
STEAM_SDK_TEMP="/tmp/rust-steam-sdk"

install_steam_sdk() {
    section "Steam 64-bit SDK"

    info "Installing Steam 64-bit SDK"

    rm -rf "${STEAM_SDK_TEMP}"
    mkdir -p "${STEAM_SDK_TEMP}"
    mkdir -p "${STEAM_SDK_DIR}"

    echo "    Downloading Steam SDK AppID ${STEAM_SDK_APPID}..."

    if ! run_steamcmd \
        sdk-install \
        +@ShutdownOnFailedCommand 1 \
        +@NoPromptForPassword 1 \
        +sSteamCmdForcePlatformType linux \
        +force_install_dir "${STEAM_SDK_TEMP}" \
        +login anonymous \
        +app_update "${STEAM_SDK_APPID}" validate \
        +quit; then

        error "Steam SDK download failed."

        echo ""
        echo "    SteamCMD download directory:"
        echo "      ${STEAM_SDK_TEMP}"

        echo ""
        echo "    Downloaded files:"

        find "${STEAM_SDK_TEMP}" \
            -maxdepth 10 \
            -type f \
            -print 2>/dev/null |
            sed 's#^#      #' |
            head -300

        rm -rf "${STEAM_SDK_TEMP}"
        exit 1
    fi

    local SDK_STEAMCLIENT=""

    SDK_STEAMCLIENT="$(
        find "${STEAM_SDK_TEMP}" \
            -type f \
            -path '*/linux64/steamclient.so' \
            -print \
            -quit 2>/dev/null || true
    )"

    if [ -z "${SDK_STEAMCLIENT}" ]; then
        SDK_STEAMCLIENT="$(
            find "${STEAM_SDK_TEMP}" \
                -type f \
                -name 'steamclient.so' \
                -print \
                -quit 2>/dev/null || true
        )"
    fi

    if [ -z "${SDK_STEAMCLIENT}" ]; then
        error "SteamCMD downloaded AppID ${STEAM_SDK_APPID},"
        echo "    but steamclient.so was not found."

        echo ""
        echo "    SteamCMD downloaded these files:"
        echo ""

        if [ -d "${STEAM_SDK_TEMP}" ]; then
            find "${STEAM_SDK_TEMP}" \
                -maxdepth 10 \
                -type f \
                -print 2>/dev/null |
                sed 's#^#      #' |
                head -300
        else
            echo "      Download directory does not exist."
        fi

        echo ""
        echo "    Expected library:"
        echo "      */linux64/steamclient.so"

        rm -rf "${STEAM_SDK_TEMP}"
        exit 1
    fi

    echo ""
    info "Found Steam 64-bit SDK"
    echo "    ${SDK_STEAMCLIENT}"

    cp "${SDK_STEAMCLIENT}" "${STEAM_CLIENT}"
    chmod 644 "${STEAM_CLIENT}"

    if [ ! -s "${STEAM_CLIENT}" ]; then
        error "Steam 64-bit SDK installation produced an empty file."
        rm -rf "${STEAM_SDK_TEMP}"
        exit 1
    fi

    SDK_SIZE="$(stat -c '%s' "${STEAM_CLIENT}" 2>/dev/null || echo 0)"

    echo ""
    success "Steam 64-bit SDK installed"
    echo "    ${STEAM_CLIENT}"
    echo "    Size: $(human_size "${SDK_SIZE}")"

    rm -rf "${STEAM_SDK_TEMP}"

    echo ""
    success "Steam SDK setup completed"
}

if [ -f "${STEAM_CLIENT}" ] && [ -s "${STEAM_CLIENT}" ]; then
    section "Steam 64-bit SDK"
    success "Steam 64-bit SDK present"
    echo "    ${STEAM_CLIENT}"
else
    install_steam_sdk
fi

# Rust app manifest
RUST_MANIFEST="/home/container/steamapps/appmanifest_${RUST_APPID}.acf"

# Build Rust SteamCMD arguments
build_rust_steamcmd_args() {
    STEAMCMD_ARGS=(
        "+@ShutdownOnFailedCommand" "1"
        "+@NoPromptForPassword" "1"
        "+force_install_dir" "/home/container"
        "+login" "anonymous"
        "+app_update" "${RUST_APPID}"
    )

    if [ -n "${STEAM_BETA}" ]; then
        STEAMCMD_ARGS+=(
            "-beta" "${STEAM_BETA}"
        )

        if [ -n "${BRANCH_PASSWORD}" ]; then
            STEAMCMD_ARGS+=(
                "-betapassword" "${BRANCH_PASSWORD}"
            )
        fi
    else
        STEAMCMD_ARGS+=(
            "-beta" "public"
        )
    fi

    if [ "${AUTO_VALIDATE}" = "1" ]; then
        STEAMCMD_ARGS+=(
            "validate"
        )
    fi

    STEAMCMD_ARGS+=(
        "+quit"
    )
}

# Determine whether Rust is already installed.
rust_server_installed() {
    if [ -f "${RUST_MANIFEST}" ]; then
        return 0
    fi

    if [ -x "/home/container/RustDedicated" ] ||
       [ -f "/home/container/RustDedicated" ] ||
       [ -f "/home/container/RustDedicated.x86_64" ]; then
        return 0
    fi

    if find /home/container \
        -maxdepth 4 \
        -type f \
        \( \
            -name "RustDedicated" \
            -o \
            -name "RustDedicated.x86_64" \
        \) \
        -print \
        -quit 2>/dev/null |
        grep -q .; then
        return 0
    fi

    return 1
}

# Rust update / validation / installation
update_rust_server() {
    section "Rust Dedicated Server"

    # Rust is already installed.
    if rust_server_installed; then

        # AUTO_VALIDATE=1:
        # Validate the existing installation.
        if [ "${AUTO_VALIDATE}" = "1" ]; then
            info "Rust Dedicated Server already installed"
            echo "    Validation enabled"
            echo ""

            info "Validating Rust Dedicated Server"
            echo ""

            build_rust_steamcmd_args

            if run_steamcmd \
                rust-validate \
                "${STEAMCMD_ARGS[@]}"; then

                echo ""
                success "Rust server validation completed"
                return 0
            fi

            echo ""
            warning "SteamCMD Rust validation failed."
            echo ""
            echo "    Attempting automatic manifest recovery..."

            if [ -f "${RUST_MANIFEST}" ]; then
                echo ""
                echo "    Removing:"
                echo "      ${RUST_MANIFEST}"

                rm -f -- "${RUST_MANIFEST}"

                if [ -f "${RUST_MANIFEST}" ]; then
                    error "Failed to remove Rust appmanifest:"
                    echo "    ${RUST_MANIFEST}"
                    return 1
                fi

                success "Rust appmanifest removed"
            else
                echo ""
                echo "    Rust appmanifest was not found."
                echo "      ${RUST_MANIFEST}"
            fi

            echo ""
            info "Retrying Rust validation"

            if run_steamcmd \
                rust-validate \
                "${STEAMCMD_ARGS[@]}"; then

                echo ""
                success "Rust server validation completed after recovery"
                return 0
            fi

            echo ""
            error "Rust validation failed"
            echo ""
            echo "    SteamCMD validation failed twice."
            echo "    Automatic manifest recovery was attempted."

            return 1
        fi

        # AUTO_VALIDATE=0:
        # Rust is already installed, so do absolutely nothing with SteamCMD.
        success "Rust Dedicated Server already installed"
        echo "    AUTO_VALIDATE=0"
        echo "    Skipping Rust update and validation"

        return 0
    fi

    # Rust is not installed.
    # Installation must happen regardless of AUTO_VALIDATE.
    info "Rust Dedicated Server not installed"
    echo ""
    info "Installing Rust Dedicated Server"
    echo ""

    build_rust_steamcmd_args

    if run_steamcmd \
        rust-install \
        "${STEAMCMD_ARGS[@]}"; then

        echo ""
        success "SteamCMD Rust installation completed"
        return 0
    fi

    echo ""
    warning "SteamCMD Rust installation failed."
    echo ""
    echo "    Attempting automatic manifest recovery..."

    if [ -f "${RUST_MANIFEST}" ]; then
        echo ""
        echo "    Removing:"
        echo "      ${RUST_MANIFEST}"

        rm -f -- "${RUST_MANIFEST}"

        if [ -f "${RUST_MANIFEST}" ]; then
            error "Failed to remove Rust appmanifest:"
            echo "    ${RUST_MANIFEST}"
            return 1
        fi

        success "Rust appmanifest removed"
    else
        echo ""
        echo "    Rust appmanifest was not found."
        echo "      ${RUST_MANIFEST}"
    fi

    echo ""
    info "Retrying Rust installation"

    if run_steamcmd \
        rust-install \
        "${STEAMCMD_ARGS[@]}"; then

        echo ""
        success "SteamCMD Rust installation completed after recovery"
        return 0
    fi

    echo ""
    error "Rust installation failed"
    echo ""
    echo "    SteamCMD installation failed twice."
    echo "    Automatic manifest recovery was attempted."

    return 1
}

if ! update_rust_server; then
    exit 1
fi

# Framework version tracking
FRAMEWORK_VERSION_FILE="/home/container/.framework-version"

get_saved_framework_version() {
    if [ ! -f "${FRAMEWORK_VERSION_FILE}" ]; then
        return 0
    fi

    awk -F'|' \
        -v framework="${FRAMEWORK}" \
        -v branch="${BRANCH}" '
        $1 == framework && $2 == branch {
            print $3
            exit
        }
    ' "${FRAMEWORK_VERSION_FILE}"
}

save_framework_version() {
    local VERSION="$1"
    local TEMP_FILE="/tmp/framework-version.$$"

    if [ -f "${FRAMEWORK_VERSION_FILE}" ]; then
        awk -F'|' \
            -v framework="${FRAMEWORK}" \
            -v branch="${BRANCH}" '
            !($1 == framework && $2 == branch)
        ' "${FRAMEWORK_VERSION_FILE}" > "${TEMP_FILE}"
    else
        : > "${TEMP_FILE}"
    fi

    printf '%s|%s|%s\n' \
        "${FRAMEWORK}" \
        "${BRANCH}" \
        "${VERSION}" >> "${TEMP_FILE}"

    mv -f "${TEMP_FILE}" "${FRAMEWORK_VERSION_FILE}"
}

# Carbon
install_carbon() {
    section "Carbon"

    local CARBON_TAG=""
    local CARBON_MODE="Release"
    local CARBON_API=""
    local CARBON_URL=""
    local LATEST_VERSION=""
    local SAVED_VERSION=""

    case "${BRANCH}" in
        public)
            CARBON_TAG="production_build"
            CARBON_MODE="Release"
            ;;

        staging)
            CARBON_TAG="rustbeta_staging_build"
            CARBON_MODE="Debug"
            ;;

        aux01)
            CARBON_TAG="rustbeta_aux01_build"
            CARBON_MODE="Debug"
            ;;

        aux02)
            CARBON_TAG="rustbeta_aux02_build"
            CARBON_MODE="Debug"
            ;;

        aux03)
            CARBON_TAG="rustbeta_aux03_build"
            CARBON_MODE="Debug"
            ;;

        aux04)
            CARBON_TAG="rustbeta_aux04_build"
            CARBON_MODE="Debug"
            ;;

        *)
            error "Unsupported Carbon branch."
            exit 1
            ;;
    esac

    CARBON_API="https://api.github.com/repos/CarbonCommunity/Carbon/releases/tags/${CARBON_TAG}"
    echo "  Release         ${CARBON_TAG}"

    LATEST_VERSION="$(
        curl -fsSL \
            -H "Accept: application/vnd.github+json" \
            "${CARBON_API}" |
        grep -oE '"name":[[:space:]]*"[^"]*v[0-9]+\.[0-9]+\.[0-9]+"' |
        grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' |
        head -n 1 |
        sed 's/^v//'
    )"

    if [ -z "${LATEST_VERSION}" ]; then
        error "Could not determine the current Carbon version"
        exit 1
    fi

    SAVED_VERSION="$(get_saved_framework_version || true)"

    echo ""
    echo "  Installed       ${SAVED_VERSION:-unknown}"
    echo "  Available       ${LATEST_VERSION}"

    if [ -n "${SAVED_VERSION}" ] && \
       [ "${SAVED_VERSION}" = "${LATEST_VERSION}" ]; then
        success "Carbon is already up to date"
        return 0
    fi

    if [ -n "${SAVED_VERSION}" ]; then
        info "Updating Carbon ${SAVED_VERSION} -> ${LATEST_VERSION}"
    else
        info "Installing Carbon ${LATEST_VERSION}"
    fi

    CARBON_URL="$(
        curl -fsSL \
            -H "Accept: application/vnd.github+json" \
            "${CARBON_API}" |
        grep '"browser_download_url":' |
        grep "Carbon.Linux.${CARBON_MODE}" |
        head -n 1 |
        sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/'
    )"

    if [ -z "${CARBON_URL}" ]; then
        error "Could not find a Carbon Linux ${CARBON_MODE} asset."
        exit 1
    fi

    rm -f /tmp/carbon.zip

    curl -fL \
        --retry 3 \
        --retry-delay 2 \
        -o /tmp/carbon.zip \
        "${CARBON_URL}"

    echo ""
    info "Extracting Carbon"

    unzip -oq /tmp/carbon.zip -d /home/container
    rm -f /tmp/carbon.zip

    save_framework_version "${LATEST_VERSION}"
    success "Carbon ${LATEST_VERSION} installation completed"
}

# Oxide
install_oxide() {
    section "Oxide"

    local OXIDE_API="https://api.github.com/repos/OxideMod/Oxide.Rust/releases/latest"
    local OXIDE_URL=""
    local LATEST_VERSION=""
    local SAVED_VERSION=""

    LATEST_VERSION="$(
        curl -fsSL \
            -H "Accept: application/vnd.github+json" \
            "${OXIDE_API}" |
        grep -oE '"tag_name":[[:space:]]*"[^"]+"' |
        head -n 1 |
        sed -E 's/.*"([^"]+)"/\1/'
    )"

    if [ -z "${LATEST_VERSION}" ]; then
        error "Could not determine the latest Oxide version."
        exit 1
    fi

    LATEST_VERSION="${LATEST_VERSION#v}"
    SAVED_VERSION="$(get_saved_framework_version || true)"

    echo "  Installed       ${SAVED_VERSION:-unknown}"
    echo "  Available       ${LATEST_VERSION}"

    if [ -n "${SAVED_VERSION}" ] && \
       [ "${SAVED_VERSION}" = "${LATEST_VERSION}" ]; then
        success "Oxide is already up to date"
        return 0
    fi

    if [ -n "${SAVED_VERSION}" ]; then
        info "Updating Oxide ${SAVED_VERSION} -> ${LATEST_VERSION}"
    else
        info "Installing Oxide ${LATEST_VERSION}"
    fi

    OXIDE_URL="$(
        curl -fsSL \
            -H "Accept: application/vnd.github+json" \
            "${OXIDE_API}" |
        grep '"browser_download_url":' |
        grep -E 'Oxide\.Rust-linux\.zip$|Oxide\.Rust.*linux.*\.zip$' |
        head -n 1 |
        sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/'
    )"

    if [ -z "${OXIDE_URL}" ]; then
        error "Could not find a Linux Oxide asset."
        exit 1
    fi

    rm -f /tmp/oxide.zip

    curl -fL \
        --retry 3 \
        --retry-delay 2 \
        -o /tmp/oxide.zip \
        "${OXIDE_URL}"

    echo ""
    info "Extracting Oxide"

    unzip -oq /tmp/oxide.zip -d /home/container
    rm -f /tmp/oxide.zip

    save_framework_version "${LATEST_VERSION}"
    success "Oxide ${LATEST_VERSION} installation completed"
}

# Framework
case "${FRAMEWORK}" in
    vanilla)
        section "Framework"
        echo "  Vanilla"
        echo ""
        success "No modding framework will be installed"
        ;;

    carbon)
        install_carbon
        ;;

    oxide)
        install_oxide
        ;;
esac

# Locate RustDedicated
RUST_SERVER=""

if [ -x "/home/container/RustDedicated" ]; then
    RUST_SERVER="/home/container/RustDedicated"
elif [ -f "/home/container/RustDedicated" ]; then
    RUST_SERVER="/home/container/RustDedicated"
elif [ -f "/home/container/RustDedicated.x86_64" ]; then
    RUST_SERVER="/home/container/RustDedicated.x86_64"
else
    RUST_SERVER="$(
        find /home/container \
            -maxdepth 4 \
            -type f \
            \( \
                -name "RustDedicated" \
                -o \
                -name "RustDedicated.x86_64" \
            \) \
            -print \
            -quit
    )"
fi

if [ -z "${RUST_SERVER}" ] || [ ! -f "${RUST_SERVER}" ]; then
    error "RustDedicated was not found."

    echo ""
    echo "Contents of /home/container:"

    find /home/container \
        -maxdepth 2 \
        -type f |
        head -100

    exit 1
fi

chmod +x "${RUST_SERVER}"

# Build RustDedicated command
SERVER_ARGS=()

SERVER_ARGS+=(
    "+server.port" "${SERVER_PORT}"
    "+server.queryport" "${QUERY_PORT}"
    "+server.identity" "rust"
)

SERVER_ARGS+=(
    "+rcon.ip" "0.0.0.0"
    "+rcon.port" "${RCON_PORT}"
    "+rcon.password" "${RCON_PASS}"
)

case "${RCON_WEB,,}" in
    1|true|yes|on)
        SERVER_ARGS+=(
            "+rcon.web" "true"
        )
        ;;

    0|false|no|off)
        SERVER_ARGS+=(
            "+rcon.web" "false"
        )
        ;;

    *)
        warning "Unknown RCON_WEB value: ${RCON_WEB}"
        echo "    Using true."

        SERVER_ARGS+=(
            "+rcon.web" "true"
        )
        ;;
esac

# Server information
SERVER_ARGS+=(
    "+server.hostname" "${HOSTNAME}"
    "+server.description" "${DESCRIPTION}"
    "+server.maxplayers" "${MAX_PLAYERS}"
    "+server.saveinterval" "${SAVEINTERVAL}"
)

# World configuration
if [ -n "${MAP_URL}" ]; then
    SERVER_ARGS+=(
        "+server.levelurl" "${MAP_URL}"
    )
else
    SERVER_ARGS+=(
        "+server.level" "${LEVEL}"
        "+server.worldsize" "${WORLD_SIZE}"
        "+server.seed" "${WORLD_SEED}"
    )
fi

# Server URL
if [ -n "${SERVER_URL}" ]; then
    SERVER_ARGS+=(
        "+server.url" "${SERVER_URL}"
    )
fi

# Header image
if [ -n "${SERVER_IMG}" ]; then
    SERVER_ARGS+=(
        "+server.headerimage" "${SERVER_IMG}"
    )
fi

# Logo
if [ -n "${SERVER_LOGO}" ]; then
    SERVER_ARGS+=(
        "+server.logoimage" "${SERVER_LOGO}"
    )
fi

# Tags
if [ -n "${SERVER_TAGS}" ]; then
    SERVER_ARGS+=(
        "+server.tags" "${SERVER_TAGS}"
    )
fi

# Game mode
if [ -n "${GAMEMODE}" ]; then
    SERVER_ARGS+=(
        "+server.gamemode" "${GAMEMODE}"
    )
fi

# Rust+
SERVER_ARGS+=(
    "+app.port" "${APP_PORT}"
)

# Display configuration
section "Server configuration"

if [ -n "${MAP_URL}" ]; then
    echo "  Map URL         ${MAP_URL}"
else
    echo "  Level           ${LEVEL}"
    echo "  World size      ${WORLD_SIZE}"
    echo "  World seed      ${WORLD_SEED}"
fi

echo ""
echo "  Hostname        ${HOSTNAME}"
echo "  Max players     ${MAX_PLAYERS}"
echo ""
echo "  Server port     ${SERVER_PORT}"
echo "  Query port      ${QUERY_PORT}"
echo "  RCON port       ${RCON_PORT}"
echo "  RCON web        ${RCON_WEB}"
echo "  App port        ${APP_PORT}"
echo ""
echo "  Framework       ${FRAMEWORK}"

# Logging
if [ -n "${LOGFILE}" ]; then
    if [[ "${LOGFILE}" = /* ]]; then
        error "LOGFILE must be a relative path."
        echo "    Example: rustserver.log"
        exit 1
    fi

    echo "  Log file        /home/container/${LOGFILE}"
    LOG_DIR="$(dirname "/home/container/${LOGFILE}")"
    mkdir -p "${LOG_DIR}"
else
    echo "  Log file        Console only"
fi

# Additional arguments
if [ -n "${ADDITIONAL_ARGS}" ]; then
    echo ""
    echo "  Additional args ${ADDITIONAL_ARGS}"
fi

# Construct command
CMD=(
    "${RUST_SERVER}"
    "-batchmode"
    "${SERVER_ARGS[@]}"
)

# Logging
if [ -n "${LOGFILE}" ]; then
    CMD+=(
        "-logfile" "${LOGFILE}"
    )
fi

# Additional arguments LAST
if [ -n "${ADDITIONAL_ARGS}" ]; then
    # shellcheck disable=SC2206
    EXTRA_ARGS=( ${ADDITIONAL_ARGS} )

    CMD+=(
        "${EXTRA_ARGS[@]}"
    )
fi

# Start server
section "Startup Parameters"

info "Starting RustDedicated"

echo ""

printf 'Command:'

for ARG in "${CMD[@]}"; do
    if [ "${ARG}" = "${RCON_PASS}" ]; then
        printf ' ********'
    else
        printf ' %q' "${ARG}"
    fi
done

echo ""
echo ""

exec "${CMD[@]}"
