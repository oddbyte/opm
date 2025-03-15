#!${BUSYBOX} ash

# OPM - Odd Package Manager

# Error handling
set -e

# Debugging
DEBUG=0
debug_print() {
    if [ $DEBUG -eq 1 ]; then
        echo "$@"
    fi
}

# Check for OPM_ROOT environment variable
[ -z "$OPM_ROOT" ] && { echo "Error: OPM_ROOT not set. Source ~/.profile or $HOME/.opm/env.sh"; exit 1; }
ENV_FILE="$OPM_ROOT/env.sh"

# Source environment file
[ -f "$ENV_FILE" ] || { echo "Error: $ENV_FILE not found"; exit 1; }
. "$ENV_FILE"

# Check for BusyBox
[ -x "$BUSYBOX" ] || { echo "Error: BusyBox not found at $BUSYBOX"; exit 1; }

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
ONE_GB=1073741824

# Create required directories
"$BUSYBOX" mkdir -p "$OPM_CONFS" "$OPM_TMP"

# Function definitions
print_header() {
    echo "====================================="
    echo "          OPM Package Manager        "
    echo "          By Oddbyte                 "
    echo "====================================="
}

usage() {
    print_header
    echo "
Usage:
    opm [command] [options]

Commands:
    help                                Show this help message
    install | add | i                   Install a package
    remove | uninstall | delete | rm    Remove a package
    repos                               List configured repositories
    addrepo [repo_url]                  Add a repository
    rmrepo [repo_url]                   Remove a repository
    list                                List all package names
    search [query]                      Search packages
    reinstall [package]                 Reinstalls the package, deleting all data
    upgrade [package]                   Reinstalls the package, keeps config data
    update                              Update OPM
    show | info [package]               Show info about package
    postinstall [package]               Run post-install script for a package
    start [package]                     Start the package's service
    doctor | diagnose                   Run system diagnostics

Options:
    -y, --yes                           Automatic yes to prompts
    -p, --parallel                      Enable parallel installation
    -j, --jobs [n]                      Set number of parallel jobs (default: 4)
    --debug                             Enable debug messages
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
            echo "Invalid choice. Please enter a number between $min and $max."
        fi
    done
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
        echo "Error: $error_msg"
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
    
    echo "Error: $message"
    [ -n "$temp_file" ] && "$BUSYBOX" rm -f "$temp_file"
    return 1
}

verify_package_in_repos() {
    local package="$1"
    local temp_file="$2"
    local found=0
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        if safe_download "$repo_url/packages.json" "$temp_file" 1; then
            echo "" >> "$temp_file"  # Ensure last line is processed
            
            while IFS='|' read -r name version displayname; do
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
                echo "Repository already exists"
            else
                echo "$repo_url" >> "$OPM_REPOS_FILE"
                echo "Repository added"
            fi
            ;;
        remove)
            if "$BUSYBOX" grep -q "^$repo_url\$" "$OPM_REPOS_FILE"; then
                "$BUSYBOX" grep -v "^$repo_url\$" "$OPM_REPOS_FILE" > "$OPM_REPOS_FILE.tmp"
                "$BUSYBOX" mv "$OPM_REPOS_FILE.tmp" "$OPM_REPOS_FILE"
                echo "Repository removed"
            else
                echo "Repository not found"
            fi
            ;;
    esac
}

