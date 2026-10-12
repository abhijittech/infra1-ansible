#!/usr/bin/env bash
# pitaas-dev-1: probe pitaas_v3-db-1 network connectivity
# Output format (two sections, separated by '---'):
#   <network names, one per line>
#   ---
#   <comma-separated aliases on mariadb-network>
set -e

NETWORKS_JSON=$(docker inspect pitaas_v3-db-1 --format '{{ json .NetworkSettings.Networks }}')

# First section: network names
echo "$NETWORKS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for name in sorted(d.keys()):
    print(name)
"

# Separator
echo "---"

# Second section: aliases on mariadb-network
echo "$NETWORKS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'mariadb-network' in d:
    print(','.join(d['mariadb-network'].get('Aliases', [])))
else:
    print('')
"
