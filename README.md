# NS8 Install Script

Script Bash interattivo per preparare un server **Rocky Linux** e installare **NethServer 8**: imposta lo swap, attiva gli aggiornamenti automatici del sistema e configura le notifiche e-mail sull'esito dei backup.

Versione corrente: **2.0** (`ns8-install-2.0.sh`)

## Requisiti

- Rocky Linux (o un'altra distribuzione RHEL-like con `dnf` e `nmtui`) appena installato
- Accesso come **root**
- Connessione a Internet (per `dnf` e per scaricare l'installer ufficiale di NethServer 8)

## Utilizzo

```bash
curl -O https://raw.githubusercontent.com/LeleKaos/NS8-Install-Script/main/ns8-install-2.0.sh
```

```bash
chmod +x ns8-install-2.0.sh
```

```bash
sudo ./ns8-install-2.0.sh
```

All'avvio compare un menu:

```
 === Installazione Nethserver 8, swap, aggiornamenti automatici e notifiche backup ===

1 - Installazione guidata
2 - Modifica Swap
3 - Modifica notifiche mail
4 - Attiva aggiornamenti automatici Rocky Linux
5 - Modifica Rete
6 - Installa SOLO Nethserver 8 senza modifiche
0 - Esci
```

Il menu torna a comparire dopo ogni operazione, finché non scegli `0`.

## Le opzioni del menu

### 1 - Installazione guidata

Esegue tutte le operazioni una dopo l'altra:

1. **Raccolta dati**: chiede l'indirizzo e-mail del **destinatario** delle notifiche, quello del **mittente** e la dimensione dello swap in MB (predefinita `4096`). Ogni valore va confermato con `s`/`n`.
2. **Swap**: crea (o ricrea) `/swapfile` della dimensione scelta, lo attiva e lo aggiunge a `/etc/fstab`.
3. **Aggiornamenti automatici**: lancia `dnf upgrade -y`, installa `dnf-automatic`, `curl` e `nano`, poi attiva il timer `dnf-automatic.timer` con un override che lo programma ogni giorno alle **6:00** (con un ritardo casuale fino a 10 minuti).
4. **NethServer 8**: se `/var/lib/nethserver` non esiste, scarica ed esegue l'installer ufficiale:
   `https://raw.githubusercontent.com/NethServer/ns8-core/ns8-stable/core/install.sh`.
   Se NethServer è già installato, salta questo passaggio.
5. **Notifiche backup**: crea l'hook
   `/var/lib/nethserver/cluster/events/backup-status-changed/20notify`
   (vedi [Notifiche e-mail sui backup](#notifiche-e-mail-sui-backup)).

Alla fine, crea il cluster dall'interfaccia web di NethServer 8 e configura lì il server SMTP per l'invio delle notifiche.

### 2 - Modifica Swap

Chiede la nuova dimensione (deve essere un intero **maggiore di 1024** MB, predefinita 4096). Poi disattiva lo `/swapfile` esistente, lo ricrea della nuova dimensione e lo riattiva.

### 3 - Modifica notifiche mail

Funziona solo se NethServer 8 è già installato. Chiede di nuovo il destinatario e il mittente e riscrive l'hook `20notify` con i nuovi indirizzi.

### 4 - Attiva aggiornamenti automatici Rocky Linux

Esegue da sola la parte "aggiornamenti automatici" dell'installazione guidata: `dnf upgrade`, installa `dnf-automatic` e attiva il timer giornaliero delle 6:00.

### 5 - Modifica Rete

Apre `nmtui` (NetworkManager TUI) per configurare interfacce, IP, DNS e hostname.

### 6 - Installa SOLO NethServer 8 senza modifiche

Lancia l'installer ufficiale di NethServer 8 senza toccare swap, aggiornamenti o notifiche. Se NethServer è già presente, non fa nulla.

## Notifiche e-mail sui backup

L'hook `20notify` parte a ogni evento `backup-status-changed` del cluster NethServer 8. Ecco cosa fa:

- legge i dati dell'evento in JSON (`module_id`, `backup_id`);
- gira **solo sul nodo leader** del cluster (sui nodi worker esce senza fare nulla);
- legge da Redis il nome del backup e il numero di errori;
- imposta lo stato a `SUCCESS` se gli errori sono 0, altrimenti a `FAIL`;
- invia una mail con `runagent ns8-sendmail`, con l'oggetto `<nome backup> (<modulo>): <stato>`.

Esempio di messaggio:

```
The backup status for Backup giornaliero on nextcloud1 has changed to SUCCESS. Please check the system for details.
```

Per inviare le mail, il server SMTP deve essere configurato in NethServer 8 (**Impostazioni → Notifiche/SMTP**).

## File modificati sul sistema

| Percorso | Opzioni | Contenuto |
|---|---|---|
| `/swapfile` | 1, 2 | File di swap |
| `/etc/fstab` | 1, 2 | Riga di mount dello swap |
| `/etc/systemd/system/dnf-automatic.timer.d/override.conf` | 1, 4 | Orario del timer `dnf-automatic` |
| `/var/lib/nethserver/cluster/events/backup-status-changed/20notify` | 1, 3 | Hook delle notifiche backup |

## Note e limitazioni

- Lo script usa `set -e`: si interrompe al primo comando che fallisce.
- Non verifica di essere eseguito come root: avvialo con `sudo` o da utente root.
- Ogni volta che crei o modifichi lo swap, aggiunge **una nuova riga** a `/etc/fstab`, anche se c'è già. Dopo più modifiche conviene controllare il file ed eliminare i duplicati.
- `dnf-automatic` usa la configurazione di `/etc/dnf/automatic.conf`. Su Rocky Linux l'impostazione predefinita è `apply_updates = no`, quindi gli aggiornamenti vengono solo scaricati. Per installarli in automatico, imposta `apply_updates = yes`.
- L'hook delle notifiche va nella cartella degli eventi del cluster NethServer. Se la cartella non esiste ancora, la scrittura fallisce e lo script si ferma (per via di `set -e`).
- Gli indirizzi e-mail non vengono validati: viene controllato solo che non siano vuoti.
