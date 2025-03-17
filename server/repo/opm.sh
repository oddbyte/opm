#!${BUSYBOX} ash

# OPM - Odd Package Manager

# Error handling
set -e

# Color support variables
NO_COLOR=0
COLOR_SUPPORT=1

# Check if terminal supports colors
check_color_support() {
    if [ -t 1 ] && [ -n "$(tput colors 2>/dev/null)" ] && [ "$(tput colors)" -ge 8 ]; then
        COLOR_SUPPORT=1
    else
        COLOR_SUPPORT=0
    fi
}

# Color definitions
COLOR_RESET=$(printf '\033[0m')
COLOR_RED=$(printf '\033[31m') 
COLOR_GREEN=$(printf '\033[32m')
COLOR_YELLOW=$(printf '\033[33m')
COLOR_BLUE=$(printf '\033[34m')
COLOR_CYAN=$(printf '\033[36m')
COLOR_GRAY=$(printf '\033[90m')
COLOR_BOLD=$(printf '\033[1m')

# Custom print functions
print_msg() {
    local type="$1"
    local msg="$2"
    local prefix=""
    
    if [ $NO_COLOR -eq 1 ] || [ $COLOR_SUPPORT -eq 0 ]; then
        # No color mode, use text prefixes
        case "$type" in
            "error")   prefix="[E] " ;;
            "warning") prefix="[W] " ;;
            "info")    prefix="[L] " ;;
            "success") prefix="[L] " ;;
            "debug")   prefix="[D] " ;;
            *)         prefix="" ;; # Dont include "header" here because it doesnt have a prefix
        esac
        printf "%s%s\n" "${prefix}" "${msg}"
    else
        # Color mode
        case "$type" in
            "error")   printf "%b%s%b\n" "${COLOR_RED}" "${msg}" "${COLOR_RESET}" ;;
            "warning") printf "%b%s%b\n" "${COLOR_YELLOW}" "${msg}" "${COLOR_RESET}" ;;
            "info")    printf "%b%s%b\n" "${COLOR_BLUE}" "${msg}" "${COLOR_RESET}" ;;
            "success") printf "%b%s%b\n" "${COLOR_GREEN}" "${msg}" "${COLOR_RESET}" ;;
            "header")  printf "%b%b%s%b\n" "${COLOR_BOLD}" "${COLOR_CYAN}" "${msg}" "${COLOR_RESET}" ;;
            "debug")   printf "%b%s%b\n" "${COLOR_GRAY}" "${msg}" "${COLOR_RESET}" ;;
            *)         printf "%s\n" "${msg}" ;;
        esac
    fi
}

# Wrapper functions for different message types
error_msg() { print_msg "error" "$1"; }
warning_msg() { print_msg "warning" "$1"; }
info_msg() { print_msg "info" "$1"; }
success_msg() { print_msg "success" "$1"; }
header_msg() { print_msg "header" "$1"; }
debug_msg() { [ $DEBUG -eq 1 ] && print_msg "debug" "$1"; }
plain_msg() { printf "%s\n" "$1"; }

# Debugging
DEBUG=0
debug_print() {
    if [ $DEBUG -eq 1 ]; then
        debug_msg "$@"
    fi
}

# Check for OPM_ROOT environment variable
[ -z "$OPM_ROOT" ] && { error_msg "Error: OPM_ROOT not set. Source ~/.profile or $HOME/.opm/env.sh"; exit 1; }
ENV_FILE="$OPM_ROOT/env.sh"

# Source environment file
[ -f "$ENV_FILE" ] || { error_msg "Error: $ENV_FILE not found"; exit 1; }
. "$ENV_FILE"

# Check for BusyBox
[ -x "$BUSYBOX" ] || { error_msg "Error: BusyBox not found at $BUSYBOX"; exit 1; }

# Ensure env.sh is sourced in profile
if ! "$BUSYBOX" grep -q ". $ENV_FILE" ~/.profile; then
    "$BUSYBOX" echo ". $ENV_FILE" >> ~/.profile
fi

# Global variables
AUTO_YES=0
PARALLEL_INSTALL=0
MAX_PARALLEL_JOBS=4

# Constants
OPM_PID_FILE="$OPM_ROOT/opm.pid"
OPM_TMP="$OPM_ROOT/tmp"
OPM_CONFS="$OPM_DATA/configs"
OPM_UPDATE_CACHE="$OPM_ROOT/update-cache"
ONE_GB=1073741824
UPDATE_CACHE_EXPIRY=3600  # 1 hour in seconds
OPM_LAST_UPDATE_CHECK="$OPM_ROOT/lastupdatecheck"
WEEK_SECONDS=604800  # 7 days in seconds

# Initialize color support at startup
check_color_support

# Create required directories
"$BUSYBOX" mkdir -p "$OPM_CONFS" "$OPM_TMP"

# Function definitions
print_header() {
    header_msg "====================================="
    header_msg "          OPM Package Manager        "
    header_msg "          By Oddbyte                 "
    header_msg "====================================="
}

usage() {
    print_header
    header_msg "
Usage:
    opm [command] [options]

Commands:
    help                                Show this help message
    install | add | i [pkg]             Install a package (pkg can be name@version)
    remove | uninstall | delete | rm    Remove a package
    repos                               List configured repositories
    addrepo [repo_url]                  Add a repository
    rmrepo [repo_url]                   Remove a repository
    list                                List all package names
    search [query]                      Search packages
    reinstall [package]                 Reinstalls the package, deleting all data
    upgrade [package1] [package2]...    Reinstalls packages, keeps config data
    update                              Update OPM
    upgradecheck                        Check for package updates
    show | info [package]               Show info about package
    postinstall [package]               Run post-install script for a package
    start [package]                     Start the package's service
    doctor | diagnose                   Run system diagnostics

Options:
    -y, --yes                           Automatic yes to prompts
    -p, --parallel                      Enable parallel installation
    -j, --jobs [n]                      Set number of parallel jobs (default: 4)
    --debug                             Enable debug messages
    --nocolor                           Disable colored output
"
}

get_numeric_choice() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local choice
    
    while true; do
        printf "%s" "$prompt"
        read choice
        
        # Verify it's a number in range
        if [ "$choice" -ge "$min" ] 2>/dev/null && [ "$choice" -le "$max" ] 2>/dev/null; then
            echo "$choice"
            return 0
        else
            error_msg "Invalid choice. Please enter a number between $min and $max."
        fi
    done
}

