<p align="center"><img src="logo.png" width="96" alt="vm technology"></p>
<h1 align="center">VM Proxmox Toolkit</h1>
<p align="center">Controllo di un nodo o di un cluster Proxmox VE: backup, snapshot dimenticati, storage, dischi, servizi. Un solo script, sola lettura, report HTML a semaforo.</p>

---

> **Stato: 1.0, da provare su un nodo vero.** Lo script è stato sviluppato e collaudato contro risposte simulate dell'API di Proxmox VE (cartella `tests/`), non ancora su un'installazione reale. È in sola lettura, quindi non può fare danni; se un controllo riporta un dato sbagliato o "non disponibile", aprire una segnalazione con l'output.

## Uso rapido

Sul nodo Proxmox VE, come root:

```bash
curl -fsSLO https://raw.githubusercontent.com/Mivenner/vm-proxmox-toolkit/main/vm-pve-check.sh
chmod +x vm-pve-check.sh
./vm-pve-check.sh
```

Il risultato compare a schermo e viene salvato in `./pve-check/` come HTML e JSON. In un cluster basta lanciarlo su un nodo: controlla tutti i nodi accesi.

Per vederlo dal browser: `./vm-pve-check.sh --serve` (solo dal nodo) oppure `--serve 9000 --bind 0.0.0.0`.

## Cosa controlla

| Area | Controlli |
|---|---|
| Cluster e nodi | quorum, nodi non raggiungibili, RAM, disco di sistema, servizi Proxmox essenziali, SMART e usura degli SSD, aggiornamenti in attesa |
| Storage | storage non attivi, spazio usato (attenzione dall'80%, critico dal 90%) |
| VM e container | guest bloccati (lock), snapshot più vecchi di 30 giorni, guest accesi senza avvio automatico |
| Backup | job attivi, guest fuori da ogni job, guest senza backup, ultimo backup più vecchio di 7 giorni, verifiche fallite su Proxmox Backup Server, backup con errori nell'ultima settimana, backup di guest eliminati |

Il report contiene anche una tabella con tutti i guest: stato, avvio automatico, numero di snapshot, data e dimensione dell'ultimo backup.

## Opzioni

```
    --giorni-backup N    soglia per "backup vecchio" (default 7)
    --giorni-snapshot N  soglia per "snapshot dimenticato" (default 30)
-o, --out DIR            cartella del report (default ./pve-check)
-c, --cliente NOME       cliente o sede
-t, --tecnico NOME       tecnico
    --json               solo JSON su stdout
-q, --quiet              nessun output
    --serve [PORTA]      pubblica il report via web
    --bind INDIRIZZO     indirizzo di ascolto per --serve
```

## Automazione

Codice di uscita: `0` verde, `1` giallo, `2` rosso, `3` errore. Con cron, ogni mattina alle 7:

```
0 7 * * * /usr/local/bin/vm-pve-check.sh -q -o /var/lib/pve-check || logger -t pve-check "stato non verde"
```

## Come funziona

Usa solo ciò che è già sul nodo: `pvesh` per interrogare l'API in lettura e `perl` per leggere le risposte. Snapshot e avvio automatico vengono letti dai file in `/etc/pve`, così non serve una chiamata per ogni guest. Nessun pacchetto da installare.

## Limiti

- Dice che i backup **esistono e sono recenti**, non che si ripristinano. Un ripristino di prova ogni tanto resta l'unica verifica vera.
- I nodi spenti o non raggiungibili vengono segnalati ma non controllati.
- Non modifica nulla: niente clonazioni, conversioni o pulizie automatiche in questa versione.
- Per installare applicazioni e fare il post-installazione del nodo c'è già [Proxmox VE Helper-Scripts](https://github.com/community-scripts/ProxmoxVE); questo strumento fa un'altra cosa, il controllo periodico.

## Test

```bash
bash tests/run.sh
```

Altri strumenti vm technology per Linux: [Health Check](https://github.com/Mivenner/vm-linux-health-check) · [Network Check](https://github.com/Mivenner/vm-network-check) · [Server Setup](https://github.com/Mivenner/vm-server-setup) · [Proxmox Toolkit](https://github.com/Mivenner/vm-proxmox-toolkit)
