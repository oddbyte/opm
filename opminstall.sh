#!bash

# OPM Installer

echo "====================================="
echo "     Welcome to the OPM Installer    "
echo "     Made by Oddbyte                 "
echo "====================================="
echo ""

# Ask for the installation directory
read -p "Please enter the installation directory for OPM [default: $HOME/.opm]: " OPM_ROOT
OPM_ROOT=${OPM_ROOT:-$HOME/.opm}

echo "OPM will be installed to: $OPM_ROOT"

# Find BusyBox in the same directory as the installer script
SCRIPT_PATH="$0"
if [[ "$SCRIPT_PATH" != /* ]]; then
  SCRIPT_PATH="$PWD/$SCRIPT_PATH"
fi
SCRIPT_DIR="${SCRIPT_PATH%/*}"
BUSYBOX="$SCRIPT_DIR/busybox"

# Function to download BusyBox using curl or wget
download_busybox() {
    BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"

    if command -v curl > /dev/null; then
        echo "Downloading BusyBox using curl..."
        curl -L "$BUSYBOX_URL" -o "$BUSYBOX"
    elif command -v wget > /dev/null; then
        echo "Downloading BusyBox using wget..."
        wget "$BUSYBOX_URL" -O "$BUSYBOX"
    else
        echo "Neither curl nor wget found. Please download BusyBox manually from:"
        echo "$BUSYBOX_URL"
        exit 1
    fi
}

# Check if BusyBox exists; if not, try to download it
if [ ! -f "$BUSYBOX" ]; then
    echo "BusyBox not found in $BUSYBOX. Attempting to download..."
    download_busybox
fi

# Make BusyBox executable
if [ -f "$BUSYBOX" ]; then
    chmod 755 "$BUSYBOX"
    "$BUSYBOX" echo "BusyBox is ready and executable."
else
    echo "Failed to prepare BusyBox. Please ensure it's available at $BUSYBOX."
    exit 1
fi

# Create necessary directories
"$BUSYBOX" mkdir -p "$OPM_ROOT"
OPM_BIN="$OPM_ROOT/bin"
OPM_DATA="$OPM_ROOT/data"
"$BUSYBOX" mkdir -p "$OPM_BIN" "$OPM_DATA"

# Copy BusyBox to the bin folder and make it executable
"$BUSYBOX" cp "$BUSYBOX" "$OPM_BIN/busybox"
"$BUSYBOX" chmod 755 "$OPM_BIN/busybox"
BUSYBOX="$OPM_BIN/busybox"

# Symlink all BusyBox applets in the bin folder
APPLET_LIST=$("$BUSYBOX" --list)
for applet in $APPLET_LIST; do
    "$BUSYBOX" ln -sf "$BUSYBOX" "$OPM_BIN/$applet"
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

# Symlink opm to $OPM_BIN
"$BUSYBOX" ln -sf "$OPM_ROOT/opm.sh" "$OPM_BIN/opm"

# Set up env.sh using BusyBox
"$BUSYBOX" echo "Setting up environment variables..."
"$BUSYBOX" echo "export OPM_ROOT=\"$OPM_ROOT\"" > "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export OPM_BIN=\"$OPM_BIN\"" >> "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export OPM_DATA=\"$OPM_DATA\"" >> "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export OPM_REPOS_FILE=\"\$OPM_ROOT/opm-repos\"" >> "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export BUSYBOX=\"$BUSYBOX\"" >> "$OPM_ROOT/env.sh"
"$BUSYBOX" echo "export PATH=\"\$OPM_BIN:\$PATH\"" >> "$OPM_ROOT/env.sh"

# Add source $OPM_ROOT/env.sh to ~/.bashrc
if ! "$BUSYBOX" grep -Fxq "source $OPM_ROOT/env.sh" ~/.bashrc; then
    "$BUSYBOX" echo "Adding source command to ~/.bashrc..."
    "$BUSYBOX" echo "source $OPM_ROOT/env.sh" >> ~/.bashrc
fi

# Create default opm-repos file using BusyBox
"$BUSYBOX" echo "Creating default repository list..."
"$BUSYBOX" echo "https://opm.oddbyte.dev/" > "$OPM_ROOT/opm-repos"

"$BUSYBOX" echo ""
"$BUSYBOX" echo "====================================="
"$BUSYBOX" echo "       OPM Installation Complete     "
"$BUSYBOX" echo "====================================="
"$BUSYBOX" echo "Please restart your terminal or run 'source ~/.bashrc' to start using OPM."
