#!/bin/bash
#installer nethserver 8 V2.0
# Esci su errore
set -e 

while true; do
	clear
	echo " === Installazione Nethserver 8, swap, aggiornamenti automatici e notifiche backup ==="
	echo ""
	echo "1 - Installazione guidata"
	echo "2 - Modifica Swap"
	echo "3 - Modifica notifiche mail"
	echo "4 - Attiva aggiornamenti automatici Rocky Linux"
	echo "5 - Modifica Rete"
	echo "6 - Installa SOLO Nethserver 8 senza modifiche"
	echo "0 - Esci"
	echo ""
	read -p "Scegli: " SELECTION

	if [[ -z "$SELECTION" ]]; then
		echo "Nessuna selezione." >&2
		read -p "Scegli: " SELECTION
		continue
	fi
	case "$SELECTION" in
	1) #Installazione Automatica
		clear
		echo " === Installazione AUTOMATICA Nethserver 8 con swap, aggiornamenti automatici e notifiche backup ==="

		#Richiesta di inserimento mail TO per notifiche
		read -p "-Inserisci l'indirizzo e-mail su cui ricevere le notifiche: " MAIL_ADDR_TO
		while true; do
			if [[ -z "$MAIL_ADDR_TO" ]]; then
				echo "==Errore: E-mail non fornita!" >&2
				read -p "-Inserisci l'indirizzo e-mail su cui ricevere le notifiche: " MAIL_ADDR_TO
				continue
			fi
			read -p "-La mail inserita è '$MAIL_ADDR_TO', è corretta? (s/n): " CONFIRM_MAIL_TO
			
			case "$CONFIRM_MAIL_TO" in
			s|S|si|SI|Si|sì|SÌ|y|Y|Yes|YES)
				break
				;;
			n|N|no|NO|No)
				echo "-Reinserisci..."
				read -p "-Inserisci l'indirizzo e-mail su cui ricevere le notifiche: " MAIL_ADDR_TO
				;;
				*)
				echo "Risposta non valida."
				;;
			esac
		done

		#Richiesta di inserimento mail TO per notifiche
		read -p "-Inserisci l'indirizzo e-mail da cui inviare le notifiche: " MAIL_ADDR_FROM
		while true; do
			if [[ -z "$MAIL_ADDR_FROM" ]]; then
				echo "==Errore: E-mail non fornita!" >&2
				read -p "-Inserisci l'indirizzo e-mail da cui inviare le notifiche: " MAIL_ADDR_FROM
				continue
			fi
			echo "-La mail inserita è '$MAIL_ADDR_FROM', è corretta? (s/n): "
			read -r CONFIRM_MAIL_FROM
			case "$CONFIRM_MAIL_FROM" in
			s|S|si|SI|Si|sì|SÌ|y|Y|Yes|YES)
				break
				;;
			n|N|no|NO|No)
				echo "-Reinserisci..."
				read -p "-Inserisci l'indirizzo e-mail da cui inviare le notifiche: " MAIL_ADDR_FROM
				;;
				*)
				echo "Risposta non valida."
				;;
			esac
		done
		sleep 1

		#Richiesta di inserimento dimensione swap
		read -p "-Indica la dimensione della swap in MB (es: 2048) [Default 4096MB]: " SWAP_SIZE
		while true; do
			if [[ -z "$SWAP_SIZE" ]]; then
				SWAP_SIZE="4096"
			fi
			
			if [[ ! "$SWAP_SIZE" =~ ^[0-9]+$ || "$SWAP_SIZE" -le 1024 ]]; then
            echo "-Errore: deve essere un numero intero > 1024 (es: 2048)"
            read -p "-Indica la dimensione della swap in MB (es: 2048) [Default 4096MB]: " SWAP_SIZE
            continue
			fi
		
			
			read -p "-Verrà creata una swap di $SWAP_SIZE MB, è corretto? (s/n): " CONFIRM_SWAP
			case "$CONFIRM_SWAP" in
			s|S|si|SI|Si|sì|SÌ|y|Y|Yes|YES)
				break
				;;
			n|N|no|NO|No)
				echo "-Reinserisci..."
				read -p "-Indica la dimensione della swap in MB (es: 2048) [Default 4096MB]: " SWAP_SIZE
				;;
				*)
				echo "Risposta non valida."
				;;
			esac
			
		done
		
		#creazione della swap
		if swapon --show | grep -q "^/swapfile "; then
			swapoff /swapfile
		fi
		dd if=/dev/zero of=/swapfile count="$SWAP_SIZE" bs=1MiB
		chmod 600 /swapfile
		mkswap /swapfile
		swapon /swapfile
		echo '/swapfile   swap    swap    sw  0   0' >> /etc/fstab
		systemctl daemon-reload
		swapon --show
		
		echo ""
		echo "=Creata swap di dimensione $SWAP_SIZE MB="
		sleep 5

		#Attivazione aggiornamenti automatici rocky linux
		dnf upgrade -y
		dnf install dnf-automatic curl nano -y
		if ! [[ -d "/etc/systemd/system/dnf-automatic.timer.d" ]]; then
			mkdir /etc/systemd/system/dnf-automatic.timer.d
		fi
		echo '[Unit]
		Description=dnf-automatic timer
		ConditionPathExists=!/run/ostree-booted
		Wants=network-online.target


		[Timer]
		OnCalendar=*-*-* 6:00
		RandomizedDelaySec=10m
		Persistent=true

		[Install]
		WantedBy=timer.target' > /etc/systemd/system/dnf-automatic.timer.d/override.conf
		systemctl enable --now dnf-automatic.timer

		echo "=Aggiornamenti automatici attivati ogni giorno alle 6:00="
		sleep 2


		#Installazione di nethserver 8
		echo "=Avvio installazione nethserver="
		sleep 2
		if [[ -d "/var/lib/nethserver" ]]; then
			echo "Nethserver 8 è già installato"
			sleep 2
		else
			curl https://raw.githubusercontent.com/NethServer/ns8-core/ns8-stable/core/install.sh | bash
			echo "=Installazione Nethserver 8 Completata="
		fi
		sleep 5

		#Configurazione delle notifiche post installazione di nethserver 
		TARGET_PATH="/var/lib/nethserver/cluster/events/backup-status-changed/20notify"
		cat > "$TARGET_PATH" << 'SCRIPT_EOF'
