#!/usr/bin/env bash

# OPM - Odd Package Manager

# Load environment variables
if [ -z "$OPM_ROOT" ]; then
    echo "OPM_ROOT not set. Please source the env.sh file, or rerun with OPM_ROOT=/path/to/opmroot/ opm"
    exit 1
fi

source $OPM_ROOT/env.sh # source again just to be sure

# Ensure BusyBox is available
if [ ! -x "$BUSYBOX" ]; then
    echo "BusyBox not found at $BUSYBOX"
    exit 1
fi

print_header() {
    "$BUSYBOX" echo "====================================="
    "$BUSYBOX" echo "          OPM Package Manager        "
    "$BUSYBOX" echo "          By Oddbyte                 "
    "$BUSYBOX" echo "====================================="
}

checkdate() {
    OPM_FILE="$OPM_ROOT/opm.sh"

    # Check if the file exists
    if [ ! -f "$OPM_FILE" ]; then
        "$BUSYBOX" echo "Error: $OPM_FILE does not exist."
        return 1
    fi

    # Get the last modified time of the local file in seconds
    last_modified=$("$BUSYBOX" stat -c %Y "$OPM_FILE")
    current_time=$("$BUSYBOX" date +%s)

    # Calculate the difference in seconds (604800 seconds = 1 week)
    diff=$((current_time - last_modified))
    if [ $diff -le 604800 ]; then
        return 0
    fi

    "$BUSYBOX" echo "You are running a opm version that is over a week old. You should probably run opm update"
}

checkdate

usage() {
    print_header
    "$BUSYBOX" cat << EOF

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

EOF
}

# Parse commands
COMMAND="$1"
shift


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

update() {
    # Pull opm.sh from the remote server
    "$BUSYBOX" echo "Downloading opm.sh from https://opm.oddbyte.dev/opm.sh..."
    "$BUSYBOX" wget -q -O "$OPM_ROOT/opm.sh" "https://opm.oddbyte.dev/opm.sh"
    
    # Verify the download
    if [ ! -f "$OPM_ROOT/opm.sh" ]; then
        "$BUSYBOX" echo "Failed to download opm.sh. Please check your internet connection and try again."
        exit 1
    fi
    
    # Make opm.sh executable
    "$BUSYBOX" chmod 755 "$OPM_ROOT/opm.sh"
    "$BUSYBOX" echo "opm.sh has been successfully updated."
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
        PACKAGES_JSON=$($BUSYBOX wget -qO - "$REPO_URL/packages.json")
        if [ $? -ne 0 ]; then
            continue
        fi
        "$BUSYBOX" echo "$PACKAGES_JSON" | while IFS='|' read -r name version displayname; do
            if [ "$name" = "$PACKAGE" ]; then
                FOUND=1
                "$BUSYBOX" echo "Installing $PACKAGE version $version..."
                # Fetch .opm file
                OPM_FILE_URL="$REPO_URL/packages/$PACKAGE.opm"
                $BUSYBOX wget -qO "$OPM_DATA/$PACKAGE.opm" "$OPM_FILE_URL"
                if [ $? -ne 0 ]; then
                    "$BUSYBOX" echo "Failed to download package metadata."
                    exit 1
                fi
                # Parse .opm file
                parse_opm_file "$OPM_DATA/$PACKAGE.opm"
                # Verify package name matches filename
                if [ "$OPM_PACKAGE_NAME" != "$PACKAGE" ]; then
                    "$BUSYBOX" echo "Package name in .opm file does not match the package name."
                    exit 1
                fi
                # Check dependencies
                check_dependencies
                # Download package data
                PACKAGE_DATA_URL="$REPO_URL/packagedata/$PACKAGE.zip"
                $BUSYBOX wget -qO "$OPM_DATA/$PACKAGE.zip" "$PACKAGE_DATA_URL"
                if [ $? -ne 0 ]; then
                    "$BUSYBOX" echo "Failed to download package data."
                    exit 1
                fi
                # Extract package data
                "$BUSYBOX" mkdir -p "$OPM_DATA/$PACKAGE"
                $BUSYBOX unzip -o "$OPM_DATA/$PACKAGE.zip" -d "$OPM_DATA/$PACKAGE"
                if [ $? -ne 0 ]; then
                    "$BUSYBOX" echo "Failed to extract package data."
                    exit 1
                fi
                # Set all files in the package data folder to be executable
                "$BUSYBOX" chmod -R 755 "$OPM_DATA/$PACKAGE"
                # Symlink files listed in addtopath to $OPM_BIN/
                for binary in "${OPM_ADD_TO_PATH[@]}"; do
                    ln -sf "$OPM_DATA/$PACKAGE/$binary" "$OPM_BIN/$binary"
                done
                "$BUSYBOX" echo "Package $PACKAGE installed successfully."
                exit 0
            fi
        done
        if [ "$FOUND" -eq 1 ]; then
            break
        fi
    done < "$OPM_REPOS_FILE"
    if [ "$FOUND" -eq 0 ]; then
        "$BUSYBOX" echo "Package $PACKAGE not found in any configured repository."
        exit 1
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
                    exit 1
                fi
                # Parse .opm file
                parse_opm_file "$OPM_DATA/$PACKAGE.opm"
                "$BUSYBOX" echo "Description: $OPM_PACKAGE_DESC"
                "$BUSYBOX" echo "Dependencies: ${OPM_DEPENDS[*]}"
                exit 0
            fi
        done
        if [ "$FOUND" -eq 1 ]; then
            break
        fi
    done < "$OPM_REPOS_FILE"
    if [ "$FOUND" -eq 0 ]; then
        "$BUSYBOX" echo "Package $PACKAGE not found."
        exit 1
    fi
}

