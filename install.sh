#!/bin/bash

set -e

echo "=== Dynamischer Swap-Manager Installer ==="

# Abfragen der Parameter
read -rp "Intervall in Sekunden (Standard 30): " CHECK_INTERVAL
CHECK_INTERVAL=${CHECK_INTERVAL:-30}

read -rp "Ziel freier RAM in MB (Standard 8192 = 8GB): " TARGET_FREE_RAM_MB
TARGET_FREE_RAM_MB=${TARGET_FREE_RAM_MB:-8192}

read -rp "Größe je Swapfile in MB (Standard 512): " SWAP_CHUNK_MB
SWAP_CHUNK_MB=${SWAP_CHUNK_MB:-512}

read -rp "Verzeichnis für Swapfiles (Standard /media/nvme_pool1/swapfiles): " SWAP_DIR
SWAP_DIR=${SWAP_DIR:-/media/nvme_pool1/swapfiles}

read -rp "Logdatei Pfad (Standard /var/log/dynamic_swap.log): " LOG_FILE
LOG_FILE=${LOG_FILE:-/var/log/dynamic_swap.log}

echo "Wähle Methode zum Erstellen der Swapfile:"
echo "  1) dd (sicher, keine Löcher)"
echo "  2) fallocate (schneller, kann Probleme machen)"
read -rp "Auswahl (1 oder 2, Standard 1): " METHOD_CHOICE
METHOD_CHOICE=${METHOD_CHOICE:-1}

if [[ "$METHOD_CHOICE" == "1" ]]; then
    METHOD="dd"
else
    METHOD="fallocate"
fi

echo
echo "Installiere mit folgenden Einstellungen:"
echo "Intervall: $CHECK_INTERVAL s"
echo "Ziel freier RAM: $TARGET_FREE_RAM_MB MB"
echo "Swapfile Größe: $SWAP_CHUNK_MB MB"
echo "Swapverzeichnis: $SWAP_DIR"
echo "Logdatei: $LOG_FILE"
echo "Erstellungsmethode: $METHOD"
echo

# Verzeichnis anlegen
mkdir -p "$SWAP_DIR"
touch "$LOG_FILE"

# Dynamisches Swap-Manager-Script schreiben
cat << EOF | sudo tee /usr/local/bin/dynamic_swap_manager.sh > /dev/null
#!/bin/bash

CHECK_INTERVAL=$CHECK_INTERVAL
TARGET_FREE_RAM_MB=$TARGET_FREE_RAM_MB
SWAP_CHUNK_MB=$SWAP_CHUNK_MB
SWAP_DIR="$SWAP_DIR"
LOG_FILE="$LOG_FILE"
METHOD="$METHOD"

mkdir -p "\$SWAP_DIR"
touch "\$LOG_FILE"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG_FILE"
}

log "Starte dynamischen Swap-Manager..."
log "Entferne alte Swap-Dateien aus \$SWAP_DIR ..."
for swapfile in \$(swapon --noheadings --show=NAME | grep "\$SWAP_DIR" || true); do
    sudo swapoff "\$swapfile"
    sudo rm -f "\$swapfile"
    log "Alte Swap-Datei deaktiviert und gelöscht: \$swapfile"
done
find "\$SWAP_DIR" -type f -name "swapfile_*" -exec rm -f {} \\;

get_free_ram_mb() {
    free -m | awk '/^Mem:/ {print \$7}'
}

get_active_swapfiles() {
    swapon --noheadings --show=NAME | grep "\$SWAP_DIR" || true
}

create_swapfile() {
    local id=\$(date +%s)
    local file="\$SWAP_DIR/swapfile_\$id"
    if [ "\$METHOD" = "dd" ]; then
        sudo dd if=/dev/zero of="\$file" bs=1M count=\$SWAP_CHUNK_MB status=none
    else
        sudo fallocate -l \$((SWAP_CHUNK_MB))M "\$file"
    fi
    sudo chmod 600 "\$file"
    sudo mkswap "\$file" >/dev/null
    sudo swapon "\$file"
    log "Swap-Datei erstellt und aktiviert: \$file (\${SWAP_CHUNK_MB}MB)"
}

remove_one_swapfile() {
    local file
    file=\$(get_active_swapfiles | head -n 1)
    if [ -n "\$file" ]; then
        sudo swapoff "\$file"
        sudo rm -f "\$file"
        log "Swap-Datei deaktiviert und gelöscht: \$file"
    fi
}

while true; do
    FREE_RAM=\$(get_free_ram_mb)
    ACTIVE_SWAP_COUNT=\$(get_active_swapfiles | wc -l)

    log "Freier RAM: \${FREE_RAM} MB, Aktive Swap-Dateien: \$ACTIVE_SWAP_COUNT"

    if (( FREE_RAM < TARGET_FREE_RAM_MB )); then
        create_swapfile
    elif (( FREE_RAM > TARGET_FREE_RAM_MB )) && (( ACTIVE_SWAP_COUNT > 0 )); then
        remove_one_swapfile
    fi

    sleep \$CHECK_INTERVAL
done
EOF

sudo chmod +x /usr/local/bin/dynamic_swap_manager.sh

# Systemd-Service anlegen
cat << EOF | sudo tee /etc/systemd/system/dynamic-swap.service > /dev/null
[Unit]
Description=Dynamischer Swap-Manager (8GB RAM freihalten)
After=network.target

[Service]
ExecStart=/usr/local/bin/dynamic_swap_manager.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Systemd neu laden und Service starten
sudo systemctl daemon-reload
sudo systemctl enable dynamic-swap.service
sudo systemctl start dynamic-swap.service

echo
echo "Installation abgeschlossen. Der Dienst läuft jetzt."
echo "Logs kannst du mit folgendem Befehl ansehen:"
echo "  sudo journalctl -u dynamic-swap.service -f"
