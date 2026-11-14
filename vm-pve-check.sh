#!/usr/bin/env bash
# VM Proxmox Toolkit - controllo di un nodo o cluster Proxmox VE: backup, snapshot dimenticati, storage, dischi, servizi.
# (c) vm technology. Sola lettura: non modifica nulla. Va eseguito come root su un nodo Proxmox VE (7, 8 o 9).
# Usa solo strumenti gia' presenti sul nodo (pvesh, perl). Uscita: 0 verde, 1 giallo, 2 rosso, 3 errore.

VERSION="1.0.0"; TOOL="VM Proxmox Toolkit"; PREFIX="pve-check"
OUT_DIR=""; CLIENTE=""; TECNICO="${SUDO_USER:-${USER:-}}"; QUIET=0; JSON_ONLY=0; NO_COLOR=0
SERVE=0; SERVE_PORT=8080; SERVE_BIND="127.0.0.1"
BK_DAYS=7; SNAP_DAYS=30; TASK_DAYS=7; ST_WARN=80; ST_CRIT=90
ETC="${VMPVE_ETC:-/etc/pve}"
FOOT="sola lettura: nessuna modifica apportata al nodo."
TXT_VERDE="Nessun problema rilevante: backup, storage e servizi sono a posto."
TXT_GIALLO="Alcuni punti meritano attenzione: vedere le voci gialle."
TXT_ROSSO="Problemi critici rilevati: intervenire sulle voci rosse prima possibile."

usage() {
cat <<'EOF'
VM Proxmox Toolkit - controllo di un nodo o cluster Proxmox VE con report HTML/JSON a semaforo.

Uso (come root, su un nodo Proxmox VE): ./vm-pve-check.sh [opzioni]

      --giorni-backup N    un guest senza backup da piu' di N giorni viene segnalato (default 7)
      --giorni-snapshot N  gli snapshot piu' vecchi di N giorni vengono segnalati (default 30)
  -o, --out DIR            cartella del report (default: ./pve-check)
  -c, --cliente NOME       cliente o sede
  -t, --tecnico NOME       tecnico
      --json               stampa solo il JSON su stdout
  -q, --quiet              nessun output a schermo
      --no-color           output senza colori
      --serve [PORTA]      dopo il controllo pubblica il report via web (default 8080, solo localhost)
      --bind INDIRIZZO     indirizzo di ascolto per --serve
  -h, --help               questo aiuto
      --version            versione

Controlla tutti i nodi accesi del cluster. Non modifica nulla.
Codice di uscita: 0 = verde, 1 = giallo, 2 = rosso, 3 = errore di esecuzione.
EOF
}
need() { [ $# -ge 2 ] || { echo "L'opzione $1 richiede un valore." >&2; exit 3; }; }
num() { [[ "$2" =~ ^[0-9]+$ ]] || { echo "L'opzione $1 vuole un numero." >&2; exit 3; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --giorni-backup) need "$@"; num "$@"; BK_DAYS="$2"; shift 2 ;;
        --giorni-snapshot) need "$@"; num "$@"; SNAP_DAYS="$2"; shift 2 ;;
        -o|--out) need "$@"; OUT_DIR="$2"; shift 2 ;;
        -c|--cliente) need "$@"; CLIENTE="$2"; shift 2 ;;
        -t|--tecnico) need "$@"; TECNICO="$2"; shift 2 ;;
        --json) JSON_ONLY=1; QUIET=1; shift ;;
        -q|--quiet) QUIET=1; shift ;;
        --no-color) NO_COLOR=1; shift ;;
        --serve) SERVE=1; if [[ "${2:-}" =~ ^[0-9]+$ ]]; then SERVE_PORT="$2"; shift; fi; shift ;;
        --bind) need "$@"; SERVE_BIND="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --version) echo "$VERSION"; exit 0 ;;
        *) echo "Opzione sconosciuta: $1 (usa --help)" >&2; exit 3 ;;
    esac
done
[ -z "$OUT_DIR" ] && OUT_DIR="./pve-check"
# --- parte comune vm technology (uguale in tutti gli strumenti Linux) -----------------------------
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "Serve bash 4 o successivo." >&2; exit 3; fi
export LC_ALL=C LANG=C
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
have() { command -v "$1" >/dev/null 2>&1; }
tmo() { local s="$1"; shift; if have timeout; then timeout "$s" "$@"; else "$@"; fi; }
if [ "$NO_COLOR" -eq 0 ] && [ -t 1 ]; then C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_CRIT=$'\e[31m'; C_INFO=$'\e[36m'; C_NA=$'\e[90m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else C_OK=""; C_WARN=""; C_CRIT=""; C_INFO=""; C_NA=""; C_B=""; C_0=""; fi
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; return 0; }

