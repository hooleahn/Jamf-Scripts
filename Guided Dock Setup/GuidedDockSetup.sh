#!/bin/bash
# shellcheck disable=SC2155,SC2086
#
# Guided Dock Setup
#
# Presents a swiftDialog checkbox list of installed apps and adds selected
# apps to the current user's Dock using dockutil.
#
# Usage:
#   Run via a Jamf Pro policy. Parameters 4-11: list of apps (each param = one app).
#   Each value can be:
#     - Path to app: /Applications/Google Chrome.app
#     - App name: Safari, Slack, "Google Chrome"
#   If no parameters are provided, uses a default list of common apps.
#
#   Test mode: Pass --test or -t as first argument to run without making changes.
#   Example: ./script.sh --test
#
# Requirements:
#   - swiftDialog (installed via jamf policy -event installSwiftDialog or similar)
#   - dockutil (installed via jamf policy -event install_dockutil or similar)
#   - jq (for JSON parsing)
#

set -e

script_version="2026.4.1"

## Test mode: when set, no Dock changes are made
## Enable via: --test or -t as first arg, or DOCK_SETUP_TEST=1 environment variable
TEST_MODE=""
[[ "$1" == "--test" || "$1" == "-t" || "$DOCK_SETUP_TEST" == "1" ]] && TEST_MODE="1"

## Variables
DIALOG_APP="/usr/local/bin/dialog"
DOCKUTIL="/usr/local/bin/dockutil"
JAMF_BINARY="/usr/local/bin/jamf"
DIALOG_TRIGGER="installSwiftDialog"
DOCKUTIL_TRIGGER="installDockutil"
JQ_TRIGGER="installJq"
# Parameters 4-11: app identifiers (path to .app or app name)

# Get the currently logged-in user
currentuser=$(stat -f %Su /dev/console 2>/dev/null || echo "")
userHome="/Users/${currentuser}"

# Temporary files
TEMP_JSON="/var/tmp/dock_setup_dialog.json"
TEMP_RESULT="/var/tmp/dock_setup_result.json"

## Default list of apps to offer for Dock (DisplayName,Path)
## Only apps that are installed will be shown to the user
DEFAULT_APPS=(
    "Google Chrome,/Applications/Google Chrome.app"
    "Microsoft Edge,/Applications/Microsoft Edge.app"
    "Safari,/Applications/Safari.app"
    "Firefox,/Applications/Firefox.app"
    "Firefox Developer Edition,/Applications/Firefox Developer Edition.app"
    "Slack,/Applications/Slack.app"
    "Microsoft Teams,/Applications/Microsoft Teams.app"
    "Microsoft Teams (work or school),/Applications/Microsoft Teams (work or school).app"
    "Microsoft Outlook,/Applications/Microsoft Outlook.app"
    "Microsoft Word,/Applications/Microsoft Word.app"
    "Microsoft Excel,/Applications/Microsoft Excel.app"
    "Microsoft PowerPoint,/Applications/Microsoft PowerPoint.app"
    "OneNote,/Applications/Microsoft OneNote.app"
    "Zoom,/Applications/Zoom.us.app"
    "Terminal,/System/Applications/Utilities/Terminal.app"
    "Calendar,/System/Applications/Calendar.app"
    "Microsoft OneDrive,/Applications/Microsoft OneDrive.app"
    "Cursor,/Applications/Cursor.app"
    "Visual Studio Code,/Applications/Visual Studio Code.app"
    "Vivaldi,/Applications/Vivaldi.app"
    "Ghostty,/Applications/Ghostty.app"
    "Brisqi,/Applications/Brisqi.app"
    "Obsidian,/Applications/Obsidian.app"
    "HeyNote,/Applications/HeyNote.app"
    "Itsypad,/Applications/Itsypad.app"
    "Keeper Password Manager,/Applications/Keeper Password Manager.app"
    "Preview,/System/Applications/Preview.app"
    "TextEdit,/System/Applications/TextEdit.app"
    "VLC,/Applications/VLC.app"
    "Xcode,/Applications/Xcode.app"
)

# Non-removable apps
# These apps will not be removed from the Dock
# Finder, System Settings, Self Service, Self Service+
NON_REMOVABLE_APPS=(
    "Finder,/System/Library/CoreServices/Finder.app"
    "System Settings,/System/Applications/System Settings.app"
    "Self Service,/Applications/Self Service.app"
    "Self Service+,/Applications/Self Service+.app"
)

