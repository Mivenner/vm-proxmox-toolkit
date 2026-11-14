#!/usr/bin/env bash
# Prova lo script contro un finto pvesh (tests/mock): due scenari, uno con problemi e uno sano.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; script="$here/../vm-pve-check.sh"
etc="$(mktemp -d)"; now=$(date +%s); trap 'rm -rf "$etc" /tmp/pvetest' EXIT
mkdir -p "$etc/nodes/pve1/qemu-server" "$etc/nodes/pve1/lxc" "$etc/nodes/pve2/qemu-server"
printf 'name: srv-dc01\nonboot: 1\n\n[pre-aggiornamento]\nonboot: 1\nsnaptime: %s\n\n[ieri]\nparent: pre-aggiornamento\nsnaptime: %s\n' $((now-95*86400)) $((now-86400)) > "$etc/nodes/pve1/qemu-server/100.conf"
printf 'name: gestionale\n' > "$etc/nodes/pve1/qemu-server/101.conf"
printf 'name: tpl-debian12\ntemplate: 1\n' > "$etc/nodes/pve1/qemu-server/9000.conf"
printf 'hostname: pihole\nonboot: 1\n' > "$etc/nodes/pve1/lxc/200.conf"
printf 'name: test-win11\nlock: backup\n' > "$etc/nodes/pve2/qemu-server/102.conf"
printf 'name: nuova-vm\nonboot: 0\n' > "$etc/nodes/pve2/qemu-server/103.conf"
export PATH="$here/mock:$PATH" VMPVE_ETC="$etc"
fail() { echo "FALLITO: $*"; exit 1; }
out="$(SCENARIO=problemi bash "$script" --no-color -o /tmp/pvetest)"; rc=$?
echo "$out"
[ "$rc" -eq 2 ] || fail "scenario problemi: atteso codice 2, avuto $rc"
for t in "Nodo pve3: Nodo non raggiungibile" "pvestatd(dead)" "SMART segnala problemi" "nas-nfs (nfs): Storage non attivo" "102 test-win11: lock=backup" "snapshot 'pre-aggiornamento' di 95 giorni fa" \
         "2 guest non inclusi" "2 guest senza nessun backup" "101 gestionale: ultimo backup 15 giorni fa" "1 backup con verifica fallita" "1 backup (40.0 GB)" "1 operazioni di backup con errori"; do
    grep -qF "$t" <<<"$out" || fail "manca: $t"
done
grep -q "<table>" /tmp/pvetest/index.html || fail "tabella dei guest assente nel report"
SCENARIO=problemi bash "$script" --json | perl -MJSON::PP -e 'local $/; my $d=decode_json(<STDIN>); die "json" unless $d->{semaforo} eq "ROSSO" && @{$d->{guest}}==6; print "JSON ok\n"' || fail "JSON non valido"
SCENARIO=sano bash "$script" --no-color --giorni-snapshot 120 -o /tmp/pvetest; rc=$?
[ "$rc" -eq 0 ] || fail "scenario sano: atteso codice 0, avuto $rc"
echo "TUTTI I TEST SUPERATI"
