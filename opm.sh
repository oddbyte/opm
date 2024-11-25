#!${BUSYBOX} ash

# OPM - Odd Package Manager

# Load environment variables
if [ -z "$OPM_ROOT" ]; then
    echo "OPM_ROOT not set. Please source the env.sh file, or rerun with OPM_ROOT=/path/to/opmroot/ opm"
    exit 1
fi

source "$OPM_ROOT/env.sh" # source again just to be sure

# Ensure BusyBox is available
if [ ! -x "$BUSYBOX" ]; then
    echo "BusyBox not found at $BUSYBOX"
    exit 1
fi

OPM_PID_FILE="$OPM_ROOT/opm.pid"
OPM_FIFO_IN="$OPM_ROOT/opmfifo.in"
OPM_FIFO_OUT="$OPM_ROOT/opmfifo.out"

# Functions

print_header() {
    echo "====================================="
    echo "          OPM Package Manager        "
    echo "          By Oddbyte                 "
    echo "====================================="
}

usage() {
    print_header
    "$BUSYBOX" cat <<EOF

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
    reinstall | upgrade [package]       Reinstall or upgrade a package
    update                              Update OPM
    show [package]                      Show package details
    postinstall [package]               Run post-install script for a package
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
    "$BUSYBOX" echo "-------------------"
    while read -r REPO_URL; do
        "$BUSYBOX" echo "From repository: $REPO_URL"
        PACKAGES_JSON=$($BUSYBOX wget -qO - "$REPO_URL/packages.json")
        if [ $? -ne 0 ]; then
            "$BUSYBOX" echo "Failed to fetch packages from $REPO_URL"
            continue
        fi
        "$BUSYBOX" echo "$PACKAGES_JSON" | while IFS='|' read -r name version displayname; do
            "$BUSYBOX" echo "$name - $version - $displayname"
        done
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
    FOUND=0
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
                    $BUSYBOX wget -qO "$OPM_DATA/$PACKAGE.$ext" "$PACKAGE_DATA_URL"
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
                        $BUSYBOX tar -xf "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" -C "$OPM_DATA/$PACKAGE.tar"
                        ;;
                    "zip")
                        $BUSYBOX unzip -o "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" -d "$OPM_DATA/$PACKAGE.zip"
                        ;;
                    "tar.gz")
                        $BUSYBOX tar -xzf "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" -C "$OPM_DATA/$PACKAGE.tar.gz"
                        ;;
                    "gz")
                        $BUSYBOX gunzip -c "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" > "$OPM_DATA/$PACKAGE/${PACKAGE}.gz"
                        ;;
                    "xz")
                        $BUSYBOX xz -d "$OPM_DATA/$PACKAGE.$PACKAGE_EXT" -c > "$OPM_DATA/$PACKAGE/${PACKAGE}.xz"
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
                "$BUSYBOX" echo "Package $PACKAGE installed successfully."
                postinstall_package "$PACKAGE"
                return 0
            fi
        done
        if [ "$FOUND" -eq 1 ]; then
            break
        fi
    done < "$OPM_REPOS_FILE"
    if [ "$FOUND" -eq 0 ]; then
        "$BUSYBOX" echo "Package $PACKAGE not found in any configured repository."
        return 1
    fi
}

remove_package() {
    PACKAGE="$1"
    if [ -d "$OPM_DATA/$PACKAGE" ]; then
        # Remove symlinks
        parse_opm_file "$OPM_DATA/$PACKAGE.opm"
        for binary in "${OPM_ADD_TO_PATH[@]}"; do
            "$BUSYBOX" rm -f "$OPM_BIN/$binary"
        done
        # Remove package data
        "$BUSYBOX" rm -rf "$OPM_DATA/$PACKAGE"
        "$BUSYBOX" rm -f "$OPM_DATA/$PACKAGE.opm" "$OPM_DATA/$PACKAGE.zip"
        "$BUSYBOX" echo "Package $PACKAGE removed successfully."
    else
        "$BUSYBOX" echo "Package $PACKAGE is not installed."
    fi
}

reinstall_package() {
    remove_package "$1"
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
                ADDTOPATH_STR=$("$BUSYBOX" echo "$line" | "$BUSYBOX" cut -d':' -f3 | "$BUSYBOX" sed 's/^\[//;s/\]$//')
                OPM_ADD_TO_PATH=$("$BUSYBOX" echo "$ADDTOPATH_STR" | "$BUSYBOX" tr ',' ' ')
                ;;
            "# :opm depends:"*)
                DEPENDS_STR=$("$BUSYBOX" echo "$line" | "$BUSYBOX" cut -d':' -f3 | "$BUSYBOX" xargs)
                OPM_DEPENDS="$OPM_DEPENDS $("$BUSYBOX" echo "$DEPENDS_STR" | "$BUSYBOX" tr ',' ' ')"
                ;;
        esac
    done < "$OPM_FILE"
}