R_CAT=(); R_TIT=(); R_ST=(); R_MSG=(); R_DET=(); R_ACT=()
N_OK=0; N_WARN=0; N_CRIT=0; LAST_CAT=""
# add CATEGORIA TITOLO STATO MESSAGGIO [DETTAGLI] [AZIONE]   STATO = OK|WARN|CRIT|INFO|NA
add() {
    local cat="$1" tit="$2" st="$3" msg="$4" det="${5:-}" act="${6:-}"
    R_CAT+=("$cat"); R_TIT+=("$tit"); R_ST+=("$st"); R_MSG+=("$msg"); R_DET+=("$det"); R_ACT+=("$act")
    case "$st" in OK) N_OK=$((N_OK+1));; WARN) N_WARN=$((N_WARN+1));; CRIT) N_CRIT=$((N_CRIT+1));; esac
    [ "$QUIET" -eq 1 ] && return 0
    if [ "$cat" != "$LAST_CAT" ]; then printf '\n%s== %s ==%s\n' "$C_B" "$cat" "$C_0"; LAST_CAT="$cat"; fi
    local col lab
    case "$st" in OK) col="$C_OK"; lab=" OK ";; WARN) col="$C_WARN"; lab="WARN";; CRIT) col="$C_CRIT"; lab="CRIT";; INFO) col="$C_INFO"; lab="INFO";; *) col="$C_NA"; lab="N/D ";; esac
    printf '  %s[%s]%s %s: %s\n' "$col" "$lab" "$C_0" "$tit" "$msg"
    if [ -n "$det" ]; then
        local nl; nl="$(printf '%s\n' "$det" | wc -l)"
        printf '%s\n' "$det" | head -n 8 | sed 's/^/           /'
        [ "$nl" -gt 8 ] && printf '           ... altre %d righe nel report\n' "$((nl-8))"
    fi
    [ -n "$act" ] && printf '         %s-> %s%s\n' "$C_NA" "$act" "$C_0"
    return 0
}
human() { awk -v b="${1:-0}" 'BEGIN{ split("B KB MB GB TB PB",u," "); i=1; while (b>=1024 && i<6) { b/=1024; i++ } if (i==1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i] }'; }

OS_ID=""; OS_NAME=""; OS_LIKE=""
if [ -r /etc/os-release ]; then
    OS_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
    OS_NAME="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-${NAME:-}}")"
    OS_LIKE="$(. /etc/os-release 2>/dev/null; echo "${ID_LIKE:-}")"
fi
PKG=""
if have apt-get; then PKG="apt"; elif have dnf; then PKG="dnf"; elif have yum; then PKG="yum"; elif have zypper; then PKG="zypper"; elif have pacman; then PKG="pacman"; elif have apk; then PKG="apk"; fi
HAS_SYSTEMD=0; [ -d /run/systemd/system ] && have systemctl && HAS_SYSTEMD=1
HOST="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo sconosciuto)"; HOST="${HOST%%.*}"
START_TS="$(date +%s)"; START_ISO="$(date '+%Y-%m-%d %H:%M:%S')"; STAMP="$(date '+%Y%m%d-%H%M%S')"

json_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/\\t}"; printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'; }
html_esc() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; printf '%s' "$s"; }

make_json() {
    local i
    printf '{\n  "strumento": "%s",\n  "versione": "%s",\n  "computer": "%s",\n  "distribuzione": "%s",\n  "inizio": "%s",\n  "durata_secondi": %d,\n  "cliente": "%s",\n  "tecnico": "%s",\n  "semaforo": "%s",\n  "critici": %d,\n  "avvisi": %d,\n  "ok": %d,\n' \
        "$TOOL" "$VERSION" "$(json_esc "$HOST")" "$(json_esc "$OS_NAME")" "$START_ISO" "$DUR" "$(json_esc "$CLIENTE")" "$(json_esc "$TECNICO")" "$SEM" "$N_CRIT" "$N_WARN" "$N_OK"
    declare -F extra_json >/dev/null && extra_json
    printf '  "risultati": [\n'
    for i in "${!R_CAT[@]}"; do
        printf '    {"categoria": "%s", "titolo": "%s", "stato": "%s", "messaggio": "%s", "dettagli": "%s", "azione": "%s"}%s\n' \
            "$(json_esc "${R_CAT[$i]}")" "$(json_esc "${R_TIT[$i]}")" "${R_ST[$i]}" "$(json_esc "${R_MSG[$i]}")" "$(json_esc "${R_DET[$i]}")" "$(json_esc "${R_ACT[$i]}")" "$([ "$i" -lt $(( ${#R_CAT[@]} - 1 )) ] && echo ,)"
    done
    printf '  ]\n}\n'
}

