#!/bin/bash
#title       : unifi_sh_api.sh
#description : Minimal UniFi OS API helper used by unifi_controller_backup.sh.
#author      : SXN31
#version     : 2.0
#
# Rewritten for UniFi OS controllers (UDM/UDM-Pro, UniFi OS Server, etc.), which
# replaced the classic controller API that Ubiquiti's original unifi_sh_api used:
#   - login moved from /api/login             -> /api/auth/login
#   - site endpoints moved from /api/s/<site>  -> /proxy/network/api/s/<site>
#   - requests must send Content-Type: application/json
#   - every response returns a rotating CSRF token (x-updated-csrf-token) that
#     must be echoed back via X-CSRF-Token on the next request
#
# Required env vars before calling unifi_login: username, password, baseurl, site
# Optional: UNIFI_CURL_INSECURE=1 (default) skips TLS verification for the
#           controller's self-signed cert; set to 0 to enforce verification.
#           UNIFI_CURL_TIMEOUT=30 (default) max seconds per request.

: "${UNIFI_CURL_INSECURE:=1}"
: "${UNIFI_CURL_TIMEOUT:=30}"

_UNIFI_COOKIE_JAR=""
_UNIFI_CSRF_TOKEN=""
UNIFI_LAST_HTTP_CODE=""
UNIFI_LAST_BODY=""

unifi_requires() {
  local missing=""
  [ -z "${username-}" ] && missing="${missing} username"
  [ -z "${password-}" ] && missing="${missing} password"
  [ -z "${baseurl-}" ]  && missing="${missing} baseurl"
  [ -z "${site-}" ]     && missing="${missing} site"
  if [ -n "${missing}" ]; then
    echo "unifi_sh_api: missing required variable(s):${missing}" >&2
    return 1
  fi
  return 0
}

_unifi_curl() {
  local insecure_flag=()
  [ "${UNIFI_CURL_INSECURE}" = "1" ] && insecure_flag=(--insecure)
  curl --silent --show-error --tlsv1.2 "${insecure_flag[@]}" --max-time "${UNIFI_CURL_TIMEOUT}" "$@"
}

# Perform a JSON request against the controller, tracking cookies + CSRF token.
# Usage: _unifi_request METHOD URL [JSON_BODY]
# On return 0, UNIFI_LAST_HTTP_CODE and UNIFI_LAST_BODY describe the response
# (caller must still check UNIFI_LAST_HTTP_CODE for HTTP-level errors).
# Returns 1 only on a transport-level failure (DNS, TLS, refused, timeout, ...).
_unifi_request() {
  local method="$1" url="$2" data="${3-}"
  local header_file body_file curl_rc new_token

  header_file=$(mktemp) || { echo "unifi_sh_api: could not create temp file" >&2; return 1; }
  body_file=$(mktemp) || { rm -f "${header_file}"; echo "unifi_sh_api: could not create temp file" >&2; return 1; }

  local args=(-X "${method}" --cookie "${_UNIFI_COOKIE_JAR}" --cookie-jar "${_UNIFI_COOKIE_JAR}"
              -D "${header_file}" -o "${body_file}" -w '%{http_code}'
              -H "Content-Type: application/json")
  [ -n "${_UNIFI_CSRF_TOKEN}" ] && args+=(-H "X-CSRF-Token: ${_UNIFI_CSRF_TOKEN}")
  [ -n "${data}" ] && args+=(--data "${data}")

  UNIFI_LAST_HTTP_CODE=$(_unifi_curl "${args[@]}" "${url}")
  curl_rc=$?

  if [ ${curl_rc} -ne 0 ]; then
    echo "unifi_sh_api: curl failed (exit ${curl_rc}) calling ${method} ${url}" >&2
    rm -f "${header_file}" "${body_file}"
    return 1
  fi

  new_token=$(grep -i '^x-updated-csrf-token:' "${header_file}" | head -1 | sed 's/.*: *//' | tr -d '\r\n')
  [ -n "${new_token}" ] && _UNIFI_CSRF_TOKEN="${new_token}"

  UNIFI_LAST_BODY=$(cat "${body_file}")
  rm -f "${header_file}" "${body_file}"
  return 0
}

