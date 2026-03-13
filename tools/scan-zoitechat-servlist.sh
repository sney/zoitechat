#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME=$(basename "$0")
VERSION="1.0.0"

REPO_URL="${REPO_URL:-}"
BRANCH="${BRANCH:-main}"
CHECKOUT_DIR="${CHECKOUT_DIR:-/tmp/zoitechat-servscan}"
SERVLIST_PATH="${SERVLIST_PATH:-}"
EMAIL_TO="${EMAIL_TO:-}"
EMAIL_FROM="${EMAIL_FROM:-servscan@$(hostname -f 2>/dev/null || hostname)}"
SUBJECT_PREFIX="${SUBJECT_PREFIX:-ZoiteChat servlist scan}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
SSL_TIMEOUT="${SSL_TIMEOUT:-15}"
PLAIN_PORT="${PLAIN_PORT:-6667}"
SSL_PORT="${SSL_PORT:-6697}"
DO_CLONE=1
DO_EMAIL=1

TMP_DIR=""
REPORT_FILE=""
ROWS_FILE=""
COMMIT_REF="local-file"

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} --repo <git-url> --branch <branch> --email-to <address> [options]
  ${SCRIPT_NAME} --servlist <path/to/src/common/servlist.c> --email-to <address> [options]

Options:
  --repo <url>             Git repository to clone or update.
  --branch <name>          Branch to scan. Default: ${BRANCH}
  --checkout-dir <path>    Dedicated checkout dir. Default: ${CHECKOUT_DIR}
  --servlist <path>        Scan a local servlist.c instead of cloning.
  --email-to <address>     Recipient email address.
  --email-from <address>   From address for the email.
  --subject-prefix <text>  Subject prefix. Default: ${SUBJECT_PREFIX}
  --connect-timeout <sec>  TCP timeout. Default: ${CONNECT_TIMEOUT}
  --ssl-timeout <sec>      TLS timeout. Default: ${SSL_TIMEOUT}
  --plain-port <port>      Default non-SSL IRC port. Default: ${PLAIN_PORT}
  --ssl-port <port>        Default SSL IRC port. Default: ${SSL_PORT}
  --no-clone               Do not clone. Requires --servlist.
  --no-email               Print report only.
  -h, --help               Show this help.

Notes:
  - Existing checkouts in --checkout-dir are hard-reset to origin/<branch>.
  - SSL is tested when the network defaults to SSL or the host uses /+port.
  - Email delivery uses sendmail, mailx, or mail.
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

sanitize_detail() {
  local text=${1:-}
  text=$(printf '%s' "$text" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')
  printf '%.220s' "$text"
}

extract_ssl_error() {
  local raw=${1:-}
  local line

  line=$(printf '%s\n' "$raw" | grep -E 'Verify return code:|verify error:|unable to get local issuer certificate|self-signed certificate|certificate has expired|hostname mismatch|wrong version number|no peer certificate available|tlsv1 alert|sslv3 alert|Connection refused|connect:' | head -n1 || true)
  if [[ -z "$line" ]]; then
    line=$(printf '%s\n' "$raw" | tail -n5 | head -n1 || true)
  fi
  sanitize_detail "$line"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO_URL=${2:?missing value for --repo}
        shift 2
        ;;
      --branch)
        BRANCH=${2:?missing value for --branch}
        shift 2
        ;;
      --checkout-dir)
        CHECKOUT_DIR=${2:?missing value for --checkout-dir}
        shift 2
        ;;
      --servlist)
        SERVLIST_PATH=${2:?missing value for --servlist}
        shift 2
        ;;
      --email-to)
        EMAIL_TO=${2:?missing value for --email-to}
        shift 2
        ;;
      --email-from)
        EMAIL_FROM=${2:?missing value for --email-from}
        shift 2
        ;;
      --subject-prefix)
        SUBJECT_PREFIX=${2:?missing value for --subject-prefix}
        shift 2
        ;;
      --connect-timeout)
        CONNECT_TIMEOUT=${2:?missing value for --connect-timeout}
        shift 2
        ;;
      --ssl-timeout)
        SSL_TIMEOUT=${2:?missing value for --ssl-timeout}
        shift 2
        ;;
      --plain-port)
        PLAIN_PORT=${2:?missing value for --plain-port}
        shift 2
        ;;
      --ssl-port)
        SSL_PORT=${2:?missing value for --ssl-port}
        shift 2
        ;;
      --no-clone)
        DO_CLONE=0
        shift
        ;;
      --no-email)
        DO_EMAIL=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  if [[ -n "${SERVLIST_PATH}" && -z "${REPO_URL}" ]]; then
    DO_CLONE=0
  fi

  if [[ ${DO_CLONE} -eq 1 && -z "${REPO_URL}" && -z "${SERVLIST_PATH}" ]]; then
    die "Provide --repo or --servlist"
  fi

  if [[ ${DO_CLONE} -eq 0 && -z "${SERVLIST_PATH}" ]]; then
    die "--no-clone requires --servlist"
  fi

  if [[ ${DO_EMAIL} -eq 1 && -z "${EMAIL_TO}" ]]; then
    die "Provide --email-to, or use --no-email for testing"
  fi
}