check_dependencies() {
    for dep in $("$BUSYBOX" echo "$OPM_DEPENDS"); do
        if [ "$dep" == "core" ]; then
            # Do nothing
            continue
        fi
        if [ ! -d "$OPM_DATA/$dep" ]; then
            "$BUSYBOX" echo "Dependency $dep is not installed."
            read -p "Do you want to install $dep now? [Y/n]: " choice
            choice=${choice:-Y}
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                install_package "$dep"
            else
                "$BUSYBOX" echo "Cannot proceed without installing dependencies."
                return 1
            fi
        fi
    done
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

# Function to start the server
start_server() {
    "$BUSYBOX" echo "Starting OPM server..."
    # Start the server using BusyBox ash in the background
    "$BUSYBOX" ash "$0" server &
    SERVER_PID=$!
    # Save the PID
    echo "$SERVER_PID" > "$OPM_PID_FILE"
    "$BUSYBOX" echo "OPM server started with PID $SERVER_PID"
}

# Function to check if server is running
is_server_running() {
    if [ -f "$OPM_PID_FILE" ]; then
        SERVER_PID=$(cat "$OPM_PID_FILE")
        if "$BUSYBOX" kill -0 "$SERVER_PID" >/dev/null 2>&1; then
            return 0 # Server is running
        else
            # PID file exists but process is not running
            rm "$OPM_PID_FILE"
            return 1 # Server is not running
        fi
    else
        return 1 # PID file does not exist, server not running
    fi
}

# Function to initialize OPM (run init.sh in each package)
opm_init() {
    "$BUSYBOX" echo "Running opm init..."
    for package_dir in "$OPM_DATA"/*; do
        if [ -d "$package_dir" ]; then
            INIT_SCRIPT="$package_dir/init.sh"
            if [ -f "$INIT_SCRIPT" ]; then
                "$BUSYBOX" echo "Running init script for package $("$BUSYBOX" basename "$package_dir")"
                PACKAGEDIR="$package_dir" "$BUSYBOX" ash "$INIT_SCRIPT"
            fi
        fi
    done
    "$BUSYBOX" echo "opm init completed."
}

execute_command() {
    COMMAND="$1"
    shift

    case "$COMMAND" in
        init)
            opm_init
            ;;
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
        reinstall|upgrade)
            PACKAGE="$1"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package to reinstall or upgrade."
                return 1
            fi
            reinstall_package "$PACKAGE"
            ;;
        show)
            PACKAGE="$1"
            if [ -z "$PACKAGE" ]; then
                "$BUSYBOX" echo "Please specify a package to show."
                return 1
            fi
            show_package "$PACKAGE"
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

    # Indicate command completion
    "$BUSYBOX" echo "Command completed."
}

# Server code
server_loop() {
    while true; do
        if read -r command; then
            case "$command" in
                exit)
                    "$BUSYBOX" echo "Shutting down OPM server..."
                    break
                    ;;
                *)
                    # Execute the command and send output to the client
                    execute_command $command
                    if [ $? -ne 0 ]; then
                        "$BUSYBOX" echo "ERROR: Command failed."
                    fi
                    ;;
            esac
        fi
    done

    # Clean up
    "$BUSYBOX" rm -f "$OPM_PID_FILE"
    "$BUSYBOX" rm -f "$OPM_FIFO_IN" "$OPM_FIFO_OUT"
    "$BUSYBOX" echo "OPM server shut down."
    exit 0
}

# Client code
client() {
    if ! is_server_running; then
        start_server
        "$BUSYBOX" sleep 1
    fi

    "$BUSYBOX" echo "$COMMAND $*" > "$OPM_FIFO_IN"

    while read -r line; do
        "$BUSYBOX" echo "$line"
        if [ "$line" = "Command completed." ] || [[ "$line" == ERROR:* ]]; then
            break
        fi
    done < "$OPM_FIFO_OUT"
}

# Main entry point
if [ "$1" = "server" ]; then
    # Server mode

    # Remove any existing FIFO files
    [ -p "$OPM_FIFO_IN" ] && "$BUSYBOX" rm "$OPM_FIFO_IN"
    [ -p "$OPM_FIFO_OUT" ] && "$BUSYBOX" rm "$OPM_FIFO_OUT"

    # Create FIFO files
    "$BUSYBOX" mkfifo "$OPM_FIFO_IN"
    "$BUSYBOX" mkfifo "$OPM_FIFO_OUT"

    # Redirect stdin and stdout to the FIFO files
    exec <"$OPM_FIFO_IN"
    exec >"$OPM_FIFO_OUT" 2>&1

    # Run opm init before starting the server loop
    opm_init

    # Now run the server loop
    server_loop
    exit 0
else
    # Client mode
    COMMAND="$1"
    shift

    if [ -z "$COMMAND" ]; then
        usage
        exit 0
    fi

    client "$@"
    exit 0
fi