# Non-business apps
# These apps will be removed from the Dock if the user does not select them
# These are apps that are not typically used by business users
# These include apps like Music, Photos, TV, etc.
# The user can choose to keep these apps in the Dock if they want to.
NON_BUSINESS_APPS=(
    "TV,/System/Applications/TV.app"
    "Music,/System/Applications/Music.app"
    "Photos,/System/Applications/Photos.app"
    "Phone,/System/Applications/Phone.app"
    "FaceTime,/System/Applications/FaceTime.app"
    "Messages,/System/Applications/Messages.app"
    "iMovie,/Applications/iMovie.app"
    "Keynote,/Applications/Keynote.app"
    "Numbers,/Applications/Numbers.app"
    "Pages,/Applications/Pages.app"
    "Photo Booth,/System/Applications/Photo Booth.app"
    "iPhone Mirroring,/System/Applications/iPhone Mirroring.app"
    "Podcasts,/System/Applications/Podcasts.app"
    "TV,/System/Applications/TV.app"
    "Mail,/System/Applications/Mail.app"
    "Contacts,/System/Applications/Contacts.app"
    "Reminders,/System/Applications/Reminders.app"
    "Maps,/System/Applications/Maps.app"
    "App Store,/System/Applications/App Store.app"
    "Launchpad,/System/Applications/Launchpad.app"
    "Notes,/System/Applications/Notes.app"
    "Games,/System/Applications/Games.app"
)
################################################################################
# Functions
################################################################################

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
}

# Check if an app path exists (handles /Applications, ~/Applications, /System/Applications)
app_is_installed() {
    local app_path="$1"
    # Expand ~ to actual home if present
    [[ "$app_path" == ~* ]] && app_path="${userHome}${app_path#\~}"
    [[ -d "$app_path" ]]
}

# Get display name from app's Info.plist
get_app_display_name() {
    local app_path="$1"
    local name
    name=$(defaults read "$app_path/Contents/Info.plist" CFBundleName 2>/dev/null)
    [[ -z "$name" ]] && name=$(defaults read "$app_path/Contents/Info.plist" CFBundleDisplayName 2>/dev/null)
    [[ -z "$name" ]] && name=$(basename "$app_path" .app)
    echo "${name}"
}

