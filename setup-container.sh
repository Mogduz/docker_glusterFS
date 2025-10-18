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

abort() { echo "ERROR: $*" >&2; exit 1; }
info()  { echo "• $*"; }
ok()    { echo "✔ $*"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="${SCRIPT_DIR}"

# --- Compose-Dateien ermitteln ------------------------------------------------
mapfile -t COMPOSE_FILES < <(
  find "$PROJECT_DIR" -maxdepth 1 -type f         \( -name 'compose*.yml' -o -name 'compose*.yaml'            -o -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \)         | sort
)

(( ${#COMPOSE_FILES[@]} > 0 )) || abort "Keine Compose-Dateien im Projektordner gefunden."

SELECTED_COMPOSE=""
if (( ${#COMPOSE_FILES[@]} == 1 )); then
  SELECTED_COMPOSE="${COMPOSE_FILES[0]}"
  info "Eine Compose-Datei gefunden: $(basename "$SELECTED_COMPOSE")"
else
  echo "Gefundene Compose-Dateien:"
  select f in "${COMPOSE_FILES[@]}"; do
    [[ -n "${f:-}" ]] || { echo "Ungültige Auswahl."; continue; }
    SELECTED_COMPOSE="$f"
    break
  done
fi

# --- Containername abfragen & validieren -------------------------------------
read -r -p "Containername: " CONTAINER_NAME
[[ -n "${CONTAINER_NAME// }" ]] || abort "Containername darf nicht leer sein."
# Docker-konforme, einfache Validierung (Buchstaben/Ziffern/._-)
if [[ ! "$CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  abort "Ungültiger Containername: Erlaubt sind Buchstaben/Ziffern/._- (nicht mit Sonderzeichen beginnen)."
fi

# --- Zielordner prüfen/anlegen ------------------------------------------------
CONTAINERS_DIR="${PROJECT_DIR}/containers"
TARGET_DIR="${CONTAINERS_DIR}/${CONTAINER_NAME}"

mkdir -p "$CONTAINERS_DIR"
if [[ -e "$TARGET_DIR" ]]; then
  abort "Der Containername '${CONTAINER_NAME}' ist bereits vergeben (${TARGET_DIR} existiert)."
fi
mkdir -p "$TARGET_DIR"

# --- Pfade ableiten -----------------------------------------------------------
compose_filename="$(basename -- "$SELECTED_COMPOSE")"
compose_base="${compose_filename%.*}"   # ohne .yml/.yaml

# Primärpfade laut Vorgabe:
ENV_EXAMPLE_PRIMARY="${PROJECT_DIR}/examples/env/${compose_base}.env.example"
VOL_EXAMPLE_PRIMARY="${PROJECT_DIR}/example/volumes/volume.full.yml.example"

# Fallbacks (ältere/alternative Repo-Strukturen):
ENV_EXAMPLE_FALLBACK1="${PROJECT_DIR}/env_examples/${compose_base}.env.example"
ENV_EXAMPLE_FALLBACK2="${PROJECT_DIR}/examples/env/${compose_base}.env"
VOL_EXAMPLE_FALLBACK1="${PROJECT_DIR}/examples/volumes/volume.full.yml.example"
VOL_EXAMPLE_FALLBACK2="${PROJECT_DIR}/volume_examples/volume.full-example.yml"

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
