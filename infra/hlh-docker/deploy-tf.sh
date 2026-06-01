#!/bin/bash
# Get PVE ticket
RESPONSE=$(curl -sk -X POST "https://192.168.1.10:8006/api2/json/access/ticket" \
  -d "username=root@pam" -d "password=Stfoms08!2025" 2>/dev/null)
TICKET=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d['ticket'])")
CSRF=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d['CSRFPreventionToken'])")
echo "Ticket acquired"

# Update tofu token permissions via API
curl -sk -b "PVEAuthCookie=$TICKET" \
  -H "CSRFPreventionToken: $CSRF" \
  -X PUT "https://192.168.1.10:8006/api2/json/access/tokens/tofu%40pve!tofu-hlh-docker" \
  -d "privs=LXC.Allocate;VM.Allocate;VM.Config.Disk;VM.Config.Network;VM.PowerMgmt;Datastore.Allocate;Datastore.AllocateSpace" \
  -d "path=/nodes/prox01" 2>&1
echo ""