#!/bin/bash

# Change the following variables to match your environment
MAIL_FROM="MAIL_PLACEHOLDER_FROM"
MAIL_TO="MAIL_PLACEHOLDER_TO"
MAIL_SUBJECT="Backup status changed:"
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

		sed -i "s|MAIL_PLACEHOLDER_FROM|$MAIL_ADDR_FROM|g" "$TARGET_PATH"
		sed -i "s|MAIL_PLACEHOLDER_TO|$MAIL_ADDR_TO|g" "$TARGET_PATH"

		chmod a+x "$TARGET_PATH"

		echo ""
		echo "=Impostate notifiche mail con mittente $MAIL_ADDR_FROM e destinatario $MAIL_ADDR_TO="
		echo ""
		echo "=Proseguire con la creazione del cluster poi impostare i parametri server mail per le notifiche.="
		echo ""
		echo "==Installazione Completata=="
		read -p "Premere un tasto per continuare ..." _
		
	;;
	2) #Modifica Swap
		clear
		read -p "-Indica la dimensione della swap in MB (es: 2048) [Default 4096MB]: " SWAP_SIZE
		while true; do
			if [[ -z "$SWAP_SIZE" ]]; then
				SWAP_SIZE="4096"
			fi
			
			if [[ ! "$SWAP_SIZE" =~ ^[0-9]+$ || "$SWAP_SIZE" -le 1024 ]]; then
            echo "-Errore: deve essere un numero intero > 1024 (es: 2048)"
            read -p "-Indica la dimensione della swap in MB (es: 2048) [Default 4096MB]: " SWAP_SIZE
            continue
			fi
		
			
			read -p "-Verrà creata una swap di $SWAP_SIZE MB, è corretto? (s/n): " CONFIRM_SWAP
			case "$CONFIRM_SWAP" in
			s|S|si|SI|Si|sì|SÌ|y|Y|Yes|YES)
				break
				;;
			n|N|no|NO|No)
				echo "-Reinserisci..."
				read -p "-Indica la dimensione della swap in MB (es: 2048) [Default 4096MB]: " SWAP_SIZE
				;;
				*)
				echo "Risposta non valida."
				;;
			esac
			
		done
		
		#creazione della swap
		if swapon --show | grep -q "^/swapfile "; then
			swapoff /swapfile
		fi
		dd if=/dev/zero of=/swapfile count="$SWAP_SIZE" bs=1MiB
		chmod 600 /swapfile
		mkswap /swapfile
		swapon /swapfile
		echo '/swapfile   swap    swap    sw  0   0' >> /etc/fstab
		systemctl daemon-reload
		swapon --show
		
		echo ""
		echo "=Creata swap di dimensione $SWAP_SIZE MB="
		read -p "Premere un tasto per continuare ..." _
		
		
	;;
	
	3) #Modifica notifiche mail
		clear
		if [[ -d "/var/lib/nethserver" ]]; then
				
			#Richiesta di inserimento mail TO per notifiche
			read -p "-Inserisci l'indirizzo e-mail su cui ricevere le notifiche: " MAIL_ADDR_TO
			while true; do
				if [[ -z "$MAIL_ADDR_TO" ]]; then
					echo "==Errore: E-mail non fornita!" >&2
					read -p "-Inserisci l'indirizzo e-mail su cui ricevere le notifiche: " MAIL_ADDR_TO
					continue
				fi
				read -p "-La mail inserita è '$MAIL_ADDR_TO', è corretta? (s/n): " CONFIRM_MAIL_TO
				 
				case "$CONFIRM_MAIL_TO" in
				s|S|si|SI|Si|sì|SÌ|y|Y|Yes|YES)
					break
					;;
				n|N|no|NO|No)
					echo "-Reinserisci..."
					read -p "-Inserisci l'indirizzo e-mail su cui ricevere le notifiche: " MAIL_ADDR_TO
					;;
					*)
					echo "Risposta non valida."
					;;
				esac
			done
			sleep 2

			#Richiesta di inserimento mail TO per notifiche
			read -p "-Inserisci l'indirizzo e-mail da cui inviare le notifiche: " MAIL_ADDR_FROM
			while true; do
				if [[ -z "$MAIL_ADDR_FROM" ]]; then
					echo "==Errore: E-mail non fornita!" >&2
					read -p "-Inserisci l'indirizzo e-mail da cui inviare le notifiche: " MAIL_ADDR_FROM
					continue
				fi
				read -p "-La mail inserita è '$MAIL_ADDR_FROM', è corretta? (s/n): " CONFIRM_MAIL_FROM

				case "$CONFIRM_MAIL_FROM" in
				s|S|si|SI|Si|sì|SÌ|y|Y|Yes|YES)
					break
					;;
				n|N|no|NO|No)
					echo "-Reinserisci..."
					read -p "-Inserisci l'indirizzo e-mail da cui inviare le notifiche: " MAIL_ADDR_FROM
					;;
					*)
					echo "Risposta non valida."
					;;
				esac
			done
			sleep 2
			
			#Configurazione delle notifiche post installazione di nethserver 
			TARGET_PATH="/var/lib/nethserver/cluster/events/backup-status-changed/20notify"