make_html() {
    local semcol i j cat st col lab seen=" "
    case "$SEM" in VERDE) semcol="#2ecc71";; GIALLO) semcol="#f1c40f";; *) semcol="#e74c3c";; esac
    cat <<EOF
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>$TOOL - $(html_esc "$HOST")</title><style>
body{font-family:Segoe UI,Ubuntu,Helvetica,Arial,sans-serif;margin:0;background:#f4f6fa;color:#1b2740}
.hdr{background:#0a1428;color:#e6f1ff;padding:18px 28px}.hdr h1{margin:0;font-size:20px;color:#38d6ff}.hdr small{color:#8fa3c7}
.wrap{max-width:1100px;margin:20px auto;padding:0 16px}
.sem{display:flex;flex-wrap:wrap;gap:14px;align-items:center;background:#fff;border-radius:10px;padding:16px 20px;box-shadow:0 1px 4px rgba(0,0,0,.08);margin-bottom:18px}
.dot{width:46px;height:46px;border-radius:50%;background:$semcol}
.kpi{display:flex;gap:10px;margin-left:auto}.kpi div{background:#f4f6fa;border-radius:8px;padding:8px 14px;text-align:center;font-size:12px;color:#5a6a8a}.kpi b{display:block;font-size:20px;color:#1b2740}
h2{font-size:15px;margin:22px 0 8px;color:#0a1428;border-bottom:2px solid #dfe6f2;padding-bottom:4px}
.row{background:#fff;border-radius:8px;padding:10px 14px;margin-bottom:6px;display:grid;grid-template-columns:110px 1fr;gap:10px;box-shadow:0 1px 3px rgba(0,0,0,.06)}
.badge{display:inline-block;padding:3px 10px;border-radius:12px;font-size:11px;font-weight:600;color:#0a1428}
.t{font-weight:600}.m{color:#3b4a66;font-size:13px}.d{color:#6b7a95;font-size:12px;margin-top:4px;white-space:pre-wrap;font-family:Consolas,Menlo,monospace}.a{color:#b03a2e;font-size:12px;margin-top:4px}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.06);font-size:13px}
th{background:#0a1428;color:#e6f1ff;text-align:left;padding:8px 10px;font-weight:600}td{padding:7px 10px;border-top:1px solid #edf1f7;vertical-align:top}
td.mono{font-family:Consolas,Menlo,monospace;font-size:12px}tr.new td{background:#eafaf1}tr.chg td{background:#fef9e7}.tblwrap{overflow-x:auto}
.foot{color:#8fa3c7;font-size:11px;text-align:center;margin:26px 0}@media print{.row{break-inside:avoid}body{background:#fff}}
</style></head><body>
<div class="hdr"><h1>$TOOL</h1><small>$(html_esc "$HOST") - $(html_esc "$OS_NAME") - $START_ISO - durata ${DUR} s$([ -n "$CLIENTE" ] && printf ' - Cliente: %s' "$(html_esc "$CLIENTE")")$([ -n "$TECNICO" ] && printf ' - Tecnico: %s' "$(html_esc "$TECNICO")")</small></div>
<div class="wrap"><div class="sem"><div class="dot"></div><div><div style="font-size:18px;font-weight:700">Stato generale: $SEM</div><div class="m">$(html_esc "$SEM_TXT")</div></div>
<div class="kpi"><div><b style="color:#e74c3c">$N_CRIT</b>critici</div><div><b style="color:#d4ac0d">$N_WARN</b>avvisi</div><div><b style="color:#27ae60">$N_OK</b>ok</div></div></div>
EOF
    declare -F extra_html >/dev/null && extra_html
    for i in "${!R_CAT[@]}"; do
        cat="${R_CAT[$i]}"
        case "$seen" in *"|$cat|"*) continue ;; esac
        seen="$seen|$cat|"
        printf '<h2>%s</h2>\n' "$(html_esc "$cat")"
        for st in CRIT WARN OK INFO NA; do
            for j in "${!R_CAT[@]}"; do
                [ "${R_CAT[$j]}" = "$cat" ] && [ "${R_ST[$j]}" = "$st" ] || continue
                case "$st" in OK) col="#2ecc71"; lab="OK";; WARN) col="#f1c40f"; lab="Attenzione";; CRIT) col="#e74c3c"; lab="Critico";; INFO) col="#38d6ff"; lab="Info";; *) col="#8fa3c7"; lab="N/D";; esac
                printf '<div class="row"><div><span class="badge" style="background:%s">%s</span></div><div><div class="t">%s</div><div class="m">%s</div>' "$col" "$lab" "$(html_esc "${R_TIT[$j]}")" "$(html_esc "${R_MSG[$j]}")"
                [ -n "${R_DET[$j]}" ] && printf '<div class="d">%s</div>' "$(html_esc "${R_DET[$j]}")"
                [ -n "${R_ACT[$j]}" ] && printf '<div class="a">&#9654; %s</div>' "$(html_esc "${R_ACT[$j]}")"
                printf '</div></div>\n'
            done
        done
    done
    printf '<div class="foot">%s v%s - vm technology - %s</div></div></body></html>\n' "$TOOL" "$VERSION" "$(html_esc "$FOOT")"
}

# finish: calcola il semaforo, scrive i report, pubblica via web se richiesto ed esce
finish() {
    DUR=$(( $(date +%s) - START_TS ))
    SEM="VERDE"; [ "$N_WARN" -gt 0 ] && SEM="GIALLO"; [ "$N_CRIT" -gt 0 ] && SEM="ROSSO"
    case "$SEM" in VERDE) SEM_TXT="$TXT_VERDE";; GIALLO) SEM_TXT="$TXT_GIALLO";; *) SEM_TXT="$TXT_ROSSO";; esac
    local code=0 sc; [ "$SEM" = "GIALLO" ] && code=1; [ "$SEM" = "ROSSO" ] && code=2
    [ "${EXIT_MIN:-0}" -gt "$code" ] && code="$EXIT_MIN"
    if [ "$JSON_ONLY" -eq 1 ]; then make_json; exit "$code"; fi
    mkdir -p "$OUT_DIR" 2>/dev/null || { echo "Impossibile creare la cartella $OUT_DIR" >&2; exit 3; }
    local base="$OUT_DIR/${PREFIX}_${HOST}_${STAMP}"
    make_json > "$base.json" && make_html > "$base.html" || { echo "Errore nella scrittura del report in $OUT_DIR" >&2; exit 3; }
    cp -f "$base.html" "$OUT_DIR/index.html" 2>/dev/null
    if [ "$QUIET" -eq 0 ]; then
        case "$SEM" in VERDE) sc="$C_OK";; GIALLO) sc="$C_WARN";; *) sc="$C_CRIT";; esac
        printf '\n%sStato generale: %s%s%s - %d critici, %d avvisi, %d ok (%d s)\n' "$C_B" "$sc" "$SEM" "$C_0" "$N_CRIT" "$N_WARN" "$N_OK" "$DUR"
        printf 'Report: %s\n        %s\n' "$base.html" "$base.json"
    fi
    if [ "$SERVE" -eq 1 ]; then
        local py=""; have python3 && py=python3; [ -z "$py" ] && have python && py=python
        if [ -z "$py" ]; then echo "Per --serve serve python3 (non trovato). Il report resta in $OUT_DIR." >&2; exit "$code"; fi
        echo; echo "Report disponibile su http://${SERVE_BIND}:${SERVE_PORT}/  (Ctrl+C per terminare)"
        [ "$SERVE_BIND" != "127.0.0.1" ] && echo "ATTENZIONE: il report e' visibile a chiunque raggiunga questo indirizzo."
        cd "$OUT_DIR" && exec "$py" -m http.server "$SERVE_PORT" --bind "$SERVE_BIND"
    fi
    exit "$code"
}
# --- fine parte comune ---------------------------------------------------------------------------

