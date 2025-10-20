#!/bin/sh
set -eu
file="${1:-/etc/gluster/volumes.yml}"
# Minimal Sample wenn Datei nicht existiert
if [ ! -s "$file" ]; then
  file="$(mktemp)"
  cat >"$file" <<'YAML'
volumes:
  - name: gv0
    replica: 1
    transport: tcp
    bricks:
      - /bricks/gv0/brick1
YAML
fi
# awk-Block aus solo-start verwenden
file_sh="/usr/local/bin/solo-start.sh"
# extrahiere awk Heredoc und führe aus
awk_start_line=$(awk '/awk -f - "\$file" <<\047AWK\047/{print NR; exit}' "$file_sh")
awk_end_line=$(awk '/^AWK$/{print NR}' "$file_sh" | tail -n1)
if [ -z "$awk_start_line" ] || [ -z "$awk_end_line" ]; then
  echo "SELFTEST: awk heredoc nicht gefunden" >&2
  exit 1
fi
# Awk Programm extrahieren
awk 'NR>start && NR<end {print}' start="$awk_start_line" end="$awk_end_line" "$file_sh" > /tmp/parser.awk

echo "SELFTEST: running awk parser on $file"
awk -f /tmp/parser.awk "$file" || { echo "SELFTEST: awk failed" >&2; exit 2; }