record_update_check_time() {
    "$BUSYBOX" date +%s > "$OPM_LAST_UPDATE_CHECK"
}

should_check_updates() {
    local now=$("$BUSYBOX" date +%s)
    
    if [ ! -f "$OPM_LAST_UPDATE_CHECK" ]; then
        return 0  # Should check if file doesn't exist
    fi
    
    local last_check=$("$BUSYBOX" cat "$OPM_LAST_UPDATE_CHECK")
    local time_diff=$((now - last_check))
    
    [ $time_diff -gt $WEEK_SECONDS ]
    return $?
}

safe_download() {
    local url="$1"
    local output="$2"
    local quiet="${3:-0}"
    
    if [ "$quiet" -eq 1 ]; then
        "$BUSYBOX" wget -qO "$output" "$url" || return 1
    else
        "$BUSYBOX" wget -O "$output" "$url" || return 1
    fi
    return 0
}

validate_param() {
    local param_value="$1"
    local error_msg="$2"
    
    if [ -z "$param_value" ]; then
        error_msg "Error: $error_msg"
        return 1
    fi
    return 0
}

is_package_installed() {
    local package="$1"
    [ -d "$OPM_DATA/$package" ]
    return $?
}

confirm_action() {
    [ $AUTO_YES -eq 1 ] && return 0
    
    printf "%s [Y/n]: " "$1"
    read choice
    choice=${choice:-Y}
    case "$choice" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

handle_error() {
    local message="$1"
    local temp_file="${2:-}"
    
    error_msg "Error: $message"
    [ -n "$temp_file" ] && "$BUSYBOX" rm -f "$temp_file"
    return 1
}

get_architecture() {
    "$BUSYBOX" arch 2>/dev/null || "$BUSYBOX" uname -m
}

parse_package_arg() {
    local arg="$1"
    local result
    
    # Check if package name includes version (package@version)
    if echo "$arg" | "$BUSYBOX" grep -q "@"; then
        local pkg_name=$(echo "$arg" | "$BUSYBOX" cut -d "@" -f 1)
        local pkg_version=$(echo "$arg" | "$BUSYBOX" cut -d "@" -f 2)
        result="${pkg_name}|${pkg_version}"
    else
        result="${arg}|latest"
    fi
    
    echo "$result"
}

verify_package_in_repos() {
    local package="$1"
    local temp_file="$2"
    local found=0
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        if safe_download "$repo_url/listpackages" "$temp_file" 1; then
            echo "" >> "$temp_file"  # Ensure last line is processed
            
            while IFS='|' read -r name version; do
                [ -z "$name" ] && continue
                
                if [ "$name" = "$package" ]; then
                    return 0
                fi
            done < "$temp_file"
        fi
    done < "$OPM_REPOS_FILE"
    
    return 1
}

manage_repo() {
    local action="$1"
    local repo_url="$2"
    
    validate_param "$repo_url" "Repository URL required" || return 1
    
    case "$action" in
        add)
            if "$BUSYBOX" grep -q "^$repo_url\$" "$OPM_REPOS_FILE"; then
                info_msg "Repository already exists"
            else
                echo "$repo_url" >> "$OPM_REPOS_FILE"
                success_msg "Repository added"
            fi
            ;;
        remove)
            if "$BUSYBOX" grep -q "^$repo_url\$" "$OPM_REPOS_FILE"; then
                "$BUSYBOX" grep -v "^$repo_url\$" "$OPM_REPOS_FILE" > "$OPM_REPOS_FILE.tmp"
                "$BUSYBOX" mv "$OPM_REPOS_FILE.tmp" "$OPM_REPOS_FILE"
                success_msg "Repository removed"
            else
                warning_msg "Repository not found"
            fi
            ;;
    esac
}

list_repos() {
    print_header
    header_msg "Configured repositories:"
    header_msg "------------------------"
    "$BUSYBOX" cat "$OPM_REPOS_FILE"
}

add_repo() {
    manage_repo "add" "$1"
}

remove_repo() {
    manage_repo "remove" "$1"
}

normalize_size() {
    local size=$1
    local unit="B"
    local normalized_size=$size
    
    if [ $normalized_size -ge 1073741824 ]; then
        normalized_size=$((normalized_size / 1073741824))
        unit="GB"
    elif [ $normalized_size -ge 1048576 ]; then
        normalized_size=$((normalized_size / 1048576))
        unit="MB"
    elif [ $normalized_size -ge 1024 ]; then
        normalized_size=$((normalized_size / 1024))
        unit="KB"
    fi
    
    echo "$normalized_size $unit"
}

# Function to fetch package info from repository
fetch_package_info() {
    local package="$1"
    local repo_url="$2"
    local output_file="$3"
    
    if safe_download "$repo_url/getinfo?package=$package" "$output_file" 1; then
        # Check if file contains valid data
        if "$BUSYBOX" grep -q "^-- OPM PACKAGE BEGIN --" "$output_file"; then
            return 0
        fi
    fi
    
    return 1
}

download_package() {
    local package="$1"
    local repo_url="$2"
    local version="$3"
    local arch="$4"
    local output_file="$5"
    
    local download_url="${repo_url}/download?package=${package}&ver=${version}&arch=${arch}"
    info_msg "Downloading ${package}..."
    
    if ! "$BUSYBOX" wget -O "$output_file" "$download_url"; then
        error_msg "Failed to download package"
        return 1
    fi
    
    return 0
}

