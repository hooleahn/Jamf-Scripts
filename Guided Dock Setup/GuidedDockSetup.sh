#!/bin/bash
# shellcheck disable=SC2155,SC2086
#
# Guided Dock Setup
#
# Presents a swiftDialog checkbox list of installed apps and adds selected
# apps to the current user's Dock using dockutil. Apps already in the Dock are
# shown as checked. A follow-up dialog lists non-business Dock items to remove,
# all checked by default; only items left checked are removed if the user confirms.
#
# Usage:
#   Run via a Jamf Pro policy. Parameters 4-11: list of apps (each param = one app).
#   Each value can be:
#     - DisplayName,Path (preferred): Safari,/Applications/Safari.app
#     - Path to app: /Applications/Google Chrome.app
#     - App name: Slack, "Google Chrome"
#   Only apps that exist on disk are included. DisplayName,Path entries must match that shape
#   (path ends in .app). If no parameters are provided, only the built-in default list is used.
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

script_version="2026.4.2"

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

# Appended to checkbox labels when an item is already in the Dock (must match jq in build_checkbox_json)
CHECKBOX_ALREADY_IN_DOCK_SUFFIX=" (Already in Dock)"

# Default list of apps to offer for Dock (DisplayName,Path)
# Only apps that are installed will be shown to the user
# The expected format is: DisplayName,Path
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
    "Microsoft OneNote,/Applications/Microsoft OneNote.app"
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
# The expected format is: DisplayName,Path
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
# The expected format is: DisplayName,Path
NON_BUSINESS_APPS=(
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

# True if value looks like DisplayName,Path (path ends with .app, both sides non-empty after trim)
valid_display_comma_path_format() {
    local entry="$1"
    local display_name app_path
    [[ -z "$entry" || "$entry" != *","* ]] && return 1
    display_name=$(echo "${entry%%,*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    app_path=$(echo "${entry#*,}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$display_name" || -z "$app_path" ]] && return 1
    [[ "$app_path" == */*.app ]] || return 1
    return 0
}

# True if needle equals any of the following arguments
path_in_array() {
    local needle="$1"
    shift
    local p
    for p in "$@"; do
        [[ "$p" == "$needle" ]] && return 0
    done
    return 1
}

# Load app list from Parameters 4-11 plus DEFAULT_APPS (populates LOAD_APP_LIST_RESULT).
# Only entries in the expected DisplayName,Path format (or legacy path / app name resolved
# via resolve_app_identifier) that point to an installed bundle are included. Order: policy
# parameters first, then defaults; duplicate paths are skipped.

load_app_list() {
    local params=("${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}" "${11:-}")
    local param display_name app_path exp_path resolved
    local seen_paths=()

    LOAD_APP_LIST_RESULT=()

    if [[ ${#params[@]} -eq 0 ]]; then
        log "INFO" "No additional apps provided. Using default apps."
    fi

    for param in "${params[@]}"; do
        param=$(echo "$param" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$param" ]] && continue

        if valid_display_comma_path_format "$param"; then
            display_name=$(echo "${param%%,*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            app_path=$(echo "${param#*,}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            exp_path="$app_path"
            [[ "$exp_path" == ~* ]] && exp_path="${userHome}${exp_path#\~}"
            if app_is_installed "$exp_path" && ! path_in_array "$exp_path" "${seen_paths[@]}"; then
                seen_paths+=("$exp_path")
                LOAD_APP_LIST_RESULT+=("${display_name},${exp_path}")
            fi
        else
            resolved=$(resolve_app_identifier "$param")
            if [[ -n "$resolved" ]]; then
                exp_path="${resolved#*,}"
                if ! path_in_array "$exp_path" "${seen_paths[@]}"; then
                    seen_paths+=("$exp_path")
                    LOAD_APP_LIST_RESULT+=("$resolved")
                fi
            fi
        fi
    done

    for param in "${DEFAULT_APPS[@]}"; do
        if ! valid_display_comma_path_format "$param"; then
            log "WARN" "Skipping malformed default Dock list entry (expected DisplayName,Path): $param"
            continue
        fi
        app_path=$(echo "${param#*,}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        exp_path="$app_path"
        [[ "$exp_path" == ~* ]] && exp_path="${userHome}${exp_path#\~}"
        if app_is_installed "$exp_path" && ! path_in_array "$exp_path" "${seen_paths[@]}"; then
            display_name=$(echo "${param%%,*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            seen_paths+=("$exp_path")
            LOAD_APP_LIST_RESULT+=("${display_name},${exp_path}")
        fi
    done
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

# Build checkbox JSON for swiftDialog. First argument: 1 = when checked is true,
# append CHECKBOX_ALREADY_IN_DOCK_SUFFIX to the label (main Dock dialog); 0 = no suffix.
# Remaining args: lines DisplayName|AppPath|checked — checked is literal "true" or "false".
# If the third field is omitted, the box defaults to unchecked.
# Entries are sorted alphabetically by display name.
build_checkbox_json() {
    local append_in_dock_suffix="${1:-0}"
    shift
    printf '%s\n' "$@" | jq -R -s \
        --arg append "$append_in_dock_suffix" \
        --arg sfx "$CHECKBOX_ALREADY_IN_DOCK_SUFFIX" '
        split("\n") | map(select(length > 0)) |
        map(split("|") |
            if length >= 3 then
                (.[2] == "true") as $chk |
                {
                    "label": (if ($chk and ($append == "1")) then (.[0] + $sfx) else .[0] end),
                    "subtitle": (if ($chk and ($append == "1")) then (.[0] + $sfx) else .[0] end),
                    "checked": $chk,
                    "icon": .[1]
                }
            else
                {"label": .[0], "checked": false, "icon": .[1]}
            end) |
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
            "title": "Dock Setup",
            "message": "Select the apps you would like to add to your Dock.\n\nNotes:\n- Only installed apps are shown.\n- Your screen will flicker briefly as the Dock is updated. \n- The applications will not be deleted from your Mac. \n- Unchecked apps will be removed from the Dock.",
            "messagefont": "weight=medium,size=14",
            "icon": "SF=dock.rectangle,colour1=#007AFF",
            "height": "600",
            "button1text": "Add to Dock",
            "button2text": "Cancel",
            "checkboxstyle": {"style": "switch", "size": "small"}
        } + $checkboxes')

    echo "$dialog_json" > "$TEMP_JSON"
    "$DIALOG_APP" -o -p --jsonfile "$TEMP_JSON" --json 2>/dev/null || true
}

# Populate NONBUSINESS_IN_DOCK_ITEMS with "DisplayName|Path" for installed
# non-business apps that appear in dock_list and are not in NON_REMOVABLE_APPS.
# Duplicate bundle names (e.g. repeated array entries) are only listed once.
collect_nonbusiness_in_dock_items() {
    local dock_list="$1"
    local entry display_name app_path app_basename skip nr
    local non_removable_names=()
    local listed_basenames=()

    NONBUSINESS_IN_DOCK_ITEMS=()

    for entry in "${NON_REMOVABLE_APPS[@]}"; do
        non_removable_names+=("$(basename "${entry#*,}" .app)")
    done

    for entry in "${NON_BUSINESS_APPS[@]}"; do
        display_name="${entry%%,*}"
        app_path="${entry#*,}"
        [[ ! -d "$app_path" ]] && continue

        app_basename=$(basename "$app_path" .app)

        path_in_array "$app_basename" "${listed_basenames[@]}" && continue
        listed_basenames+=("$app_basename")

        skip=0
        for nr in "${non_removable_names[@]}"; do
            [[ "$app_basename" == "$nr" ]] && { skip=1; break; }
        done
        [[ $skip -eq 1 ]] && continue

        if echo "$dock_list" | grep -qF "$app_basename"; then
            NONBUSINESS_IN_DOCK_ITEMS+=("$display_name|$app_path")
        fi
    done
}

# Show second dialog: same message and buttons; lists removable non-business
# Dock apps as checkboxes (caller supplies checkbox JSON). JSON result on stdout.
show_remove_nonbusiness_dialog() {
    local checkbox_json="$1"
    local message="Would you like to remove non-business apps (e.g. Music, Photos, FaceTime, iMovie, etc.) from your Dock?\n\nThis will not remove essential apps like Finder or Self Service.\n\nOnly apps currently in the Dock are listed."
    local dialog_json

    dialog_json=$(jq -n \
        --arg msg "$message" \
        --argjson checkboxes "$checkbox_json" \
        '{
            "title": "Remove Non-Business Apps",
            "message": $msg,
            "messagefont": "weight=medium,size=14",
            "icon": "SF=trash,colour1=#FF3B30",
            "height": "450",
            "button1text": "Yes, Remove Them",
            "button2text": "No, Keep Them",
            "checkboxstyle": {"style": "switch", "size": "small"}
        } + $checkboxes')

    echo "$dialog_json" > "$TEMP_JSON"
    "$DIALOG_APP" -o -p --jsonfile "$TEMP_JSON" --json 2>/dev/null
}

# Remove non-business apps from Dock for checkbox items still selected as true
# in result_json (first arg). Remaining args are "DisplayName|Path" shown in the dialog.
remove_nonbusiness_apps_from_dock() {
    local result_json="$1"
    shift
    local item display_name app_path selected app_basename
    local removed=0
    local dock_list

    dock_list=$("$DOCKUTIL" --list "$userHome" 2>/dev/null || true)

    for item in "$@"; do
        display_name="${item%|*}"
        app_path="${item#*|}"

        selected=$(echo "$result_json" | jq -r --arg name "$display_name" '.[$name] // empty')
        [[ "$selected" != "true" ]] && continue

        app_basename=$(basename "$app_path" .app)

        if echo "$dock_list" | grep -qF "$app_basename"; then
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
    log "INFO" "Running cleanup"
    log "INFO" "Removing temp files"
    if [[ -f "$TEMP_JSON" ]]; then
        rm -f "$TEMP_JSON" 2>/dev/null || true
        log "INFO" "Temp file $TEMP_JSON removed"
    fi
    if [[ -f "$TEMP_RESULT" ]]; then
        rm -f "$TEMP_RESULT" 2>/dev/null || true
        log "INFO" "Temp file $TEMP_RESULT removed"
    fi
    log "INFO" "Cleanup complete"
    exit 0
}

################################################################################
# Main
################################################################################

log "INFO" "Starting Dock setup"
log "INFO" "Script version: $script_version"
log "INFO" "Test mode: $TEST_MODE"
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

# Build checkbox JSON (pre-check apps already in the Dock; labels match swiftDialog JSON keys)
dockutil_list_cache=$("$DOCKUTIL" --list "$userHome" 2>/dev/null || true)
main_checkbox_input=()
installed_apps_labeled=()
for item in "${installed_apps[@]}"; do
    display_name="${item%|*}"
    app_path="${item#*|}"
    app_basename=$(basename "$app_path" .app)
    if echo "$dockutil_list_cache" | grep -qF "$app_basename"; then
        main_checkbox_input+=("${item}|true")
        installed_apps_labeled+=("${display_name}${CHECKBOX_ALREADY_IN_DOCK_SUFFIX}|${app_path}")
    else
        main_checkbox_input+=("${item}|false")
        installed_apps_labeled+=("$item")
    fi
done
installed_apps=("${installed_apps_labeled[@]}")
checkbox_json=$(build_checkbox_json 1 "${main_checkbox_input[@]}")
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

# Second dialog: offer to remove non-business apps from Dock (list pre-checked)
dockutil_list_nb=$("$DOCKUTIL" --list "$userHome" 2>/dev/null || true)
collect_nonbusiness_in_dock_items "$dockutil_list_nb"

if [[ ${#NONBUSINESS_IN_DOCK_ITEMS[@]} -eq 0 ]]; then
    log "INFO" "No removable non-business apps in the Dock; skipping removal prompt."
else
    nb_checkbox_input=()
    for item in "${NONBUSINESS_IN_DOCK_ITEMS[@]}"; do
        nb_checkbox_input+=("${item}|true")
    done
    nb_checkbox_json=$(build_checkbox_json 0 "${nb_checkbox_input[@]}")
    set +e
    remove_nb_result=$(show_remove_nonbusiness_dialog "$nb_checkbox_json")
    remove_dialog_exit=$?
    set -e
    if [[ $remove_dialog_exit -eq 0 ]]; then
        log "INFO" "User confirmed non-business Dock cleanup (removing apps still checked)"
        remove_nonbusiness_apps_from_dock "$remove_nb_result" "${NONBUSINESS_IN_DOCK_ITEMS[@]}"
    else
        log "INFO" "User chose to keep non-business apps in Dock"
    fi
fi

log "INFO" "Dock setup complete."

exit 0
