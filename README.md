# NS8 Install Script

Script Bash interattivo per preparare un server **Rocky Linux** e installare **NethServer 8**: rete, swap, aggiornamenti automatici del sistema e notifiche e-mail sull'esito dei backup.

Dalla versione 3.0 l'interfaccia usa `whiptail`, con menu a finestre in stile `raspi-config`.

| Versione | File | Note |
|---|---|---|
| **3.0** (consigliata) | `ns8-install-3.0.sh` | Interfaccia grafica, installazione guidata a scelta |
| 2.0 | `ns8-install-2.0.sh` | Menu testuale, mantenuta per compatibilità |

## Requisiti

- Rocky Linux (o un'altra distribuzione RHEL-like con `dnf` e `nmtui`)
- Accesso come **root**: lo script si ferma se non lo è
- Connessione a Internet (per `dnf` e per scaricare l'installer ufficiale di NethServer 8)
- `whiptail` (pacchetto `newt`): se manca, lo script lo installa da solo

## Utilizzo

```bash
curl -O https://raw.githubusercontent.com/LeleKaos/NS8-Install-Script/main/ns8-install-3.0.sh
```

```bash
chmod +x ns8-install-3.0.sh
```

```bash
sudo ./ns8-install-3.0.sh
```

All'avvio compare il menu principale, che in cima mostra se NethServer 8 è installato e quanto swap è attivo:

```
┌──────────────── NS8 Install Script v3.0 ────────────────┐
│ NethServer 8: non installato  |  Swap: 0 MB             │
│                                                         │
│ Scegli un'opzione:                                      │
│                                                         │
│   1  Installazione guidata                              │
│   2  Swap                                               │
│   3  Aggiornamenti automatici Rocky Linux               │
│   4  Notifiche e-mail sui backup                        │
│   5  Rete e hostname (nmtui)                            │
│   6  Installa solo NethServer 8                         │
│                                                         │
│          <Seleziona>              <Esci>                │
└─────────────────────────────────────────────────────────┘
```

Comandi: frecce per muoversi, **INVIO** per confermare, **TAB** per passare ai pulsanti, **SPAZIO** per spuntare le caselle.

## Installazione guidata

1. **Scelta delle operazioni**: una lista di caselle permette di decidere cosa configurare:
   - Rete e hostname (nmtui), non spuntata di default
   - Swap
   - Aggiornamenti automatici Rocky Linux
   - Installa NethServer 8 (non spuntata se NS8 è già installato)
   - Notifiche e-mail sui backup

   Se scegli le notifiche senza NethServer 8, e NS8 non è installato, lo script propone di aggiungere anche la sua installazione.
2. **Parametri**: lo script fa all'inizio tutte le domande che servono per le operazioni scelte:
   - dimensione dello swap
   - orario degli aggiornamenti e se installarli in automatico
   - indirizzi e-mail di destinatario e mittente

   Premendo **Annulla** in qualunque momento l'installazione viene annullata senza modificare nulla.
3. **Riepilogo**: mostra cosa verrà fatto e chiede conferma.
4. **Esecuzione**: dopo la conferma tutto procede senza altre domande, in questo ordine: rete → swap → aggiornamenti → NethServer 8 → notifiche.
5. **Esito**: una schermata finale mostra lo stato di ogni passo (`[OK]`, `[ERRORE]`, `[SALTATO]`).

Le notifiche vengono configurate **solo dopo** che NethServer 8 è installato. Se l'installazione di NS8 fallisce, le notifiche risultano `[SALTATO]` e non producono errori.

Alla fine, crea il cluster dall'interfaccia web di NethServer 8 e configura lì il server SMTP per l'invio delle notifiche.

## Le singole voci del menu

### 2 - Swap

Chiede la dimensione in MB (minimo **1024**, predefinita 4096) e controlla che sul disco ci sia spazio sufficiente, con almeno 1 GB di margine. Poi disattiva lo `/swapfile` esistente, lo ricrea e lo riattiva.

In `/etc/fstab` resta **una sola** riga per lo swapfile: vengono rimossi anche gli eventuali duplicati lasciati dalla versione 2.0. Prima della modifica viene salvata una copia in `/etc/fstab.bak-ns8-install`.

### 3 - Aggiornamenti automatici Rocky Linux

- Esegue `dnf upgrade -y` e installa `dnf-automatic`, `curl` e `nano`.
- Programma il timer `dnf-automatic.timer` ogni giorno all'**orario scelto** (predefinito 06:00), con un ritardo casuale fino a 10 minuti.
- Chiede se gli aggiornamenti vanno anche **installati** in automatico (`apply_updates = yes`) o solo scaricati (`apply_updates = no`).

### 4 - Notifiche e-mail sui backup

Disponibile solo se NethServer 8 è installato, altrimenti compare un avviso. Chiede destinatario e mittente e propone come valori predefiniti quelli già configurati. Gli indirizzi vengono controllati prima di essere salvati.

Poi crea la cartella degli eventi, se manca, e scrive l'hook `20notify` (vedi [Come funzionano le notifiche](#come-funzionano-le-notifiche)).

### 5 - Rete e hostname

Apre `nmtui` (NetworkManager TUI) per configurare interfacce, IP, DNS e hostname.

### 6 - Installa solo NethServer 8

Lancia l'installer ufficiale (`https://raw.githubusercontent.com/NethServer/ns8-core/ns8-stable/core/install.sh`) senza toccare il resto del sistema. Al termine chiede se configurare subito le notifiche sui backup. Se NethServer 8 è già presente, non fa nulla.

## Come funzionano le notifiche

L'hook `/var/lib/nethserver/cluster/events/backup-status-changed/20notify` parte a ogni evento `backup-status-changed` del cluster NethServer 8. Ecco cosa fa:

- legge i dati dell'evento in JSON (`module_id`, `backup_id`);
- gira **solo sul nodo leader** del cluster (sui nodi worker esce senza fare nulla);
- legge da Redis il nome del backup e il numero di errori;
- imposta lo stato a `SUCCESS` se gli errori sono 0, altrimenti a `FAIL`;
- invia una mail con `runagent ns8-sendmail`, con l'oggetto `<nome backup> (<modulo>): <stato>`.

Esempio di messaggio:

```
The backup status for Backup giornaliero on nextcloud1 has changed to SUCCESS. Please check the system for details.
```

## Log

L'output di tutte le operazioni viene mostrato a video e salvato in `/var/log/ns8-install.log`. Se un passaggio non riesce, i dettagli sono lì.

## File modificati sul sistema

| Percorso | Voce del menu | Contenuto |
|---|---|---|
| `/swapfile` | Swap | File di swap |
| `/etc/fstab` (+ `/etc/fstab.bak-ns8-install`) | Swap | Riga di mount dello swap |
| `/etc/systemd/system/dnf-automatic.timer.d/override.conf` | Aggiornamenti | Orario del timer |
| `/etc/dnf/automatic.conf` | Aggiornamenti | Valore di `apply_updates` |
| `/var/lib/nethserver/cluster/events/backup-status-changed/20notify` | Notifiche | Hook delle notifiche backup |
| `/var/log/ns8-install.log` | Tutte | Log delle operazioni |

## Novità della 3.0 rispetto alla 2.0

- Interfaccia a finestre con `whiptail`, in stile `raspi-config`
- Installazione guidata con scelta delle operazioni, riepilogo prima di procedere ed esito finale
- Le notifiche vengono configurate dopo l'installazione di NS8; la cartella degli eventi viene creata se manca, quindi non dà più errore
- Controllo dei permessi di root e installazione automatica di `whiptail`
- Nessuna riga duplicata in `/etc/fstab`
- Controllo dello spazio su disco prima di creare lo swap
- Orario degli aggiornamenti e `apply_updates` configurabili; il nuovo orario sostituisce quello predefinito del timer invece di aggiungersi
- Controllo del formato degli indirizzi e-mail
- Log delle operazioni in `/var/log/ns8-install.log`
- Fine riga sempre LF per gli script (`.gitattributes`)

## Versione 2.0

`ns8-install-2.0.sh` resta disponibile, con il menu testuale originale. Ha però dei limiti noti, risolti nella 3.0:

- aggiunge una nuova riga a `/etc/fstab` ogni volta che si modifica lo swap;
- non verifica i permessi di root;
- configurare le notifiche fallisce se la cartella degli eventi di NethServer non esiste;
- lascia `apply_updates` al valore predefinito di Rocky Linux (`no`): gli aggiornamenti vengono solo scaricati.
