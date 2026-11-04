#!/bin/bash
# =============================================================================
#  NS8 Install Script v3.0
#  Preparazione Rocky Linux + installazione NethServer 8
#  (swap, aggiornamenti automatici, rete, notifiche e-mail sui backup)
#
#  Interfaccia testuale basata su whiptail (stile raspi-config).
# =============================================================================

set -o pipefail

VERSION="3.0"
TITLE="NS8 Install Script v$VERSION"
LOG_FILE="/var/log/ns8-install.log"

NS8_DIR="/var/lib/nethserver"
NS8_INSTALLER_URL="https://raw.githubusercontent.com/NethServer/ns8-core/ns8-stable/core/install.sh"
EVENTS_DIR="$NS8_DIR/cluster/events/backup-status-changed"
NOTIFY_HOOK="$EVENTS_DIR/20notify"

SWAPFILE="/swapfile"
DEFAULT_SWAP_MB=4096
MIN_SWAP_MB=1024

TIMER_OVERRIDE_DIR="/etc/systemd/system/dnf-automatic.timer.d"
DNF_AUTOMATIC_CONF="/etc/dnf/automatic.conf"
DEFAULT_UPDATE_TIME="06:00"

# Parametri raccolti dai prompt
SWAP_SIZE=""
UPDATE_TIME=""
UPDATE_APPLY=""
MAIL_TO=""
MAIL_FROM=""

# =============================================================================
#  Utilità generali
# =============================================================================

log() {
	echo "[$(date '+%F %T')] $*" >>"$LOG_FILE"
}

# Esegue un comando mostrando l'output a video e salvandolo nel log.
# Restituisce il codice di uscita del comando.
run() {
	log "\$ $*"
	"$@" 2>&1 | tee -a "$LOG_FILE"
}

banner() {
	clear
	echo "=================================================================="
	echo "  $1"
	echo "=================================================================="
	echo
	log "=== $1 ==="
}

pause() {
	echo
	read -rp "Premi INVIO per continuare..." _
}

# Dimensioni delle finestre adattate al terminale (come raspi-config)
calc_size() {
	local lines cols
	lines=$(tput lines 2>/dev/null || echo 24)
	cols=$(tput cols 2>/dev/null || echo 80)
	WT_HEIGHT=$((lines - 4))
	((WT_HEIGHT > 22)) && WT_HEIGHT=22
	((WT_HEIGHT < 18)) && WT_HEIGHT=18
	WT_WIDTH=$((cols - 10))
	((WT_WIDTH > 78)) && WT_WIDTH=78
	((WT_WIDTH < 60)) && WT_WIDTH=60
	WT_MENU_HEIGHT=$((WT_HEIGHT - 9))
}

msg() {
	whiptail --title "$TITLE" --msgbox "$1" "$WT_HEIGHT" "$WT_WIDTH"
}

ask_yesno() {
	whiptail --title "$TITLE" --yes-button "Sì" --no-button "No" \
		--yesno "$1" "$WT_HEIGHT" "$WT_WIDTH"
}

# Stampa il valore inserito; restituisce 1 se l'utente annulla
ask_input() {
	whiptail --title "$TITLE" --ok-button "OK" --cancel-button "Annulla" \
		--inputbox "$1" "$WT_HEIGHT" "$WT_WIDTH" "$2" 3>&1 1>&2 2>&3
}

ns8_installed() {
	[[ -d "$NS8_DIR" ]]
}

current_swap_mb() {
	free -m | awk '/^Swap:/ {print $2}'
}