parse_opm_file() {
    OPM_FILE="$1"
    OPM_PACKAGE_NAME=""
    OPM_PACKAGE_DISPLAY=""
    OPM_PACKAGE_VER=""
    OPM_PACKAGE_DESC=""
    OPM_ADD_TO_PATH=()
    OPM_DEPENDS=()

    while read -r line; do
        case "$line" in
            "# :opm packagename:"*)
                OPM_PACKAGE_NAME=$("$BUSYBOX" echo "$line" | cut -d':' -f3 | xargs)
                ;;
            "# :opm packagedisplay:"*)
                OPM_PACKAGE_DISPLAY=$("$BUSYBOX" echo "$line" | cut -d':' -f3 | xargs)
                ;;
            "# :opm packagever:"*)
                OPM_PACKAGE_VER=$("$BUSYBOX" echo "$line" | cut -d':' -f3 | xargs)
                ;;
            "# :opm packagedesc:"*)
                OPM_PACKAGE_DESC=$("$BUSYBOX" echo "$line" | cut -d':' -f3 | xargs)
                ;;
            "# :opm addtopath:"*)
                ADDTOPATH_STR=$("$BUSYBOX" echo "$line" | cut -d':' -f3 | xargs)
                ADDTOPATH_STR="${ADDTOPATH_STR#[}"
                ADDTOPATH_STR="${ADDTOPATH_STR%]}"
                IFS=',' read -ra ADDR <<< "$ADDTOPATH_STR"
                for i in "${ADDR[@]}"; do
                    OPM_ADD_TO_PATH+=("$("$BUSYBOX" echo "$i" | xargs)")
                done
                ;;
            "# :opm depends:"*)
                DEPENDS_STR=$("$BUSYBOX" echo "$line" | cut -d':' -f3 | xargs)
                IFS=',' read -ra ADDR <<< "$DEPENDS_STR"
                for i in "${ADDR[@]}"; do
                    OPM_DEPENDS+=("$("$BUSYBOX" echo "$i" | xargs)")
                done
                ;;
        esac
    done < "$OPM_FILE"
}

check_dependencies() {
    for dep in "${OPM_DEPENDS[@]}"; do
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
                exit 1
            fi
        fi
    done
}

case "$COMMAND" in
    help)
        usage
        ;;
    install|add|i)
        PACKAGE="$1"
        if [ -z "$PACKAGE" ]; then
            "$BUSYBOX" echo "Please specify a package to install."
            exit 1
        fi
        install_package "$PACKAGE"
        ;;
    remove|uninstall|delete|rm)
        PACKAGE="$1"
        if [ -z "$PACKAGE" ]; then
            "$BUSYBOX" echo "Please specify a package to remove."
            exit 1
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
            exit 1
        fi
        add_repo "$REPO_URL"
        ;;
    rmrepo)
        REPO_URL="$1"
        if [ -z "$REPO_URL" ]; then
            "$BUSYBOX" echo "Please specify a repository URL."
            exit 1
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
            exit 1
        fi
        search_packages "$QUERY"
        ;;
    reinstall|upgrade)
        PACKAGE="$1"
        if [ -z "$PACKAGE" ]; then
            "$BUSYBOX" echo "Please specify a package to reinstall or upgrade."
            exit 1
        fi
        reinstall_package "$PACKAGE"
        ;;
    show)
        PACKAGE="$1"
        if [ -z "$PACKAGE" ]; then
            "$BUSYBOX" echo "Please specify a package to show."
            exit 1
        fi
        show_package "$PACKAGE"
        ;;
    *)
        if [ -z "$COMMAND" ]; then
            usage
            exit 0
        fi
        "$BUSYBOX" echo "Unknown command: $COMMAND"
        usage
        ;;
esac
