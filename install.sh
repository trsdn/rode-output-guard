#!/usr/bin/env bash
# Install rode-output-guard as a LaunchAgent.
#   - compiles the binary
#   - copies it to ~/.local/bin/rode-output-guard
#   - writes ~/Library/LaunchAgents/rode-output-guard.plist with correct paths
#   - launchctl unload + load
#   - tails the log briefly to confirm startup

set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="$HOME/.local/bin"
BIN_PATH="$BIN_DIR/rode-output-guard"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PATH="$AGENT_DIR/rode-output-guard.plist"
LOG_DIR="$HOME/Library/Logs"
LOG_PATH="$LOG_DIR/rode-output-guard.log"

mkdir -p "$BIN_DIR" "$AGENT_DIR" "$LOG_DIR"

echo "→ compiling"
./build.sh

echo "→ installing binary to $BIN_PATH"
cp rode-output-guard "$BIN_PATH"
chmod +x "$BIN_PATH"

echo "→ writing LaunchAgent to $AGENT_PATH"
sed \
    -e "s|__BINARY_PATH__|$BIN_PATH|g" \
    -e "s|__LOG_PATH__|$LOG_PATH|g" \
    rode-output-guard.plist > "$AGENT_PATH"

echo "→ reloading LaunchAgent"
launchctl unload "$AGENT_PATH" 2>/dev/null || true
launchctl load "$AGENT_PATH"

sleep 1
echo
echo "=== last 10 log lines ==="
tail -n 10 "$LOG_PATH" 2>/dev/null || echo "(log not written yet)"
echo
echo "Installed. Follow the log with:"
echo "  tail -f $LOG_PATH"
echo
echo "Uninstall with:"
echo "  launchctl unload $AGENT_PATH && rm $AGENT_PATH $BIN_PATH"
