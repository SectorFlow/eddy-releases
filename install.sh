#!/bin/sh
# Installs Eddyline on an Ubuntu or Debian server: Docker, then a Caddy and app stack (plus Postgres,
# unless --database-url is given) in /opt/eddy, a nightly backup and the eddy command.
#
#   curl -fsSL https://get.eddyline.app/install.sh | sudo sh
#
# Run from a checkout, it uses the templates, lib.sh and cli.sh next to it. Run from a pipe, it
# downloads them from RELEASES_BASE_URL and checks them against its SHA256SUMS. Running it again
# after a failed attempt reuses the secrets and keeps the other settings in .env. When the app is
# healthy it finishes an install that stopped before the eddy command was in place, and otherwise
# refuses and points at the update command.
set -eu
# Tracing would print secrets and the database URL.
set +x

# shellcheck source=install/lib.sh
# shellcheck shell=sh disable=SC2034 # the constants below are used by install.sh and cli.sh
# Shared functions for install.sh and cli.sh. POSIX sh.
#
# Both scripts source this file with exactly this line, which the release workflow and
# install_cli replace with the file's contents so the published and installed copies stand alone:
#
#   . "$(dirname "$0")/lib.sh"
#
# No set -e here: the caller sets it. Functions print plain messages and return 1 on failure.
# Functions with a ( ) body run in a subshell, so their variables stay local.
#
# Secrets (AUTH_SECRET, POSTGRES_PASSWORD, SETUP_TOKEN, DATABASE_URL, SMTP_URL) are never echoed.
# A secret reaches a child process only through its environment for that one command, never argv.

PRODUCT_NAME="Eddyline"
PRODUCT_SLUG="eddy"
IMAGE_REPO="ghcr.io/sectorflow/eddy"
# The install directory. install_cli rewrites this exact line in the installed command when the
# installer ran with --dir.
INSTALL_DIR="/opt/$PRODUCT_SLUG"
BIN_PATH="/usr/local/bin/$PRODUCT_SLUG"
CRON_PATH="/etc/cron.d/$PRODUCT_SLUG-backup"
# The host serving install.sh, cli.sh, the templates and releases.json.
RELEASES_BASE_URL="${RELEASES_BASE_URL:-https://get.eddyline.app}"
# The client image for checking an external database.
PREFLIGHT_IMAGE="postgres:16-alpine"
# The source line both scripts use for this file, matched as text.
# shellcheck disable=SC2016 # the line is matched as text, never run
LIB_SOURCE_LINE='. "$(dirname "$0")/lib.sh"'

say() {
  printf '%s\n' "$*"
}

warn() {
  printf '%s\n' "$*" >&2
}

# --- Input ---------------------------------------------------------------------------------------

