#!${BUSYBOX} ash

# OPM - Odd Package Manager

# Locate the script's directory dynamically
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
    /*) SCRIPT_DIR="${SCRIPT_PATH%/*}" ;; # Absolute path
    *) SCRIPT_DIR="${PWD}/${SCRIPT_PATH%/*}" ;; # Relative path
esac

# Set OPM_ROOT based on script directory if not already set
[ -z "$OPM_ROOT" ] && OPM_ROOT="$SCRIPT_DIR"
ENV_FILE="$OPM_ROOT/env.sh"

# Source the environment file
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "Environment file $ENV_FILE not found. Exiting."
    exit 1
fi

# Ensure BusyBox is available
if [ ! -x "$BUSYBOX" ]; then
    echo "BusyBox not found at $BUSYBOX"
    exit 1
fi

# Ensure `env.sh` is sourced dynamically
if ! "$BUSYBOX" grep -Fxq "source $ENV_FILE" ~/.profile; then
    "$BUSYBOX" echo "Adding source $ENV_FILE to ~/.profile..."
    "$BUSYBOX" echo "source $ENV_FILE" >> ~/.profile
fi

OPM_PID_FILE="$OPM_ROOT/opm.pid"
OPM_FIFO_IN="$OPM_ROOT/opmfifo.in"
OPM_FIFO_OUT="$OPM_ROOT/opmfifo.out"

# Functions

print_header() {
    echo "‏"
    echo "‏====================================="
    echo "‏          OPM Package Manager        "
    echo "‏          By Oddbyte                 "
    echo "‏====================================="
}

usage() {
    print_header
    "$BUSYBOX" cat <<EOF
‏
‏Usage:
‏    opm [command] [options]
‏
‏Commands:
‏    help                                Show this help message
‏    install | add | i                   Install a package
‏    remove | uninstall | delete | rm    Remove a package
‏    repos                               List configured repositories
‏    addrepo [repo_url]                  Add a repository
‏    rmrepo [repo_url]                   Remove a repository
‏    list                                List all package names
‏    search [query]                      Search packages
‏    reinstall [package]                 Reinstalls the package, deleting all data.
‏    upgrade [package]                   Reinstalls the package, but keeps the config data.
‏    update                              Update OPM
‏    show [package]                      Show package details
‏    postinstall [package]               Run post-install script for a package
‏    enable [package]                    Enable the package's service 
‏    disable [package]                   Disable the package's service
‏
EOF
}


list_repos() {
    print_header
    "$BUSYBOX" echo "Configured repositories:"
    "$BUSYBOX" echo "------------------------"
    "$BUSYBOX" cat "$OPM_REPOS_FILE"
}

add_repo() {
    REPO_URL="$1"
    if "$BUSYBOX" grep -Fxq "$REPO_URL" "$OPM_REPOS_FILE"; then
        "$BUSYBOX" echo "Repository already exists."
    else
        "$BUSYBOX" echo "$REPO_URL" >> "$OPM_REPOS_FILE"
        "$BUSYBOX" echo "Repository added."
    fi
}

remove_repo() {
    REPO_URL="$1"
    if "$BUSYBOX" grep -Fxq "$REPO_URL" "$OPM_REPOS_FILE"; then
        "$BUSYBOX" grep -Fxv "$REPO_URL" "$OPM_REPOS_FILE" > "$OPM_REPOS_FILE.tmp"
        mv "$OPM_REPOS_FILE.tmp" "$OPM_REPOS_FILE"
        "$BUSYBOX" echo "Repository removed."
    else
        "$BUSYBOX" echo "Repository not found."
    fi
}

list_packages() {
    print_header
    "$BUSYBOX" echo "Available packages:"
    "$BUSYBOX" echo "------------------------------------"
    "$BUSYBOX" echo "-- name -- version -- displayname --"
    "$BUSYBOX" echo "------------------------------------"
    while read -r REPO_URL; do
        "$BUSYBOX" echo "From repository: $REPO_URL"
        "$BUSYBOX" echo "------------------------------------"
        PACKAGES_JSON=$($BUSYBOX wget -qO - "$REPO_URL/packages.json")
        if [ $? -ne 0 ]; then
            "$BUSYBOX" echo "Failed to fetch packages from $REPO_URL"
            continue
        fi
        "$BUSYBOX" echo "$PACKAGES_JSON" | while IFS='|' read -r name version displayname; do
            "$BUSYBOX" echo "$name - $version - $displayname"
        done
        "$BUSYBOX" echo "------------------------------------"
        "$BUSYBOX" echo ""
    done < "$OPM_REPOS_FILE"
}

search_packages() {
    QUERY="$1"
    print_header
    "$BUSYBOX" echo "Search results for '$QUERY':"
    "$BUSYBOX" echo "----------------------------"
    while read -r REPO_URL; do
        PACKAGES_JSON=$($BUSYBOX wget -qO - "$REPO_URL/packages.json")
        if [ $? -ne 0 ]; then
            "$BUSYBOX" echo "Failed to fetch packages from $REPO_URL"
            continue
        fi
        "$BUSYBOX" echo "$PACKAGES_JSON" | while IFS='|' read -r name version displayname; do
            if "$BUSYBOX" echo "$name $displayname" | "$BUSYBOX" grep -iq "$QUERY"; then
                "$BUSYBOX" echo "$name - $version - $displayname (from $REPO_URL)"
            fi
        done
    done < "$OPM_REPOS_FILE"
}

install_package() {
    PACKAGE="$1"
    while read -r REPO_URL; do
        PACKAGES_JSON=$("$BUSYBOX" wget -qO - "$REPO_URL/packages.json")
        if [ $? -ne 0 ]; then
            continue
        fi
        echo "$PACKAGES_JSON" | while IFS='|' read -r name version displayname; do
            if [ "$name" = "$PACKAGE" ]; then
                FOUND=1
                "$BUSYBOX" echo "Installing $PACKAGE version $version..."
                OPM_FILE_URL="$REPO_URL/packages/$PACKAGE.opm"
                $BUSYBOX wget -qO "$OPM_DATA/$PACKAGE.opm" "$OPM_FILE_URL"
                if [ $? -ne 0 ]; then
                    "$BUSYBOX" echo "Failed to download package metadata."
                    return 1
                fi
                parse_opm_file "$OPM_DATA/$PACKAGE.opm"
                if [ "$OPM_PACKAGE_NAME" != "$PACKAGE" ]; then
                    "$BUSYBOX" echo "Package name in .opm file does not match the package name."
                    return 1
                fi
                check_dependencies

                PACKAGE_FOUND=0
                for ext in tar zip tar.gz gz xz; do
                    PACKAGE_DATA_URL="$REPO_URL/packagedata/$PACKAGE.$ext"
                    $BUSYBOX wget -qO "$OPM_DATA/$PACKAGE.$ext" "$PACKAGE_DATA_URL" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        PACKAGE_FOUND=1
                        PACKAGE_EXT="$ext"
                        break
                    fi
                done
                
                if [ "$PACKAGE_FOUND" -eq 0 ]; then
                    "$BUSYBOX" echo "Failed to download package data."
                    return 1
                fi
                
                "$BUSYBOX" mkdir -p "$OPM_DATA/$PACKAGE"
                case "$PACKAGE_EXT" in
                    "tar")
                        "$BUSYBOX" mkdir -p "$OPM_DATA/$PACKAGE"
                        "$BUSYBOX" tar -xf "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" -C "$OPM_DATA/$PACKAGE/"
                        ;;
                    "zip")
                        "$BUSYBOX" mkdir -p "$OPM_DATA/$PACKAGE"
                        "$BUSYBOX" unzip -o "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" -d "$OPM_DATA/$PACKAGE/"
                        ;;
                    "tar.gz")
                        "$BUSYBOX" mkdir -p "$OPM_DATA/$PACKAGE"
                        "$BUSYBOX" tar -xzf "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" -C "$OPM_DATA/$PACKAGE/"
                        ;;
                    "gz")
                        "$BUSYBOX" mkdir -p "$OPM_DATA/$PACKAGE"
                        "$BUSYBOX" gunzip -c "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" > "$OPM_DATA/$PACKAGE/"
                        ;;
                    "xz")
                        "$BUSYBOX" mkdir -p "$OPM_DATA/$PACKAGE"
                        "$BUSYBOX" xz -d "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" -c > "$OPM_DATA/$PACKAGE/"
                        ;;
                    *)
                        "$BUSYBOX" echo "Could not find the package data. Contact the repo maintainer."
                        return 1
                        ;;
                esac
                "$BUSYBOX" chmod -R 755 "$OPM_DATA/$PACKAGE"
                PACKAGEDIR="$OPM_DATA/$PACKAGE/"
                for binary in $OPM_ADD_TO_PATH; do
                    "$BUSYBOX" ln -sf "$PACKAGEDIR/$binary" "$OPM_BIN/$binary"
                done
                enable_service "$PACKAGEDIR"
                "$BUSYBOX" echo "Package $PACKAGE installed successfully."
                postinstall_package "$PACKAGE"
                return 0
            fi
        done
    done < "$OPM_REPOS_FILE"
}

remove_package() {
    PACKAGE="$1"
    KEEP_CONFIG="$2"  # Optional second argument to keep config folder (true/false)

    if [ -d "$OPM_DATA/$PACKAGE" ]; then
        # Remove symlinks
        parse_opm_file "$OPM_DATA/$PACKAGE.opm"

        # Iterate over binaries listed in OPM_ADD_TO_PATH
        for binary in $OPM_ADD_TO_PATH; do
            "$BUSYBOX" rm -f "$OPM_BIN/$binary"
        done

        # Remove package data, except for the config folder if KEEP_CONFIG is true
        if [ "$KEEP_CONFIG" != "true" ]; then
            "$BUSYBOX" rm -rf "$OPM_DATA/$PACKAGE"  # Remove the entire package data folder
        else
            # Keep the config folder but remove everything else
            "$BUSYBOX" find "$OPM_DATA/$PACKAGE" -mindepth 1 -not -path "$OPM_DATA/$PACKAGE/config*" -exec "$BUSYBOX" rm -rf {} \;
        fi

        # Remove the package .opm and .zip files
        "$BUSYBOX" rm -f "$OPM_DATA/$PACKAGE.opm" "$OPM_DATA/$PACKAGE.zip"
        
        "$BUSYBOX" echo "Package $PACKAGE removed successfully."
    else
        "$BUSYBOX" echo "Package $PACKAGE is not installed."
    fi
}

reinstall_package() {
    remove_package "$1" "$2"
    install_package "$1"
}

show_package() {
    PACKAGE="$1"
    FOUND=0
    while read -r REPO_URL; do
        PACKAGES_JSON=$($BUSYBOX wget -qO - "$REPO_URL/packages.json")
        if [ $? -ne 0 ]; then
            continue
        fi
        "$BUSYBOX" echo "$PACKAGES_JSON" | while IFS='|' read -r name version displayname; do
            if [ "$name" = "$PACKAGE" ]; then
                FOUND=1
                "$BUSYBOX" echo "Package: $name"
                "$BUSYBOX" echo "Version: $version"
                "$BUSYBOX" echo "Display Name: $displayname"
                # Fetch .opm file
                OPM_FILE_URL="$REPO_URL/packages/$PACKAGE.opm"
                $BUSYBOX wget -qO "$OPM_DATA/$PACKAGE.opm" "$OPM_FILE_URL"
                if [ $? -ne 0 ]; then
                    "$BUSYBOX" echo "Failed to download package metadata."
                    return 1
                fi
                # Parse .opm file
                parse_opm_file "$OPM_DATA/$PACKAGE.opm"
                "$BUSYBOX" echo "Description: $OPM_PACKAGE_DESC"
                "$BUSYBOX" echo "Dependencies: ${OPM_DEPENDS[*]}"
                return 0
            fi
        done
        if [ "$FOUND" -eq 1 ]; then
            break
        fi
    done < "$OPM_REPOS_FILE"
    if [ "$FOUND" -eq 0 ]; then
        "$BUSYBOX" echo "Package $PACKAGE not found."
        return 1
    fi
}

postinstall_package() {
    PACKAGE="$1"
    POSTINSTALL_SCRIPT="$OPM_DATA/$PACKAGE/postinstall.sh"

    if [ -f "$POSTINSTALL_SCRIPT" ]; then
        "$BUSYBOX" echo "Running post-installation script for $PACKAGE..."
        PACKAGEDIR="$OPM_DATA/$PACKAGE" "$BUSYBOX" ash "$POSTINSTALL_SCRIPT"
        "$BUSYBOX" echo "Post-installation script completed."
    else
        "$BUSYBOX" echo "No post-installation script found for $PACKAGE."
    fi
    "$BUSYBOX" echo "Nothing else to do."
}

parse_opm_file() {
    OPM_FILE="$1"
    OPM_PACKAGE_NAME=""
    OPM_PACKAGE_DISPLAY=""
    OPM_PACKAGE_VER=""
    OPM_PACKAGE_DESC=""
    OPM_ADD_TO_PATH=""
    OPM_DEPENDS=""

    while read -r line; do
        case "$line" in
            "# :opm packagename:"*)
                OPM_PACKAGE_NAME=$("$BUSYBOX" echo "$line" | "$BUSYBOX" cut -d':' -f3 | "$BUSYBOX" xargs)
                ;;
            "# :opm packagedisplay:"*)
                OPM_PACKAGE_DISPLAY=$("$BUSYBOX" echo "$line" | "$BUSYBOX" cut -d':' -f3 | "$BUSYBOX" xargs)
                ;;
            "# :opm packagever:"*)
                OPM_PACKAGE_VER=$("$BUSYBOX" echo "$line" | "$BUSYBOX" cut -d':' -f3 | "$BUSYBOX" xargs)
                ;;
            "# :opm packagedesc:"*)
                OPM_PACKAGE_DESC=$("$BUSYBOX" echo "$line" | "$BUSYBOX" cut -d':' -f3 | "$BUSYBOX" xargs)
                ;;
            "# :opm addtopath:"*)
                ADDTOPATH_STR=$("$BUSYBOX" echo "$line" | "$BUSYBOX" cut -d':' -f3)
                OPM_ADD_TO_PATH=$("$BUSYBOX" echo "$ADDTOPATH_STR" | "$BUSYBOX" sed 's/,/ /g')
                ;;
            "# :opm depends:"*)
                DEPENDS_STR=$("$BUSYBOX" echo "$line" | "$BUSYBOX" cut -d':' -f3)
                OPM_DEPENDS=$("$BUSYBOX" echo "$DEPENDS_STR" | "$BUSYBOX" sed 's/,/ /g')
                ;;
        esac
    done < "$OPM_FILE"
}

check_dependencies() {
    for dep in $("$BUSYBOX" echo "$OPM_DEPENDS"); do
        if [ "$dep" = "core" ]; then
            # Skip "core" dependency
            continue
        fi
        if [ ! -d "$OPM_DATA/$dep" ]; then
            "$BUSYBOX" echo "Dependency $dep is not installed."
            "$BUSYBOX" echo -n "Do you want to install $dep now? [Y/n]: "
            read choice
            choice=${choice:-Y}
            if echo "$choice" | grep -iq "^y"; then
                install_package "$dep"
            else
                "$BUSYBOX" echo "Cannot proceed without installing dependencies."
                return 1
            fi
        fi
    done
}

# Service management functions
enable_service() {
    SERVICE_DIR="$1"
    if [ -f "$SERVICE_DIR/service.sh" ]; then
        "$BUSYBOX" ln -sf "$SERVICE_DIR/service.sh" "$OPM_ROOT/services/$("$BUSYBOX" basename "$SERVICE_DIR")"
        "$BUSYBOX" echo "Service $("$BUSYBOX" basename "$SERVICE_DIR") enabled."
    else
        "$BUSYBOX" echo "No service.sh found in $SERVICE_DIR."
    fi
}

disable_service() {
    SERVICE_NAME="$1"
    if [ -L "$OPM_ROOT/services/$SERVICE_NAME" ]; then
        "$BUSYBOX" rm "$OPM_ROOT/services/$SERVICE_NAME"
        "$BUSYBOX" echo "Service $SERVICE_NAME disabled."
    else
        "$BUSYBOX" echo "Service $SERVICE_NAME not found."
    fi
}

update() {
    "$BUSYBOX" rm "$OPM_ROOT/opm.sh"
    # Pull opm.sh from the remote server
    "$BUSYBOX" echo "Downloading opm.sh from https://opm.oddbyte.dev/opm.sh..."
    "$BUSYBOX" wget -q -O "$OPM_ROOT/opm.sh" "https://opm.oddbyte.dev/opm.sh"

    # Verify the download
    if [ ! -f "$OPM_ROOT/opm.sh" ]; then
        "$BUSYBOX" echo "Failed to download opm.sh. Please check your internet connection and try again."
        return 1
    fi

    # Read the first line of opm.sh
    FIRST_LINE=$("$BUSYBOX" head -n 1 "$OPM_ROOT/opm.sh")
    
    # Check if the first line is a shebang
    if [[ "$FIRST_LINE" == "#!"* ]]; then
        # Remove the first line
        "$BUSYBOX" tail -n +2 "$OPM_ROOT/opm.sh" > "$OPM_ROOT/opm.sh.tmp"
    else
        # No shebang line, copy the script as is
        "$BUSYBOX" cp "$OPM_ROOT/opm.sh" "$OPM_ROOT/opm.sh.tmp"
    fi
    
    # Add the new shebang line pointing to BusyBox ash
    "$BUSYBOX" echo "#!$BUSYBOX ash" > "$OPM_ROOT/opm.sh"
    
    # Append the rest of the script
    "$BUSYBOX" cat "$OPM_ROOT/opm.sh.tmp" >> "$OPM_ROOT/opm.sh"
    
    # Clean up temporary file
    "$BUSYBOX" rm "$OPM_ROOT/opm.sh.tmp"
    
    "$BUSYBOX" echo "Shebang line updated in $OPM_ROOT/opm.sh to '#!$BUSYBOX ash'"
    
    # Make opm.sh executable
    "$BUSYBOX" chmod 755 "$OPM_ROOT/opm.sh"

    "$BUSYBOX" echo "opm.sh has been successfully updated."
    exit 0
}

start_services() {
    echo "Starting all enabled services..."
    for package_dir in "$OPM_DATA"/*; do
        service="$OPM_ROOT/services/$($BUSYBOX basename $package_dir)"
        if [ -f "$service" ]; then
            echo "Starting service: $("$BUSYBOX" basename "$service")"
            PACKAGEDIR=${package_dir} "$BUSYBOX" ash "$service" || echo "Error starting service $("$BUSYBOX" basename "$service")"
        fi
    done
}

start_service() {
    for package_dir in "$OPM_DATA"/*; do
        service="$OPM_ROOT/services/$($BUSYBOX basename $package_dir)"
        if [ -f "$service" ]; then
            echo "Starting service: $("$BUSYBOX" basename "$service")"
            PACKAGEDIR=${package_dir} "$BUSYBOX" ash "$service" || echo "Error starting service $("$BUSYBOX" basename "$service")"
        fi
    done
}

# Error handling
trap 'echo "Error occurred at line $LINENO with exit code $?." | "$BUSYBOX" tee -a "$OPM_ROOT/opm.err"; exit 1' ERR

# Function to check if another opm instance is running
is_opm_running() {
    if [ -f "$OPM_PID_FILE" ]; then
        OTHER_OPM_PID=$("$BUSYBOX" cat "$OPM_PID_FILE")
        if "$BUSYBOX" kill -0 "$OTHER_OPM_PID" >/dev/null 2>&1; then
            return 0 # Another opm instance is running
        else
            # PID file exists but process is not running
            "$BUSYBOX" rm "$OPM_PID_FILE"
            echo "WARNING: The previous opm instance crashed. This is a bug, so bug oddbyte about it."
            return 1 # No other opm instances are running, but the previous one probably crashed
        fi
    else
        return 1 # PID file does not exist, server not running
    fi
}

# Function to handle user input for killing or waiting
handle_existing_process() {
    echo "Warning: Another process is already running with PID $OTHER_OPM_PID."

    echo "What would you like to do?"
    echo "1) Kill the existing process (Warning: Potential data loss or corruption)"
    echo "2) Wait for the existing process to finish"

    read -p "Enter your choice (1 or 2): " choice

    case "$choice" in
        1)
            echo "Killing process $OTHER_OPM_PID..."
            "$BUSYBOX" kill -9 "$OTHER_OPM_PID"
            "$BUSYBOX" rm -f "$OPM_PID_FILE"
            ;;
        2)
            "$BUSYBOX" echo "Waiting for process $OTHER_OPM_PID to finish..."
            while kill -0 "$OTHER_OPM_PID" >/dev/null 2>&1; do
                "$BUSYBOX" sleep 1
            done
            echo "Process $OTHER_OPM_PID has finished."
            ;;
        *)
            echo "Invalid choice. Please enter 1 or 2."
            handle_existing_process
            ;;
    esac
}

# The jumping off point, calls other functions.
execute_command() {
    case "$COMMAND" in
        help)
            usage
            ;;
        install|add|i)
            PACKAGE="$1"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package to install."
                return 1
            fi
            install_package "$PACKAGE"
            ;;
        remove|uninstall|delete|rm)
            PACKAGE="$1"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package to remove."
                return 1
            fi
            remove_package "$PACKAGE"
            ;;
        repos)
            list_repos
            ;;
        addrepo)
            REPO_URL="$1"
            if [ -z "$REPO_URL" ]; then
                "$BUSYBOX" echo "Please specify a repository URL."
                return 1
            fi
            add_repo "$REPO_URL"
            ;;
        rmrepo)
            REPO_URL="$1"
            if [ -z "$REPO_URL" ]; then
                "$BUSYBOX" echo "Please specify a repository URL."
                return 1
            fi
            remove_repo "$REPO_URL"
            ;;
        list)
            list_packages
            ;;
        update)
            update
            ;;
        search)
            QUERY="$1"
            if [ -z "$QUERY" ]; then
                "$BUSYBOX" echo "Please specify a search query."
                return 1
            fi
            search_packages "$QUERY"
            ;;
        reinstall)
            PACKAGE="$1"
            KEEP_CONFIG="false"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package to reinstall."
                return 1
            fi
            reinstall_package "$PACKAGE" "$KEEP_CONFIG"
            ;;
        upgrade)
            PACKAGE="$1"
            KEEP_CONFIG="true"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package to upgrade."
                return 1
            fi
            reinstall_package "$PACKAGE" "$KEEP_CONFIG"
            ;;
        show)
            PACKAGE="$1"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package to show."
                return 1
            fi
            show_package "$PACKAGE"
            ;;
        start)
            PACKAGE="$1"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package to start."
                return 1
            fi
            start_service "$PACKAGE"
            ;;
        enable)
            PACKAGE="$1"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package to enable as a service."
                return 1
            fi
            enable_service "$OPM_DATA/$PACKAGE"
            ;;
        disable)
            SERVICE_NAME="$1"
            if [ -z "$SERVICE_NAME" ]; then
                "$BUSYBOX" echo "Please specify a service to disable."
                return 1
            fi
            disable_service "$SERVICE_NAME"
            ;;
        postinstall)
            PACKAGE="$1"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package for post-installation."
                return 1
            fi
            postinstall_package "$PACKAGE"
            ;;
        *)
            "$BUSYBOX" echo "Unknown command: $COMMAND"
            usage
            ;;
    esac

    # Indicate command completion. If this doesnt show up, something has gone horribly wrong, and you should bug oddbyte about it.
    "$BUSYBOX" echo "Command completed."
}

# Redirect stderr to the log file
exec 2>> "$OPM_ROOT/opm.err"

# Prepare $COMMAND, because execute_command needs something to be there, if there's no arguments, we just set it to "help" and call it a day.
if [ $# -eq 0 ]; then
    COMMAND="help"
else
    COMMAND="$1"
    shift
fi

# Main entry point of opm
execute_command "$COMMAND" "$@"