list_repos() {
    print_header
    echo "Configured repositories:"
    echo "------------------------"
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

download_package() {
    local package="$1"
    local repo_url="$2"
    local file_path="$3"
    local file_size="$4"
    
    # Initialize a temporary file for wget progress
    local temp_log="$OPM_TMP/${package}_download.log"
    
    # Start wget in background with progress to log file
    "$BUSYBOX" wget -q --show-progress -O "$file_path" "$repo_url" 2>"$temp_log" &
    local wget_pid=$!
    
    local downloaded=0
    local prev_size=0
    
    while kill -0 $wget_pid 2>/dev/null; do
        if [ -f "$file_path" ]; then
            downloaded=$("$BUSYBOX" stat -c %s "$file_path" 2>/dev/null || echo 0)
            if [ $downloaded -ne $prev_size ]; then
                show_pacman_progress $downloaded $file_size "Downloading $package"
                prev_size=$downloaded
            fi
        fi
        "$BUSYBOX" sleep 0.1
    done
    
    # Show completed progress
    show_pacman_progress $file_size $file_size "Downloaded $package"
    "$BUSYBOX" rm -f "$temp_log"
    
    # Check if download was successful
    wait $wget_pid
    return $?
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

    while IFS= read -r line; do
        case "$line" in
            "# :opm packagename:"*)
                OPM_PACKAGE_NAME=$(echo "$line" | "$BUSYBOX" sed 's/# :opm packagename://;s/^[[:space:]]*//;s/[[:space:]]*$//')
                ;;
            "# :opm packagedisplay:"*)
                OPM_PACKAGE_DISPLAY=$(echo "$line" | "$BUSYBOX" sed 's/# :opm packagedisplay://')
                ;;
            "# :opm packagever:"*)
                OPM_PACKAGE_VER=$(echo "$line" | "$BUSYBOX" sed 's/# :opm packagever://;s/^[[:space:]]*//;s/[[:space:]]*$//')
                ;;
            "# :opm packagedesc:"*)
                OPM_PACKAGE_DESC=$(echo "$line" | "$BUSYBOX" sed 's/# :opm packagedesc://')
                ;;
            "# :opm addtopath:"*)
                ADDTOPATH_STR=$(echo "$line" | "$BUSYBOX" sed 's/# :opm addtopath://')
                OPM_ADD_TO_PATH=$(echo "$ADDTOPATH_STR" | "$BUSYBOX" sed 's/,/ /g')
                ;;
            "# :opm depends:"*)
                DEPENDS_STR=$(echo "$line" | "$BUSYBOX" sed 's/# :opm depends://;s/^[[:space:]]*//;s/[[:space:]]*$//')
                OPM_PACKAGE_DEPS=$(echo "$DEPENDS_STR" | "$BUSYBOX" sed 's/,/ /g')
                ;;
            "# :opm filesize:"*)
                OPM_PACKAGE_SIZE=$(echo "$line" | "$BUSYBOX" sed 's/# :opm filesize://;s/^[[:space:]]*//;s/[[:space:]]*$//')
                ;;
            "# :opm ext:"*)
                OPM_PACKAGE_EXT=$(echo "$line" | "$BUSYBOX" sed 's/# :opm ext://;s/^[[:space:]]*//;s/[[:space:]]*$//')
                ;;
        esac
    done < "$OPM_FILE"
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
    
    [ "$package" = "$expected_name" ] || { echo "Error: Package name mismatch in metadata"; return 1; }
    [ -n "$version" ] || { echo "Error: Missing package version"; return 1; }
    
    return 0
}

extract_package() {
    local package=$1
    local ext=$2
    local target_dir="$OPM_DATA/$package"
    local redirect=""
    
    "$BUSYBOX" mkdir -p "$target_dir"
    
    # Show errors if debug is on
    [ $DEBUG -eq 0 ] && redirect=">/dev/null"
    
    case "$ext" in
        "tar")     eval "$BUSYBOX tar -xf \"$OPM_DATA/$package.$ext\" -C \"$target_dir/\" $redirect" ;;
        "zip")     eval "$BUSYBOX unzip -o \"$OPM_DATA/$package.$ext\" -d \"$target_dir/\" $redirect" ;;
        "tar.gz")  eval "$BUSYBOX tar -xzf \"$OPM_DATA/$package.$ext\" -C \"$target_dir/\" $redirect" ;;
        "gz")      eval "$BUSYBOX gunzip -c \"$OPM_DATA/$package.$ext\" > \"$target_dir/\" $redirect" ;;
        "xz")      eval "$BUSYBOX xz -d \"$OPM_DATA/$package.$ext\" -c > \"$target_dir/\" $redirect" ;;
        *)         echo "Error: Unsupported package format: $ext"; return 1 ;;
    esac
    
    return $?
}

check_dependencies() {
    for dep in $OPM_PACKAGE_DEPS; do
        [ "$dep" = "core" ] && continue
        
        if ! is_package_installed "$dep"; then
            echo "Dependency $dep is not installed"
            
            if confirm_action "Install dependency $dep now?"; then
                PKG_BAK=$PACKAGE
                EXT_BAK=$OPM_PACKAGE_EXT
                install_package "$dep" || return 1
                PACKAGE=$PKG_BAK
                OPM_PACKAGE_EXT=$EXT_BAK
                parse_opm_file "$OPM_DATA/$PACKAGE.opm"
            else
                echo "Cannot proceed without installing dependencies"
                return 1
            fi
        fi
    done
    return 0
}