parse_opm_file() {
    OPM_FILE="$1"
    OPM_PACKAGE_NAME=""
    OPM_PACKAGE_DISPLAY=""
    OPM_PACKAGE_VER=""
    OPM_PACKAGE_DESC=""
    OPM_ADD_TO_PATH=""
    OPM_PACKAGE_DEPS=""
    OPM_PACKAGE_SIZE=""
    OPM_PACKAGE_EXT=""
    OPM_PACKAGE_TYPE=""
    OPM_PACKAGE_BUILTFOR=""
    OPM_PACKAGE_INTERPRETER=""
    OPM_PACKAGE_HOMEPAGE=""
    OPM_PACKAGE_REPO=""

    # Check if this is a new format file
    if "$BUSYBOX" grep -q "^-- OPM PACKAGE BEGIN --" "$OPM_FILE"; then
        # Process new format
        IN_PACKAGE=0
        CURRENT_KEY=""
        PARSING_LIST=0
        LIST_VALUE=""
        
        while IFS= read -r line; do
            line=$(echo "$line" | "$BUSYBOX" sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Skip empty lines and comments
            [ -z "$line" ] && continue
            [ "${line:0:1}" = "#" ] && continue
            
            if [ "$line" = "-- OPM PACKAGE BEGIN --" ]; then
                IN_PACKAGE=1
                continue
            fi
            
            if [ $IN_PACKAGE -eq 1 ]; then
                # Check if this line defines a new key
                if echo "$line" | "$BUSYBOX" grep -q "^[a-zA-Z0-9_]\+:"; then
                    CURRENT_KEY=$(echo "$line" | "$BUSYBOX" cut -d':' -f1)
                    VALUE=$(echo "$line" | "$BUSYBOX" cut -d':' -f2- | "$BUSYBOX" sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    
                    # Handle lists (starting with -)
                    if [ "${VALUE:0:1}" = "-" ]; then
                        PARSING_LIST=1
                        LIST_VALUE="$(echo "$VALUE" | "$BUSYBOX" sed 's/^[[:space:]]*-[[:space:]]*//')"
                    else
                        PARSING_LIST=0
                        
                        # Handle different keys
                        case "$CURRENT_KEY" in
                            packagename)
                                OPM_PACKAGE_NAME=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            displayname)
                                OPM_PACKAGE_DISPLAY=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            description)
                                OPM_PACKAGE_DESC=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            path)
                                OPM_ADD_TO_PATH=$(echo "$VALUE" | "$BUSYBOX" tr -d '",' | "$BUSYBOX" tr ' ' ',')
                                ;;
                            depends)
                                OPM_PACKAGE_DEPS=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            archivetype)
                                OPM_PACKAGE_EXT=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            type)
                                OPM_PACKAGE_TYPE=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            builtfor)
                                OPM_PACKAGE_BUILTFOR=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            interpreter)
                                OPM_PACKAGE_INTERPRETER=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            version)
                                OPM_PACKAGE_VER=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            filesize)
                                OPM_PACKAGE_SIZE=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                            repo)
                                OPM_PACKAGE_REPO=$(echo "$VALUE" | "$BUSYBOX" tr -d '"')
                                ;;
                        esac
                    fi
                elif [ $PARSING_LIST -eq 1 ] && [ "${line:0:1}" = "-" ]; then
                    # Handle list items
                    ITEM=$(echo "$line" | "$BUSYBOX" sed 's/^[[:space:]]*-[[:space:]]*//')
                    
                    case "$CURRENT_KEY" in
                        homepage)
                            if [ -z "$OPM_PACKAGE_HOMEPAGE" ]; then
                                OPM_PACKAGE_HOMEPAGE="$ITEM"
                            else
                                OPM_PACKAGE_HOMEPAGE="$OPM_PACKAGE_HOMEPAGE $ITEM"
                            fi
                            ;;
                    esac
                else
                    # This is a continuation of the previous key value
                    case "$CURRENT_KEY" in
                        description)
                            OPM_PACKAGE_DESC="$OPM_PACKAGE_DESC\\n$line"
                            ;;
                    esac
                fi
            fi
        done < "$OPM_FILE"
    else
        error_msg "Error while parsing package $OPM_FILE"
        return 1
    fi
}

wait_for_job() {
    local pids="$1"
    local completed=0
    
    while [ $completed -eq 0 ]; do
        for pid in $pids; do
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid"
                completed=1
                break
            fi
        done
        [ $completed -eq 0 ] && sleep 1
    done
}

verify_package() {
    local package=$1
    local version=$2
    local expected_name=$3
    
    [ "$package" = "$expected_name" ] || { error_msg "Error: Package name mismatch in metadata"; return 1; }
    [ -n "$version" ] || { error_msg "Error: Missing package version"; return 1; }
    
    return 0
}

setup_executables() {
    local package="$1"
    
    # For each binary in OPM_ADD_TO_PATH
    for binary in $OPM_ADD_TO_PATH; do
        if [ "$OPM_PACKAGE_TYPE" = "script" ] && [ -n "$OPM_PACKAGE_INTERPRETER" ]; then
            # Create a wrapper script
            local wrapper="$OPM_BIN/$binary"
            echo "#!/bin/sh" > "$wrapper"
            
            # Replace template variables
            local interpreter="$OPM_PACKAGE_INTERPRETER"
            interpreter=$(echo "$interpreter" | "$BUSYBOX" sed "s|{{OPM_BIN_DIR}}|$OPM_BIN|g")
            
            echo "exec $interpreter \"$OPM_DATA/$package/$binary\" \"\$@\"" >> "$wrapper"
            "$BUSYBOX" chmod 755 "$wrapper"
        else
            # Regular binary, just symlink
            "$BUSYBOX" ln -sf "$OPM_DATA/$package/$binary" "$OPM_BIN/"
        fi
    done
}

extract_package() {
    local package=$1
    local ext=$2
    local archive_path=$3
    local target_dir="$OPM_DATA/$package"
    
    "$BUSYBOX" mkdir -p "$target_dir"
    info_msg "Extracting package..."
    
    # Capture error output
    local error_output
    case "$ext" in
        "tar")     error_output=$("$BUSYBOX" tar -xf "$archive_path" -C "$target_dir/" 2>&1) ;;
        "zip")     error_output=$("$BUSYBOX" unzip -o "$archive_path" -d "$target_dir/" 2>&1) ;;
        "tar.gz")  error_output=$("$BUSYBOX" tar -xzf "$archive_path" -C "$target_dir/" 2>&1) ;;
        "gz")      error_output=$("$BUSYBOX" gunzip -c "$archive_path" > "$target_dir/" 2>&1) ;;
        "xz")      error_output=$("$BUSYBOX" xz -d "$archive_path" -c > "$target_dir/" 2>&1) ;;
        *)         error_msg "Error: Unsupported package format: $ext"; return 1 ;;
    esac
    
    if [ $? -ne 0 ]; then
        error_msg "Failed to extract package: ${package}"
        [ $DEBUG -eq 1 ] && debug_msg "Extraction error: $error_output"
        return 1
    fi
    
    return 0
}