have pvesh || { echo "pvesh non trovato: questo strumento va eseguito su un nodo Proxmox VE." >&2; exit 3; }
have perl || { echo "perl non trovato." >&2; exit 3; }
[ "$IS_ROOT" -eq 1 ] || { echo "Serve root: su Proxmox VE eseguire come root." >&2; exit 3; }
NOW="$START_TS"; S=$'\037'

# pv PERCORSO [opzioni]: chiamata API in sola lettura, JSON su stdout
pv() { tmo 60 pvesh get "$@" --output-format json 2>/dev/null; }
# jt "campo1 campo2 a.b": da JSON (elenco di oggetti, o un oggetto solo) a righe con i campi separati da \037
jt() { perl -MJSON::PP -e '
    my @f = split / /, shift; local $/; my $d = eval { decode_json(<STDIN>) }; exit 1 unless defined $d;
    $d = [$d] if ref $d eq "HASH"; exit 1 unless ref $d eq "ARRAY";
    for my $o (@$d) { next unless ref $o eq "HASH";
        print join("\x1f", map { my $v = $o; for my $k (split /\./, $_) { $v = ref $v eq "HASH" ? $v->{$k} : undef }
            $v = "" if !defined $v || ref $v; $v =~ s/[\r\n\t\x1f]+/ /g; $v } @f), "\n" }' "$1"; }
days_ago() { echo $(( (NOW - $1) / 86400 )); }
fmt_date() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$1"; }
pct() { awk -v u="${1:-0}" -v t="${2:-0}" 'BEGIN{ if (t>0) printf "%d", u*100/t; else print 0 }'; }

# --- nodi e cluster ----------------------------------------------------------------------------
PVE_VER="$(pveversion 2>/dev/null | head -n1)"
[ -n "$PVE_VER" ] && add "Cluster e nodi" "Versione" INFO "$PVE_VER"
CL_JSON="$(pv /cluster/status)"
[ -z "$CL_JSON" ] && { echo "pvesh non risponde (servizio pve-cluster fermo?)." >&2; exit 3; }
IS_CLUSTER=0; NODES_ON=(); CL_NAME=""
while IFS="$S" read -r type name online quorate nodes; do
    if [ "$type" = "cluster" ]; then
        IS_CLUSTER=1; CL_NAME="$name"
        if [ "$quorate" = "1" ]; then add "Cluster e nodi" "Cluster $name" OK "Quorum presente, $nodes nodi"
        else add "Cluster e nodi" "Cluster $name" CRIT "Quorum ASSENTE: la configurazione e' in sola lettura e le VM non si possono avviare" "" "Riportare in linea i nodi mancanti"; fi
    elif [ "$type" = "node" ]; then
        if [ "$online" = "1" ]; then NODES_ON+=("$name"); else add "Cluster e nodi" "Nodo $name" CRIT "Nodo non raggiungibile" "" "Verificare alimentazione, rete e servizio corosync del nodo"; fi
    fi
done < <(jt "type name online quorate nodes" <<<"$CL_JSON")
[ "${#NODES_ON[@]}" -eq 0 ] && NODES_ON=("$HOST")
[ "$IS_CLUSTER" -eq 0 ] && add "Cluster e nodi" "Tipo" INFO "Nodo singolo (nessun cluster)"

for n in "${NODES_ON[@]}"; do
    IFS="$S" read -r mu mt ru rt up < <(pv "/nodes/$n/status" | jt "memory.used memory.total rootfs.used rootfs.total uptime")
    if [ -n "$mt" ]; then
        mp="$(pct "$mu" "$mt")"; rp="$(pct "$ru" "$rt")"
        st=OK; [ "$mp" -ge 90 ] && st=WARN
        add "Cluster e nodi" "Nodo $n: memoria" "$st" "RAM usata ${mp}% ($(human "$mu") di $(human "$mt")) - acceso da $(( ${up:-0} / 86400 )) giorni" "" "$([ $st = WARN ] && echo "Poca memoria libera per le VM: ridurre le assegnazioni o aggiungere RAM")"
        st=OK; [ "$rp" -ge "$ST_WARN" ] && st=WARN; [ "$rp" -ge "$ST_CRIT" ] && st=CRIT
        add "Cluster e nodi" "Nodo $n: disco di sistema" "$st" "Usato ${rp}% ($(human "$ru") di $(human "$rt"))" "" "$([ $st != OK ] && echo "Liberare spazio su / (log, ISO e backup in /var/lib/vz, kernel vecchi)")"
    else add "Cluster e nodi" "Nodo $n" NA "Stato del nodo non leggibile"; fi
    # servizi essenziali
    bad=""
    while IFS="$S" read -r sname state; do
        case "$sname" in pve-cluster|pvedaemon|pveproxy|pvestatd|pvescheduler) ;; corosync) [ "$IS_CLUSTER" -eq 1 ] || continue ;; *) continue ;; esac
        [ "$state" = "running" ] || bad="$bad $sname($state)"
    done < <(pv "/nodes/$n/services" | jt "name state")
    if [ -n "$bad" ]; then add "Cluster e nodi" "Nodo $n: servizi" CRIT "Servizi Proxmox non in esecuzione:$bad" "" "systemctl status <servizio> sul nodo $n"
    else add "Cluster e nodi" "Nodo $n: servizi" OK "Servizi Proxmox essenziali in esecuzione"; fi
    # dischi fisici
    dbad=""; dwear=""; nd=0
    while IFS="$S" read -r dev health wear model; do
        [ -z "$dev" ] && continue; nd=$((nd+1))
        case "$health" in PASSED|OK|"") ;; UNKNOWN) ;; *) dbad="$dbad$dev ($model): $health"$'\n' ;; esac
        if [[ "$wear" =~ ^[0-9]+$ ]] && [ "$wear" -le 20 ]; then dwear="$dwear$dev ($model): vita residua ${wear}%"$'\n'; fi
    done < <(pv "/nodes/$n/disks/list" | jt "devpath health wearout model")
    if [ -n "$dbad" ]; then add "Cluster e nodi" "Nodo $n: dischi" CRIT "SMART segnala problemi" "${dbad%$'\n'}" "Sostituire il disco prima possibile"
    elif [ -n "$dwear" ]; then add "Cluster e nodi" "Nodo $n: dischi" WARN "SSD vicini a fine vita" "${dwear%$'\n'}" "Pianificare la sostituzione"
    elif [ "$nd" -gt 0 ]; then add "Cluster e nodi" "Nodo $n: dischi" OK "$nd dischi, SMART senza errori"; fi
    # aggiornamenti in attesa (elenco gia' scaricato dal nodo)
    nu="$(pv "/nodes/$n/apt/update" | jt "Package" | grep -c .)"
    if [ "${nu:-0}" -gt 0 ]; then add "Cluster e nodi" "Nodo $n: aggiornamenti" INFO "$nu pacchetti aggiornabili" "" "Aggiornare in una finestra di manutenzione (apt update && apt dist-upgrade)"; fi