cat > "$TARGET_PATH" << 'SCRIPT_EOF'
#!/bin/bash

# Change the following variables to match your environment
MAIL_FROM="MAIL_PLACEHOLDER_FROM"
MAIL_TO="MAIL_PLACEHOLDER_TO"
MAIL_SUBJECT="Backup status changed:"
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

			sed -i "s|MAIL_PLACEHOLDER_FROM|$MAIL_ADDR_FROM|g" "$TARGET_PATH"
			sed -i "s|MAIL_PLACEHOLDER_TO|$MAIL_ADDR_TO|g" "$TARGET_PATH"

			chmod a+x "$TARGET_PATH"

			echo ""
			echo "=Impostate notifiche mail con mittente $MAIL_ADDR_FROM e destinatario $MAIL_ADDR_TO="
			read -p "Premere un tasto per continuare ..." _
			
			
		else
			echo "Nethserver 8 non è installato."
			read -p "Premere un tasto per continuare ..." _
		fi
		
			
	;;
	4)
		clear
		#Attivazione aggiornamenti automatici rocky linux
		dnf upgrade -y
		dnf install dnf-automatic curl nano -y
		if ! [[ -d "/etc/systemd/system/dnf-automatic.timer.d" ]]; then
			mkdir /etc/systemd/system/dnf-automatic.timer.d
		fi
		echo '[Unit]
		Description=dnf-automatic timer
		ConditionPathExists=!/run/ostree-booted
		Wants=network-online.target


		[Timer]
		OnCalendar=*-*-* 6:00
		RandomizedDelaySec=10m
		Persistent=true

		[Install]
		WantedBy=timer.target' > /etc/systemd/system/dnf-automatic.timer.d/override.conf
		systemctl enable --now dnf-automatic.timer
		
		clear
		echo ""
		echo ""
		echo ""
		echo "=Aggiornamenti automatici attivati ogni giorno alle 6:00="
		read -p "Premere un tasto per continuare ..." _
	;;
	5)
		nmtui
		read -p "Premere un tasto per continuare ..." _
	;;	
	6)
		#Installazione di nethserver 8
		clear
		echo "=Avvio installazione nethserver="
		sleep 2
		if [[ -d "/var/lib/nethserver" ]]; then
			echo "Nethserver 8 è già installato"
		else
			curl https://raw.githubusercontent.com/NethServer/ns8-core/ns8-stable/core/install.sh | bash
		echo "=Installazione Nethserver 8 Completata="
		fi
		read -p "Premere un tasto per continuare ..." _
	;;
	
	0)
		exit 0
	;;
	
	*)
		clear
		echo "Selezione invalida."
		read -p "Premere un tasto per continuare ..." _
	;;
	esac
done
sleep 2