install_package() {
    local package="$1"
    local temp_file="$OPM_TMP/packages_temp_$$"
    
    # Validate parameter
    validate_param "$package" "Package name required" || return 1
    
    # Check if package exists in repositories
    if ! verify_package_in_repos "$package" "$temp_file"; then
        handle_error "Package $package not found in any repository" "$temp_file"
        return 1
    fi
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        if safe_download "$repo_url/packages.json" "$temp_file" 1; then
            echo "" >> "$temp_file"
            
            while IFS='|' read -r name version displayname; do
                [ -z "$name" ] && continue
                
                if [ "$name" = "$package" ]; then
                    echo "Installing $package version $version ($displayname)..."
                    
                    # Download and verify package metadata
                    local opm_file="$OPM_DATA/$package.opm"
                    if ! safe_download "$repo_url/packages/$package.opm" "$opm_file" 1; then
                        handle_error "Failed to download package metadata" "$temp_file"
                        return 1
                    fi
                    
                    # Parse metadata
                    parse_opm_file "$opm_file"
                    if ! verify_package "$name" "$version" "$package"; then
                        "$BUSYBOX" rm -f "$temp_file"
                        return 1
                    fi
                    
                    local human_size
                    human_size=$(normalize_size "$OPM_PACKAGE_SIZE")
                    [ "$OPM_PACKAGE_SIZE" -gt "$ONE_GB" ] && echo "Warning: Large package size: $human_size"
                    
                    # Download package data
                    local data_file="$OPM_DATA/$package.$OPM_PACKAGE_EXT"
                    if ! safe_download "$repo_url/packagedata/$package.$OPM_PACKAGE_EXT" "$data_file" 1; then
                        handle_error "Failed to download package data" "$temp_file"
                        return 1
                    fi
                    
                    # Handle dependencies and extract
                    check_dependencies || {
                        "$BUSYBOX" rm -f "$temp_file"
                        return 1
                    }
                    
                    extract_package "$package" "$OPM_PACKAGE_EXT" || {
                        "$BUSYBOX" rm -f "$temp_file"
                        return 1
                    }
                    
                    # Set permissions and create symlinks
                    "$BUSYBOX" chmod -R 755 "$OPM_DATA/$package"
                    
                    # Create symlinks for each binary in OPM_ADD_TO_PATH
                    for binary in $OPM_ADD_TO_PATH; do
                        "$BUSYBOX" ln -sf "$OPM_DATA/$package/$binary" "$OPM_BIN/"
                    done
                    
                    # Run post-installation script
                    postinstall_package "$package"
                    echo "Package $package installed successfully"
                    "$BUSYBOX" rm -f "$temp_file"
                    return 0
                fi
            done < "$temp_file"
        fi
    done < "$OPM_REPOS_FILE"
    
    "$BUSYBOX" rm -f "$temp_file"
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

        # Remove symlinks
        for binary in $OPM_ADD_TO_PATH; do
            "$BUSYBOX" rm -f "$OPM_BIN/$binary"
        done

        # Remove package data and metadata
        "$BUSYBOX" rm -rf "$OPM_DATA/$package" "$OPM_DATA/$package.*"
        echo "Package $package removed successfully"
    else
        echo "Package $package is not installed"
    fi
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
        
        "$BUSYBOX" wget -qO "$tmp_file" "$repo_url/packages.json" || continue

        # Add a newline to ensure last line is processed
        "$BUSYBOX" echo "" >> "$tmp_file"

        while IFS='|' read -r name version displayname; do
            [ -z "$name" ] && continue
            
            if [ "$name" = "$package" ]; then
                found=1
                
                if [ -f "$OPM_DATA/$package.opm" ]; then
                    echo "Package: $name (installed)"
                    parse_opm_file "$OPM_DATA/$package.opm"
                    echo "Installed Version: $OPM_PACKAGE_VER"
                    
                    # Compare versions
                    if [ "$OPM_PACKAGE_VER" != "$version" ]; then
                        echo "Version: $version (Update available from $OPM_PACKAGE_VER)"
                    else
                        echo "Version: $version (latest)"
                    fi
                else
                    echo "Package: $name (not installed)"
                    echo "Version: $version"
                fi
                
                # Additional details
                echo "Display Name: $displayname"
                if [ -f "$OPM_DATA/$package.opm" ]; then
                    echo "Description: $OPM_PACKAGE_DESC"
                    if [ -n "$OPM_PACKAGE_DEPS" ]; then
                        echo "Dependencies: $OPM_PACKAGE_DEPS"
                    else
                        echo "No dependencies"
                    fi
                    echo "Archive Size: $(normalize_size $OPM_PACKAGE_SIZE)"
                    echo "Archive Type: $OPM_PACKAGE_EXT"
                fi
                break
            fi
        done < "$tmp_file"
        
        [ $found -eq 1 ] && break
    done < "$OPM_REPOS_FILE"

    # Clean up temporary file
    "$BUSYBOX" rm -f "$tmp_file"
    
    [ $found -eq 0 ] && echo "Package $package not found in any repository"
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
    echo "Available packages:"
    echo "------------------------------------"
    echo "Name | Version | Display Name"
    echo "------------------------------------"
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        echo "From repository: $repo_url"
        echo "------------------------------------"
        
        packages_info=$("$BUSYBOX" wget -qO - "$repo_url/packages.json")
        if [ $? -ne 0 ]; then
            echo "Failed to fetch packages from $repo_url"
            continue
        fi
        
        echo "$packages_info" | while IFS='|' read -r name version displayname; do
            [ -z "$name" ] && continue
            echo "$name | $version | $displayname"
        done
        echo "------------------------------------"
        echo ""
    done < "$OPM_REPOS_FILE"
}