done

# --- storage -----------------------------------------------------------------------------------
declare -A ST_SEEN BK_STORES
for n in "${NODES_ON[@]}"; do
    while IFS="$S" read -r sname stype content active enabled total used shared; do
        [ -z "$sname" ] && continue; [ "$enabled" = "0" ] && continue
        key="$sname"; [ "$shared" = "1" ] || key="$n/$sname"
        [ -n "${ST_SEEN[$key]:-}" ] && continue; ST_SEEN[$key]=1
        lab="$sname"; [ "$shared" = "1" ] || [ "${#NODES_ON[@]}" -eq 1 ] || lab="$sname su $n"
        if [ "$active" != "1" ]; then add "Storage" "$lab ($stype)" CRIT "Storage non attivo" "" "Verificare il collegamento (rete, share, pool) da Datacenter > Storage"; continue; fi
        case ",$content," in *,backup,*) BK_STORES[$key]="$n$S$sname" ;; esac
        [ "${total:-0}" = "0" ] && { add "Storage" "$lab ($stype)" INFO "Attivo, capienza non riportata"; continue; }
        p="$(pct "$used" "$total")"; st=OK; [ "$p" -ge "$ST_WARN" ] && st=WARN; [ "$p" -ge "$ST_CRIT" ] && st=CRIT
        add "Storage" "$lab ($stype)" "$st" "Usato ${p}% ($(human "$used") di $(human "$total")) - contenuto: $content" "" "$([ $st != OK ] && echo "Liberare spazio o ampliare lo storage: con lo storage pieno le VM si bloccano e i backup falliscono")"
    done < <(pv "/nodes/$n/storage" | jt "storage type content active enabled total used shared")