unifi_login() {
  unifi_requires || return 1

  _UNIFI_COOKIE_JAR=$(mktemp) || { echo "unifi_sh_api: could not create cookie jar" >&2; return 1; }
  _UNIFI_CSRF_TOKEN=""

  _unifi_request POST "${baseurl}/api/auth/login" \
    "{\"username\":\"${username}\",\"password\":\"${password}\"}" || return 1

  if [ "${UNIFI_LAST_HTTP_CODE}" != "200" ]; then
    echo "unifi_sh_api: login failed for ${username}@${baseurl} (HTTP ${UNIFI_LAST_HTTP_CODE}): ${UNIFI_LAST_BODY}" >&2
    rm -f "${_UNIFI_COOKIE_JAR}"
    _UNIFI_COOKIE_JAR=""
    return 1
  fi
  return 0
}

unifi_logout() {
  local rc=0
  if [ -n "${_UNIFI_COOKIE_JAR}" ]; then
    _unifi_request POST "${baseurl}/api/auth/logout" "" || rc=1
    rm -f "${_UNIFI_COOKIE_JAR}"
  fi
  _UNIFI_COOKIE_JAR=""
  _UNIFI_CSRF_TOKEN=""
  return ${rc}
}

# Generic call against the site-scoped Network application API.
# Usage: unifi_api <uri> [json]   e.g. unifi_api /stat/sta
# Prints the response body on stdout; returns 0 on HTTP 2xx, 1 otherwise.
unifi_api() {
  if [ $# -lt 1 ]; then
    echo "Usage: unifi_api <uri> [json]" >&2
    return 1
  fi
  local uri="$1"; shift
  local json="$*"
  [ "${uri#/}" = "${uri}" ] && uri="/${uri}"
  [ -z "${json}" ] && json="{}"

  _unifi_request POST "${baseurl}/proxy/network/api/s/${site}${uri}" "${json}" || return 1
  echo "${UNIFI_LAST_BODY}"
  case "${UNIFI_LAST_HTTP_CODE}" in
    2??) return 0 ;;
    *) return 1 ;;
  esac
}

# List the controller's existing (auto/manual) backups for the current site.
unifi_list_backups() {
  unifi_api /cmd/backup '{"cmd":"list-backups"}'
}

# Download a controller-relative path (as returned by cmd/backup or
# list-backups, e.g. "/dl/autobackup/xxx.unf") to a local file.
unifi_download_path() {
  local path="$1" output="$2" header_file http_code curl_rc

  case "${path}" in
    /proxy/network/*) : ;;
    /*) path="/proxy/network${path}" ;;
    *) path="/proxy/network/${path}" ;;
  esac

  header_file=$(mktemp) || { echo "unifi_sh_api: could not create temp file" >&2; return 1; }

  local args=(-X GET --cookie "${_UNIFI_COOKIE_JAR}" --cookie-jar "${_UNIFI_COOKIE_JAR}"
              -D "${header_file}" -o "${output}" -w '%{http_code}')
  [ -n "${_UNIFI_CSRF_TOKEN}" ] && args+=(-H "X-CSRF-Token: ${_UNIFI_CSRF_TOKEN}")

  http_code=$(_unifi_curl "${args[@]}" "${baseurl}${path}")
  curl_rc=$?
  rm -f "${header_file}"

  if [ ${curl_rc} -ne 0 ]; then
    echo "unifi_sh_api: curl failed (exit ${curl_rc}) downloading ${path}" >&2
    rm -f "${output}"
    return 1
  fi
  if [ "${http_code}" != "200" ]; then
    echo "unifi_sh_api: download failed for ${path} (HTTP ${http_code})" >&2
    rm -f "${output}"
    return 1
  fi
  if [ ! -s "${output}" ]; then
    echo "unifi_sh_api: downloaded file ${output} is empty" >&2
    rm -f "${output}"
    return 1
  fi
  return 0
}

# Trigger an on-demand backup and download it to $1.
unifi_backup() {
  local output="${1:-unifi-backup.unf}" path

  _unifi_request POST "${baseurl}/proxy/network/api/s/${site}/cmd/backup" '{"cmd":"backup"}' || return 1
  if [ "${UNIFI_LAST_HTTP_CODE}" != "200" ]; then
    echo "unifi_sh_api: backup request failed (HTTP ${UNIFI_LAST_HTTP_CODE}): ${UNIFI_LAST_BODY}" >&2
    return 1
  fi

  path=$(echo "${UNIFI_LAST_BODY}" | sed -n 's/.*"\(\/dl[^"]*\.unf\)".*/\1/p')
  if [ -z "${path}" ]; then
    echo "unifi_sh_api: could not find a backup file path in response: ${UNIFI_LAST_BODY}" >&2
    return 1
  fi

  unifi_download_path "${path}" "${output}"
}