# normalise_domain <text>: lowercases, and strips spaces, a scheme, any path and a trailing dot.
normalise_domain() (
  d=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  case $d in
    *://*) d=${d#*://} ;;
  esac
  d=${d%%/*}
  d=${d%.}
  printf '%s\n' "$d"
)

# valid_domain <name>: a host name made of letters, digits, dots and hyphens.
valid_domain() {
  printf '%s\n' "$1" | grep -Eqx '[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*'
}

valid_email() {
  printf '%s\n' "$1" | grep -Eqx '[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+'
}

# random_secret <bytes>: that many random bytes from /dev/urandom, base64url without padding.
random_secret() {
  head -c "$1" /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_'
  printf '\n'
}

# check_database_url <url>: returns 1 with a hint when the URL does not parse. Never prints it.
check_database_url() (
  # One character of a user name, password or database name: unreserved, sub-delims, or %XX.
  url_char="([A-Za-z0-9._~!\$&'()*+,;=-]|%[0-9A-Fa-f]{2})"
  url_re="postgres(ql)?://${url_char}+(:${url_char}*)?@([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?/${url_char}+(\?[^#[:space:]]*)?"
  if printf '%s\n' "$1" | grep -Eqx "$url_re"; then
    # A password in the query would reach the database clients' argv, which the process list
    # shows. Only the password before the @ is passed to them separately.
    case $1 in
      *\?*)
        if printf '%s\n' "${1#*\?}" | grep -Eiq '(^|&)password='; then
          warn "Put the password in the URL before the @, as postgres://user:password@host:5432/database with special characters percent-encoded, not in ?password=."
          return 1
        fi
        ;;
    esac
    return 0
  fi
  warn "The database URL could not be read. Write it as postgres://user:password@host:5432/database, and percent-encode @, /, : and other special characters in the user name or password (for example @ as %40, / as %2F and : as %3A)."
  return 1
)

# resolve_version <stable|version>: prints a concrete version. stable is read from releases.json.
resolve_version() (
  v=$1
  if [ "$v" = stable ]; then
    url="$RELEASES_BASE_URL/releases.json"
    json=$(curl -fsSL --max-time 30 "$url" 2>/dev/null) || json=""
    # The first "version" in the file is the latest release.
    # shellcheck disable=SC2020 # each of { } and , becomes a line break
    v=$(printf '%s\n' "$json" | tr '{},' '\n\n\n' |
      sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if ! printf '%s\n' "$v" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+'; then
      warn "Could not read the latest version from $url. Check that this server can reach it, or pass --version."
      return 1
    fi
  fi
  v=${v#v}
  if ! printf '%s\n' "$v" | grep -Eqx '[A-Za-z0-9][A-Za-z0-9._-]*'; then
    warn "The version can only contain letters, digits, dots, hyphens and underscores."
    return 1
  fi
  printf '%s\n' "$v"
)

# verify_checksums <dir> <file...>: checks each file in <dir> against <dir>/SHA256SUMS, as the
# release workflow writes it. Returns 1, naming the file, when one is missing from the list or
# does not match. SHA256SUMS comes from the same host, so this catches a broken or mixed-up
# download, not a host that serves altered files.
verify_checksums() (
  dir=$1
  shift
  cd "$dir" || return 1
  for file in "$@"; do
    expected=$(awk -v f="$file" '$2 == f || $2 == "*" f { print $1; exit }' SHA256SUMS 2>/dev/null)
    actual=$(sha256sum "$file" | awk '{ print $1 }')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
      warn "$file from $RELEASES_BASE_URL does not match its checksum in SHA256SUMS. Try again in a few minutes, as a release may be in progress."
      return 1
    fi
  done
)

# --- System checks -------------------------------------------------------------------------------

# check_os [os-release file]: Ubuntu or Debian only.
check_os() (
  file=${1:-/etc/os-release}
  id=""
  name=""
  if [ -f "$file" ]; then
    id=$(env_get ID "$file")
    name=$(env_get PRETTY_NAME "$file")
  fi
  case $id in
    ubuntu | debian) return 0 ;;
  esac
  warn "This installer supports Ubuntu and Debian. This server runs ${name:-${id:-an unknown system}}."
  return 1
)

check_arch() (
  arch=$(uname -m)
  case $arch in
    x86_64 | amd64 | aarch64 | arm64) return 0 ;;
  esac
  warn "This installer supports 64-bit x86 and ARM servers. This server is $arch."
  return 1
)

check_root() {
  if [ "$(id -u)" = 0 ]; then
    return 0
  fi
  warn "Run the installer as root, for example: curl -fsSL $RELEASES_BASE_URL/install.sh | sudo sh"
  return 1
}

# memory_mb [meminfo file]: total memory in MB.
memory_mb() {
  awk '/^MemTotal:/ { print int($2 / 1024) }' "${1:-/proc/meminfo}"
}

# check_ports: returns 1 when anything listens on TCP 80 or 443.
check_ports() (
  if ! command -v ss > /dev/null 2>&1; then
    warn "Warning: could not check ports 80 and 443 because ss is not installed."
    return 0
  fi
  # The local address is the fourth column, such as 0.0.0.0:443, [::]:80 or *:80.
  busy=$(ss -Hltn 2>/dev/null |
    awk '{ n = split($4, part, ":"); if (part[n] == "80" || part[n] == "443") print part[n] }' |
    sort -nu | tr '\n' ' ')
  case $busy in
    "80 443 ") ports="80 and 443" ;;
    "80 ") ports="80" ;;
    "443 ") ports="443" ;;
    *) return 0 ;;
  esac
  warn "Ports 80 and 443 must be free. Something is already listening on $ports."
  return 1
)

# check_dns <domain>: warns, and returns 0, when the domain does not point at this server. The
# server's addresses come from its interfaces: asking an outside service would add a connection
# the customer guide does not list.
check_dns() (
  domain=$1
  resolved=$(getent ahosts "$domain" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')
  resolved=${resolved% }
  if [ -z "$resolved" ]; then
    warn "Warning: $domain does not resolve yet. Point its DNS A record at this server, or Caddy cannot get a certificate."
    return 0
  fi
  addresses=" $(hostname -I 2>/dev/null) "
  for ip in $resolved; do
    case $addresses in
      *" $ip "*)
        say "$domain points at this server."
        return 0
        ;;
    esac
  done
  addresses=$(printf '%s' "$addresses" | tr -s ' ')
  addresses=${addresses# }
  addresses=${addresses% }
  warn "Warning: $domain resolves to $resolved, but this server's addresses are ${addresses:-unknown}. Caddy cannot get a certificate until the domain points here. If this server is behind NAT, check that the domain points at its public address."
  return 0
)

# redact_db_errors <url> <file>: prints the file to stderr without any line that holds the URL or
# its password, so a client's error message never shows them.
redact_db_errors() (
  password=${1#*://}
  password=${password%%@*}
  case $password in
    *:*) password=${password#*:} ;;
    *) password="" ;;
  esac
  REDACT_URL="$1" REDACT_PASSWORD="$password" awk '
    index($0, ENVIRON["REDACT_URL"]) { next }
    ENVIRON["REDACT_PASSWORD"] != "" && index($0, ENVIRON["REDACT_PASSWORD"]) { next }
    { print }
  ' "$2" >&2
)

# percent_decode <text>: decodes %XX escapes, byte by byte. The text reaches awk through its
# environment, never argv.
percent_decode() {
  ENCODED="$1" LC_ALL=C awk 'BEGIN {
    s = ENVIRON["ENCODED"]
    hex = "0123456789abcdef"
    out = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == "%" && i + 2 <= length(s)) {
        hi = index(hex, tolower(substr(s, i + 1, 1))) - 1
        lo = index(hex, tolower(substr(s, i + 2, 1))) - 1
        if (hi >= 0 && lo >= 0) {
          out = out sprintf("%c", hi * 16 + lo)
          i += 2
          continue
        }
      }
      out = out c
    }
    printf "%s", out
  }'
}

# split_db_url <url>: sets DB_URL_NOPASS to the URL without its password, and DB_PASSWORD to the
# password, percent-decoded. A client gets the first in argv and the second only as PGPASSWORD in
# its environment, because the host's process list shows every container process's argv.
# check_database_url refuses an unencoded @, : or / in the user or password; should one slip
# through, the user and password end at the last @ before the first / after //, where Node's URL
# parser, and so the app, ends them too.
split_db_url() {
  split_rest=${1#*://}
  split_authority=${split_rest%%/*}
  DB_PASSWORD=""
  case $split_authority in
    *@*)
      split_userinfo=${split_authority%@*}
      case $split_userinfo in
        *:*) DB_PASSWORD=$(percent_decode "${split_userinfo#*:}") ;;
      esac
      DB_URL_NOPASS="${1%%://*}://${split_userinfo%%:*}@${split_rest#"$split_userinfo"@}"
      ;;
    *) DB_URL_NOPASS=$1 ;;
  esac
}

# check_external_db <url>: connects through a one-off postgres:16-alpine container with the same
# host mapping as the app, and checks the version, citext and that the database is empty or
# already holds this product's migrations and tables. The password reaches the container only as
# PGPASSWORD in its environment (see split_db_url).
check_external_db() (
  url=$1
  split_db_url "$url"
  err=$(mktemp)
  # The server version number, whether citext exists or the role can create it (a trusted
  # extension needs CREATE on the database), the number of tables and views outside
  # the system schemas, and whether this is an earlier install: the migrations table, which any
  # Drizzle app has, together with this product's own users and issues tables. Both reads go
  # through the catalogs, never to_regclass, because to_regclass needs USAGE on the schema and a
  # role that cannot see another app's schema would turn the check into a permission error.
  # shellcheck disable=SC2016 # $DATABASE_URL and $@ expand inside the container
  out=$(DATABASE_URL="$DB_URL_NOPASS" PGPASSWORD="$DB_PASSWORD" docker run --rm \
    -e DATABASE_URL -e PGPASSWORD -e PGCONNECT_TIMEOUT=10 \
    --add-host host.docker.internal:host-gateway "$PREFLIGHT_IMAGE" \
    sh -c 'exec psql "$DATABASE_URL" -XAtq -v ON_ERROR_STOP=1 "$@"' psql \
    -c "show server_version_num" \
    -c "select exists (select 1 from pg_extension where extname = 'citext') or (exists (select 1 from pg_available_extensions where name = 'citext') and has_database_privilege(current_database(), 'CREATE'))" \
    -c "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p', 'v', 'm', 'f') and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg\\_%'" \
    -c "select exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'drizzle' and c.relname = '__drizzle_migrations') and exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'users') and exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'issues')" \
    2>"$err") || {
    redact_db_errors "$url" "$err"
    rm -f "$err"
    warn "Could not connect to the database. Check the URL, and that this server can reach the database."
    return 1
  }
  rm -f "$err"
  version=$(printf '%s\n' "$out" | sed -n 1p)
  citext=$(printf '%s\n' "$out" | sed -n 2p)
  tables=$(printf '%s\n' "$out" | sed -n 3p)
  migrations=$(printf '%s\n' "$out" | sed -n 4p)
  case $version$tables in
    '' | *[!0-9]*)
      warn "Could not read the database's version and tables."
      return 1
      ;;
  esac
  major=$((version / 10000))
  if [ "$major" -lt 14 ]; then
    warn "This database runs Postgres $major. Use Postgres 14 or newer."
    return 1
  fi
  if [ "$citext" != t ]; then
    warn "This database cannot use the citext extension. Make the app's role the owner of the database, or have a superuser run: create extension citext;"
    return 1
  fi
  if [ "$tables" -gt 0 ] && [ "$migrations" != t ]; then
    warn "This database already has tables from another app. Use an empty database."
    return 1
  fi
  return 0
)

# --- .env ----------------------------------------------------------------------------------------

# env_get <key> <file>: the key's last value, with one pair of surrounding quotes removed. The
# file is never sourced: values can hold spaces, <, >, & and $.
env_get() {
  awk -v key="$1" -v quote="'" '
    { sub(/\r$/, "") }
    index($0, key "=") == 1 { value = substr($0, length(key) + 2); found = 1 }
    END {
      if (!found) exit
      first = substr(value, 1, 1)
      if (length(value) >= 2 && (first == "\"" || first == quote) && substr(value, length(value)) == first)
        value = substr(value, 2, length(value) - 2)
      print value
    }
  ' "$2"
}

# env_set <key> <value> <file>: sets KEY to the value, quoted as env_quote does, in place of the
# key's first line (later lines for the key are dropped), or at the end. The file is rewritten
# through a temp file and keeps mode 600.
env_set() (
  quoted=$(env_quote "$1" "$2") || return 1
  (
    umask 077
    KEY="$1" VALUE="$quoted" awk '
      { line = $0; sub(/\r$/, "", line) }
      index(line, ENVIRON["KEY"] "=") == 1 {
        if (!done) print ENVIRON["KEY"] "=" ENVIRON["VALUE"]
        done = 1
        next
      }
      { print }
      END { if (!done) print ENVIRON["KEY"] "=" ENVIRON["VALUE"] }
    ' "$3" > "$3.tmp"
  ) || {
    rm -f "$3.tmp"
    return 1
  }
  chmod 600 "$3.tmp"
  mv "$3.tmp" "$3"
)

# merge_env <old .env> <new .env> [key...]: keeps every setting of the old file in the new one,
# except the keys given, which this run sets. A kept setting replaces the new file's line for
# that key, or is added at the end. Lines are copied as they are, so their quoting is kept. The
# file keeps mode 600.
merge_env() (
  old=$1
  new=$2
  shift 2
  (
    umask 077
    OLD="$old" SET_KEYS=" $* " awk '
      function key_of(line) {
        if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) return ""
        return substr(line, 1, index(line, "=") - 1)
      }
      { sub(/\r$/, "") }
      FILENAME == ENVIRON["OLD"] {
        k = key_of($0)
        if (k != "" && index(ENVIRON["SET_KEYS"], " " k " ") == 0) {
          if (!(k in kept)) order[++n] = k
          kept[k] = $0
        }
        next
      }
      {
        k = key_of($0)
        if (k != "" && (k in kept)) {
          if (!(k in done)) print kept[k]
          done[k] = 1
          next
        }
        print
      }
      END {
        added = 0
        for (i = 1; i <= n; i++) {
          if (order[i] in done) continue
          if (!added) { print ""; print "# Kept from the earlier .env"; added = 1 }
          print kept[order[i]]
        }
      }
    ' "$old" "$new" > "$new.tmp"
  ) || {
    rm -f "$new.tmp"
    return 1
  }
  chmod 600 "$new.tmp"
  mv "$new.tmp" "$new"
)

# env_quote <name> <value>: prints the value as it goes after NAME= in .env. Compose would expand
# $ and cut at # in a bare value, so those values are single-quoted, which Compose reads literally.
env_quote() (
  name=$1
  value=$2
  newline='
'
  case $value in
    *"$newline"* | *"$(printf '\r')"*)
      warn "$name cannot contain a line break."
      return 1
      ;;
  esac
  case $value in
    *[\$\#\"\\\`]* | \'* | " "* | *" ")
      case $value in
        *\'*)
          warn "$name cannot contain a single quote together with \$, #, \", \\ or \`. Percent-encode it in URLs as %27."
          return 1
          ;;
      esac
      printf "'%s'\n" "$value"
      ;;
    *) printf '%s\n' "$value" ;;
  esac
)

# load_secrets <dir>: sets POSTGRES_PASSWORD, AUTH_SECRET and SETUP_TOKEN, reusing the values in
# <dir>/.env from an earlier attempt. A new database password against an initialised volume would
# break the database.
load_secrets() {
  POSTGRES_PASSWORD=""
  AUTH_SECRET=""
  SETUP_TOKEN=""
  if [ -f "$1/.env" ]; then
    POSTGRES_PASSWORD=$(env_get POSTGRES_PASSWORD "$1/.env")
    AUTH_SECRET=$(env_get AUTH_SECRET "$1/.env")
    SETUP_TOKEN=$(env_get SETUP_TOKEN "$1/.env")
  fi
  if [ -z "$POSTGRES_PASSWORD" ]; then POSTGRES_PASSWORD=$(random_secret 24); fi
  if [ -z "$AUTH_SECRET" ]; then AUTH_SECRET=$(random_secret 32); fi
  if [ -z "$SETUP_TOKEN" ]; then SETUP_TOKEN=$(random_secret 24); fi
}

# write_install_files <template dir> <install dir>: writes compose.yml, compose.db.yml (bundled
# only), Caddyfile, .env (mode 600) and backups/. Reads IMAGE, DOMAIN, ACME_EMAIL, TLS (true or
# false), DB_MODE (bundled or external), DATABASE_URL (external), POSTGRES_PASSWORD (bundled),
# AUTH_SECRET, SETUP_TOKEN, LICENSE_KEY, SMTP_URL and MAIL_FROM.
# shellcheck disable=SC2153 # the settings are globals that install.sh sets
write_install_files() (
  src=$1
  dir=$2
  if [ "$TLS" = true ]; then
    scheme=https
    caddyfile=Caddyfile
  else
    scheme=http
    caddyfile=Caddyfile.http
  fi
  if [ "$DB_MODE" = external ]; then
    compose_file=compose.yml
    database_url=$DATABASE_URL
  else
    compose_file=compose.yml:compose.db.yml
    database_url="postgres://eddy:$POSTGRES_PASSWORD@db:5432/eddy"
  fi
  # Quote every value before writing anything, so a refused value leaves nothing half written.
  V_IMAGE=$(env_quote IMAGE "$IMAGE") || return 1
  V_DOMAIN=$(env_quote DOMAIN "$DOMAIN") || return 1
  V_ACME_EMAIL=$(env_quote ACME_EMAIL "$ACME_EMAIL") || return 1
  V_DB_MODE=$(env_quote DB_MODE "$DB_MODE") || return 1
  V_COMPOSE_FILE=$compose_file
  V_POSTGRES_PASSWORD=$(env_quote POSTGRES_PASSWORD "$POSTGRES_PASSWORD") || return 1
  V_DATABASE_URL=$(env_quote DATABASE_URL "$database_url") || return 1
  V_AUTH_SECRET=$(env_quote AUTH_SECRET "$AUTH_SECRET") || return 1
  V_APP_URL=$(env_quote APP_URL "$scheme://$DOMAIN") || return 1
  V_SETUP_TOKEN=$(env_quote SETUP_TOKEN "$SETUP_TOKEN") || return 1
  V_LICENSE_KEY=$(env_quote LICENSE_KEY "$LICENSE_KEY") || return 1
  V_SMTP_URL=$(env_quote SMTP_URL "$SMTP_URL") || return 1
  V_MAIL_FROM=$(env_quote MAIL_FROM "$MAIL_FROM") || return 1
  export V_IMAGE V_DOMAIN V_ACME_EMAIL V_DB_MODE V_COMPOSE_FILE V_POSTGRES_PASSWORD V_DATABASE_URL \
    V_AUTH_SECRET V_APP_URL V_SETUP_TOKEN V_LICENSE_KEY V_SMTP_URL V_MAIL_FROM

  mkdir -p "$dir/backups"
  chmod 700 "$dir/backups"
  cp "$src/compose.yml" "$dir/compose.yml"
  if [ "$DB_MODE" = external ]; then
    rm -f "$dir/compose.db.yml"
  else
    cp "$src/compose.db.yml" "$dir/compose.db.yml"
  fi
  cp "$src/$caddyfile" "$dir/Caddyfile"

  # Each KEY=__NAME__ line becomes KEY=<value of NAME>, taken from the environment so no value is
  # ever parsed as a pattern or replacement. An external database has no POSTGRES_PASSWORD line.
  (
    umask 077
    DROP_KEY=""
    if [ "$DB_MODE" = external ]; then DROP_KEY=POSTGRES_PASSWORD; fi
    DROP_KEY="$DROP_KEY" awk '
      /^[A-Z_]+=__[A-Z_]+__$/ {
        key = substr($0, 1, index($0, "=") - 1)
        if (key == ENVIRON["DROP_KEY"]) next
        name = substr($0, index($0, "=") + 3)
        name = substr(name, 1, length(name) - 2)
        if (!(("V_" name) in ENVIRON)) { print "env.template has an unknown placeholder __" name "__." > "/dev/stderr"; exit 1 }
        print key "=" ENVIRON["V_" name]
        next
      }
      /^[^#]*__[A-Z_]+__/ { print "env.template has a placeholder the installer cannot fill: " $0 > "/dev/stderr"; exit 1 }
      { print }
    ' "$src/env.template" > "$dir/.env.tmp"
  ) || {
    rm -f "$dir/.env.tmp"
    return 1
  }
  chmod 600 "$dir/.env.tmp"
  mv "$dir/.env.tmp" "$dir/.env"
)

# --- The stack -----------------------------------------------------------------------------------

# compose <dir> <args...>: docker compose in the install directory, which reads COMPOSE_FILE from
# .env.
compose() (
  cd "$1" || return 1
  shift
  docker compose "$@"
)

# app_healthy <dir>: asks /api/health from inside the app container. Its stdin is /dev/null, so it
# never reads answers meant for a later question.
app_healthy() {
  compose "$1" exec -T app wget -q -O /dev/null http://127.0.0.1:3000/api/health < /dev/null > /dev/null 2>&1
}

# wait_healthy <dir> <seconds>: returns 0 once the app is healthy, 1 after <seconds>.
wait_healthy() (
  waited=0
  while ! app_healthy "$1"; do
    if [ "$waited" -ge "$2" ]; then
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
)

# --- The installed command -----------------------------------------------------------------------

# install_cli <source dir> <dest> <install dir>: installs <source dir>/cli.sh as <dest>, inlining
# <source dir>/lib.sh when it is there (a published cli.sh already has it), with INSTALL_DIR set.
install_cli() (
  src=$1
  dest=$2
  dir=$3
  if [ -f "$src/lib.sh" ]; then
    LIB="$src/lib.sh" LINE="$LIB_SOURCE_LINE" awk '
      $0 == ENVIRON["LINE"] { while ((getline lib < ENVIRON["LIB"]) > 0) print lib; next }
      { print }
    ' "$src/cli.sh" > "$dest.tmp"
  else
    cp "$src/cli.sh" "$dest.tmp"
  fi
  # shellcheck disable=SC2016 # the line is matched as text, never run
  FROM='INSTALL_DIR="/opt/$PRODUCT_SLUG"' TO="INSTALL_DIR=\"$dir\"" awk '
    $0 == ENVIRON["FROM"] { print ENVIRON["TO"]; found = 1; next }
    { print }
    END { if (!found) exit 1 }
  ' "$dest.tmp" > "$dest.tmp2" || {
    rm -f "$dest.tmp" "$dest.tmp2"
    warn "Could not set the install directory in $dest."
    return 1
  }
  rm -f "$dest.tmp"
  chmod 755 "$dest.tmp2"
  mv "$dest.tmp2" "$dest"
)

usage() {
  cat <<EOF
Usage: install.sh [options]

Installs $PRODUCT_NAME with Docker on an Ubuntu or Debian server. Without --yes it asks for
anything that is missing.

  curl -fsSL $RELEASES_BASE_URL/install.sh | sudo sh -s -- --domain tracker.acme.com

Options:
  --domain <name>       The domain to serve $PRODUCT_NAME on, for example tracker.acme.com (required)
  --email <address>     Contact address for Let's Encrypt certificate notices (required unless --no-tls)
  --license <key>       Licence key. Without one $PRODUCT_NAME runs as the free edition
  --smtp-url <url>      SMTP server for email, for example smtps://user:pass@smtp.acme.com:465
  --mail-from <sender>  Sender of emails, for example "Acme <ops@acme.com>"
  --version <version>   The version to install (default stable, the latest release)
  --dir <path>          The install directory (default $INSTALL_DIR)
  --no-tls              Serve plain HTTP on port 80, for testing on a LAN or in CI
  --yes                 Ask nothing. A missing required option is an error
  --database-url <url>  Advanced: use an existing empty Postgres 14 or newer database instead of
                        the bundled one. Percent-encode special characters in the password
  --help                Show this help

Environment:
  RELEASES_BASE_URL     Where to download releases.json, cli.sh and the templates
                        (default https://get.eddyline.app)
  SKIP_PULL=1           Do not pull the images first, so an app image already on this machine is
                        used, for CI. For example: sudo SKIP_PULL=1 sh install.sh --version ci ...
EOF
}

usage_error() {
  warn "$1"
  warn ""
  usage >&2
  exit 1
}

# ask <prompt>: prints the answer typed on the terminal. A piped install reads its script from
# stdin, so questions always go through /dev/tty.
ask() {
  printf '%s' "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=""
  printf '%s\n' "$answer"
}

# ask_secret <prompt>: like ask, without showing what is typed.
ask_secret() (
  trap 'stty echo < /dev/tty 2>/dev/null' EXIT
  trap 'exit 130' INT TERM
  printf '%s' "$1" > /dev/tty
  stty -echo < /dev/tty 2>/dev/null || true
  IFS= read -r answer < /dev/tty || answer=""
  printf '\n' > /dev/tty
  printf '%s\n' "$answer"
)

valid_smtp_url() {
  case $1 in
    smtp://?* | smtps://?*) return 0 ;;
  esac
  return 1
}

# ensure_swap <memory MB>: adds a 2 GB swap file when the server has no swap.
ensure_swap() {
  if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
    return 0
  fi
  if [ -e /swapfile ]; then
    warn "Warning: this server has $1 MB of memory and no swap, and /swapfile already exists, so no swap file was added."
    return 0
  fi
  say "This server has $1 MB of memory. Adding a 2 GB swap file at /swapfile."
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null
  chmod 600 /swapfile
  mkswap /swapfile > /dev/null
  swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  fi
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"
}

# install_docker: Docker Engine and the compose plugin from Docker's apt repository, when missing.
install_docker() {
  if command -v docker > /dev/null 2>&1; then
    if docker compose version > /dev/null 2>&1; then
      if ! command -v curl > /dev/null 2>&1; then
        apt_install ca-certificates curl
      fi
      return 0
    fi
    warn "Docker is installed but its compose plugin is not. Install docker-compose-plugin, then run the installer again."
    exit 1
  fi
  say "Installing Docker from Docker's apt repository."
  os_id=$(env_get ID /etc/os-release)
  codename=$(env_get VERSION_CODENAME /etc/os-release)
  apt_install ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$os_id/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "$os_id" "$codename" > /etc/apt/sources.list.d/docker.list
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_cron() {
  if [ ! -d "$(dirname "$CRON_PATH")" ]; then
    apt_install cron
  fi
  cat > "$CRON_PATH" <<EOF
# Nightly backup for $PRODUCT_NAME, written by the installer. BACKUP_NIGHTLY=false in
# $INSTALL_DIR/.env turns it off.
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 3 * * * root $BIN_PATH backup --quiet
EOF
  chmod 644 "$CRON_PATH"
}

# fetch_sources: when not run from a checkout, downloads the templates and cli.sh from
# RELEASES_BASE_URL, checks them against its SHA256SUMS, and points SOURCE_DIR at them.
fetch_sources() {
  if [ -n "$SOURCE_DIR" ]; then
    return 0
  fi
  FETCH_DIR=$(mktemp -d)
  SOURCE_DIR=$FETCH_DIR
  # The release workflow publishes these at the root of RELEASES_BASE_URL, with SHA256SUMS.
  fetched="compose.yml compose.db.yml Caddyfile Caddyfile.http env.template cli.sh"
  for file in $fetched SHA256SUMS; do
    if ! curl -fsSL --max-time 60 "$RELEASES_BASE_URL/$file" -o "$SOURCE_DIR/$file"; then
      warn "Could not download $file from $RELEASES_BASE_URL."
      exit 1
    fi
  done
  # shellcheck disable=SC2086 # the list is split on purpose
  if ! verify_checksums "$SOURCE_DIR" $fetched; then
    exit 1
  fi
}

# setup_open: true when /setup still opens with SETUP_TOKEN, that is while no account exists. It
# asks from inside the app container, where the token is already in the environment, so it is
# never in argv. Returns 1 when setup is closed, and 2 or more when it could not tell.
setup_open() {
  # shellcheck disable=SC2016 # the script runs in node, not in this shell
  compose "$INSTALL_DIR" exec -T app node -e 'fetch("http://127.0.0.1:3000/setup?token=" + encodeURIComponent(process.env.SETUP_TOKEN || "")).then((r) => process.exit(r.status === 200 ? 0 : 1), () => process.exit(2))' \
    < /dev/null > /dev/null 2>&1
}

# finish_install: steps 8 and 9. Installs the nightly backup and the command, then prints the setup
# link while no account exists, and the next steps. Reads DOMAIN, TLS, VERSION, SETUP_TOKEN and
# SMTP_URL.
finish_install() {
  # --- 8. Backups and the command ----------------------------------------------------------------
  install_cron
  install_cli "$SOURCE_DIR" "$BIN_PATH" "$INSTALL_DIR"

  # --- 9. Done -----------------------------------------------------------------------------------
  if [ "$TLS" = true ]; then
    APP_URL="https://$DOMAIN"
  else
    APP_URL="http://$DOMAIN"
  fi
  setup_status=0
  setup_open || setup_status=$?
  say ""
  say "$PRODUCT_NAME $VERSION is running."
  say ""
  if [ "$setup_status" = 1 ]; then
    say "The first account already exists. Sign in at $APP_URL"
  else
    say "Open this link to create the first account. It works until that account exists:"
    say "  $APP_URL/setup?token=$SETUP_TOKEN"
  fi
  say ""
  say "Next steps:"
  if [ "$TLS" = true ]; then
    say "- DNS: point an A record for $DOMAIN at this server, if it does not already. Caddy gets the certificate once it does."
  fi
  if [ -z "$SMTP_URL" ]; then
    say "- Email: mail is not set up, so staff copy invite and reset links by hand. To send email, set SMTP_URL and MAIL_FROM with: $PRODUCT_SLUG config"
  fi
  say "- Sign-in with Google or OpenID Connect (optional): set the keys with $PRODUCT_SLUG config, and register this callback URL with the provider:"
  say "    Google: $APP_URL/api/auth/callback/google"
  say "    OpenID Connect: $APP_URL/api/auth/callback/oidc"
  say "- Manage the install with $PRODUCT_SLUG, for example $PRODUCT_SLUG status, $PRODUCT_SLUG backup or $PRODUCT_SLUG update. A backup runs every night at 03:15."
  say ""
  say "Keep a copy of $INSTALL_DIR/.env somewhere safe. Backups need it."
}

FETCH_DIR=""
cleanup() {
  if [ -n "$FETCH_DIR" ]; then
    rm -rf "$FETCH_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- Options -------------------------------------------------------------------------------------

# Unset first, so a value from the caller's environment is not exported to every child process.
unset DOMAIN ACME_EMAIL LICENSE_KEY SMTP_URL MAIL_FROM DATABASE_URL POSTGRES_PASSWORD AUTH_SECRET \
  SETUP_TOKEN IMAGE DB_MODE TLS
DOMAIN=""
ACME_EMAIL=""
LICENSE_KEY=""
SMTP_URL=""
MAIL_FROM=""
DATABASE_URL=""
VERSION_ARG=stable
VERSION_SET=false
YES=false
TLS=true

while [ $# -gt 0 ]; do
  opt=$1
  has_value=false
  case $opt in
    --*=*)
      value=${opt#*=}
      opt=${opt%%=*}
      has_value=true
      ;;
  esac
  case $opt in
    --yes) YES=true ;;
    --no-tls) TLS=false ;;
    --help | -h)
      usage
      exit 0
      ;;
    --domain | --email | --license | --smtp-url | --mail-from | --version | --dir | --database-url)
      if [ "$has_value" = false ]; then
        if [ $# -lt 2 ]; then
          usage_error "$opt needs a value."
        fi
        value=$2
        shift
      fi
      case $opt in
        --domain) DOMAIN=$value ;;
        --email) ACME_EMAIL=$value ;;
        --license) LICENSE_KEY=$value ;;
        --smtp-url) SMTP_URL=$value ;;
        --mail-from) MAIL_FROM=$value ;;
        --version)
          VERSION_ARG=$value
          VERSION_SET=true
          ;;
        --dir) INSTALL_DIR=${value%/} ;;
        --database-url) DATABASE_URL=$value ;;
      esac
      ;;
    *) usage_error "Unknown option: $opt" ;;
  esac
  shift
done

if [ -n "$DOMAIN" ]; then
  DOMAIN=$(normalise_domain "$DOMAIN")
  if ! valid_domain "$DOMAIN"; then
    usage_error "$DOMAIN is not a valid domain."
  fi
fi
if [ -n "$ACME_EMAIL" ] && ! valid_email "$ACME_EMAIL"; then
  usage_error "$ACME_EMAIL is not a valid email address."
fi
if [ -n "$DATABASE_URL" ] && ! check_database_url "$DATABASE_URL"; then
  exit 1
fi
if [ -n "$SMTP_URL" ] && ! valid_smtp_url "$SMTP_URL"; then
  usage_error "The SMTP URL must start with smtp:// or smtps://."
fi
# A licence key pasted from an email can carry line breaks and spaces.
LICENSE_KEY=$(printf '%s' "$LICENSE_KEY" | tr -d '[:space:]')
if ! printf '%s\n' "$INSTALL_DIR" | grep -Eqx '/[A-Za-z0-9._/-]+'; then
  usage_error "--dir must be an absolute path made of letters, digits, dots, hyphens and underscores."
fi
if [ "$YES" = true ]; then
  if [ -z "$DOMAIN" ]; then
    usage_error "--domain is required with --yes."
  fi
  if [ "$TLS" = true ] && [ -z "$ACME_EMAIL" ]; then
    usage_error "--email is required with --yes, unless --no-tls is set."
  fi
elif ! (: < /dev/tty) 2> /dev/null; then
  usage_error "There is no terminal to ask questions on. Pass the options with --yes."
fi

# Run from a checkout, the templates, lib.sh and cli.sh are next to this script. Run from a pipe,
# they are downloaded and checked in step 6. Piped into sh, $0 is the shell's name and the
# directory beside it is the caller's working directory, so files there are never used: only a
# script run by its own path as install.sh looks beside itself.
SOURCE_DIR=""
SCRIPT_DIR=$(dirname "$0")
if [ "$(basename "$0")" = install.sh ] && [ -f "$0" ] &&
  [ -f "$SCRIPT_DIR/lib.sh" ] && [ -f "$SCRIPT_DIR/env.template" ]; then
  SOURCE_DIR=$SCRIPT_DIR
  if [ ! -f "$SOURCE_DIR/cli.sh" ]; then
    warn "cli.sh is missing next to install.sh."
    exit 1
  fi
fi

# --- 1. The server -------------------------------------------------------------------------------

check_root
check_os
check_arch
MEMORY_MB=$(memory_mb)
if [ "$MEMORY_MB" -lt 900 ]; then
  warn "This server has $MEMORY_MB MB of memory. $PRODUCT_NAME needs at least 1 GB."
  exit 1
fi

if [ -f "$INSTALL_DIR/.env" ]; then
  if command -v docker > /dev/null 2>&1 && app_healthy "$INSTALL_DIR"; then
    if [ -f "$BIN_PATH" ] && [ -f "$CRON_PATH" ]; then
      warn "Already installed. Use $PRODUCT_SLUG update."
      exit 1
    fi
    # An earlier run stopped after the app became healthy but before step 8. Finish it from what
    # is running, rather than refusing and pointing at a command that was never installed.
    say "$PRODUCT_NAME is running, but the earlier install stopped before it finished. Finishing it."
    DOMAIN=$(env_get DOMAIN "$INSTALL_DIR/.env")
    case $(env_get APP_URL "$INSTALL_DIR/.env") in
      https://*) TLS=true ;;
      *) TLS=false ;;
    esac
    IMAGE=$(env_get IMAGE "$INSTALL_DIR/.env")
    VERSION=${IMAGE##*:}
    SETUP_TOKEN=$(env_get SETUP_TOKEN "$INSTALL_DIR/.env")
    SMTP_URL=$(env_get SMTP_URL "$INSTALL_DIR/.env")
    fetch_sources
    finish_install
    exit 0
  fi
  say "Found $INSTALL_DIR/.env from an earlier attempt. Its secrets will be reused."
  # Stop what that attempt started, so its Caddy does not hold ports 80 and 443. Volumes stay.
  if command -v docker > /dev/null 2>&1; then
    compose "$INSTALL_DIR" down > /dev/null 2>&1 || true
  fi
fi

check_ports
if [ "$MEMORY_MB" -lt 1800 ]; then
  ensure_swap "$MEMORY_MB"
fi

# --- 2. Docker -----------------------------------------------------------------------------------

install_docker

# --- 3. Questions --------------------------------------------------------------------------------

if [ "$YES" = false ]; then
  while [ -z "$DOMAIN" ]; do
    answer=$(normalise_domain "$(ask "Domain for $PRODUCT_NAME, for example tracker.acme.com: ")")
    if valid_domain "$answer"; then
      DOMAIN=$answer
    else
      say "That is not a valid domain."
    fi
  done
  while [ "$TLS" = true ] && [ -z "$ACME_EMAIL" ]; do
    answer=$(ask "Email address for Let's Encrypt certificate notices: ")
    if valid_email "$answer"; then
      ACME_EMAIL=$answer
    else
      say "That is not a valid email address."
    fi
  done
  if [ -z "$LICENSE_KEY" ]; then
    LICENSE_KEY=$(ask "Licence key (press Enter for the free edition): " | tr -d '[:space:]')
  fi
  while [ -z "$SMTP_URL" ]; do
    answer=$(ask_secret "SMTP URL for email, for example smtps://user:pass@smtp.acme.com:465 (typing is hidden, press Enter to skip): ")
    if [ -z "$answer" ]; then
      break
    elif valid_smtp_url "$answer"; then
      SMTP_URL=$answer
    else
      say "The SMTP URL must start with smtp:// or smtps://."
    fi
  done
  if [ -n "$SMTP_URL" ] && [ -z "$MAIL_FROM" ]; then
    MAIL_FROM=$(ask "Sender of emails, for example Acme <ops@acme.com>: ")
  fi
fi

# Running again over an earlier attempt keeps its pinned version unless --version is given.
IMAGE=""
if [ "$VERSION_SET" = false ] && [ -f "$INSTALL_DIR/.env" ]; then
  IMAGE=$(env_get IMAGE "$INSTALL_DIR/.env")
fi
if [ -n "$IMAGE" ]; then
  VERSION=${IMAGE##*:}
else
  VERSION=$(resolve_version "$VERSION_ARG")
  IMAGE="$IMAGE_REPO:$VERSION"
fi

# --- 4. DNS --------------------------------------------------------------------------------------

if [ "$TLS" = true ]; then
  check_dns "$DOMAIN"
fi

# --- External database ---------------------------------------------------------------------------

if [ -n "$DATABASE_URL" ]; then
  DB_MODE=external
  say "Checking the database."
  check_external_db "$DATABASE_URL"
else
  DB_MODE=bundled
fi

# --- 5. Secrets ----------------------------------------------------------------------------------

load_secrets "$INSTALL_DIR"

# --- 6. Files ------------------------------------------------------------------------------------

fetch_sources

say "Writing $INSTALL_DIR."
mkdir -p "$INSTALL_DIR"
if [ -f "$INSTALL_DIR/.env" ]; then
  # An earlier attempt's .env: keep a copy, then keep every setting this run does not set, such
  # as sign-in keys, BACKUP_HOOK or a licence key added with the config command.
  (
    umask 077
    cp "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.previous"
  )
  chmod 600 "$INSTALL_DIR/.env.previous"
  write_install_files "$SOURCE_DIR" "$INSTALL_DIR"
  set_keys="IMAGE DOMAIN DB_MODE COMPOSE_FILE POSTGRES_PASSWORD DATABASE_URL AUTH_SECRET AUTH_URL APP_URL SETUP_TOKEN"
  for key in ACME_EMAIL LICENSE_KEY SMTP_URL MAIL_FROM; do
    eval "value=\${$key}"
    if [ -n "$value" ]; then
      set_keys="$set_keys $key"
    fi
  done
  # shellcheck disable=SC2086 # the list is split on purpose
  merge_env "$INSTALL_DIR/.env.previous" "$INSTALL_DIR/.env" $set_keys
  say "Kept the settings of the earlier .env. The old file is $INSTALL_DIR/.env.previous."
else
  write_install_files "$SOURCE_DIR" "$INSTALL_DIR"
fi

# --- 7. Start ------------------------------------------------------------------------------------

if [ "${SKIP_PULL:-}" != 1 ]; then
  say "Downloading the images."
  compose "$INSTALL_DIR" pull
fi
compose "$INSTALL_DIR" up -d
say "Waiting for $PRODUCT_NAME to start. The first start sets up the database and can take a few minutes."
if ! wait_healthy "$INSTALL_DIR" 300; then
  warn "$PRODUCT_NAME did not become healthy within 5 minutes. See what happened with: cd $INSTALL_DIR && docker compose logs app"
  warn "Then run the installer again. It reuses the secrets in $INSTALL_DIR/.env."
  exit 1
fi

finish_install