done

# --- guest (VM e container) --------------------------------------------------------------------
declare -A G_NAME G_TYPE G_NODE G_STATUS G_TPL G_ONBOOT G_SNAPS B_LAST B_SIZE B_VER B_COUNT
VMIDS=(); n_run=0; n_stop=0; n_tpl=0; locked=""
while IFS="$S" read -r vmid name type node status tpl lock; do
    [ -z "$vmid" ] && continue
    VMIDS+=("$vmid"); G_NAME[$vmid]="$name"; G_TYPE[$vmid]="$type"; G_NODE[$vmid]="$node"; G_STATUS[$vmid]="$status"; G_TPL[$vmid]="${tpl:-0}"
    if [ "${tpl:-0}" = "1" ]; then n_tpl=$((n_tpl+1)); elif [ "$status" = "running" ]; then n_run=$((n_run+1)); else n_stop=$((n_stop+1)); fi
    [ -n "$lock" ] && locked="$locked$vmid $name: lock=$lock"$'\n'
done < <(pv /cluster/resources --type vm | jt "vmid name type node status template lock" | sort -t "$S" -k1,1n)
add "VM e container" "Riepilogo" INFO "${#VMIDS[@]} guest: $n_run accesi, $n_stop spenti, $n_tpl template"
[ -n "$locked" ] && add "VM e container" "Guest bloccati" WARN "Guest con un blocco attivo (normale solo durante backup, migrazione o snapshot in corso)" "${locked%$'\n'}" "Se nessuna operazione e' in corso: qm unlock <vmid> oppure pct unlock <vmid>"

# avvio automatico e snapshot: letti dai file di configurazione, senza una chiamata API per guest
old_snaps=""; n_old=0; noboot=""
for vmid in "${VMIDS[@]}"; do
    sub="qemu-server"; [ "${G_TYPE[$vmid]}" = "lxc" ] && sub="lxc"
    conf="$ETC/nodes/${G_NODE[$vmid]}/$sub/$vmid.conf"
    [ -r "$conf" ] || continue
    G_ONBOOT[$vmid]=0; ns=0
    while read -r kind a b; do
        if [ "$kind" = "O" ]; then G_ONBOOT[$vmid]="$a"
        elif [ "$kind" = "S" ]; then ns=$((ns+1)); d="$(days_ago "$b")"
            if [ "$d" -gt "$SNAP_DAYS" ]; then n_old=$((n_old+1)); old_snaps="$old_snaps$vmid ${G_NAME[$vmid]}: snapshot '$a' di $d giorni fa"$'\n'; fi
        fi
    done < <(awk '/^\[/{sec=$0; gsub(/[\[\]]/,"",sec); next} sec=="" && /^onboot:/{print "O", $2} sec!="" && /^snaptime:/{print "S", sec, $2}' "$conf")
    G_SNAPS[$vmid]="$ns"
    [ "${G_TPL[$vmid]}" != "1" ] && [ "${G_STATUS[$vmid]}" = "running" ] && [ "${G_ONBOOT[$vmid]}" != "1" ] && noboot="$noboot$vmid ${G_NAME[$vmid]}"$'\n'
done
if [ "$n_old" -gt 0 ]; then add "VM e container" "Snapshot dimenticati" WARN "$n_old snapshot piu' vecchi di $SNAP_DAYS giorni: occupano spazio che cresce e rallentano il disco" "${old_snaps%$'\n'}" "Eliminare gli snapshot che non servono piu' (uno snapshot non e' un backup)"
else add "VM e container" "Snapshot" OK "Nessuno snapshot piu' vecchio di $SNAP_DAYS giorni"; fi
[ -n "$noboot" ] && add "VM e container" "Avvio automatico" INFO "Guest accesi che non ripartono da soli dopo un riavvio del nodo" "${noboot%$'\n'}" "Se devono ripartire da soli: Opzioni > Avvia all'accensione"

