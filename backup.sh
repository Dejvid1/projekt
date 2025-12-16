#!/bin/bash
set -u

CONFIG_DIR="$HOME/backup_project"
CONFIG_FILE="$CONFIG_DIR/backup.conf"
LOCK_FILE="$CONFIG_DIR/backup.lock"

if [ -f "$LOCK_FILE" ]; then
    echo "Skrypt juz jest uruchomiony (plik lock istnieje)."
    exit 1
fi
touch "$LOCK_FILE"

trap 'rm -f "$LOCK_FILE"' EXIT

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Blad: Brak pliku konfiguracyjnego $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
CURRENT_PERIOD=$(date "+$PERIOD_FORMAT")
LOG_FILE="$LOG_DIR/log_$(date +%F).txt"

mkdir -p "$LOG_DIR"
mkdir -p "$TEMP_DIR"

log() {
    local MESS=$1
    local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$TIMESTAMP $MESS" >> "$LOG_FILE"
    if [ -t 1 ]; then echo "$TIMESTAMP $MESS"; fi
}

check_space_on_disk() {
    if [ ! -d "$LOCAL_BACKUP_BASE" ]; then
        mkdir -p "$LOCAL_BACKUP_BASE"
    fi
    
    local required=${MIN_DISK_SPACE_MB:-100}
    local available=$(df -m "$LOCAL_BACKUP_BASE" | awk 'NR==2 {print $4}')

    log "Dysk: Dostepne ${available} MB (Wymagane: ${required} MB)"

    if [[ "$available" -lt "$required" ]]; then
        log "BLAD KRYTYCZNY: Za malo miejsca na dysku! Przerywam."
        return 1
    fi
    return 0
}

check_remote_host() {
    log "Sprawdzanie dostepnosci hosta zdalnego: $REMOTE_HOST..."
    
    ping -c 1 -W 2 "$REMOTE_HOST" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log "BLAD: Host zdalny $REMOTE_HOST nie odpowiada na ping."
        return 1
    fi

    ssh -p "$REMOTE_PORT" -q -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_HOST" exit
    if [ $? -ne 0 ]; then
        log "BLAD: Nie mozna nawiazac polaczenia SSH z $REMOTE_HOST."
        return 1
    fi

    log "SUKCES: Host zdalny dostepny."
    return 0
}

synchronize_dir() {
    local source="$1"
    local target="$2"

    if [[ ! -d "$source" ]]; then
        log "Blad: Katalog zrodlowy '$source' nie istnieje!"
        return 1
    fi

    if [[ ! -d "$target" ]]; then
        mkdir -p "$target"
    fi

    log "Rozpoczynam synchronizacje rsync (katalog): '$source' -> '$target'"

    rsync -rlptgo -v  --delete $EXCLUDE_PARAMS "$source/" "$target/" >> "$LOG_FILE" 2>&1

    if [ $? -ne 0 ]; then
        log "Blad krytyczny rsync!"
        return 1
    fi

    log "Synchronizacja rsync zakonczona."
}

synchronize_git() {
    local source_path="$1"
    local target_dir="$2"

    
    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir"
    fi

    
    if [ -f "$target_dir/HEAD" ] || [ -d "$target_dir/.git" ]; then
        log "Aktualizacja istniejacego repozytorium w: $target_dir"
        (
            cd "$target_dir" || exit
            git remote update >> "$LOG_FILE" 2>&1
        )
        if [ $? -eq 0 ]; then
            log "SUKCES: Repozytorium zaktualizowane."
        else
            log "BLAD: Nie udalo sie zaktualizowac repozytorium."
        fi
    else
        
        log "Klonowanie nowego repozytorium (mirror) do: $target_dir"
        
        
        rmdir "$target_dir" 2>/dev/null 

        git clone --mirror "$source_path" "$target_dir" >> "$LOG_FILE" 2>&1
        if [ $? -eq 0 ]; then
            log "SUKCES: Repozytorium sklonowane."
        else
            log "BLAD: Nie udalo sie sklonowac repozytorium."
        fi
    fi
}

archive_previous_periods() {
    log "Sprawdzanie czy istnieja stare okresy do archiwizacji..."
    
    find "$LOCAL_BACKUP_BASE" -maxdepth 1 -mindepth 1 -type d | while read dir_path; do
        local dir_name=$(basename "$dir_path")
        
        if [ "$dir_name" == "$CURRENT_PERIOD" ]; then
            continue
        fi

        log "Wykryto zakonczony okres: $dir_name. Rozpoczynam archiwizacje."

        if ! check_remote_host; then
            log "BLAD: Pomijam archiwizacje $dir_name z powodu braku polaczenia."
            continue
        fi

        local archive_name="backup_${dir_name}.tar.gz"
        local archive_path="$TEMP_DIR/$archive_name"

        log "Kompresja katalogu: $dir_path -> $archive_path"
        tar -czf "$archive_path" -C "$LOCAL_BACKUP_BASE" "$dir_name" >> "$LOG_FILE" 2>&1

        if [ $? -ne 0 ]; then
            log "BLAD: Kompresja nie powiodla sie."
            rm -f "$archive_path"
            continue
        fi

        log "Wysylanie archiwum na zdalny host..."
        ssh -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_DEST_DIR"
        scp -P "$REMOTE_PORT" "$archive_path" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DEST_DIR/" >> "$LOG_FILE" 2>&1

        if [ $? -eq 0 ]; then
            log "SUKCES: Archiwum wyslane. Usuwanie kopii lokalnej i tymczasowej."
            rm -rf "$dir_path"
            rm -f "$archive_path"
        else
            log "BLAD: Nie udalo sie wyslac archiwum. Pozostawiam dane lokalnie."
        fi
    done
}

log "--- START SKRYPTU BACKUPU: $CURRENT_TIME ---"

if ! check_space_on_disk; then 
    exit 1
fi

CURRENT_PERIOD_DIR="$LOCAL_BACKUP_BASE/$CURRENT_PERIOD"
REPO_DEST_BASE="$CURRENT_PERIOD_DIR/repozytoria"
FILES_DEST_BASE="$CURRENT_PERIOD_DIR/zasoby_archiwalne"

if [ ! -d "$CURRENT_PERIOD_DIR" ]; then
    log "Tworzenie struktury katalogow dla nowego okresu: $CURRENT_PERIOD"
    mkdir -p "$CURRENT_PERIOD_DIR"
    mkdir -p "$REPO_DEST_BASE"
    mkdir -p "$FILES_DEST_BASE"
fi

for src in "${SOURCES[@]}"; do
    if [ -z "$src" ]; then continue; fi

    dir_name=$(basename "$src")
    
    if [[ "$dir_name" == *" "* ]]; then
        log "UWAGA: Nazwa katalogu zawiera spacje: '$dir_name'. Przetwarzam bezpiecznie."
    fi

    if [ -d "$src/.git" ]; then
        dst="$REPO_DEST_BASE/$dir_name.git"
        log "Zadanie: Synchronizacja repozytorium GIT: $src"
        synchronize_git "$src" "$dst"
    else
        dst="$FILES_DEST_BASE/$dir_name"
        log "Zadanie: Synchronizacja katalogu plikow: $src"
        synchronize_dir "$src" "$dst"
    fi
done

archive_previous_periods

rm -f "$LOCK_FILE"
log "--- STOP SKRYPTU BACKUPU ---"