is_valid_email() {
	[[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

# Legge un valore (MAIL_TO / MAIL_FROM) dall'hook già esistente, se c'è
read_hook_value() {
	[[ -f "$NOTIFY_HOOK" ]] || return 0
	sed -n "s/^$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}\$/\1/p" "$NOTIFY_HOOK" | head -n1
}

# =============================================================================
#  Controlli iniziali
# =============================================================================

check_root() {
	if [[ $EUID -ne 0 ]]; then
		echo "Questo script deve essere eseguito come root (es: sudo $0)." >&2
		exit 1
	fi
}

ensure_whiptail() {
	command -v whiptail >/dev/null 2>&1 && return 0
	echo "whiptail non trovato: installo il pacchetto 'newt'..."
	if ! dnf install -y newt; then
		echo "Impossibile installare whiptail. Interrompo." >&2
		exit 1
	fi
}

# =============================================================================
#  Prompt (raccolta parametri) - restituiscono 1 se l'utente annulla
# =============================================================================

prompt_swap() {
	local value avail
	while true; do
		value=$(ask_input "Dimensione dello swap in MB (minimo $MIN_SWAP_MB).

Swap attuale: $(current_swap_mb) MB" "$DEFAULT_SWAP_MB") || return 1

		if [[ ! "$value" =~ ^[0-9]+$ ]] || ((10#$value < MIN_SWAP_MB)); then
			msg "Valore non valido: inserisci un numero intero di almeno $MIN_SWAP_MB MB."
			continue
		fi
		value=$((10#$value))

		avail=$(df -Pm / | awk 'NR==2 {print $4}')
		if [[ -n "$avail" ]] && ((value > avail - 1024)); then
			msg "Spazio su disco insufficiente: disponibili ${avail} MB su /, ne servono almeno $((value + 1024)) (swap + 1 GB di margine)."
			continue
		fi

		SWAP_SIZE=$value
		return 0
	done
}

prompt_updates() {
	local value
	while true; do
		value=$(ask_input "Orario giornaliero degli aggiornamenti automatici (HH:MM).

Verrà aggiunto un ritardo casuale fino a 10 minuti." "${UPDATE_TIME:-$DEFAULT_UPDATE_TIME}") || return 1
		if [[ "$value" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
			UPDATE_TIME=$value
			break
		fi
		msg "Orario non valido: usa il formato HH:MM (es: 06:00)."
	done

	if ask_yesno "Vuoi che gli aggiornamenti vengano anche INSTALLATI automaticamente?

Sì = scarica e installa (apply_updates = yes)
No = scarica soltanto, l'installazione resta manuale"; then
		UPDATE_APPLY="yes"
	else
		UPDATE_APPLY="no"
	fi
	return 0
}

prompt_mail() {
	local value
	while true; do
		value=$(ask_input "Indirizzo e-mail del DESTINATARIO delle notifiche sui backup:" \
			"${MAIL_TO:-$(read_hook_value MAIL_TO)}") || return 1
		is_valid_email "$value" && { MAIL_TO=$value; break; }
		msg "Indirizzo e-mail non valido: '$value'"
	done
	while true; do
		value=$(ask_input "Indirizzo e-mail del MITTENTE delle notifiche:" \
			"${MAIL_FROM:-$(read_hook_value MAIL_FROM)}") || return 1
		is_valid_email "$value" && { MAIL_FROM=$value; break; }
		msg "Indirizzo e-mail non valido: '$value'"
	done
	return 0
}

# =============================================================================
#  Azioni - restituiscono 0 se ok, diverso da 0 in caso di errore
# =============================================================================

apply_network() {
	log "Avvio nmtui"
	nmtui
}

apply_swap() {
	banner "Configurazione swap ($SWAP_SIZE MB)"

	if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
		run swapoff "$SWAPFILE" || return 1
	fi
	rm -f "$SWAPFILE"

	run dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_SIZE" status=progress || return 1
	chmod 600 "$SWAPFILE"
	run mkswap "$SWAPFILE" || return 1
	run swapon "$SWAPFILE" || return 1

	# Una sola riga per lo swapfile in fstab (rimuove anche i duplicati creati dalla v2.0)
	cp -a /etc/fstab /etc/fstab.bak-ns8-install
	sed -i "\|^[[:space:]]*$SWAPFILE[[:space:]]|d" /etc/fstab
	echo "$SWAPFILE   none   swap   defaults   0 0" >>/etc/fstab
	log "fstab aggiornato (backup in /etc/fstab.bak-ns8-install)"
	systemctl daemon-reload

	echo
	swapon --show | tee -a "$LOG_FILE"
}

apply_updates() {
	banner "Aggiornamenti automatici (ogni giorno alle $UPDATE_TIME)"

	run dnf upgrade -y || return 1
	run dnf install -y dnf-automatic curl nano || return 1

	mkdir -p "$TIMER_OVERRIDE_DIR" || return 1
	# "OnCalendar=" vuoto azzera l'orario originale del timer prima di impostare il nuovo
	cat >"$TIMER_OVERRIDE_DIR/override.conf" <<EOF
[Timer]
OnCalendar=
OnCalendar=*-*-* $UPDATE_TIME
RandomizedDelaySec=10m
Persistent=true
EOF

	if [[ -f "$DNF_AUTOMATIC_CONF" ]]; then
		sed -i -E "s/^[[:space:]]*apply_updates[[:space:]]*=.*/apply_updates = $UPDATE_APPLY/" "$DNF_AUTOMATIC_CONF"
		log "apply_updates = $UPDATE_APPLY in $DNF_AUTOMATIC_CONF"
	else
		echo "ATTENZIONE: $DNF_AUTOMATIC_CONF non trovato, apply_updates non modificato." | tee -a "$LOG_FILE"
	fi

	systemctl daemon-reload
	run systemctl enable --now dnf-automatic.timer || return 1
	echo
	systemctl list-timers dnf-automatic.timer --no-pager | tee -a "$LOG_FILE"
}

apply_ns8() {
	banner "Installazione NethServer 8"

	if ns8_installed; then
		echo "NethServer 8 è già installato: nessuna operazione." | tee -a "$LOG_FILE"
		return 0
	fi

	command -v curl >/dev/null 2>&1 || run dnf install -y curl || return 1

	log "\$ curl -fsSL $NS8_INSTALLER_URL | bash"
	curl -fsSL "$NS8_INSTALLER_URL" | bash 2>&1 | tee -a "$LOG_FILE" || return 1

	ns8_installed
}

apply_notify() {
	banner "Notifiche e-mail sui backup"

	if ! ns8_installed; then
		echo "NethServer 8 non è installato: impossibile configurare le notifiche." | tee -a "$LOG_FILE"
		return 1
	fi

	mkdir -p "$EVENTS_DIR" || return 1

	{
		echo '#!/bin/bash'
		echo
		echo '# Generato da NS8 Install Script - modificabile dal menu "Notifiche e-mail backup"'
		printf 'MAIL_FROM=%q\n' "$MAIL_FROM"
		printf 'MAIL_TO=%q\n' "$MAIL_TO"
		cat <<'SCRIPT_EOF'
MAIL_TEMPLATE="The backup status for {BACKUP_NAME} on {MODULE_ID} has changed to {STATUS}. Please check the system for details."

# WARNING - DO NOT EDIT BELOW THIS LINE (unless you know what you're doing)

# Redis command
rdb="redis-cli --raw"

# Read event data from stdin
read -r event_data
if ! echo "$event_data" | jq . >/dev/null 2>&1; then
	echo "Failed to parse JSON input" >&2
	exit 1
fi

# Extract necessary fields from event_data
module_id=$(echo "$event_data" | jq -r '.module_id')
backup_id=$(echo "$event_data" | jq -r '.backup_id')

leader_id=$($rdb hget cluster/environment NODE_ID)
self_id=$NODE_ID

if [[ "$self_id" != "$leader_id" ]]; then
	exit 0 # LEADER ONLY! Do not run this procedure in worker nodes.
fi
backup_name=$($rdb hget "cluster/backup/$backup_id" "name")

errors=$($rdb hget "module/$module_id/backup_status/$backup_id" errors)
if [[ -z "$errors" ]]; then
	echo "INFO: Status unknown, exiting." >&2
	exit 0
fi

if [[ "$errors" == "0" ]]; then
	status="SUCCESS"
else
	status="FAIL"
fi

# Send email
subject="$backup_name ($module_id): $status"
msg="$(echo "$MAIL_TEMPLATE" | sed "s/{BACKUP_NAME}/$backup_name/g; s/{STATUS}/$status/g; s/{MODULE_ID}/$module_id/g")"
echo "$msg" | runagent ns8-sendmail -s "$subject" -f "$MAIL_FROM" "$MAIL_TO"
SCRIPT_EOF
	} >"$NOTIFY_HOOK" || return 1

	chmod 755 "$NOTIFY_HOOK"
	echo "Hook creato: $NOTIFY_HOOK" | tee -a "$LOG_FILE"
	echo "Mittente: $MAIL_FROM  ->  Destinatario: $MAIL_TO" | tee -a "$LOG_FILE"
}

# Mostra l'esito di un'azione singola lanciata dal menu
finish_step() {
	local name=$1 rc=$2
	pause
	if [[ $rc -eq 0 ]]; then
		msg "$name: operazione completata."
	else
		msg "$name: operazione NON riuscita.

Controlla il log: $LOG_FILE"
	fi
}

# =============================================================================
#  Installazione guidata
# =============================================================================

guided_install() {
	local choices ns8_label ns8_default c summary
	local do_network=0 do_swap=0 do_updates=0 do_ns8=0 do_notify=0

	if ns8_installed; then
		ns8_label="Installa NethServer 8 (già installato)"
		ns8_default=OFF
	else
		ns8_label="Installa NethServer 8"
		ns8_default=ON
	fi

	choices=$(whiptail --title "$TITLE - Installazione guidata" --separate-output \
		--ok-button "Avanti" --cancel-button "Indietro" \
		--checklist "Scegli cosa configurare.
SPAZIO = seleziona/deseleziona, INVIO = conferma" \
		"$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU_HEIGHT" \
		NETWORK "Rete e hostname (nmtui)" OFF \
		SWAP "Swap" ON \
		UPDATES "Aggiornamenti automatici Rocky Linux" ON \
		NS8 "$ns8_label" "$ns8_default" \
		NOTIFY "Notifiche e-mail sui backup" ON \
		3>&1 1>&2 2>&3) || return 0

	while read -r c; do
		case "$c" in
		NETWORK) do_network=1 ;;
		SWAP) do_swap=1 ;;
		UPDATES) do_updates=1 ;;
		NS8) do_ns8=1 ;;
		NOTIFY) do_notify=1 ;;
		esac
	done <<<"$choices"

	if ((do_network + do_swap + do_updates + do_ns8 + do_notify == 0)); then
		msg "Nessuna operazione selezionata."
		return 0
	fi

	# Le notifiche richiedono NethServer 8
	if ((do_notify && !do_ns8)) && ! ns8_installed; then
		if ask_yesno "Le notifiche sui backup richiedono NethServer 8, che non è installato.

Vuoi aggiungere anche l'installazione di NethServer 8?"; then
			do_ns8=1
		else
			do_notify=0
		fi
	fi

	# --- Raccolta parametri (tutto prima, così l'installazione procede senza interruzioni)
	if ((do_swap)); then prompt_swap || { msg "Installazione annullata."; return 0; }; fi
	if ((do_updates)); then prompt_updates || { msg "Installazione annullata."; return 0; }; fi
	if ((do_notify)); then prompt_mail || { msg "Installazione annullata."; return 0; }; fi

	# --- Riepilogo
	summary="Verranno eseguite le seguenti operazioni:
"
	((do_network)) && summary+="
 - Rete e hostname: apertura di nmtui"
	((do_swap)) && summary+="
 - Swap: $SWAP_SIZE MB su $SWAPFILE"
	((do_updates)) && summary+="
 - Aggiornamenti: ogni giorno alle $UPDATE_TIME, installazione automatica: $UPDATE_APPLY"
	((do_ns8)) && summary+="
 - Installazione NethServer 8"
	((do_notify)) && summary+="
 - Notifiche backup (dopo NS8): da $MAIL_FROM a $MAIL_TO"
	summary+="

Procedere?"

	ask_yesno "$summary" || { msg "Installazione annullata."; return 0; }

	# --- Esecuzione
	local results=() failed=0
	log "##### Installazione guidata avviata #####"

	if ((do_network)); then
		apply_network
		results+=("[OK]       Rete e hostname")
	fi

	if ((do_swap)); then
		if apply_swap; then results+=("[OK]       Swap ($SWAP_SIZE MB)"); else results+=("[ERRORE]   Swap"); failed=1; fi
	fi

	if ((do_updates)); then
		if apply_updates; then results+=("[OK]       Aggiornamenti automatici ($UPDATE_TIME)"); else results+=("[ERRORE]   Aggiornamenti automatici"); failed=1; fi
	fi

	local ns8_ok=1
	if ((do_ns8)); then
		if apply_ns8; then results+=("[OK]       NethServer 8"); else results+=("[ERRORE]   NethServer 8"); failed=1; ns8_ok=0; fi
	fi

	# Le notifiche vengono configurate SOLO al termine dell'installazione di NS8
	if ((do_notify)); then
		if ((!ns8_ok)); then
			results+=("[SALTATO]  Notifiche backup (NethServer 8 non installato)")
		elif apply_notify; then
			results+=("[OK]       Notifiche backup")
		else
			results+=("[ERRORE]   Notifiche backup"); failed=1
		fi
	fi

	log "##### Installazione guidata terminata (errori: $failed) #####"
	pause

	local text="Riepilogo installazione:
"
	for c in "${results[@]}"; do text+="
$c"; done
	if ((failed)); then
		text+="

Alcune operazioni non sono riuscite: controlla il log $LOG_FILE"
	fi
	if ((do_ns8 && ns8_ok)); then
		text+="

Prossimi passi: apri l'interfaccia web di NethServer 8, crea il cluster e configura il server SMTP per l'invio delle notifiche."
	fi
	msg "$text"
}

# =============================================================================
#  Voci singole del menu
# =============================================================================

menu_swap() {
	prompt_swap || return 0
	ask_yesno "Verrà creato uno swap di $SWAP_SIZE MB su $SWAPFILE.

Procedere?" || return 0
	apply_swap
	finish_step "Swap" $?
}

menu_updates() {
	prompt_updates || return 0
	ask_yesno "Aggiornamenti automatici ogni giorno alle $UPDATE_TIME.
Installazione automatica: $UPDATE_APPLY

Prima verrà eseguito un aggiornamento completo del sistema (dnf upgrade).

Procedere?" || return 0
	apply_updates
	finish_step "Aggiornamenti automatici" $?
}

menu_notify() {
	if ! ns8_installed; then
		msg "NethServer 8 non è installato.

Le notifiche si possono configurare solo dopo l'installazione di NethServer 8 (dall'installazione guidata o dalla voce 'Installa solo NethServer 8')."
		return 0
	fi
	prompt_mail || return 0
	ask_yesno "Notifiche sui backup:
 Mittente:     $MAIL_FROM
 Destinatario: $MAIL_TO

Procedere?" || return 0
	apply_notify
	finish_step "Notifiche backup" $?
}

menu_network() {
	apply_network
}

menu_ns8() {
	if ns8_installed; then
		msg "NethServer 8 è già installato."
		return 0
	fi
	ask_yesno "Verrà installato NethServer 8 senza altre modifiche al sistema.

Procedere?" || return 0
	apply_ns8
	local rc=$?
	if [[ $rc -eq 0 ]] && ask_yesno "NethServer 8 è installato.

Vuoi configurare ora le notifiche e-mail sui backup?"; then
		if prompt_mail; then
			apply_notify
			finish_step "Notifiche backup" $?
		fi
		return 0
	fi
	finish_step "Installazione NethServer 8" $rc
}

# =============================================================================
#  Menu principale
# =============================================================================

main_menu() {
	local choice status
	while true; do
		calc_size
		if ns8_installed; then status="installato"; else status="non installato"; fi

		choice=$(whiptail --title "$TITLE" --ok-button "Seleziona" --cancel-button "Esci" \
			--menu "NethServer 8: $status  |  Swap: $(current_swap_mb) MB

Scegli un'opzione:" "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU_HEIGHT" \
			"1" "Installazione guidata" \
			"2" "Swap" \
			"3" "Aggiornamenti automatici Rocky Linux" \
			"4" "Notifiche e-mail sui backup" \
			"5" "Rete e hostname (nmtui)" \
			"6" "Installa solo NethServer 8" \
			3>&1 1>&2 2>&3) || break

		case "$choice" in
		1) guided_install ;;
		2) menu_swap ;;
		3) menu_updates ;;
		4) menu_notify ;;
		5) menu_network ;;
		6) menu_ns8 ;;
		esac
	done
	clear
}

# =============================================================================
#  Avvio
# =============================================================================

check_root
ensure_whiptail
touch "$LOG_FILE"
log "Avvio $TITLE"
main_menu
exit 0