search_packages() {
    local query="$1"
    print_header
    echo "Search results for '$query':"
    echo "----------------------------"
    
    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        
        packages_info=$("$BUSYBOX" wget -qO - "$repo_url/packages.json") || continue
        
        echo "$packages_info" | while IFS='|' read -r name version displayname; do
            [ -z "$name" ] && continue
            if echo "$name $displayname" | "$BUSYBOX" grep -i "$query" >/dev/null; then
                echo "$name | $version | $displayname (from $repo_url)"
            fi
        done
    done < "$OPM_REPOS_FILE"
}

update() {
    "$BUSYBOX" rm -f "$OPM_ROOT/opm.sh"
    echo "Downloading updater script..."
    
    "$BUSYBOX" wget -qO "$OPM_TMP/opminstall.sh" "https://opm.oddbyte.dev/opminstall.sh" || {
        echo "Failed to download updater script";
        return 1;
    }

    "$BUSYBOX" chmod 755 "$OPM_TMP/opminstall.sh"
    "$OPM_TMP/opminstall.sh" --update
    
    "$BUSYBOX" rm -f "$OPM_TMP/opminstall.sh"
    echo "OPM has been successfully updated"
    exit 0
}

start_service() {
    local package="$1"
    local service="$OPM_DATA/$package/service.sh"
    
    if [ -f "$service" ]; then
        echo "Starting service: $service"
        CONFDIR="$OPM_CONFS/$package" PKGDIR="$OPM_DATA/$package" "$BUSYBOX" ash "$service" || 
            echo "Error starting service $service"
    else
        echo "No service script found for $package"
    fi
}

