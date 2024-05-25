#!/bin/bash

# Disk space threshold in Gigabytes
THRESHOLD=80


# List of disks to check (e.g., "/", "/data", etc.)
DISKS=("/" "/opt")

for DISK in "${DISKS[@]}"; do
    # Current available disk space in GB
    AVAILABLE_SPACE=$(df -BG --output=avail "$DISK" | tail -n 1 | tr -d 'G ')
    echo $AVAILBLE_SPACE

    if [ "$AVAILABLE_SPACE" -lt "$THRESHOLD" ]; then
        SUBJECT="Disk Space Alert: Low disk space on $DISK"
        MESSAGE="Warning: The available disk space on $DISK is below ${THRESHOLD}GB. Currently, only ${AVAILABLE_SPACE}GB is available."

	    echo "$MESSAGE" | /opt/efresh/send_email "$SUBJECT" 

    fi
done

