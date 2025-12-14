#!/bin/bash

#BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG_DIR="$HOME/backup_project"
CONFIG_FILE="$CONFIG_DIR/backup.conf"

LOCK_FILE="$CONFIG_DIR/backup.lock"


#LOG_FILE="$CONFIG_DIR/logs/run.log"

if [ -f "$LOCK_FILE" ]; then 
	echo "Skrypt juz jest uruchomiony"
	exit 1
fi	
touch "$LOCK_FILE"

trap 'rm -f "$LOCK_FILE"' EXIT

mkdir -p "$CONFIG_DIR/logs"

if [ ! -f "$CONFIG_FILE" ];  then
	echo "brak pliku konfiguracyjnego $CONFIG_FILE"
	exit 1
fi 

source "$CONFIG_FILE"

CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
CURRENT_PERIOD=$(date "+$PERIOD_FORMAT")
LOG_FILE="$LOG_DIR/log_$CURRENT_PERIOD.txt"
log(){
	local MESS=$1
	local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
	echo "$TIMESTAMP $MESS" >> "$LOG_FILE"
	if [ -t 1 ]; then echo "$TIMESTAMP $MESS"; fi
}
mkdir -p "$LOG_DIR"

log "start"
echo "h"
log "stop"