prepare_workspace() {
  TMP_DIR=$(mktemp -d)
  REPORT_FILE="${TMP_DIR}/report.txt"
  ROWS_FILE="${TMP_DIR}/rows.tsv"
}

clone_or_update_repo() {
  [[ ${DO_CLONE} -eq 1 ]] || return 0

  require_cmd git

  if [[ -d "${CHECKOUT_DIR}/.git" ]]; then
    git -C "${CHECKOUT_DIR}" fetch --depth 1 origin "${BRANCH}"
    git -C "${CHECKOUT_DIR}" checkout -q "${BRANCH}" 2>/dev/null || git -C "${CHECKOUT_DIR}" checkout -q -B "${BRANCH}" "origin/${BRANCH}"
    git -C "${CHECKOUT_DIR}" reset --hard "origin/${BRANCH}" >/dev/null
  else
    rm -rf "${CHECKOUT_DIR}"
    git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${CHECKOUT_DIR}" >/dev/null
  fi

  COMMIT_REF=$(git -C "${CHECKOUT_DIR}" rev-parse --short HEAD)
  SERVLIST_PATH="${CHECKOUT_DIR}/src/common/servlist.c"
}

validate_inputs() {
  require_cmd awk
  require_cmd grep
  require_cmd sed
  require_cmd openssl
  require_cmd timeout

  [[ -f "${SERVLIST_PATH}" ]] || die "servlist.c not found: ${SERVLIST_PATH}"
}

