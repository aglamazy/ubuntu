#!/bin/bash

# The path to the battery status
BATTERY_STATUS_PATH="/sys/class/power_supply/BAT0/status"

# Last known status
LAST_STATUS=""

while true; do
  CURRENT_STATUS=$(cat $BATTERY_STATUS_PATH)

  if [ "$CURRENT_STATUS" != "$LAST_STATUS" ]; then
    echo "Status changed to $CURRENT_STATUS"
    LAST_STATUS=$CURRENT_STATUS

    case $CURRENT_STATUS in
      "Charging")
        echo "Apply AC power settings."
	powerprofilesctl set balanced
        ;;
      "Discharging")
        echo "Apply Battery power settings."
	powerprofilesctl set power-saver
        ;;
      "Full"|"Not charging")
        echo "Battery is full."
	powerprofilesctl set performance
        ;;
    esac
  fi
  if [ "$CURRENT_STATUS" != "$LAST_STATUS" ]; then
    echo "Status changed to $CURRENT_STATUS"
    LAST_STATUS=$CURRENT_STATUS

    case $CURRENT_STATUS in
      "Charging")
        echo "Apply AC power settings."
        powerprofilesctl set balanced
        ;;
      "Discharging")
        echo "Apply Battery power settings."
        powerprofilesctl set power-saver
        ;;
      "Full"|"Not charging")
	echo "Battery is full."
        powerprofilesctl set performance
        ;;
    esac
  fi

  sleep 60 # check every 60 seconds
done