check_dependencies() {
    for dep in $OPM_PACKAGE_DEPS; do
        [ "$dep" = "core" ] && continue
        
        if ! is_package_installed "$dep"; then
            warning_msg "Dependency $dep is not installed"
            
            if confirm_action "Install dependency $dep now?"; then
                PKG_BAK=$PACKAGE
                EXT_BAK=$OPM_PACKAGE_EXT
                install_package "$dep" || return 1
                PACKAGE=$PKG_BAK
                OPM_PACKAGE_EXT=$EXT_BAK
                parse_opm_file "$OPM_DATA/$PACKAGE.opm"
            else
                error_msg "Cannot proceed without installing dependencies"
                return 1
            fi
        fi
    done
    return 0
}

install_package() {
    local pkg_arg="$1"
    local parsed_arg=$(parse_package_arg "$pkg_arg")
    local package=$(echo "$parsed_arg" | "$BUSYBOX" cut -d "|" -f 1)
    local requested_version=$(echo "$parsed_arg" | "$BUSYBOX" cut -d "|" -f 2)
    local temp_file="$OPM_TMP/packages_temp_$$"
    local system_arch=$(get_architecture)
    
    # Validate parameter
    validate_param "$package" "Package name required" || return 1
    
    # Check if package exists in repositories
    debug_print "Looking for package $package..."
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        if safe_download "$repo_url/listpackages" "$temp_file" 1; then
            if "$BUSYBOX" grep -q "^$package|" "$temp_file"; then
                debug_print "Found package $package in $repo_url"
                
                # Get package info
                local info_file="$OPM_TMP/${package}_info_$$"
                if fetch_package_info "$package" "$repo_url" "$info_file"; then
                    # Parse package info
                    parse_opm_file "$info_file"
                    
                    # Verify the package
                    if ! verify_package "$OPM_PACKAGE_NAME" "$OPM_PACKAGE_VER" "$package"; then
                        "$BUSYBOX" rm -f "$temp_file" "$info_file"
                        return 1
                    fi
                    
                    # Check if binary packages are compatible with system architecture
                    if [ "$OPM_PACKAGE_TYPE" = "binary" ] && [ "$OPM_PACKAGE_BUILTFOR" != "$system_arch" ]; then
                        warning_msg "Warning: Package architecture ($OPM_PACKAGE_BUILTFOR) different from system architecture ($system_arch)"
                        if ! confirm_action "Continue with installation anyway?"; then
                            "$BUSYBOX" rm -f "$temp_file" "$info_file"
                            return 1
                        fi
                    fi
                    
                    # Show package info
                    printf "\n"
                    info_msg "Installing $package version $OPM_PACKAGE_VER"
                    printf "\n"

                    # Show size info if available
                    if [ -n "$OPM_PACKAGE_SIZE" ]; then
                        local human_size=$(normalize_size "$OPM_PACKAGE_SIZE")
                        debug_print "Package size: $human_size"
                        [ "$OPM_PACKAGE_SIZE" -gt "$ONE_GB" ] && warning_msg "Warning: Large package size: $human_size"
                    fi
                    
                    # Download package data with new endpoint
                    local download_path="$OPM_DATA/${package}.${OPM_PACKAGE_EXT}"
                    if ! download_package "$package" "$repo_url" "$requested_version" "$system_arch" "$download_path"; then
                        handle_error "Failed to download package data" "$temp_file $info_file"
                        return 1
                    fi
                    
                    # Save package metadata
                    "$BUSYBOX" cp "$info_file" "$OPM_DATA/${package}.opm"
                    
                    # Handle dependencies and extract
                    check_dependencies || {
                        "$BUSYBOX" rm -f "$temp_file" "$info_file" "$download_path"
                        return 1
                    }
                    
                    extract_package "$package" "$OPM_PACKAGE_EXT" "$download_path" || {
                        "$BUSYBOX" rm -f "$temp_file" "$info_file" "$download_path"
                        return 1
                    }
                    
                    # Set permissions
                    "$BUSYBOX" chmod -R 755 "$OPM_DATA/$package"
                    
                    # Set up executables (symlinks or wrapper scripts)
                    setup_executables "$package"
                    
                    # Run post-installation script
                    postinstall_package "$package"
                    
                    # Clean up download if extraction succeeded
                    "$BUSYBOX" rm -f "$download_path" "$temp_file" "$info_file"
                    
                    success_msg "Package $package installed successfully"
                    return 0
                else
                    error_msg "Failed to get package info from $repo_url"
                fi
            fi
        fi
    done < "$OPM_REPOS_FILE"
    
    handle_error "Package $package not found in any repository" "$temp_file"
    return 1
}

install_packages() {
    local packages="$*"
    local tmp_dir="$OPM_TMP/install_$$"
    "$BUSYBOX" mkdir -p "$tmp_dir"
    local failed=0

    if [ "$PARALLEL_INSTALL" -eq 1 ]; then
        local running=0
        local job_slots=$MAX_PARALLEL_JOBS
        local job_pids=""

        for package in $packages; do
            # Start installation in background
            (install_package "$package" > "$tmp_dir/$package.log" 2>&1; 
             echo $? > "$tmp_dir/$package.exit") &
            
            job_pids="$job_pids $!"
            running=$((running + 1))

            # Wait if we've reached max parallel jobs
            if [ $running -ge $job_slots ]; then
                wait_for_job "$job_pids"
                running=$((running - 1))
            fi
        done

        # Wait for remaining jobs
        for pid in $job_pids; do
            wait $pid
        done

        # Check results
        for package in $packages; do
            "$BUSYBOX" cat "$tmp_dir/$package.log"
            if [ "$(cat $tmp_dir/$package.exit)" != "0" ]; then
                failed=1
            fi
        done
    else
        # Sequential installation
        for package in $packages; do
            if ! install_package "$package"; then
                failed=1
            fi
        done
    fi

    "$BUSYBOX" rm -rf "$tmp_dir"
    return $failed
}