# Resolve app identifier (path or name) to "DisplayName,Path" - returns empty if not found
resolve_app_identifier() {
    local id
    id=$(echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$id" ]] && return

    local app_path="" display_name=""

    # If it looks like a path (contains / and ends with .app)
    if [[ "$id" == */*.app ]]; then
        app_path="${id}"
        [[ "$app_path" == ~* ]] && app_path="${userHome}${app_path#\~}"
        if [[ -d "$app_path" ]]; then
            display_name=$(get_app_display_name "$app_path")
            echo "${display_name},${app_path}"
        fi
    else
        # Treat as app name - search standard locations
        local search_name="${id}.app"
        local search_dirs=(
            "/Applications"
            "/Applications/Utilities"
            "/System/Applications"
            "/System/Applications/Utilities"
            "${userHome}/Applications"
        )
        for dir in "${search_dirs[@]}"; do
            [[ ! -d "$dir" ]] && continue
            # Handle names with spaces: "Google Chrome" -> "Google Chrome.app"
            if [[ -d "$dir/$search_name" ]]; then
                app_path="$dir/$search_name"
                display_name=$(get_app_display_name "$app_path")
                echo "${display_name},${app_path}"
                return
            fi
            # Also try direct directory search for exact match
            for found in "$dir"/*.app; do
                [[ -d "$found" && "$(basename "$found")" == "$search_name" ]] && {
                    app_path="$found"
                    display_name=$(get_app_display_name "$app_path")
                    echo "${display_name},${app_path}"
                    return
                }
            done
        done
    fi
}

# Load app list from Parameters 4-11 or use defaults (populates LOAD_APP_LIST_RESULT)
load_app_list() {
    local params=("${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}" "${11:-}")
    local param_items=()
    local entry path seen_paths

    for p in "${params[@]}"; do
        [[ -z "$p" ]] && continue
        # Support comma-separated values in a single param (e.g. "Chrome,Safari" or "/Applications/Chrome.app,/Applications/Safari.app")
        IFS=',' read -ra items <<< "$p"
        for item in "${items[@]}"; do
            item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$item" ]] && continue
            [[ "$item" == "--test" || "$item" == "-t" ]] && continue
            local resolved
            resolved=$(resolve_app_identifier "$item")
            [[ -n "$resolved" ]] && param_items+=("$resolved")
        done
    done

    LOAD_APP_LIST_RESULT=()
    if [[ ${#param_items[@]} -gt 0 ]]; then
        seen_paths=""
        for entry in "${param_items[@]}"; do
            path="${entry#*,}"
            if ! echo "$seen_paths" | grep -qFx "$path" 2>/dev/null; then
                seen_paths="${seen_paths:+$seen_paths$'\n'}$path"
                LOAD_APP_LIST_RESULT+=("$entry")
            fi
        done
    else
        LOAD_APP_LIST_RESULT=("${DEFAULT_APPS[@]}")
    fi
}

# Filter to only installed apps, return "DisplayName|Path" for each (populates GET_INSTALLED_APPS_RESULT)
get_installed_apps() {
    local in_arr=("$@")
    local entry display_name app_path

    GET_INSTALLED_APPS_RESULT=()
    for entry in "${in_arr[@]}"; do
        display_name="${entry%%,*}"
        app_path="${entry#*,}"
        if app_is_installed "$app_path"; then
            GET_INSTALLED_APPS_RESULT+=("$display_name|$app_path")
        fi
    done
}

# Ensure swiftDialog is installed
ensure_swiftdialog() {
    if [[ ! -e "/Library/Application Support/Dialog/Dialog.app" ]]; then
        if [[ -e "$JAMF_BINARY" ]]; then
            log "INFO" "Installing swiftDialog..."
            "$JAMF_BINARY" policy -event "$DIALOG_TRIGGER" -forceNoRecon 2>/dev/null || true
        else
            log "ERROR" "Jamf binary not found!"
        fi
    fi
    if [[ ! -e "$DIALOG_APP" ]]; then
        log "ERROR" "swiftDialog is required. Install it or run via Jamf with $DIALOG_TRIGGER policy."
        exit 1
    fi
}

# Ensure dockutil is installed
ensure_dockutil() {
    if [[ ! -e "$DOCKUTIL" ]]; then
        if [[ -e "$JAMF_BINARY" ]]; then
            log "INFO" "Installing dockutil..."
            "$JAMF_BINARY" policy -event "$DOCKUTIL_TRIGGER" -forceNoRecon 2>/dev/null || true
        else
            log "ERROR" "Jamf binary not found!"
        fi
    fi
    if [[ ! -e "$DOCKUTIL" ]]; then
        log "ERROR" "dockutil is required. Install it or run via Jamf with $DOCKUTIL_TRIGGER policy."
        exit 1
    fi
}

# Ensure jq is installed (used for JSON parsing)
ensure_jq() {
    if ! command -v jq &>/dev/null; then
        if [[ -e "$JAMF_BINARY" ]]; then
            log "INFO" "Installing jq..."
            "$JAMF_BINARY" policy -event "$JQ_TRIGGER" -forceNoRecon 2>/dev/null || true
        fi
    fi
    if ! command -v jq &>/dev/null; then
        log "ERROR" "jq is required for JSON parsing. Install it or run via Jamf with $JQ_TRIGGER policy trigger."
        exit 1
    fi
}

# Build checkbox JSON for swiftDialog (each item is "DisplayName|AppPath")
# Entries are sorted alphabetically by display name
build_checkbox_json() {
    printf '%s\n' "$@" | jq -R -s '
        split("\n") | map(select(length > 0)) |
        map(split("|") | {"label": .[0], "checked": true, "icon": .[1]}) |
        sort_by(.label | ascii_downcase) |
        {"checkbox": .}
    '
}

# Create and show swiftDialog
show_dialog() {
    local checkbox_json="$1"
    local dialog_json

    dialog_json=$(jq -n \
        --argjson checkboxes "$checkbox_json" \
        '{
            "title": "Set Up Your Dock",
            "message": "Select the apps you would like to add to your Dock.\n\nOnly installed apps are shown.\n\nYour screen will flicker briefly as the Dock is updated. \n\nThe applications will not be deleted from your Mac.",
            "icon": "SF=dock.rectangle,colour1=#007AFF",
            "height": "450",
            "button1text": "Add to Dock",
            "button2text": "Cancel",
            "checkboxstyle": {"style": "switch", "size": "small"}
        } + $checkboxes')

    echo "$dialog_json" > "$TEMP_JSON"
    "$DIALOG_APP" -o -p --jsonfile "$TEMP_JSON" --json 2>/dev/null || true
}

# Show second dialog: prompt to remove non-business apps from Dock
show_remove_nonbusiness_dialog() {
    local message="Would you like to remove non-business apps (e.g. Music, Photos, FaceTime, iMovie, etc.) from your Dock?\n\nThis will not remove essential apps like Finder or Self Service."
    local dialog_json

    dialog_json=$(jq -n \
        --arg msg "$message" \
        '{
            "title": "Remove Non-Business Apps",
            "message": $msg,
            "icon": "SF=trash,colour1=#FF3B30",
            "height": "250",
            "button1text": "Yes, Remove Them",
            "button2text": "No, Keep Them"
        }')

    echo "$dialog_json" > "$TEMP_JSON"
    "$DIALOG_APP" -o -p --jsonfile "$TEMP_JSON" 2>/dev/null || true
}

# Remove non-business apps from Dock (skips NON_REMOVABLE_APPS)
remove_nonbusiness_apps_from_dock() {
    local entry display_name app_path app_basename
    local removed=0

    # Build set of non-removable app names for exclusion
    local non_removable_names=()
    for entry in "${NON_REMOVABLE_APPS[@]}"; do
        non_removable_names+=("$(basename "${entry#*,}" .app)")
    done

    for entry in "${NON_BUSINESS_APPS[@]}"; do
        display_name="${entry%%,*}"
        app_path="${entry#*,}"
        [[ ! -d "$app_path" ]] && continue

        app_basename=$(basename "$app_path" .app)

        # Skip if in non-removable list
        local skip=0
        for nr in "${non_removable_names[@]}"; do
            [[ "$app_basename" == "$nr" ]] && { skip=1; break; }
        done
        [[ $skip -eq 1 ]] && continue

        # Remove from Dock if present
        if "$DOCKUTIL" --list "$userHome" 2>/dev/null | grep -qF "$app_basename"; then
            if [[ "$TEST_MODE" == "1" ]]; then
                log "TEST" "Would remove $display_name from Dock"
            else
                log "INFO" "Removing $display_name from Dock"
                sudo -u "$currentuser" "$DOCKUTIL" --remove "$app_basename" --homeloc "$userHome" --no-restart 2>/dev/null || true
            fi
            ((removed++)) || true
        fi
    done

    if [[ $removed -gt 0 && "$TEST_MODE" != "1" ]]; then
        killall Dock 2>/dev/null || true
    fi
}

# Remove unchecked apps from Dock (skips NON_REMOVABLE_APPS)
remove_unselected_apps_from_dock() {
    local result_json="$1"
    shift
    local removed=0
    local item display_name app_path selected app_basename

    # Build set of non-removable app names for exclusion
    local non_removable_names=()
    local entry
    for entry in "${NON_REMOVABLE_APPS[@]}"; do
        non_removable_names+=("$(basename "${entry#*,}" .app)")
    done

    for item in "$@"; do
        display_name="${item%|*}"
        app_path="${item#*|}"

        selected=$(echo "$result_json" | jq -r --arg name "$display_name" '.[$name] // empty')

        if [[ "$selected" != "true" ]]; then
            app_basename=$(basename "$app_path" .app)

            # Skip if in non-removable list
            local skip=0
            for nr in "${non_removable_names[@]}"; do
                [[ "$app_basename" == "$nr" ]] && { skip=1; break; }
            done
            [[ $skip -eq 1 ]] && continue

            if "$DOCKUTIL" --list "$userHome" 2>/dev/null | grep -qF "$app_basename"; then
                if [[ "$TEST_MODE" == "1" ]]; then
                    log "TEST" "Would remove $display_name from Dock (unchecked)"
                else
                    log "INFO" "Removing $display_name from Dock (unchecked)"
                    sudo -u "$currentuser" "$DOCKUTIL" --remove "$app_basename" --homeloc "$userHome" --no-restart 2>/dev/null || true
                fi
                ((removed++)) || true
            fi
        fi
    done

    if [[ $removed -gt 0 && "$TEST_MODE" != "1" ]]; then
        killall Dock 2>/dev/null || true
    fi
}

# Add selected apps to Dock
add_apps_to_dock() {
    local result_json="$1"
    shift
    local added=0
    local item display_name app_path selected app_basename

    for item in "$@"; do
        display_name="${item%|*}"
        app_path="${item#*|}"

        # Check if user selected this app (checkbox returns true for selected)
        selected=$(echo "$result_json" | jq -r --arg name "$display_name" '.[$name] // empty')

        if [[ "$selected" == "true" ]]; then
            # Check if already in Dock
            app_basename=$(basename "$app_path" .app)
            if [[ "$TEST_MODE" == "1" ]]; then
                log "TEST" "Would add/replace $display_name in Dock"
            elif "$DOCKUTIL" --list "$userHome" 2>/dev/null | grep -qF "$app_basename"; then
                log "INFO" "Replacing $display_name in Dock"
                sudo -u "$currentuser" "$DOCKUTIL" --add "$app_path" --replacing "$app_basename" --homeloc "$userHome" 2>/dev/null || true
            else
                log "INFO" "Adding $display_name to Dock"
                sudo -u "$currentuser" "$DOCKUTIL" --add "$app_path" --homeloc "$userHome" 2>/dev/null || true
            fi
            ((added++)) || true
        fi
    done

    # Restart Dock to apply changes
    if [[ $added -gt 0 && "$TEST_MODE" != "1" ]]; then
        killall Dock 2>/dev/null || true
    fi
}

cleanup() {
    rm -f "$TEMP_JSON" "$TEMP_RESULT" 2>/dev/null || true
}

################################################################################
# Main
################################################################################

log "INFO" "Starting Guided Dock setup"
log "INFO" "Script version: $script_version"
log "INFO" "Test mode: ${TEST_MODE:-"False"}"
log "INFO" "Current user: $currentuser"
log "INFO" "User home: $userHome"
log "INFO" "Current user ID: $(id -u $currentuser)"

trap cleanup EXIT

# Must run as root for jamf policies and user detection
if [[ $(id -u) -ne 0 ]]; then
    log "ERROR" "This script must be run as root."
    exit 1
fi

# Need a logged-in user
if [[ -z "$currentuser" || "$currentuser" == "loginwindow" ]]; then
    log "ERROR" "No user is currently logged in."
    exit 1
fi

[[ "$TEST_MODE" == "1" ]] && log "INFO" "TEST MODE - no changes will be made"
log "INFO" "Running Dock setup for user: $currentuser"

ensure_swiftdialog
ensure_dockutil
ensure_jq

# Load and filter app list
load_app_list
get_installed_apps "${LOAD_APP_LIST_RESULT[@]}"
installed_apps=("${GET_INSTALLED_APPS_RESULT[@]}")

if [[ ${#installed_apps[@]} -eq 0 ]]; then
    log "INFO" "No apps from the list are installed on this Mac."
    "$DIALOG_APP" --title "Dock Setup" \
        --message "None of the configured apps were found on this computer.\n\nNo changes will be made to your Dock." \
        --icon "SF=info.circle" \
        --button1text "OK" 2>/dev/null || true
    exit 0
fi

# Build checkbox JSON and show dialog
checkbox_json=$(build_checkbox_json "${installed_apps[@]}")
result=$(show_dialog "$checkbox_json")

# User canceled or closed without selecting
if [[ -z "$result" || "$result" == "{}" ]]; then
    log "INFO" "User canceled Dock setup."
    exit 0
fi

# Add selected apps to Dock
add_apps_to_dock "$result" "${installed_apps[@]}"

# Remove unchecked apps from Dock
remove_unselected_apps_from_dock "$result" "${installed_apps[@]}"

# Second dialog: offer to remove non-business apps from Dock
show_remove_nonbusiness_dialog
remove_dialog_exit=$?
if [[ $remove_dialog_exit -eq 0 ]]; then
    log "INFO" "User chose to remove non-business apps from Dock"
    remove_nonbusiness_apps_from_dock
else
    log "INFO" "User chose to keep non-business apps in Dock"
fi

log "INFO" "Dock setup complete."
exit 0