# --- backup ------------------------------------------------------------------------------------
n_guest=$(( n_run + n_stop ))
JOBS="$(pv /cluster/backup | jt "id enabled schedule storage")"
n_jobs="$(grep -c . <<<"$JOBS")"; n_jobs_on=0
while IFS="$S" read -r jid en sched jst; do [ -z "$jid" ] && continue; [ "$en" = "0" ] || n_jobs_on=$((n_jobs_on+1)); done <<<"$JOBS"
if [ "$n_guest" -eq 0 ]; then add "Backup" "Job pianificati" INFO "Nessun guest da salvare"
elif [ "$n_jobs_on" -eq 0 ]; then add "Backup" "Job pianificati" CRIT "Nessun job di backup attivo$([ "$n_jobs" -gt 0 ] && echo " ($n_jobs presenti ma disattivati)")" "" "Creare un job da Datacenter > Backup"
else add "Backup" "Job pianificati" OK "$n_jobs_on job attivi$([ "$n_jobs" -gt "$n_jobs_on" ] && echo ", $((n_jobs - n_jobs_on)) disattivati")" "$(while IFS="$S" read -r jid en sched jst; do [ -n "$jid" ] && echo "$jid: $sched -> $jst$([ "$en" = "0" ] && echo " (disattivato)")"; done <<<"$JOBS")"; fi
NB="$(pv /cluster/backup-info/not-backed-up | jt "vmid name type")"
if [ -n "$NB" ]; then
    lst=""; c=0; while IFS="$S" read -r vmid name type; do [ -z "$vmid" ] && continue; [ "${G_TPL[$vmid]:-0}" = "1" ] && continue; c=$((c+1)); lst="$lst$vmid $name ($type)"$'\n'; done <<<"$NB"
    [ "$c" -gt 0 ] && add "Backup" "Guest fuori dai job" WARN "$c guest non inclusi in nessun job di backup" "${lst%$'\n'}" "Aggiungerli a un job, oppure usare la selezione 'Tutti'"
fi
# backup presenti sugli storage
n_ver_bad=0; ver_bad=""; orphan_n=0; orphan_sz=0; bk_unread=""
for key in "${!BK_STORES[@]}"; do
    IFS="$S" read -r bn bs <<<"${BK_STORES[$key]}"
    CONT="$(pv "/nodes/$bn/storage/$bs/content" --content backup)" || { bk_unread="$bk_unread $bs"; continue; }
    while IFS="$S" read -r vmid ctime size vstate volid; do
        [ -z "$vmid" ] && continue
        B_COUNT[$vmid]=$(( ${B_COUNT[$vmid]:-0} + 1 ))
        if [ "${ctime:-0}" -gt "${B_LAST[$vmid]:-0}" ]; then B_LAST[$vmid]="$ctime"; B_SIZE[$vmid]="$size"; B_VER[$vmid]="$vstate"; fi
        if [ "$vstate" = "failed" ]; then n_ver_bad=$((n_ver_bad+1)); ver_bad="$ver_bad$volid"$'\n'; fi
        if [ -z "${G_NAME[$vmid]+x}" ]; then orphan_n=$((orphan_n+1)); orphan_sz=$(( orphan_sz + ${size:-0} )); fi
    done < <(jt "vmid ctime size verification.state volid" <<<"$CONT")
done
[ -n "$bk_unread" ] && add "Backup" "Storage di backup" WARN "Contenuto non leggibile:$bk_unread" "" "Verificare che lo storage risponda"
if [ "${#BK_STORES[@]}" -eq 0 ] && [ "$n_guest" -gt 0 ]; then add "Backup" "Storage di backup" CRIT "Nessuno storage attivo abilitato per i backup" "" "Aggiungere uno storage con contenuto 'backup', meglio se su un'altra macchina (PBS o NAS)"; fi
none=""; n_none=0; old=""; n_old_b=0; n_fresh=0
for vmid in "${VMIDS[@]}"; do
    [ "${G_TPL[$vmid]}" = "1" ] && continue
    if [ -z "${B_LAST[$vmid]:-}" ]; then n_none=$((n_none+1)); none="$none$vmid ${G_NAME[$vmid]} (${G_STATUS[$vmid]})"$'\n'
    else d="$(days_ago "${B_LAST[$vmid]}")"
        if [ "$d" -gt "$BK_DAYS" ]; then n_old_b=$((n_old_b+1)); old="$old$vmid ${G_NAME[$vmid]}: ultimo backup $d giorni fa ($(fmt_date "${B_LAST[$vmid]}"))"$'\n'; else n_fresh=$((n_fresh+1)); fi
    fi
done
if [ "$n_guest" -gt 0 ]; then
    [ "$n_none" -gt 0 ] && add "Backup" "Guest senza backup" CRIT "$n_none guest senza nessun backup sugli storage" "${none%$'\n'}" "Eseguire un backup e includerli in un job"
    [ "$n_old_b" -gt 0 ] && add "Backup" "Backup vecchi" WARN "$n_old_b guest con l'ultimo backup piu' vecchio di $BK_DAYS giorni" "${old%$'\n'}" "Controllare il job e l'esito degli ultimi backup"
    [ "$n_none" -eq 0 ] && [ "$n_old_b" -eq 0 ] && add "Backup" "Copertura" OK "Tutti i $n_fresh guest hanno un backup degli ultimi $BK_DAYS giorni"
