#!/bin/bash
#title       : unifi_controller_backup.sh
#description : Backs up UniFi OS Network controllers via the API.
#author      : SXN31
#version     : 2.0
#usage       : unifi_controller_backup.sh [-c config_file] [-d controllers_dir] [-v] [-h]
#
# note: on the Synology, Task Scheduler runs this as the task's configured user,
# which is what grants it access to the backup share (BACKUP_DIR/UCB_LOG_FILE).
# Running it from another machine/user reaches the UniFi controller fine, but
# will fail on any BACKUP_DIR/UCB_LOG_FILE path that only that Synology user
# context can reach - that's expected outside of the Synology, not a bug.

set -u
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$(basename "${BASH_SOURCE[0]}")
LONG_NAME="Unifi Controller Backup"
VERSION="2.0"

CONFIG_FILE="${SCRIPT_DIR}/config"
DIR_UNIFIS_CONFIG="${SCRIPT_DIR}/controllers"
VERBOSE=0
EXIT_CODE=0

help() {
  cat <<EOF

Help documentation for ${LONG_NAME}, version ${VERSION}

Basic usage: ${SCRIPT}

Command line switches are optional. The following switches are recognized.
  -c  Sets the config file path. Default file is ${CONFIG_FILE}
  -d  Sets the directory path with all the controller configs. Default directory is ${DIR_UNIFIS_CONFIG}
  -v  Sets verbose mode (bash 'set -x'), not set by default
  -h  Displays this help message. No further functions are performed.

Example: ${SCRIPT} -c ${CONFIG_FILE} -d ${DIR_UNIFIS_CONFIG}
EOF
  exit 1
}

while getopts "c:d:vh" OPT; do
  case "${OPT}" in
    c) CONFIG_FILE=${OPTARG} ;;
    d) DIR_UNIFIS_CONFIG=${OPTARG} ;;
    v) VERBOSE=1; set -x ;;
    h|\?) help ;;
  esac
done

write_log() {
  # $1 = level (INFO|ERROR), $2 = message
  local level="$1" message="$2" date_log

  if [ ! -f "${UCB_LOG_FILE}" ]; then
    mkdir -p "$(dirname "${UCB_LOG_FILE}")" 2>/dev/null
    if ! touch "${UCB_LOG_FILE}" 2>/dev/null; then
      date_log=$(date "+%Y-%m-%d %H:%M:%S")
      echo "${date_log}: [ERROR] Can't create log file ${UCB_LOG_FILE}" >&2
      return 1
    fi
    echo "$(date "+%Y-%m-%d %H:%M:%S"): [INFO] Log file ${UCB_LOG_FILE} did not exist, created it" >> "${UCB_LOG_FILE}"
  fi

  date_log=$(date "+%Y-%m-%d %H:%M:%S")
  echo "${date_log}: [${level}] ${message}" >> "${UCB_LOG_FILE}"
  [ "${VERBOSE}" = "1" ] && echo "${date_log}: [${level}] ${message}" >&2
  return 0
}

log_info()  { write_log "INFO" "$1"; }
log_error() { write_log "ERROR" "$1"; EXIT_CODE=1; }

get_date() { date +%Y%m%d; }

check_backup_requirements() {
  if [ ! -f "${UNIFI_SH_API_PATH}" ]; then
    log_error "unifi_sh_api not found at ${UNIFI_SH_API_PATH}"
    return 1
  fi

  if [ ! -d "${BACKUP_DIR}" ]; then
    log_info "Backup dir ${BACKUP_DIR} does not exist, creating it"
    if ! mkdir -p "${BACKUP_DIR}" 2>/dev/null; then
      log_error "Could not create backup dir ${BACKUP_DIR} (permissions? wrong user context?)"
      return 1
    fi
  fi

  if [ ! -w "${BACKUP_DIR}" ]; then
    log_error "Backup dir ${BACKUP_DIR} is not writable by the current user ($(id -un 2>/dev/null))"
    return 1
  fi

  return 0
}

clean_old_backups() {
  local number_of_copies delete
  # shellcheck disable=SC2086  # DELETE_PATERN is a glob, must not be quoted
  number_of_copies=$(ls -1 ${DELETE_PATERN} 2>/dev/null | wc -l)

  log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> We must keep ${KEEP_BACKUP} backups and we have ${number_of_copies}"

  if [ "${number_of_copies}" -gt "${KEEP_BACKUP}" ]; then
    delete=$(( number_of_copies - KEEP_BACKUP ))
    log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Deleting ${delete} old copies"
    # shellcheck disable=SC2086  # DELETE_PATERN is a glob, must not be quoted
    if ! ls -1 ${DELETE_PATERN} 2>/dev/null | head -n "${delete}" | xargs -r rm --; then
      log_error "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Failed to delete some old copies"
    fi
  else
    log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> No old copies to delete"
  fi
}