parse_servlist() {
  awk '
    function clean_comment(s) {
      gsub(/^[[:space:]]*\/\*[[:space:]]*/, "", s)
      gsub(/[[:space:]]*\*\/[[:space:]]*$/, "", s)
      gsub(/[[:space:]]+/, " ", s)
      return s
    }

    /static const struct defaultserver def\[\]/ {
      in_def = 1
      next
    }

    !in_def { next }

    /^[[:space:]]*#(if|ifdef|ifndef|else|elif|endif)/ { next }
    /^[[:space:]]*\};/ { exit }

    /^[[:space:]]*\/\*/ {
      last_comment = clean_comment($0)
      next
    }

    /^[[:space:]]*\{[[:space:]]*0[[:space:]]*,[[:space:]]*0[[:space:]]*\}[[:space:]]*,?[[:space:]]*$/ {
      exit
    }

    /^[[:space:]]*\{[[:space:]]*"/ {
      line = $0
      sub(/^[[:space:]]*\{[[:space:]]*"/, "", line)
      split(line, parts, /"/)
      current_network = parts[1]
      current_ssl = ($0 ~ /,[[:space:]]*TRUE[[:space:]]*\}[[:space:]]*,?[[:space:]]*$/) ? 1 : 0
      last_comment = ""
      next
    }

    /^[[:space:]]*\{[[:space:]]*0[[:space:]]*,[[:space:]]*"/ {
      line = $0
      sub(/^[[:space:]]*\{[[:space:]]*0[[:space:]]*,[[:space:]]*"/, "", line)
      split(line, parts, /"/)
      gsub(/\t/, " ", last_comment)
      printf "%s\t%s\t%s\t%s\n", current_network, current_ssl, parts[1], last_comment
      last_comment = ""
      next
    }

    {
      last_comment = ""
    }
  ' "${SERVLIST_PATH}"
}

scan_server() {
  local network=$1
  local ssl_default=$2
  local hostspec=$3
  local note=${4:-}

  local host="$hostspec"
  local port=""
  local port_part=""
  local explicit_ssl=0
  local ssl_expected=$ssl_default
  local tcp_status="FAIL"
  local tcp_detail=""
  local ssl_status="N/A"
  local ssl_detail="-"
  local ssl_raw=""
  local tcp_raw=""
  local tcp_rc=0
  local ssl_rc=0
  local verify_line=""
  local cert_block=""
  local cert_meta=""
  local enddate=""
  local expires_note=""

  if [[ "$hostspec" == */* ]]; then
    host=${hostspec%/*}
    port_part=${hostspec##*/}
    if [[ "$port_part" == +* ]]; then
      explicit_ssl=1
      port=${port_part#+}
    else
      port=$port_part
    fi
  fi

  if [[ ${explicit_ssl} -eq 1 ]]; then
    ssl_expected=1
  fi

  if [[ -z "$port" ]]; then
    if [[ ${ssl_expected} -eq 1 ]]; then
      port=$SSL_PORT
    else
      port=$PLAIN_PORT
    fi
  fi

  set +e
  tcp_raw=$(timeout "${CONNECT_TIMEOUT}" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>&1)
  tcp_rc=$?
  set -e

  if [[ ${tcp_rc} -eq 0 ]]; then
    tcp_status="OK"
    tcp_detail="connected"
  elif [[ ${tcp_rc} -eq 124 ]]; then
    tcp_detail="timeout"
  else
    tcp_detail=$(sanitize_detail "$tcp_raw")
  fi

  if [[ ${ssl_expected} -eq 1 ]]; then
    if [[ "$tcp_status" != "OK" ]]; then
      ssl_status="SKIPPED"
      ssl_detail="tcp failed"
    else
      set +e
      ssl_raw=$(timeout "${SSL_TIMEOUT}" openssl s_client \
        -connect "${host}:${port}" \
        -servername "${host}" \
        -verify_return_error \
        -verify_hostname "${host}" \
        < /dev/null 2>&1)
      ssl_rc=$?
      set -e

      if [[ ${ssl_rc} -eq 124 ]]; then
        ssl_status="INVALID"
        ssl_detail="tls timeout"
      else
        verify_line=$(printf '%s\n' "$ssl_raw" | grep -E 'Verify return code:' | tail -n1 || true)
        cert_block=$(printf '%s\n' "$ssl_raw" | awk '
          /-----BEGIN CERTIFICATE-----/ { found = 1 }
          found { print }
          /-----END CERTIFICATE-----/ { exit }
        ')

        if [[ -n "$cert_block" ]]; then
          cert_meta=$(printf '%s\n' "$cert_block" | openssl x509 -noout -enddate 2>/dev/null || true)
          enddate=$(printf '%s\n' "$cert_meta" | sed -n 's/^notAfter=//p' | head -n1)
          if [[ -n "$enddate" ]]; then
            expires_note="expires ${enddate}"
          fi
        fi

        if printf '%s\n' "$ssl_raw" | grep -q 'Verify return code: 0 (ok)'; then
          ssl_status="VALID"
          ssl_detail="ok"
        else
          ssl_status="INVALID"
          ssl_detail=$(extract_ssl_error "$ssl_raw")
        fi

        if [[ -n "$verify_line" && "$ssl_status" != "VALID" ]]; then
          ssl_detail=$(sanitize_detail "$verify_line")
        fi

        if [[ -n "$expires_note" ]]; then
          ssl_detail="${ssl_detail}; ${expires_note}"
        fi
      fi
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$network" \
    "$host" \
    "$port" \
    "$ssl_expected" \
    "$tcp_status" \
    "$ssl_status" \
    "$ssl_detail" \
    "$note"
}

build_report() {
  local total=0
  local tcp_ok=0
  local tcp_fail=0
  local ssl_expected_count=0
  local ssl_valid=0
  local ssl_invalid=0
  local issue_count=0
  local scan_status="CLEAN"
  local repo_display="${REPO_URL:-local file}"
  local generated_at
  local host_name
  generated_at=$(date '+%Y-%m-%d %H:%M:%S %Z')
  host_name=$(hostname -f 2>/dev/null || hostname)

  while IFS=$'\t' read -r network ssl_default hostspec note; do
    [[ -n "$network" ]] || continue
    scan_server "$network" "$ssl_default" "$hostspec" "$note" >> "${ROWS_FILE}"
  done < <(parse_servlist)

  while IFS=$'\t' read -r network host port ssl_expected tcp_status ssl_status ssl_detail note; do
    ((total += 1))

    if [[ "$tcp_status" == "OK" ]]; then
      ((tcp_ok += 1))
    else
      ((tcp_fail += 1))
      ((issue_count += 1))
    fi

    if [[ "$ssl_expected" == "1" ]]; then
      ((ssl_expected_count += 1))
      if [[ "$ssl_status" == "VALID" ]]; then
        ((ssl_valid += 1))
      else
        ((ssl_invalid += 1))
        ((issue_count += 1))
      fi
    fi
  done < "${ROWS_FILE}"

  if [[ ${issue_count} -gt 0 ]]; then
    scan_status="ISSUES"
  fi

  {
    printf 'ZoiteChat servlist scan report\n'
    printf 'Status: %s\n' "$scan_status"
    printf 'Generated: %s\n' "$generated_at"
    printf 'Runner: %s\n' "$host_name"
    printf 'Repo: %s\n' "$repo_display"
    printf 'Branch: %s\n' "$BRANCH"
    printf 'Commit: %s\n' "$COMMIT_REF"
    printf 'servlist: %s\n' "$SERVLIST_PATH"
    printf '\n'
    printf 'Summary\n'
    printf '  Total servers scanned : %d\n' "$total"
    printf '  TCP reachable         : %d\n' "$tcp_ok"
    printf '  TCP failed            : %d\n' "$tcp_fail"
    printf '  SSL expected          : %d\n' "$ssl_expected_count"
    printf '  SSL valid             : %d\n' "$ssl_valid"
    printf '  SSL invalid/skipped   : %d\n' "$ssl_invalid"
    printf '\n'
    printf '%-18s %-34s %-6s %-4s %-5s %-8s %s\n' 'Network' 'Server' 'Port' 'SSL' 'TCP' 'TLS' 'Details'
    printf '%-18s %-34s %-6s %-4s %-5s %-8s %s\n' '------------------' '----------------------------------' '------' '----' '-----' '--------' '-------'

    while IFS=$'\t' read -r network host port ssl_expected tcp_status ssl_status ssl_detail note; do
      local detail="$ssl_detail"
      if [[ "$ssl_expected" != "1" ]]; then
        detail="$tcp_status"
      fi
      if [[ -n "$note" ]]; then
        detail="${detail} | comment: ${note}"
      fi

      printf '%-18.18s %-34.34s %-6s %-4s %-5s %-8s %s\n' \
        "$network" \
        "$host" \
        "$port" \
        "$([[ "$ssl_expected" == "1" ]] && printf 'yes' || printf 'no')" \
        "$tcp_status" \
        "$ssl_status" \
        "$detail"
    done < "${ROWS_FILE}"
  } > "${REPORT_FILE}"
}

send_report() {
  [[ ${DO_EMAIL} -eq 1 ]] || return 0

  local status_word="CLEAN"
  local subject=""

  if grep -q '^Status: ISSUES$' "${REPORT_FILE}"; then
    status_word="ISSUES"
  fi

  subject="${SUBJECT_PREFIX} [${status_word}] $(date '+%Y-%m-%d')"

  if command -v sendmail >/dev/null 2>&1; then
    {
      printf 'To: %s\n' "$EMAIL_TO"
      printf 'From: %s\n' "$EMAIL_FROM"
      printf 'Subject: %s\n' "$subject"
      printf 'Date: %s\n' "$(LC_ALL=C date -R)"
      printf 'MIME-Version: 1.0\n'
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf '\n'
      cat "${REPORT_FILE}"
    } | sendmail -t
    return 0
  fi

  if command -v mailx >/dev/null 2>&1; then
    mailx -r "$EMAIL_FROM" -s "$subject" "$EMAIL_TO" < "${REPORT_FILE}"
    return 0
  fi

  if command -v mail >/dev/null 2>&1; then
    if mail --help 2>&1 | grep -q -- ' -r'; then
      mail -r "$EMAIL_FROM" -s "$subject" "$EMAIL_TO" < "${REPORT_FILE}"
    else
      mail -s "$subject" "$EMAIL_TO" < "${REPORT_FILE}"
    fi
    return 0
  fi

  die "No supported mailer found. Install sendmail, mailx, or mail."
}

main() {
  parse_args "$@"
  prepare_workspace
  clone_or_update_repo
  validate_inputs
  build_report
  cat "${REPORT_FILE}"
  send_report
}

main "$@"