fi
[ "$n_ver_bad" -gt 0 ] && add "Backup" "Verifica PBS" CRIT "$n_ver_bad backup con verifica fallita su Proxmox Backup Server" "$(head -n 15 <<<"${ver_bad%$'\n'}")" "Quei backup non sono affidabili: rifarli e controllare il datastore"
[ "$orphan_n" -gt 0 ] && add "Backup" "Backup di guest eliminati" INFO "$orphan_n backup ($(human "$orphan_sz")) appartengono a VMID che non esistono piu'" "" "Se non servono, eliminarli per recuperare spazio"
# job di backup falliti di recente
since=$(( NOW - TASK_DAYS * 86400 )); fails=""; nf=0
for n in "${NODES_ON[@]}"; do
    while IFS="$S" read -r stt status id; do
        [ -z "$stt" ] && continue; [ "$stt" -lt "$since" ] && continue
        case "$status" in ""|OK|RUNNING|unknown|WARNINGS*) continue ;; esac   # "errors" esclude solo gli OK
        nf=$((nf+1)); fails="$fails$(fmt_date "$stt") nodo $n${id:+ vmid $id}: $status"$'\n'
    done < <(pv "/nodes/$n/tasks" --typefilter vzdump --errors 1 --limit 200 | jt "starttime status id")
done
if [ "$nf" -gt 0 ]; then add "Backup" "Backup falliti" WARN "$nf operazioni di backup con errori negli ultimi $TASK_DAYS giorni" "$(head -n 15 <<<"${fails%$'\n'}")" "Aprire il log dell'operazione in Proxmox per il dettaglio"
elif [ "$n_jobs_on" -gt 0 ]; then add "Backup" "Backup falliti" OK "Nessuna operazione di backup con errori negli ultimi $TASK_DAYS giorni"; fi
add "Backup" "Promemoria" INFO "Questo controllo dice che i backup esistono e sono recenti, non che si ripristinano: provare un ripristino ogni tanto"

extra_json() {
    local i=0 tot="${#VMIDS[@]}" vmid
    printf '  "cluster": "%s",\n  "guest": [\n' "$(json_esc "$CL_NAME")"
    for vmid in "${VMIDS[@]}"; do
        i=$((i+1))
        printf '    {"vmid": %s, "nome": "%s", "tipo": "%s", "nodo": "%s", "stato": "%s", "template": %s, "avvio_automatico": %s, "snapshot": %s, "ultimo_backup": %s, "numero_backup": %s}%s\n' \
            "$vmid" "$(json_esc "${G_NAME[$vmid]}")" "${G_TYPE[$vmid]}" "$(json_esc "${G_NODE[$vmid]}")" "${G_STATUS[$vmid]}" "$([ "${G_TPL[$vmid]}" = "1" ] && echo true || echo false)" \
            "$([ "${G_ONBOOT[$vmid]:-0}" = "1" ] && echo true || echo false)" "${G_SNAPS[$vmid]:-0}" "${B_LAST[$vmid]:-null}" "${B_COUNT[$vmid]:-0}" "$([ "$i" -lt "$tot" ] && echo ,)"
    done
    printf '  ],\n'
}
extra_html() {
    [ "${#VMIDS[@]}" -eq 0 ] && return
    local vmid lb cls d
    printf '<h2>VM e container (%s)</h2>\n<div class="tblwrap"><table><tr><th>VMID</th><th>Nome</th><th>Tipo</th><th>Nodo</th><th>Stato</th><th>Avvio auto</th><th>Snapshot</th><th>Ultimo backup</th><th>Dimensione</th><th>N. backup</th></tr>\n' "${#VMIDS[@]}"
    for vmid in "${VMIDS[@]}"; do
        cls=""; lb="-"
        if [ "${G_TPL[$vmid]}" = "1" ]; then lb="template"
        elif [ -n "${B_LAST[$vmid]:-}" ]; then d="$(days_ago "${B_LAST[$vmid]}")"; lb="$(fmt_date "${B_LAST[$vmid]}") ($d g)"; [ "$d" -gt "$BK_DAYS" ] && cls=' class="chg"'
        else lb="NESSUNO"; cls=' class="chg"'; fi
        printf '<tr%s><td class="mono">%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$cls" "$vmid" "$(html_esc "${G_NAME[$vmid]}")" \
            "$([ "${G_TYPE[$vmid]}" = "lxc" ] && echo CT || echo VM)" "$(html_esc "${G_NODE[$vmid]}")" "${G_STATUS[$vmid]}" "$([ "${G_ONBOOT[$vmid]:-0}" = "1" ] && echo si || echo no)" "${G_SNAPS[$vmid]:-0}" "$lb" \
            "$([ -n "${B_SIZE[$vmid]:-}" ] && human "${B_SIZE[$vmid]}" || echo -)" "${B_COUNT[$vmid]:-0}"
    done
    printf '</table></div>\n'
}
finish
