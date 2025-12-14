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
synchronizuj_katalogi() {
    local zrodlo="$1"
    local cel="$2"

    if [[ ! -d "$zrodlo" ]]; then
        log "Błąd: Katalog źródłowy '$zrodlo' nie istnieje!"
        return 1
    fi

    if [[ ! -d "$cel" ]]; then
        log "Tworzę katalog docelowy: '$cel'"
        mkdir -p "$cel"
    fi

    log "Rozpoczynam synchronizację: '$zrodlo' -> '$cel'"

    # rsync: -rlptgo (bez -D dla device/specials), --delete (usuwanie), verbose
    rsync -rlptgo --delete --verbose "$zrodlo/" "$cel/"

    if [ $? -ne 0 ]; then
        log "Błąd krytyczny rsync!"
        return 1
    fi

    log "Synchronizacja rsync zakończona. Weryfikacja diff..."

    # Test różnicowy (pomijamy sockety i fifo w wynikach grepa)
    DIFF_OUT=$(diff -r -q "$zrodlo" "$cel" 2>/dev/null | grep -vE "socket|fifo")
    
    if [ -z "$DIFF_OUT" ]; then
        log "SUKCES: Katalogi są zsynchronizowane."
    else
        log "UWAGA: Wykryto różnice:"
        echo "$DIFF_OUT"
    fi
}

obsluga_git() {
    local url_repo="$1"
    local katalog_docelowy="$2"

    # 1. Sprawdzenie czy katalog istnieje i czy to repozytorium GIT (Wykrywanie)
    if [ -d "$katalog_docelowy/.git" ]; then
        log "Wykryto istniejące repozytorium w: $katalog_docelowy"
        log "Rozpoczynam aktualizację (git pull)..."

        # Przejście do katalogu, wykonanie pull i powrót
        # Używamy nawiasów ( ... ), żeby zmiana katalogu była tylko lokalna dla tych komend
        (
            cd "$katalog_docelowy" || exit
            git pull
        )

        if [ $? -eq 0 ]; then
            log "SUKCES: Repozytorium zaktualizowane."
        else
            log "BŁĄD: Nie udało się zaktualizować repozytorium."
        fi

    elif [ -d "$katalog_docelowy" ]; then
        # Katalog istnieje, ale nie ma tam .git
        log "BŁĄD: Katalog '$katalog_docelowy' istnieje, ale to nie jest repozytorium Git! Pomijam."
    else
        # 2. Katalog nie istnieje -> Klonowanie
        log "Katalog nie istnieje. Rozpoczynam klonowanie (git clone)..."
        git clone "$url_repo" "$katalog_docelowy"

        if [ $? -eq 0 ]; then
            log "SUKCES: Repozytorium sklonowane do '$katalog_docelowy'."
        else
            log "BŁĄD: Nie udało się sklonować repozytorium."
        fi
    fi
}
mkdir -p "$LOG_DIR"

log "start"

while true; do
    echo "----------------------------------------"
    echo "MENU GŁÓWNE BACKUPU:"
    echo "1. Synchronizacja katalogów"
    echo "2. Rezpoztoria Git clone/pull"
    echo "0. Wyjście"
    echo "----------------------------------------"
    read -p "Wybierz opcję: " opcja

    case "$opcja" in
        1)
            echo "--- Synchronizacja Katalogów ---"
            read -p "Podaj katalog źródłowy: " src
            read -p "Podaj katalog docelowy: " dst
            # Wywołanie funkcji zdefiniowanej wyżej
            synchronizuj_katalogi "$src" "$dst"
            ;;
        2)
            echo "--- Obsługa Repozytoriów Git ---"
            read -p "Podaj URL repozytorium (np. https://github.com/...): " repo_url
            read -p "Podaj katalog docelowy (ścieżka lokalna): " repo_dir

            if [ -z "$repo_url" ] || [ -z "$repo_dir" ]; then
                echo "Błąd: Musisz podać URL i katalog."
            else
                obsluga_git "$repo_url" "$repo_dir"
            fi
            ;;
        0)
            echo "Kończenie pracy..."
            break
            ;;
        *)
            echo "Nieprawidłowa opcja, spróbuj ponownie."
            ;;
    esac
done

echo "h"
log "stop"
