#!/bin/bash

# === Default-Werte ===
DEFAULT_CHECK_INTERVAL=30
DEFAULT_TARGET_FREE_RAM_MB=16384
DEFAULT_SWAP_CHUNK_MB=1024
DEFAULT_SWAP_DIR="/media/nvme_pool1/swapfiles"
DEFAULT_LOG_FILE="/var/log/dynamic_swap.log"
DEFAULT_USE_FALLOCATE=true

echo "== Dynamischer Swap Installer =="

read -p "Intervall in Sekunden [$DEFAULT_CHECK_INTERVAL]: " CHECK_INTERVAL
read -p "RAM-Ziel in MB [$DEFAULT_TARGET_FREE_RAM_MB]: " TARGET_FREE_RAM_MB
read -p "Swapfile-Größe in MB [$DEFAULT_SWAP_CHUNK_MB]: " SWAP_CHUNK_MB
read -p "Swap-Verzeichnis [$DEFAULT_SWAP_DIR]: " SWAP_DIR
read -p "Logdatei [$DEFAULT_LOG_FILE]: " LOG_FILE
read -p "fallocate verwenden? (true/false) [$DEFAULT_USE_FALLOCATE]: " USE_FALLOCATE

# Standardwerte setzen, wenn leer
CHECK_INTERVAL=${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}
TARGET_FREE_RAM_MB=${TARGET_FREE_RAM_MB:-$DEFAULT_TARGET_FREE_RAM_MB}
SWAP_CHUNK_MB=${SWAP_CHUNK_MB:-$DEFAULT_SWAP_CHUNK_MB}
SWAP_DIR=${SWAP_DIR:-$DEFAULT_SWAP_DIR}
LOG_FILE=${LOG_FILE:-$DEFAULT_LOG_FILE}
USE_FALLOCATE=${USE_FALLOCATE:-$DEFAULT_USE_FALLOCATE}

# === Script-Pfad ===
SCRIPT_PATH="/usr/local/bin/dynamic_swap_manager.sh"

echo "→ Installiere Script nach $SCRIPT_PATH"

# === Erstelle das Script ===
cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash

CHECK_INTERVAL=$CHECK_INTERVAL
TARGET_FREE_RAM_MB=$TARGET_FREE_RAM_MB
SWAP_CHUNK_MB=$SWAP_CHUNK_MB
SWAP_DIR="$SWAP_DIR"
LOG_FILE="$LOG_FILE"
USE_FALLOCATE=$USE_FALLOCATE

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" | tee -a "\$LOG_FILE"
}

get_free_ram_mb() {
    awk '/MemAvailable/ {print int(\$2/1024)}' /proc/meminfo
}

get_total_swap_used_kb() {
    awk '/SwapTotal/ {total=\$2} /SwapFree/ {free=\$2} END {print total - free}' /proc/meminfo
}

get_total_swap_kb() {
    awk '/SwapTotal/ {print \$2}' /proc/meminfo
}

create_swapfile() {
    local swapfile="\$1"
    local size_mb="\$2"

    if [ "\$USE_FALLOCATE" = true ]; then
        fallocate -l "\${size_mb}M" "\$swapfile"
    else
        dd if=/dev/zero of="\$swapfile" bs=1M count="\$size_mb" status=none
    fi

    chmod 600 "\$swapfile"
    mkswap "\$swapfile"
}

activate_swapfile() {
    swapon "\$1"
}

deactivate_swapfile() {
    swapoff "\$1"
    rm -f "\$1"
}

get_active_swapfiles() {
    swapon --show=NAME --noheadings | grep "^\\\$SWAP_DIR" || true
}

cleanup_swapfiles() {
    if [ -d "\$SWAP_DIR" ]; then
        for f in "\$SWAP_DIR"/swapfile_*; do
            if [ -f "\$f" ]; then
                log "Cleanup: Deaktiviere und lösche alten Swapfile \$f"
                swapoff "\$f" 2>/dev/null || true
                rm -f "\$f"
            fi
        done
    fi
}

mkdir -p "\$SWAP_DIR"
touch "\$LOG_FILE"
log "Starte dynamischen Swapmanager mit Ziel \$TARGET_FREE_RAM_MB MB freiem RAM..."

cleanup_swapfiles

while true; do
    free_ram=\$(get_free_ram_mb)
    swap_used_kb=\$(get_total_swap_used_kb)
    swap_total_kb=\$(get_total_swap_kb)

    log "Freier RAM: \${free_ram}MB, Swap benutzt: \$((swap_used_kb/1024))MB, Swap gesamt: \$((swap_total_kb/1024))MB"

    if [ "\$free_ram" -ge "\$TARGET_FREE_RAM_MB" ]; then
        active_swaps=(\$(get_active_swapfiles))
        if [ "\${#active_swaps[@]}" -gt 0 ]; then
            for swapfile in \$(printf '%s\n' "\${active_swaps[@]}" | sort); do
                log "Deaktiviere und lösche Swapfile \$swapfile, weil genügend RAM frei ist."
                deactivate_swapfile "\$swapfile"
                free_ram=\$(get_free_ram_mb)
                if [ "\$free_ram" -lt "\$TARGET_FREE_RAM_MB" ]; then
                    log "Freier RAM jetzt unter Ziel, stoppe weitere Swap-Deaktivierung."
                    break
                fi
            done
        fi
    else
        if [ "\$swap_total_kb" -eq 0 ] || [ "\$swap_used_kb" -ge \$((swap_total_kb * 80 / 100)) ]; then
            timestamp=\$(date +%s)
            new_swapfile="\$SWAP_DIR/swapfile_\${timestamp}"
            log "RAM zu knapp und Swap >80% voll, erstelle neuen Swapfile \$new_swapfile (\${SWAP_CHUNK_MB}MB)."
            create_swapfile "\$new_swapfile" "\$SWAP_CHUNK_MB"
            activate_swapfile "\$new_swapfile"
            log "Swapfile erstellt und aktiviert: \$new_swapfile"
        else
            log "RAM zu knapp, aber Swap noch nicht voll genug, keine neue Swapfile."
        fi
    fi

    sleep "\$CHECK_INTERVAL"
done
EOF

chmod +x "$SCRIPT_PATH"

# === systemd-Service ===
SERVICE_PATH="/etc/systemd/system/dynamic-swap.service"
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Dynamischer Swap-Manager (RAM überwacht & dynamisch swappt)
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# === Systemd aktivieren ===
systemctl daemon-reload
systemctl enable dynamic-swap.service
systemctl restart dynamic-swap.service

echo "✅ Installation abgeschlossen!"
echo "→ Service läuft: systemctl status dynamic-swap.service"
echo "→ Logfile: $LOG_FILE"
