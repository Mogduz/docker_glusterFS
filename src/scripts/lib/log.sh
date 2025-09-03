#!/usr/bin/env bash
# Logging & UI helpers

TS() { date +"%Y-%m-%d %H:%M:%S%z"; }
if [ -t 1 ]; then
  C_BOLD="\e[1m"; C_DIM="\e[2m"; C_RESET="\e[0m"
  C_BLUE="\e[34m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_RED="\e[31m"; C_CYAN="\e[36m"; C_MAGENTA="\e[35m"
else
  C_BOLD=""; C_DIM=""; C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_MAGENTA=""
fi

log()  { echo -e "[$(TS)] ${C_BLUE}INFO${C_RESET}  $*"; }
ok()   { echo -e "[$(TS)] ${C_GREEN}OK${C_RESET}    $*"; }
warn() { echo -e "[$(TS)] ${C_YELLOW}WARN${C_RESET}  $*"; }
err()  { echo -e "[$(TS)] ${C_RED}ERROR${C_RESET} $*"; }
step() { echo -e "\n${C_BOLD}${C_MAGENTA}==>${C_RESET} $*"; }
banner() {
  echo -e "${C_BOLD}${C_CYAN}\n  GlusterFS Container Entrypoint\n${C_RESET}"
}
