#!/bin/sh

###################################
# OPM Installer                   #
# By: Oddbyte                     #
# Official website: oddbyte.dev   #
###################################

echo "====================================="
echo "     Welcome to the OPM Installer    "
echo "     Made by Oddbyte                 "
echo "====================================="
echo ""

# Profile script to check default shell
profile_script='
normalize_path() {
  # Replace multiple consecutive slashes with a single slash
  echo "$1" | sed "s|/\+/|/|g"
}
# Source package-specific environment files
for pkg_env in "$OPM_DATA"/*/env.sh; do
    if [ -f "$pkg_env" ]; then
        . "$pkg_env"
    fi
done
'

# Check if --update flag is passed
if [ "$1" = "--update" ]; then
    echo "Performing OPM update..."
    
    # Use existing OPM_ROOT from the environment
    if [ -z "$OPM_ROOT" ]; then
        echo "OPM_ROOT environment variable is not set. Please set OPM_ROOT to proceed."
        exit 1
    fi
    
    # Use the existing directories
    OPM_BIN="$OPM_ROOT/bin"
    OPM_DATA="$OPM_ROOT/data"
    
    echo "Updating opm.sh and env.sh in $OPM_ROOT..."

    # Pull the latest opm.sh from the remote server
    "$BUSYBOX" echo "Downloading opm.sh from https://opm.oddbyte.dev/opm.sh..."
    "$BUSYBOX" wget -q -O "$OPM_ROOT/opm.sh" "https://opm.oddbyte.dev/opm.sh"

    # Verify the download
    if [ ! -f "$OPM_ROOT/opm.sh" ]; then
        "$BUSYBOX" echo "Failed to download opm.sh. Please check your internet connection and try again."
        exit 1
    fi

    # Read the first line of opm.sh
    FIRST_LINE=$("$BUSYBOX" head -n 1 "$OPM_ROOT/opm.sh")

    # Check if the first line is a shebang
    case "$FIRST_LINE" in
        "#!"*)
            # Remove the first line
            "$BUSYBOX" tail -n +2 "$OPM_ROOT/opm.sh" > "$OPM_ROOT/opm.sh.tmp"
            ;;
        *)
            # No shebang line, copy the script as is
            "$BUSYBOX" cp "$OPM_ROOT/opm.sh" "$OPM_ROOT/opm.sh.tmp"
            ;;
    esac

    # Add the new shebang line pointing to BusyBox ash
    "$BUSYBOX" echo "#!$OPM_BIN/busybox/ash" > "$OPM_ROOT/opm.sh"

    # Append the rest of the script
    "$BUSYBOX" cat "$OPM_ROOT/opm.sh.tmp" >> "$OPM_ROOT/opm.sh"

    # Clean up temporary file
    "$BUSYBOX" rm "$OPM_ROOT/opm.sh.tmp"

    "$BUSYBOX" echo "Shebang line updated in $OPM_ROOT/opm.sh to '#!$OPM_BIN/busybox/ash'"

    # Make opm.sh executable
    "$BUSYBOX" chmod 755 "$OPM_ROOT/opm.sh"

    # Symlink opm to $OPM_BIN
    "$BUSYBOX" ln -sf "$OPM_ROOT/opm.sh" "$OPM_BIN/opm"

    # Update env.sh with necessary environment variables
    "$BUSYBOX" echo "Setting up environment variables in env.sh..."
    "$BUSYBOX" echo "export OPM_ROOT=\"$OPM_ROOT\"" > "$OPM_ROOT/env.sh"
    "$BUSYBOX" echo "export OPM_BIN=\"$OPM_BIN\"" >> "$OPM_ROOT/env.sh"
    "$BUSYBOX" echo "export OPM_DATA=\"$OPM_DATA\"" >> "$OPM_ROOT/env.sh"
    "$BUSYBOX" echo "export OPM_REPOS_FILE=\"\$OPM_ROOT/opm-repos\"" >> "$OPM_ROOT/env.sh"
    "$BUSYBOX" echo "export BUSYBOX=\"$OPM_BIN/busybox/busybox\"" >> "$OPM_ROOT/env.sh"
    "$BUSYBOX" echo "export PATH=\"\$OPM_BIN:\$PATH:\$OPM_BIN/busybox/\"" >> "$OPM_ROOT/env.sh"
    "$BUSYBOX" echo "$profile_script" >> "$OPM_ROOT/env.sh"

    # Ensure the changes to env.sh are sourced in ~/.profile
    if ! "$BUSYBOX" grep -Fxq ". $OPM_ROOT/env.sh" ~/.profile; then
        "$BUSYBOX" echo "Adding . $OPM_ROOT/env.sh to ~/.profile..."
        "$BUSYBOX" echo ". $OPM_ROOT/env.sh" >> ~/.profile
    fi

    echo ""
    echo "====================================="
    echo "       OPM Update Complete          "
    echo "====================================="
    echo ""

    echo "Please run . ~/.profile or restart your shell to apply the update."
    exit 0
fi

# If not updating, proceed with normal installation:
#
# Ask for the installation directory
printf "Please enter the installation directory for OPM [default: $HOME/.opm]: "
read OPM_ROOT
OPM_ROOT=${OPM_ROOT:-$HOME/.opm}

echo "OPM will be installed to: $OPM_ROOT"

# Download BusyBox into the current directory
BUSYBOX="./busybox"
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"

# Function to download BusyBox using curl or wget
download_busybox() {
    if command -v curl >/dev/null 2>&1; then
        echo "Downloading BusyBox using curl..."
        curl -L "$BUSYBOX_URL" -o "$BUSYBOX"
    elif command -v wget >/dev/null 2>&1; then
        echo "Downloading BusyBox using wget..."
        wget "$BUSYBOX_URL" -O "$BUSYBOX"
    else
        echo "Neither curl nor wget found. Please download BusyBox manually from:"
        echo "$BUSYBOX_URL"
        exit 1
    fi
}

# Download BusyBox if it's not already present in the current directory
if [ ! -f "$BUSYBOX" ]; then
    echo "BusyBox not found in current directory. Attempting to download..."
    download_busybox
fi

# Check if chmod exists in the shell PATH by searching the directories in $PATH
# Use shell's built-in `command -v` to search for chmod
if command -v chmod >/dev/null 2>&1; then
    echo "Found chmod command."
else
    echo "chmod not found. Please manually set BusyBox as executable."
    exit 1
fi

# Make BusyBox executable
chmod 755 "$BUSYBOX"

# Now use the downloaded BusyBox to create necessary directories for OPM
"$BUSYBOX" mkdir -p "$OPM_ROOT"
OPM_BIN="$OPM_ROOT/bin"
OPM_DATA="$OPM_ROOT/data"
"$BUSYBOX" mkdir -p "$OPM_BIN" "$OPM_DATA"

# Create busybox folder within $OPM_BIN
"$BUSYBOX" mkdir -p "$OPM_BIN/busybox"

# Move the downloaded BusyBox to the busybox folder
"$BUSYBOX" mv "$BUSYBOX" "$OPM_BIN/busybox/"

# Set the path to the new BusyBox
BUSYBOX="$OPM_BIN/busybox/busybox"

# Symlink all BusyBox applets in the bin folder (to $OPM_BIN/busybox/)
APPLET_LIST=$("$BUSYBOX" --list)
for applet in $APPLET_LIST; do
    if [ ! -e "$OPM_BIN/busybox/$applet" ]; then
        "$BUSYBOX" ln -s "$OPM_BIN/busybox/busybox" "$OPM_BIN/busybox/$applet"
    fi
done

# Pull opm.sh from the remote server
"$BUSYBOX" echo "Downloading opm.sh from https://opm.oddbyte.dev/opm.sh..."
"$BUSYBOX" wget -q -O "$OPM_ROOT/opm.sh" "https://opm.oddbyte.dev/opm.sh"

# Verify the download
if [ ! -f "$OPM_ROOT/opm.sh" ]; then
    "$BUSYBOX" echo "Failed to download opm.sh. Please check your internet connection and try again."
    exit 1
fi

# Read the first line of opm.sh
FIRST_LINE=$("$BUSYBOX" head -n 1 "$OPM_ROOT/opm.sh")

# Check if the first line is a shebang
case "$FIRST_LINE" in
    "#!"*)
        # Remove the first line
        "$BUSYBOX" tail -n +2 "$OPM_ROOT/opm.sh" > "$OPM_ROOT/opm.sh.tmp"
        ;;
    *)
        # No shebang line, copy the script as is
        "$BUSYBOX" cp "$OPM_ROOT/opm.sh" "$OPM_ROOT/opm.sh.tmp"
        ;;
esac

# Add the new shebang line pointing to BusyBox ash
"$BUSYBOX" echo "#!$OPM_BIN/busybox/ash" > "$OPM_ROOT/opm.sh"

# Append the rest of the script
"$BUSYBOX" cat "$OPM_ROOT/opm.sh.tmp" >> "$OPM_ROOT/opm.sh"

# Clean up temporary file
"$BUSYBOX" rm "$OPM_ROOT/opm.sh.tmp"

"$BUSYBOX" echo "Shebang line updated in $OPM_ROOT/opm.sh to '#!$OPM_BIN/busybox/ash'"

# Make opm.sh executable
"$BUSYBOX" chmod 755 "$OPM_ROOT/opm.sh"

# Symlink opm to $OPM_BIN
"$BUSYBOX" ln -s "$OPM_ROOT/opm.sh" "$OPM_BIN/opm"

# Set up env.sh using BusyBox
"$BUSYBOX" echo "Setting up environment variables..."
"$BUSYBOX" echo "export OPM_ROOT=\"$OPM_ROOT\"" > "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export OPM_BIN=\"$OPM_BIN\"" >> "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export OPM_DATA=\"$OPM_DATA\"" >> "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export OPM_REPOS_FILE=\"\$OPM_ROOT/opm-repos\"" >> "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export BUSYBOX=\"$OPM_BIN/busybox/busybox\"" >> "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export PATH=\"\$OPM_BIN:\$PATH:\$OPM_BIN/busybox/\"" >> "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "$profile_script" >> "$OPM_ROOT/env.sh"

# Add . $OPM_ROOT/env.sh to ~/.profile
if ! "$BUSYBOX" grep -Fxq ". $OPM_ROOT/env.sh" ~/.profile; then
    "$BUSYBOX" echo "Adding . $OPM_ROOT/env.sh to ~/.profile..."
    "$BUSYBOX" echo ". $OPM_ROOT/env.sh" >> ~/.profile
fi

# Create default opm-repos file using BusyBox
"$BUSYBOX" echo "Creating default repository list..."
"$BUSYBOX" echo "https://opm.oddbyte.dev/" > "$OPM_ROOT/opm-repos"

"$BUSYBOX" echo ""
"$BUSYBOX" echo "====================================="
"$BUSYBOX" echo "       OPM Installation Complete     "
"$BUSYBOX" echo "====================================="
"$BUSYBOX" echo ""

"$BUSYBOX" echo "Please run . ~/.profile or restart your shell to be able to run opm."