remove_package() {
    local package="$1"

    if [ -d "$OPM_DATA/$package" ]; then
        parse_opm_file "$OPM_DATA/$package.opm"

        # Remove binaries based on package type
        for binary in $OPM_ADD_TO_PATH; do
            if [ "$OPM_PACKAGE_TYPE" = "script" ] && [ -n "$OPM_PACKAGE_INTERPRETER" ]; then
                # Remove wrapper script
                "$BUSYBOX" rm -f "$OPM_BIN/$binary"
            else
                # Remove symlink
                "$BUSYBOX" rm -f "$OPM_BIN/$binary"
            fi
        done

        # Remove package data and metadata
        "$BUSYBOX" rm -rf "$OPM_DATA/$package" "$OPM_DATA/$package.opm"
        
        success_msg "Package $package removed successfully"
    else
        warning_msg "Package $package is not installed"
    fi
}

reinstall_packages() {
    local packages="$*"
    for package in $packages; do
        info_msg "Upgrading package: $package"
        reinstall_package "$package"
    done
}

reinstall_package() {
    local package="$1"
    remove_package "$package"
    install_package "$package"
}

show_package() {
    local package="$1"
    local tmp_file="$OPM_TMP/packages.json"
    local found=0
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        if safe_download "$repo_url/listpackages" "$tmp_file" 1; then
            if "$BUSYBOX" grep -q "^$package|" "$tmp_file"; then
                found=1
                
                # Get package info
                local info_file="$OPM_TMP/${package}_info_$$"
                if fetch_package_info "$package" "$repo_url" "$info_file"; then
                    # Parse package info
                    parse_opm_file "$info_file"
                    
                    local repo_version="$OPM_PACKAGE_VER"
                    local installed_version=""
                    
                    if [ -f "$OPM_DATA/$package.opm" ]; then
                        info_msg "Package: $package (installed)"
                        parse_opm_file "$OPM_DATA/$package.opm"
                        installed_version="$OPM_PACKAGE_VER"
                        
                        # Compare versions
                        if [ "$installed_version" != "$repo_version" ]; then
                            info_msg "Version: $installed_version (Update available: $repo_version)"
                        else
                            info_msg "Version: $installed_version (latest)"
                        fi
                    else
                        info_msg "Package: $package (not installed)"
                        info_msg "Version: $repo_version"
                    fi
                    
                    # Additional details
                    [ -n "$OPM_PACKAGE_DISPLAY" ] && info_msg "Display Name: $OPM_PACKAGE_DISPLAY"
                    [ -n "$OPM_PACKAGE_TYPE" ] && info_msg "Type: $OPM_PACKAGE_TYPE"
                    [ -n "$OPM_PACKAGE_BUILTFOR" ] && info_msg "Architecture: $OPM_PACKAGE_BUILTFOR"
                    [ -n "$OPM_PACKAGE_DESC" ] && info_msg "Description: $OPM_PACKAGE_DESC"
                    
                    if [ -n "$OPM_PACKAGE_DEPS" ]; then
                        info_msg "Dependencies: $OPM_PACKAGE_DEPS"
                    else
                        info_msg "No dependencies"
                    fi
                    
                    [ -n "$OPM_PACKAGE_SIZE" ] && info_msg "Archive Size: $(normalize_size $OPM_PACKAGE_SIZE)"
                    [ -n "$OPM_PACKAGE_EXT" ] && info_msg "Archive Type: $OPM_PACKAGE_EXT"
                    [ -n "$OPM_PACKAGE_HOMEPAGE" ] && info_msg "Homepage: $OPM_PACKAGE_HOMEPAGE"
                    [ -n "$OPM_PACKAGE_REPO" ] && info_msg "Repository: $OPM_PACKAGE_REPO"
                    
                    "$BUSYBOX" rm -f "$info_file"
                    break
                fi
            fi
        fi
    done < "$OPM_REPOS_FILE"

    # Clean up temporary file
    "$BUSYBOX" rm -f "$tmp_file"
    
    [ $found -eq 0 ] && warning_msg "Package $package not found in any repository"
}

