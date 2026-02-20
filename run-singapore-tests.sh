#!/bin/bash
#
# DEPRECATED: Use run-region-tests.sh instead
#
# This script is maintained for backward compatibility.
# It redirects to the new multi-region test runner.
#
# Usage:
#   ./run-singapore-tests.sh        # Runs Singapore tests
#   ./run-region-tests.sh singapore # Same thing
#   ./run-region-tests.sh thailand  # Runs Thailand tests
#

echo "⚠ WARNING: run-singapore-tests.sh is deprecated"
echo "Please use: ./run-region-tests.sh singapore"
echo ""
echo "Redirecting to run-region-tests.sh..."
echo ""

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the new script with singapore as the region
exec "$SCRIPT_DIR/run-region-tests.sh" singapore
