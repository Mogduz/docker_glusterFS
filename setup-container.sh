# === [DOC] Autogenerierte Inline-Dokumentation: setup-container.sh ===
# Datei: setup-container.sh
# Typ: POSIX/Bash-Shellskript.
# Zweck: Steuerung/Bootstrap/Start des Gluster-Dienstes bzw. Solo-Setups.
# Wichtige Aspekte: Fehlerbehandlung (fatal/log), Umgebungsvariablen, Brick/Volume-Handling, YAML-Parsing.
# Erkannte Funktionen: abort, info, ok
# Sicherheitsaspekte: Skript bricht bei Fehlern ab, prüft Pfade/Rechte, loggt diagnostische Infos.
# === [DOC-END] ===

#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------------------------
# setup-container.sh
#
# Listet Compose-Dateien im Projekt, lässt eine auswählen, fragt einen Container-
# namen ab, erzeugt containers/<name> und kopiert:
#   - die ausgewählte Compose-Datei        -> containers/<name>/<originaler Name>
#   - passende .env.example (aus examples/env) -> containers/<name>/.env
#   - Standard-Volume-File (example/volumes/volume.full.yml.example)
#         -> containers/<name>/volumes.yml
#
# Annahme: Skript wird im Projekt-Root ausgeführt (dort, wo auch die Compose-Datei liegt).
# ------------------------------------------------------------------------------
# ---
# Funktion: 
# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

abort() { echo "ERROR: $*" >&2; exit 1; }
# ---
# Funktion: info()  
# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---
info()  { echo "• $*"; }
# ---
# Funktion: ok()    
# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---
ok()    { echo "✔ $*"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="${SCRIPT_DIR}"

# Compose-Dateien strikt im Unterordner 'compose' suchen
mapfile -t COMPOSE_FILES < <(
  find "$PROJECT_DIR/compose" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort
)

# --- Compose-Dateien ermitteln ------------------------------------------------
mapfile -t COMPOSE_FILES < <(
  {
    [ -d "$PROJECT_DIR/compose" ] && find "$PROJECT_DIR/compose" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \);
    find "$PROJECT_DIR" -maxdepth 1 -type f \( -name 'compose*.yml' -o -name 'compose*.yaml' -o -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \);
  } 2>/dev/null | sort
)

(( ${#COMPOSE_FILES[@]} > 0 )) || abort "Keine Compose-Dateien im Projektordner gefunden."

SELECTED_COMPOSE=""
# --- Auswahl (immer numerisch, auch bei nur einer Datei) ----------------------
(( ${#COMPOSE_FILES[@]} > 0 )) || abort "Keine Compose-Dateien im Ordner $PROJECT_DIR/compose gefunden."

echo "Gefundene Compose-Dateien in $PROJECT_DIR/compose:"
for i in "${!COMPOSE_FILES[@]}"; do
  idx=$((i+1))
  printf '  [%d] %s
' "$idx" "$(basename -- "${COMPOSE_FILES[$i]}")"
done

read -r -p "Bitte Nummer wählen [1..${#COMPOSE_FILES[@]}]: " CHOICE
[[ "$CHOICE" =~ ^[0-9]+$ ]] || abort "Ungültige Eingabe: Bitte eine Zahl eingeben."
(( CHOICE >= 1 && CHOICE <= ${#COMPOSE_FILES[@]} )) || abort "Nummer außerhalb des gültigen Bereichs."

SELECTED_COMPOSE="${COMPOSE_FILES[$((CHOICE-1))]}"
compose_filename="$(basename -- "$SELECTED_COMPOSE")"
info "Ausgewählt: ${compose_filename}"

# --- Containername abfragen & validieren -------------------------------------
read -r -p "Containername: " CONTAINER_NAME
[[ -n "${CONTAINER_NAME// }" ]] || abort "Containername darf nicht leer sein."
if [[ ! "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  abort "Ungültiger Containername: Erlaubt sind Buchstaben/Ziffern/._- (nicht mit Sonderzeichen beginnen)."
fi

# --- Zielordner prüfen/anlegen ------------------------------------------------
CONTAINERS_DIR="${PROJECT_DIR}/containers"
TARGET_DIR="${CONTAINERS_DIR}/${CONTAINER_NAME}"
mkdir -p -- "$TARGET_DIR" || abort "Konnte Zielordner nicht erstellen: $TARGET_DIR"
[[ -d "$TARGET_DIR" && -w "$TARGET_DIR" ]] || abort "Zielordner nicht beschreibbar: $TARGET_DIR"
   # ohne .yml/.yaml

# Primärpfade laut Vorgabe:
compose_base="${compose_filename%.*}"   # ohne .yml/.yaml
ENV_EXAMPLE_PRIMARY="${PROJECT_DIR}/examples/env/${compose_base}.env.example"
VOL_EXAMPLE_PRIMARY="${PROJECT_DIR}/examples/volume/volume.full.yml.example"

# Fallbacks (ältere/alternative Repo-Strukturen):
ENV_EXAMPLE_FALLBACK1="${PROJECT_DIR}/examples/env/${compose_base}.env"
ENV_EXAMPLE_FALLBACK2="${PROJECT_DIR}/examples/env/${compose_base}.env"
VOL_EXAMPLE_FALLBACK1="${PROJECT_DIR}/examples/volume/volumes.yml.example"
VOL_EXAMPLE_FALLBACK2="${PROJECT_DIR}/examples/volume/volumes.yml.example"

ENV_SRC=""
for cand in "$ENV_EXAMPLE_PRIMARY" "$ENV_EXAMPLE_FALLBACK1" "$ENV_EXAMPLE_FALLBACK2"; do
  if [[ -f "$cand" ]]; then ENV_SRC="$cand"; break; fi
done
[[ -n "$ENV_SRC" ]] || abort "Keine passende ENV-Beispieldatei gefunden (gesucht: ${ENV_EXAMPLE_PRIMARY})."

VOL_SRC=""
for cand in "$VOL_EXAMPLE_PRIMARY" "$VOL_EXAMPLE_FALLBACK1" "$VOL_EXAMPLE_FALLBACK2"; do
  if [[ -f "$cand" ]]; then VOL_SRC="$cand"; break; fi
done
[[ -n "$VOL_SRC" ]] || abort "Keine Standard-Volume-Datei gefunden (gesucht: ${VOL_EXAMPLE_PRIMARY})."

# --- Kopieren/Umbenennen ------------------------------------------------------
# 1) Compose-Datei (Originalname beibehalten)
cp -v -- "$SELECTED_COMPOSE" "${TARGET_DIR}/${compose_filename}"

# 2) ENV-Beispiel als .env
cp -v -- "$ENV_SRC" "${TARGET_DIR}/.env"

# 3) Standard-Volumenfile als volumes.yml
cp -v -- "$VOL_SRC" "${TARGET_DIR}/volumes.yml"

ok "Setup erzeugt in: ${TARGET_DIR}"
echo "Inhalt:"
printf "  - %s\n" "${compose_filename}" ".env" "volumes.yml"

echo
ok "Fertig. Du kannst jetzt z. B. starten mit:"
echo "  cd containers/${CONTAINER_NAME}"
echo "  docker compose -f ${compose_filename} --env-file .env up -d"