check_for_updates() {
    local quiet=${1:-0}
    local updatable_packages=""
    
    "$BUSYBOX" mkdir -p "$OPM_UPDATE_CACHE"
    
    # Record this check time
    record_update_check_time
    
    local cache_file="$OPM_UPDATE_CACHE/packages.list"
    local now=$("$BUSYBOX" date +%s)
    local cache_time=0
    local force_refresh=0
    
    # Check if cache file exists and is recent
    if [ -f "$cache_file" ]; then
        cache_time=$("$BUSYBOX" stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        local cache_age=$((now - cache_time))
        
        if [ $cache_age -gt $UPDATE_CACHE_EXPIRY ]; then
            force_refresh=1
        fi
    else
        force_refresh=1
    fi
    
    # Refresh the cache if needed
    if [ $force_refresh -eq 1 ]; then
        debug_print "Refreshing package list cache..."
        
        # Clear old cache file
        "$BUSYBOX" rm -f "$cache_file"
        
        # Get package listings from all repositories
        while IFS= read -r repo_url; do
            [ -z "$repo_url" ] && continue
            
            local repo_list="$OPM_UPDATE_CACHE/repo_${now}.list"
            if safe_download "$repo_url/listpackages" "$repo_list" 1; then
                # Add to cache file
                "$BUSYBOX" cat "$repo_list" >> "$cache_file"
                "$BUSYBOX" rm -f "$repo_list"
            fi
        done < "$OPM_REPOS_FILE"
    else
        debug_print "Using package cache (age: $(((now - cache_time) / 60)) minutes)"
    fi
    
    # Get list of installed packages
    local updates_available=0
    
    # Check if any .opm files exist before trying to process them
    if [ -n "$("$BUSYBOX" find "$OPM_DATA" -name "*.opm" 2>/dev/null)" ]; then
        local installed_packages=$("$BUSYBOX" find "$OPM_DATA" -name "*.opm" | "$BUSYBOX" xargs -n1 basename | "$BUSYBOX" sed 's/\.opm$//')
        
        [ $quiet -eq 0 ] && info_msg "Checking for updates..."
        debug_print "-----------------------"
        
        for package in $installed_packages; do
            # Parse installed package info
            parse_opm_file "$OPM_DATA/$package.opm"
            local installed_version="$OPM_PACKAGE_VER"
            
            # Look for latest version in cache
            local latest_version=""
            if "$BUSYBOX" grep -q "^$package|" "$cache_file"; then
                # Get all versions
                local versions=$("$BUSYBOX" grep "^$package|" "$cache_file" | "$BUSYBOX" cut -d'|' -f2)
                
                # Find the "largest" version (this is a simplistic approach)
                for ver in $versions; do
                    if [ -z "$latest_version" ] || [ "$ver" \> "$latest_version" ]; then
                        latest_version="$ver"
                    fi
                done
                
                # Compare versions
                if [ "$installed_version" != "$latest_version" ]; then
                    [ $quiet -eq 0 ] && info_msg "$package: update available ($installed_version → $latest_version)"
                    updates_available=$((updates_available + 1))
                    updatable_packages="$updatable_packages $package"
                else
                    debug_print "$package: up to date ($installed_version)"
                fi
            else
                [ $quiet -eq 0 ] && warning_msg "$package: unknown status (not found in repositories)"
            fi
        done
        
        debug_print "-----------------------"
        if [ $quiet -eq 0 ]; then
            if [ $updates_available -eq 0 ]; then
                success_msg "All packages are up to date."
            else
                warning_msg "$updates_available package(s) can be updated."
                info_msg "Run 'opm upgrade$updatable_packages' to update these packages."
            fi
        fi
    else
        [ $quiet -eq 0 ] && info_msg "No packages installed."
    fi
    
    # Return the updatable packages list
    echo "$updatable_packages" | "$BUSYBOX" sed 's/^ *//'
}

postinstall_package() {
    local package="$1"
    local script="$OPM_DATA/$package/postinstall.sh"

    if [ -f "$script" ]; then
        debug_print "Running post-installation script for $package..."
        PKGDIR="$OPM_DATA/$package" CONFDIR="$OPM_CONFS/$package" "$BUSYBOX" ash "$script"
        debug_print "Post-installation completed"
    else
        debug_print "No post-installation script found for $package"
    fi
}

list_packages() {
    print_header
    header_msg "Available packages:"
    header_msg "------------------------------------"
    header_msg "Name | Version | Type | Architecture | Display Name"
    header_msg "------------------------------------"
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        header_msg "From repository: $repo_url"
        header_msg "------------------------------------"
        
        packages_info=$("$BUSYBOX" wget -qO - "$repo_url/listpackages")
        if [ $? -ne 0 ]; then
            error_msg "Failed to fetch packages from $repo_url"
            continue
        fi
        
        echo "$packages_info" | while IFS='|' read -r name version; do
            [ -z "$name" ] && continue
            
            # Try to get more info about the package
            local info_file="$OPM_TMP/${name}_info_$$"
            if fetch_package_info "$name" "$repo_url" "$info_file"; then
                parse_opm_file "$info_file"
                
                local type="${OPM_PACKAGE_TYPE:-unknown}"
                local arch="${OPM_PACKAGE_BUILTFOR:-unknown}"
                local displayname="${OPM_PACKAGE_DISPLAY:-$name}"
                local size=""
                
                if [ -n "$OPM_PACKAGE_SIZE" ]; then
                    size=" ($(normalize_size $OPM_PACKAGE_SIZE))"
                fi
                
                plain_msg "$name | $version | $type | $arch | $displayname$size"
                "$BUSYBOX" rm -f "$info_file"
            else
                # Minimal info if we can't get details
                plain_msg "$name | $version | unknown | unknown | $name"
            fi
        done
        header_msg "------------------------------------"
        printf "\n"
    done < "$OPM_REPOS_FILE"
}

search_packages() {
    local query="$1"
    print_header
    header_msg "Search results for '$query':"
    header_msg "----------------------------"
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        local tmp_file="$OPM_TMP/search_$$_$(echo "$repo_url" | "$BUSYBOX" md5sum | "$BUSYBOX" cut -d' ' -f1)"
        if safe_download "$repo_url/listpackages" "$tmp_file" 1; then
            local matches=$("$BUSYBOX" grep -i "$query" "$tmp_file" || echo "")
            
            if [ -n "$matches" ]; then
                header_msg "From $repo_url:"
                echo "$matches" | while IFS='|' read -r name version; do
                    [ -z "$name" ] && continue
                    
                    # Try to get more info about the package
                    local info_file="$OPM_TMP/${name}_info_$$"
                    if fetch_package_info "$name" "$repo_url" "$info_file"; then
                        parse_opm_file "$info_file"
                        
                        local type="${OPM_PACKAGE_TYPE:-unknown}"
                        local arch="${OPM_PACKAGE_BUILTFOR:-unknown}"
                        local desc="${OPM_PACKAGE_DESC:-No description}"
                        
                        info_msg "- $name ($version) [$type/$arch]: $desc"
                        "$BUSYBOX" rm -f "$info_file"
                    else
                        # Minimal info if we can't get details
                        info_msg "- $name ($version)"
                    fi
                done
                printf "\n"
            fi
            "$BUSYBOX" rm -f "$tmp_file"
        fi
    done < "$OPM_REPOS_FILE"
}

update() {
    "$BUSYBOX" rm -f "$OPM_ROOT/opm.sh"
    debug_print "Downloading updater script..."
    
    "$BUSYBOX" wget -qO "$OPM_TMP/opminstall.sh" "https://opm.oddbyte.dev/opminstall.sh" || {
        error_msg "Failed to download updater script";
        return 1;
    }

    "$BUSYBOX" chmod 755 "$OPM_TMP/opminstall.sh"
    "$OPM_TMP/opminstall.sh" --update
    
    "$BUSYBOX" rm -f "$OPM_TMP/opminstall.sh"
    success_msg "OPM has been successfully updated"
    exit 0
}

start_service() {
    local package="$1"
    local service="$OPM_DATA/$package/service.sh"
    
    if [ -f "$service" ]; then
        info_msg "Starting service: $service"
        CONFDIR="$OPM_CONFS/$package" PKGDIR="$OPM_DATA/$package" "$BUSYBOX" ash "$service" || 
            error_msg "Error starting service $service"
    else
        warning_msg "No service script found for $package"
    fi
}

run_diagnostics() {
    header_msg "=== OPM Diagnostics Report ==="
    info_msg "Generated: $("$BUSYBOX" date)"
    printf "\n"

    # System information
    header_msg "=== System Information ==="
    info_msg "Hostname: $("$BUSYBOX" hostname)"
    info_msg "Kernel: $("$BUSYBOX" uname -a)"
    info_msg "Architecture: $(get_architecture)"
    [ -f /etc/os-release ] && info_msg "OS: $("$BUSYBOX" cat /etc/os-release | "$BUSYBOX" grep "PRETTY_NAME" | "$BUSYBOX" cut -d= -f2 | "$BUSYBOX" tr -d '"')"
    info_msg "CPU: $("$BUSYBOX" grep "model name" /proc/cpuinfo | "$BUSYBOX" head -1 | "$BUSYBOX" cut -d: -f2 | "$BUSYBOX" sed 's/^[ \t]*//')"
    info_msg "Available memory: $("$BUSYBOX" free -h | "$BUSYBOX" grep Mem | "$BUSYBOX" awk '{print $2}')"
    info_msg "Disk usage: $("$BUSYBOX" df -h / | "$BUSYBOX" tail -1 | "$BUSYBOX" awk '{print $5}')"
    printf "\n"

    # OPM environment
    header_msg "=== OPM Environment ==="
    info_msg "OPM_ROOT: $OPM_ROOT"
    info_msg "OPM_BIN: $OPM_BIN"
    info_msg "OPM_DATA: $OPM_DATA"
    info_msg "OPM_REPOS_FILE: $OPM_REPOS_FILE"
    info_msg "BUSYBOX: $BUSYBOX"
    printf "\n"

    # BusyBox information
    header_msg "=== BusyBox Information ==="
    if [ -x "$BUSYBOX" ]; then
        info_msg "BusyBox location: $BUSYBOX"
        info_msg "BusyBox version: $("$BUSYBOX" --help | "$BUSYBOX" head -n 1)"
        info_msg "BusyBox applets: $("$BUSYBOX" --list | "$BUSYBOX" wc -l)"
        info_msg "BusyBox size: $("$BUSYBOX" ls -lh "$BUSYBOX" | "$BUSYBOX" awk '{print $5}')"
    else
        error_msg "ERROR: BusyBox not found or not executable"
    fi
    printf "\n"

    # Directory structure
    header_msg "=== Directory Structure ==="
    for dir in "$OPM_ROOT" "$OPM_BIN" "$OPM_DATA" "$OPM_TMP" "$OPM_CONFS"; do
        if [ -d "$dir" ]; then
            success_msg "✓ $dir ($(du -sh "$dir" 2>/dev/null | cut -f1))"
            "$BUSYBOX" ls -la "$dir" | "$BUSYBOX" head -n 10
            [ "$("$BUSYBOX" ls -la "$dir" | "$BUSYBOX" wc -l)" -gt 11 ] && plain_msg "   ... and more files"
        else
            error_msg "✗ $dir (missing)"
        fi
        printf "\n"
    done

    # Repository check
    header_msg "=== Repository Status ==="
    if [ -f "$OPM_REPOS_FILE" ]; then
        info_msg "Repositories configured: $("$BUSYBOX" wc -l < "$OPM_REPOS_FILE")"
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            info_msg "Testing: $repo"
            if "$BUSYBOX" timeout 5 wget -q --spider "$repo" 2>/dev/null; then
                success_msg "  ✓ Repository accessible"
                
                if "$BUSYBOX" timeout 5 wget -q --spider "$repo/listpackages" 2>/dev/null; then
                    pkg_count=$("$BUSYBOX" wget -qO - "$repo/listpackages" 2>/dev/null | "$BUSYBOX" wc -l)
                    success_msg "  ✓ Package list available ($pkg_count packages)"
                    success_msg "  ✓ First 3 packages:"
                    "$BUSYBOX" wget -qO - "$repo/listpackages" 2>/dev/null | "$BUSYBOX" head -3
                else
                    error_msg "  ✗ Package list not accessible"
                fi
            else
                error_msg "  ✗ Repository not accessible"
            fi
            printf "\n"
        done < "$OPM_REPOS_FILE"
    else
        error_msg "✗ Repository file missing"
    fi
    printf "\n"

    # Installed packages
    header_msg "=== Installed Packages ==="
    pkg_count=$(ls -1 "$OPM_DATA"/*.opm 2>/dev/null | wc -l)
    if [ "$pkg_count" -gt 0 ]; then
        info_msg "Found $pkg_count installed packages:"
        for pkg_file in "$OPM_DATA"/*.opm; do
            [ -f "$pkg_file" ] || continue
            pkg_name=$(basename "$pkg_file" .opm)
            parse_opm_file "$pkg_file"
            info_msg "- $OPM_PACKAGE_NAME (v$OPM_PACKAGE_VER)"
            info_msg "  Type: ${OPM_PACKAGE_TYPE:-binary}"
            info_msg "  Architecture: ${OPM_PACKAGE_BUILTFOR:-unknown}"
            info_msg "  Description: $OPM_PACKAGE_DESC"
            info_msg "  Size: $(du -sh "$OPM_DATA/$OPM_PACKAGE_NAME" 2>/dev/null | cut -f1)"
            info_msg "  Binaries: $OPM_ADD_TO_PATH"
            printf "\n"
        done
    else
        warning_msg "No packages installed"
    fi
    printf "\n"

    # Update cache
    header_msg "=== Update Cache ==="
    if [ -d "$OPM_UPDATE_CACHE" ]; then
        info_msg "Update cache directory: $OPM_UPDATE_CACHE"
        if [ -f "$OPM_UPDATE_CACHE/packages.list" ]; then
            cache_time=$("$BUSYBOX" stat -c %Y "$OPM_UPDATE_CACHE/packages.list" 2>/dev/null || echo 0)
            now=$("$BUSYBOX" date +%s)
            cache_age=$((now - cache_time))
            info_msg "Cache last updated: $(($cache_age / 60)) minutes ago"
            info_msg "Cache entries: $("$BUSYBOX" wc -l < "$OPM_UPDATE_CACHE/packages.list") packages"
        else
            warning_msg "No update cache file found"
        fi
    else
        warning_msg "Update cache directory not found"
    fi
    printf "\n"

    # Symbolic links
    header_msg "=== Symbolic Links Check ==="
    bin_count=$(ls -1 "$OPM_BIN" 2>/dev/null | wc -l)
    info_msg "Found $bin_count items in $OPM_BIN"
    for item in "$OPM_BIN"/*; do
        [ -e "$item" ] || continue
        [ "$item" = "$OPM_BIN/busybox" ] && continue
        
        if [ -L "$item" ]; then
            target=$("$BUSYBOX" readlink "$item")
            if [ -e "$target" ]; then
                success_msg "✓ $(basename "$item") -> $target"
            else
                error_msg "✗ $(basename "$item") -> $target (broken link)"
            fi
        else
            warning_msg "! $(basename "$item") (not a symlink)"
        fi
    done
    printf "\n"

    # PATH environment variable
    header_msg "=== PATH Environment Variable ==="
    echo "$PATH" | "$BUSYBOX" tr ':' '\n'
    printf "\n"

    # Profile check
    header_msg "=== Profile Configuration ==="
    if [ -f ~/.profile ]; then
        if "$BUSYBOX" grep -q "$OPM_ROOT/env.sh" ~/.profile; then
            success_msg "✓ OPM environment sourced in ~/.profile"
        else
            error_msg "✗ OPM environment not sourced in ~/.profile"
        fi
    else
        error_msg "✗ ~/.profile does not exist"
    fi
    
    # Check other common profile files
    for profile in ~/.bash_profile ~/.bashrc ~/.zshrc; do
        if [ -f "$profile" ] && "$BUSYBOX" grep -q "$OPM_ROOT/env.sh" "$profile"; then
            success_msg "✓ OPM environment also sourced in $profile"
        fi
    done
    printf "\n"

    header_msg "=== End of Diagnostics Report ==="
}

is_opm_running() {
    if [ -f "$OPM_PID_FILE" ]; then
        other_pid=$("$BUSYBOX" cat "$OPM_PID_FILE")
        if "$BUSYBOX" kill -0 "$other_pid" 2>/dev/null; then
            return 0
        else
            "$BUSYBOX" rm "$OPM_PID_FILE"
            warning_msg "WARNING: Previous OPM instance crashed. Please report this!"
            return 1
        fi
    fi
    return 1
}

handle_existing_process() {
    warning_msg "Warning: Another process is already running with PID $other_pid"
    plain_msg "Options:"
    plain_msg "1) Kill the existing process (may cause data corruption)"
    plain_msg "2) Wait for existing process to finish"
    
    choice=$(get_numeric_choice "Enter choice (1 or 2): " 1 2)
    
    case "$choice" in
        1)
            info_msg "Killing process $other_pid..."
            "$BUSYBOX" kill -9 "$other_pid"
            "$BUSYBOX" rm -f "$OPM_PID_FILE"
            ;;
        2)
            info_msg "Waiting for process $other_pid to finish..."
            while "$BUSYBOX" kill -0 "$other_pid" 2>/dev/null; do
                "$BUSYBOX" sleep 1
            done
            success_msg "Process $other_pid has finished"
            ;;
    esac
}

auto_check_updates() {
    if should_check_updates; then
        info_msg "Performing weekly update check..."
        updatable_packages=$(check_for_updates 1)
        if [ -n "$updatable_packages" ]; then
            warning_msg "Updates available for:$updatable_packages"
            info_msg "Run 'opm upgrade$updatable_packages' to update."
        fi
    fi
}

execute_command() {
    command="$1"
    shift
    
    # Parse global flags
    local args=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)
                AUTO_YES=1
                shift
                ;;
            -j|--jobs)
                PARALLEL_INSTALL=1
                shift
                if [ $# -gt 0 ] && [ "$1" -gt 0 ] 2>/dev/null; then
                    MAX_PARALLEL_JOBS=$1
                    shift
                fi
                ;;
            -p|--parallel)
                PARALLEL_INSTALL=1
                shift
                ;;
            --debug)
                DEBUG=1
                shift
                ;;
            --nocolor)
                NO_COLOR=1
                shift
                ;;
            *)
                args="$args $1"
                shift
                ;;
        esac
    done

    # Create a PID file to prevent concurrent instances
    echo $$ > "$OPM_PID_FILE"
    trap 'rm -f "$OPM_PID_FILE"' EXIT INT TERM

    case "$command" in
        ""|help)
            usage
            ;;
        install|add|i)
            [ -z "$args" ] && { error_msg "Error: Please specify packages to install"; return 1; }
            install_packages $args
            ;;
        doctor|diagnose)
            run_diagnostics
            ;;
        remove|uninstall|delete|rm)
            [ -z "$args" ] && { error_msg "Error: Please specify a package to remove"; return 1; }
            remove_package $args
            ;;
        repos)
            list_repos
            ;;
        addrepo)
            [ -z "$args" ] && { error_msg "Error: Please specify a repository URL"; return 1; }
            add_repo $args
            ;;
        rmrepo)
            [ -z "$args" ] && { error_msg "Error: Please specify a repository URL"; return 1; }
            remove_repo $args
            ;;
        list)
            list_packages
            ;;
        update)
            update
            ;;
        upgradecheck)
            check_for_updates
            ;;
        search)
            [ -z "$args" ] && { error_msg "Error: Please specify a search query"; return 1; }
            search_packages $args
            ;;
        reinstall)
            [ -z "$args" ] && { error_msg "Error: Please specify a package to reinstall"; return 1; }
            reinstall_packages $args
            ;;
        upgrade)
            if [ -z "$args" ]; then
                check_for_updates
            else
                reinstall_packages $args
            fi
            ;;
        info|show)
            [ -z "$args" ] && { error_msg "Error: Please specify a package to show"; return 1; }
            show_package $args
            ;;
        start)
            [ -z "$args" ] && { error_msg "Error: Please specify a package to start"; return 1; }
            start_service $args
            ;;
        postinstall)
            [ -z "$args" ] && { error_msg "Error: Please specify a package for post-installation"; return 1; }
            postinstall_package $args
            ;;
        *)
            error_msg "Unknown command: $command"
            usage
            return 1
            ;;
    esac

    debug_print "Command completed successfully"
}

# Run auto-update check on startup
auto_check_updates

# Main entry point
[ $# -eq 0 ] && execute_command "help" || execute_command "$@"