backup_site() {
  site="$1"
  local date backup_size

  date=$(get_date)
  BACKUP_FILENAME="${BACKUP_DIR}/${date}-${UNIFI_HOSTNAME}-${site}.unf"
  DELETE_PATERN="${BACKUP_DIR}/*-${UNIFI_HOSTNAME}-${site}.unf"

  log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Login"
  if ! unifi_login; then
    log_error "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Login failed, skipping this site"
    return 1
  fi

  log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Requesting backup -> ${BACKUP_FILENAME}"
  if ! unifi_backup "${BACKUP_FILENAME}"; then
    log_error "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Backup failed, no file was produced"
    unifi_logout 2>/dev/null
    return 1
  fi

  backup_size=$(du -sh "${BACKUP_FILENAME}" 2>/dev/null | cut -f1)
  log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Size of ${BACKUP_FILENAME} is ${backup_size:-unknown}"

  log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Cleaning old backups"
  clean_old_backups

  log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Logout"
  if ! unifi_logout; then
    log_error "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Logout request failed (non-fatal)"
  fi

  return 0
}

backup_controller() {
  local controller_conf="$1"

  # Clear vars a previous controller's conf may have set, so a missing
  # variable in this conf can't silently inherit the last controller's value.
  unset username password baseurl SITES UNIFI_VERSION UNIFI_HOSTNAME KEEP_BACKUP site

  if [ ! -r "${controller_conf}" ]; then
    log_error "Controller config ${controller_conf} is not readable"
    return 1
  fi
  # shellcheck source=/dev/null
  source "${controller_conf}"

  if [ -z "${username-}" ] || [ -z "${password-}" ] || [ -z "${baseurl-}" ] || \
     [ -z "${SITES-}" ] || [ -z "${UNIFI_HOSTNAME-}" ] || [ -z "${KEEP_BACKUP-}" ]; then
    log_error "Controller config ${controller_conf} is missing one or more required variables (username/password/baseurl/SITES/UNIFI_HOSTNAME/KEEP_BACKUP)"
    return 1
  fi

  check_backup_requirements || return 1

  # shellcheck source=/dev/null
  source "${UNIFI_SH_API_PATH}"

  log_info "Finding sites for ${UNIFI_HOSTNAME}"
  local controller_rc=0
  for site in ${SITES}; do
    log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Starting"
    if backup_site "${site}"; then
      log_info "Hostname: ${UNIFI_HOSTNAME}, Site: ${site} -> Finished"
    else
      controller_rc=1
    fi
  done
  return ${controller_rc}
}

main() {
  if [ ! -r "${CONFIG_FILE}" ]; then
    echo "Config file ${CONFIG_FILE} not found or not readable" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"

  if [ -z "${UCB_LOG_FILE-}" ]; then
    echo "UCB_LOG_FILE is not set in ${CONFIG_FILE}" >&2
    exit 1
  fi

  : "${UNIFI_SH_API_PATH:=${SCRIPT_DIR}/unifi_sh_api.sh}"
  : "${BACKUP_DIR:?BACKUP_DIR is not set in ${CONFIG_FILE}}"

  if [ ! -d "${DIR_UNIFIS_CONFIG}" ]; then
    log_error "Controllers directory ${DIR_UNIFIS_CONFIG} does not exist"
    exit 1
  fi

  shopt -s nullglob
  local controllers=("${DIR_UNIFIS_CONFIG}"/*.conf)
  shopt -u nullglob

  if [ "${#controllers[@]}" -eq 0 ]; then
    log_error "No controller *.conf files found in ${DIR_UNIFIS_CONFIG}"
    exit 1
  fi

  local controller
  for controller in "${controllers[@]}"; do
    log_info "Starting backup from the file ${controller}"
    if backup_controller "${controller}"; then
      log_info "Finished backup from the file ${controller}"
    else
      log_error "Finished backup from the file ${controller} with errors"
    fi
  done

  exit ${EXIT_CODE}
}

trap 'unifi_logout 2>/dev/null || true' EXIT

main
