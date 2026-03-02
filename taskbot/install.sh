#!/bin/bash
#
# taskbot install — adds taskbot to PATH
#

set -euo pipefail

TASKBOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHELL_RC=""

# Detect shell config file
if [ -n "${ZSH_VERSION:-}" ] || [ "$SHELL" = "/bin/zsh" ]; then
  SHELL_RC="$HOME/.zshrc"
elif [ -n "${BASH_VERSION:-}" ] || [ "$SHELL" = "/bin/bash" ]; then
  SHELL_RC="$HOME/.bashrc"
fi

if [ -z "$SHELL_RC" ]; then
  echo "Could not detect shell. Add this to your shell config manually:"
  echo "  export PATH=\"$TASKBOT_DIR:\$PATH\""
  exit 1
fi

# Check if already installed
if grep -q "taskbot" "$SHELL_RC" 2>/dev/null; then
  echo "taskbot is already in $SHELL_RC"
else
  echo "" >> "$SHELL_RC"
  echo "# taskbot — unattended Claude agent task runner" >> "$SHELL_RC"
  echo "export PATH=\"$TASKBOT_DIR:\$PATH\"" >> "$SHELL_RC"
  echo "Added taskbot to PATH in $SHELL_RC"
fi

# Make scripts executable
chmod +x "$TASKBOT_DIR/taskbot.sh"
chmod +x "$TASKBOT_DIR/configure.sh"

echo ""
echo "Run 'source $SHELL_RC' or open a new terminal, then:"
echo "  taskbot.sh <project-dir> [task-number] [--all] [--dry-run]"
echo "  taskbot.sh <project-dir> --configure"