run_diagnostics() {
    echo "=== OPM Diagnostics Report ==="
    echo "Generated: $("$BUSYBOX" date)"
    echo

    # System information
    echo "=== System Information ==="
    echo "Hostname: $("$BUSYBOX" hostname)"
    echo "Kernel: $("$BUSYBOX" uname -a)"
    [ -f /etc/os-release ] && echo "OS: $("$BUSYBOX" cat /etc/os-release | "$BUSYBOX" grep "PRETTY_NAME" | "$BUSYBOX" cut -d= -f2 | "$BUSYBOX" tr -d '"')"
    echo "CPU: $("$BUSYBOX" grep "model name" /proc/cpuinfo | "$BUSYBOX" head -1 | "$BUSYBOX" cut -d: -f2 | "$BUSYBOX" sed 's/^[ \t]*//')"
    echo "Available memory: $("$BUSYBOX" free -h | "$BUSYBOX" grep Mem | "$BUSYBOX" awk '{print $2}')"
    echo "Disk usage: $("$BUSYBOX" df -h / | "$BUSYBOX" tail -1 | "$BUSYBOX" awk '{print $5}')"
    echo

    # OPM environment
    echo "=== OPM Environment ==="
    echo "OPM_ROOT: $OPM_ROOT"
    echo "OPM_BIN: $OPM_BIN"
    echo "OPM_DATA: $OPM_DATA"
    echo "OPM_REPOS_FILE: $OPM_REPOS_FILE"
    echo "BUSYBOX: $BUSYBOX"
    echo

    # BusyBox information
    echo "=== BusyBox Information ==="
    if [ -x "$BUSYBOX" ]; then
        echo "BusyBox location: $BUSYBOX"
        echo "BusyBox version: $("$BUSYBOX" --help | "$BUSYBOX" head -n 1)"
        echo "BusyBox applets: $("$BUSYBOX" --list | "$BUSYBOX" wc -l)"
        echo "BusyBox size: $("$BUSYBOX" ls -lh "$BUSYBOX" | "$BUSYBOX" awk '{print $5}')"
    else
        echo "ERROR: BusyBox not found or not executable"
    fi
    echo

    # Directory structure
    echo "=== Directory Structure ==="
    for dir in "$OPM_ROOT" "$OPM_BIN" "$OPM_DATA" "$OPM_TMP" "$OPM_CONFS"; do
        if [ -d "$dir" ]; then
            echo "✓ $dir ($(du -sh "$dir" 2>/dev/null | cut -f1))"
            "$BUSYBOX" ls -la "$dir" | "$BUSYBOX" head -n 10
            [ "$("$BUSYBOX" ls -la "$dir" | "$BUSYBOX" wc -l)" -gt 11 ] && echo "   ... and more files"
        else
            echo "✗ $dir (missing)"
        fi
        echo
    done

    # Repository check
    echo "=== Repository Status ==="
    if [ -f "$OPM_REPOS_FILE" ]; then
        echo "Repositories configured: $("$BUSYBOX" wc -l < "$OPM_REPOS_FILE")"
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            echo "Testing: $repo"
            if "$BUSYBOX" timeout 5 wget -q --spider "$repo" 2>/dev/null; then
                echo "  ✓ Repository accessible"
                
                if "$BUSYBOX" timeout 5 wget -q --spider "$repo/packages.json" 2>/dev/null; then
                    pkg_count=$("$BUSYBOX" wget -qO - "$repo/packages.json" 2>/dev/null | "$BUSYBOX" wc -l)
                    echo "  ✓ Package list available ($pkg_count packages)"
                    echo "  ✓ First 3 packages:"
                    "$BUSYBOX" wget -qO - "$repo/packages.json" 2>/dev/null | "$BUSYBOX" head -3
                else
                    echo "  ✗ Package list not accessible"
                fi
            else
                echo "  ✗ Repository not accessible"
            fi
            echo
        done < "$OPM_REPOS_FILE"
    else
        echo "✗ Repository file missing"
    fi
    echo

    # Installed packages
    echo "=== Installed Packages ==="
    pkg_count=$(ls -1 "$OPM_DATA"/*.opm 2>/dev/null | wc -l)
    if [ "$pkg_count" -gt 0 ]; then
        echo "Found $pkg_count installed packages:"
        for pkg_file in "$OPM_DATA"/*.opm; do
            [ -f "$pkg_file" ] || continue
            pkg_name=$(basename "$pkg_file" .opm)
            parse_opm_file "$pkg_file"
            echo "- $pkg_name (v$OPM_PACKAGE_VER)"
            echo "  Description: $OPM_PACKAGE_DESC"
            echo "  Size: $(du -sh "$OPM_DATA/$pkg_name" 2>/dev/null | cut -f1)"
            echo "  Binaries: $OPM_ADD_TO_PATH"
            echo
        done
    else
        echo "No packages installed"
    fi
    echo

    # Symbolic links
    echo "=== Symbolic Links Check ==="
    bin_count=$(ls -1 "$OPM_BIN" 2>/dev/null | wc -l)
    echo "Found $bin_count items in $OPM_BIN"
    for item in "$OPM_BIN"/*; do
        [ -e "$item" ] || continue
        [ "$item" = "$OPM_BIN/busybox" ] && continue
        
        if [ -L "$item" ]; then
            target=$("$BUSYBOX" readlink "$item")
            if [ -e "$target" ]; then
                echo "✓ $(basename "$item") -> $target"
            else
                echo "✗ $(basename "$item") -> $target (broken link)"
            fi
        else
            echo "! $(basename "$item") (not a symlink)"
        fi
    done
    echo

    # PATH environment variable
    echo "=== PATH Environment Variable ==="
    echo "$PATH" | "$BUSYBOX" tr ':' '\n'
    echo

    # Profile check
    echo "=== Profile Configuration ==="
    if [ -f ~/.profile ]; then
        if "$BUSYBOX" grep -q "$OPM_ROOT/env.sh" ~/.profile; then
            echo "✓ OPM environment sourced in ~/.profile"
        else
            echo "✗ OPM environment not sourced in ~/.profile"
        fi
    else
        echo "✗ ~/.profile does not exist"
    fi
    
    # Check other common profile files
    for profile in ~/.bash_profile ~/.bashrc ~/.zshrc; do
        if [ -f "$profile" ] && "$BUSYBOX" grep -q "$OPM_ROOT/env.sh" "$profile"; then
            echo "✓ OPM environment also sourced in $profile"
        fi
    done
    echo

    echo "=== End of Diagnostics Report ==="
}

is_opm_running() {
    if [ -f "$OPM_PID_FILE" ]; then
        other_pid=$("$BUSYBOX" cat "$OPM_PID_FILE")
        if "$BUSYBOX" kill -0 "$other_pid" 2>/dev/null; then
            return 0
        else
            "$BUSYBOX" rm "$OPM_PID_FILE"
            echo "WARNING: Previous OPM instance crashed. Please report this bug."
            return 1
        fi
    fi
    return 1
}

handle_existing_process() {
    echo "Warning: Another process is already running with PID $other_pid"
    echo "Options:"
    echo "1) Kill the existing process (may cause data corruption)"
    echo "2) Wait for existing process to finish"
    
    choice=$(get_numeric_choice "Enter choice (1 or 2): " 1 2)
    
    case "$choice" in
        1)
            echo "Killing process $other_pid..."
            "$BUSYBOX" kill -9 "$other_pid"
            "$BUSYBOX" rm -f "$OPM_PID_FILE"
            ;;
        2)
            echo "Waiting for process $other_pid to finish..."
            while "$BUSYBOX" kill -0 "$other_pid" 2>/dev/null; do
                "$BUSYBOX" sleep 1
            done
            echo "Process $other_pid has finished"
            ;;
    esac
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
            [ -z "$args" ] && { echo "Error: Please specify packages to install"; return 1; }
            install_packages $args
            ;;
        doctor|diagnose)
            run_diagnostics
            ;;
        remove|uninstall|delete|rm)
            [ -z "$args" ] && { echo "Error: Please specify a package to remove"; return 1; }
            remove_package $args
            ;;
        repos)
            list_repos
            ;;
        addrepo)
            [ -z "$args" ] && { echo "Error: Please specify a repository URL"; return 1; }
            add_repo $args
            ;;
        rmrepo)
            [ -z "$args" ] && { echo "Error: Please specify a repository URL"; return 1; }
            remove_repo $args
            ;;
        list)
            list_packages
            ;;
        update)
            update
            ;;
        search)
            [ -z "$args" ] && { echo "Error: Please specify a search query"; return 1; }
            search_packages $args
            ;;
        reinstall)
            [ -z "$args" ] && { echo "Error: Please specify a package to reinstall"; return 1; }
            reinstall_package $args
            ;;
        upgrade)
            [ -z "$args" ] && { echo "Error: Please specify a package to upgrade"; return 1; }
            reinstall_package $args
            ;;
        info|show)
            [ -z "$args" ] && { echo "Error: Please specify a package to show"; return 1; }
            show_package $args
            ;;
        start)
            [ -z "$args" ] && { echo "Error: Please specify a package to start"; return 1; }
            start_service $args
            ;;
        postinstall)
            [ -z "$args" ] && { echo "Error: Please specify a package for post-installation"; return 1; }
            postinstall_package $args
            ;;
        *)
            echo "Unknown command: $command"
            usage
            return 1
            ;;
    esac

    echo ""
    echo "Command completed successfully"
}

# Main entry point
[ $# -eq 0 ] && execute_command "help" || execute_command "$@"
