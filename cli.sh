#!/bin/sh
# The eddy command: manages the install in /opt/eddy. install.sh installs it as /usr/local/bin/eddy
# with lib.sh inlined and INSTALL_DIR set. Run it as root:
#
#   sudo eddy status
#
# create-admin and set-license pass through to `node cli.mjs` in the app container, and so does
# the second half of status. backup and restore use the db container, or for an external database
# a one-off postgres:<major>-alpine container matching the server's major version.
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

# Unset first, so a value from the caller's environment never reaches a child process.
unset DATABASE_URL DB_URL PGPASSWORD
DB_URL_NOPASS=""
DB_PASSWORD=""
UPDATE_OLD_IMAGE=""
ENV_FILE="$INSTALL_DIR/.env"
BACKUP_DIR="$INSTALL_DIR/backups"
# The bundled database's role and database, as in compose.db.yml.
BUNDLED_DB=eddy
DB_MODE=""
YES=false
QUIET=false
PURGE=false
ARG=""
HOOK_FAILED=false

usage() {
  cat <<EOF
Usage: $PRODUCT_SLUG <command> [options]

Manages $PRODUCT_NAME in $INSTALL_DIR. Run it as root, for example: sudo $PRODUCT_SLUG status

Commands:
  status              Shows the containers, then the version, plan and team members
  logs [service]      Follows the logs of app, caddy or db, or of all of them
  update [version]    Backs up, then moves to the version (default stable, the latest release)
  backup              Writes a backup of the database to $BACKUP_DIR
  restore <file>      Replaces the database with a backup, after asking
  config              Opens .env in your editor, then applies the changes
  restart             Restarts the stack
  create-admin --email <email> --name <name>
                      Creates a staff account and prints a link to choose its password
  set-license <key>   Sets the licence key. set-license --remove goes back to the free edition
  uninstall           Stops and removes the containers. The data, .env and backups stay
  help                Shows this help

Options:
  --yes               Asks nothing: restore and uninstall go ahead, and a failed update only
                      prints the command that restores the backup it took
  --purge             uninstall only: also deletes the database, .env and every backup. Asks you
                      to type the domain, even with --yes. Never touches an external database
  --quiet             backup only, for the nightly job: prints only errors, and does nothing
                      when .env sets BACKUP_NIGHTLY=false

Environment:
  SKIP_PULL=1         update only: use an image already on this machine instead of pulling it

BACKUP_HOOK in .env runs after each backup, with the backup's path as \$1 and in BACKUP_FILE.
EOF
}

usage_error() {
  warn "$1"
  warn ""
  usage >&2
  exit 1
}

fail() {
  warn "$1"
  exit 1
}

# info: says it, unless --quiet.
info() {
  if [ "$QUIET" = false ]; then
    say "$@"
  fi
}

# confirm <question>: true when the answer is y or yes. Under --yes it asks nothing.
confirm() {
  if [ "$YES" = true ]; then
    return 0
  fi
  printf '%s [y/N] ' "$1"
  IFS= read -r answer || answer=""
  if [ ! -t 0 ]; then printf '\n'; fi
  case $answer in
    [yY] | [yY][eE][sS]) return 0 ;;
  esac
  return 1
}

parse_options() {
  while [ $# -gt 0 ]; do
    case $1 in
      --yes | -y) YES=true ;;
      --quiet) QUIET=true ;;
      --purge) PURGE=true ;;
      --help | -h)
        usage
        exit 0
        ;;
      -*) usage_error "Unknown option: $1" ;;
      *)
        if [ -n "$ARG" ]; then
          usage_error "Too many arguments: $1"
        fi
        ARG=$1
        ;;
    esac
    shift
  done
}

no_arg() {
  if [ -n "$ARG" ]; then
    usage_error "$COMMAND takes no arguments."
  fi
}

require_install() {
  if [ ! -f "$ENV_FILE" ]; then
    fail "No install found in $INSTALL_DIR. Install $PRODUCT_NAME with install.sh first."
  fi
  if [ ! -r "$ENV_FILE" ]; then
    fail "Run this command as root, for example: sudo $PRODUCT_SLUG $COMMAND"
  fi
  DB_MODE=$(env_get DB_MODE "$ENV_FILE")
}

# db_host <url>: the host of a database URL, without the user, password, port or database.
db_host() (
  rest=${1#*://}
  rest=${rest%%[/?]*}
  rest=${rest##*@}
  case $rest in
    \[*) printf '%s\n' "${rest%%]*}]" ;;
    *) printf '%s\n' "${rest%%:*}" ;;
  esac
)

# --- External database -----------------------------------------------------------------------------

# pg_client <image> <program> [args...]: runs a Postgres client program in a one-off container
# against DB_URL, with the app's host mapping. The program's argv gets the URL without its
# password; the password reaches the container only as PGPASSWORD in its environment, and the
# docker command names that variable without its value. stdin and stdout pass through.
pg_client() (
  image=$1
  shift
  # shellcheck disable=SC2016 # $@ and $DATABASE_URL expand inside the container
  DATABASE_URL="$DB_URL_NOPASS" PGPASSWORD="$DB_PASSWORD" docker run --rm -i \
    -e DATABASE_URL -e PGPASSWORD -e PGCONNECT_TIMEOUT=10 \
    --add-host host.docker.internal:host-gateway "$image" \
    sh -c 'exec "$@" --dbname="$DATABASE_URL"' sh "$@"
)

# client_image: reads DB_URL from .env, splits off its password, and sets CLIENT_IMAGE to
# postgres:<major>-alpine for the server's major version, so pg_dump and pg_restore match it.
client_image() {
  DB_URL=$(env_get DATABASE_URL "$ENV_FILE")
  # .env can be edited by hand, so the URL is checked as the installer checks it, before any
  # part of it reaches a client.
  if ! check_database_url "$DB_URL"; then
    warn "Fix DATABASE_URL in $ENV_FILE with: $PRODUCT_SLUG config"
    return 1
  fi
  split_db_url "$DB_URL"
  err=$(mktemp)
  if ! version=$(pg_client "$PREFLIGHT_IMAGE" psql -XAtq -c "show server_version_num" < /dev/null 2> "$err"); then
    redact_db_errors "$DB_URL" "$err"
    rm -f "$err"
    warn "Could not connect to the database. Check DATABASE_URL in $ENV_FILE, and that this server can reach the database."
    return 1
  fi
  rm -f "$err"
  case $version in
    '' | *[!0-9]*)
      warn "Could not read the database's version."
      return 1
      ;;
  esac
  CLIENT_IMAGE="postgres:$((version / 10000))-alpine"
}

# --- Backups -------------------------------------------------------------------------------------

# prune_backups: keeps the newest BACKUP_KEEP backups (default 14). Names hold a UTC timestamp,
# so they sort oldest first.
prune_backups() (
  keep=$(env_get BACKUP_KEEP "$ENV_FILE")
  case $keep in
    '' | *[!0-9]*) keep=14 ;;
  esac
  if [ "$keep" -lt 1 ]; then keep=1; fi
  for f in "$BACKUP_DIR/$PRODUCT_SLUG"-*.dump; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; fi
  done | sort -r | tail -n +"$((keep + 1))" | while IFS= read -r f; do
    rm -f "$f"
  done
)

# backup_now: writes a pg_dump -Fc backup to backups/ and sets BACKUP_FILE, then prunes and runs
# BACKUP_HOOK (setting HOOK_FAILED when it fails). Returns 1, leaving no file, when the dump fails.
backup_now() {
  if [ "$DB_MODE" = external ]; then
    client_image || return 1
  fi
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || return 1
  BACKUP_FILE="$BACKUP_DIR/$PRODUCT_SLUG-$(date -u +%Y%m%d-%H%M%S).dump"
  while [ -e "$BACKUP_FILE" ]; do
    sleep 1
    BACKUP_FILE="$BACKUP_DIR/$PRODUCT_SLUG-$(date -u +%Y%m%d-%H%M%S).dump"
  done
  partial="$BACKUP_FILE.partial"
  err=$(mktemp)
  dumped=true
  (
    umask 077
    if [ "$DB_MODE" = external ]; then
      pg_client "$CLIENT_IMAGE" pg_dump -Fc < /dev/null > "$partial" 2> "$err"
    else
      compose "$INSTALL_DIR" exec -T db pg_dump -U "$BUNDLED_DB" -d "$BUNDLED_DB" -Fc \
        < /dev/null > "$partial" 2> "$err"
    fi
  ) || dumped=false
  # A custom-format dump starts with PGDMP.
  if [ "$dumped" = true ] && [ "$(head -c 5 "$partial")" != PGDMP ]; then
    dumped=false
  fi
  if [ "$dumped" = false ]; then
    if [ "$DB_MODE" = external ]; then
      redact_db_errors "$DB_URL" "$err"
    else
      cat "$err" >&2
    fi
    rm -f "$err" "$partial"
    warn "The backup failed, so no backup was written. Check that $PRODUCT_NAME is running with: $PRODUCT_SLUG status"
    return 1
  fi
  rm -f "$err"
  mv "$partial" "$BACKUP_FILE" || return 1
  info "Backup written to $BACKUP_FILE."
  prune_backups
  hook=$(env_get BACKUP_HOOK "$ENV_FILE")
  if [ -n "$hook" ]; then
    if ! (cd "$INSTALL_DIR" && export BACKUP_FILE && sh -c "$hook" sh "$BACKUP_FILE"); then
      warn "The backup is in $BACKUP_FILE, but BACKUP_HOOK failed."
      HOOK_FAILED=true
    fi
  fi
  return 0
}

# --- Restore -------------------------------------------------------------------------------------

# wait_db: waits up to a minute for the bundled database to accept connections.
wait_db() (
  waited=0
  while ! compose "$INSTALL_DIR" exec -T db pg_isready -q -U "$BUNDLED_DB" -d "$BUNDLED_DB" < /dev/null > /dev/null 2>&1; do
    if [ "$waited" -ge 60 ]; then
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
)

# restore_file <file>: stops the app, restores the backup and starts the app. Bundled: recreates
# the database, then pg_restore. External: pg_restore --clean --if-exists into the existing
# database, which is never dropped or created, because the role often cannot create databases.
restore_file() {
  file=$1
  if [ "$DB_MODE" = external ]; then
    client_image || return 1
  fi
  say "Stopping the app."
  if ! compose "$INSTALL_DIR" stop app; then
    warn "Could not stop the app, so nothing was restored."
    return 1
  fi
  err=$(mktemp)
  restored=true
  if [ "$DB_MODE" = external ]; then
    say "Restoring $file."
    if ! pg_client "$CLIENT_IMAGE" pg_restore --clean --if-exists --no-owner --no-privileges \
      < "$file" 2> "$err"; then
      redact_db_errors "$DB_URL" "$err"
      restored=false
    fi
  elif ! compose "$INSTALL_DIR" up -d db || ! wait_db; then
    warn "The database did not start, so nothing was restored. See what happened with: $PRODUCT_SLUG logs db"
    restored=false
  elif ! compose "$INSTALL_DIR" exec -T db psql -X -q -v ON_ERROR_STOP=1 -U "$BUNDLED_DB" -d postgres \
    -c "drop database if exists $BUNDLED_DB with (force)" \
    -c "create database $BUNDLED_DB owner $BUNDLED_DB" < /dev/null; then
    warn "Could not recreate the database."
    restored=false
  else
    say "Recreated the database. Restoring $file."
    if ! compose "$INSTALL_DIR" exec -T db pg_restore -U "$BUNDLED_DB" -d "$BUNDLED_DB" \
      --no-owner --no-privileges < "$file" 2> "$err"; then
      cat "$err" >&2
      restored=false
    fi
  fi
  rm -f "$err"
  say "Starting the app."
  compose "$INSTALL_DIR" up -d
  if [ "$restored" = false ]; then
    warn "The restore reported the errors above. Check them before relying on this install."
    return 1
  fi
  if ! wait_healthy "$INSTALL_DIR" 300; then
    warn "The app did not become healthy after the restore. See what happened with: $PRODUCT_SLUG logs app"
    return 1
  fi
  say "Restored $file."
}

# --- Commands ------------------------------------------------------------------------------------

# Prints the JSON fields of cli.mjs status that are present, one per line.
print_status() (
  json=$1
  field() {
    # shellcheck disable=SC2020 # each of { } and , becomes a line break
    printf '%s\n' "$json" | tr '{},' '\n\n\n' |
      sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*//p" | head -n 1 |
      sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e 's/^null$/none/'
  }
  line() {
    if [ -n "$2" ]; then say "$1: $2"; fi
  }
  line Version "$(field version)"
  line Built "$(field buildDate)"
  line Plan "$(field plan)"
  used=$(field seatsUsed)
  seats=$(field seats)
  if [ -n "$used" ] && [ -n "$seats" ]; then
    say "Team members: $used of $seats"
  else
    line "Team members" "$used"
    line "Licence covers" "$seats"
  fi
  line "Updates until" "$(field updatesUntil)"
  line Expires "$(field expiresAt)"
)

cmd_status() {
  no_arg
  require_install
  compose "$INSTALL_DIR" ps
  say ""
  if ! json=$(compose "$INSTALL_DIR" exec -T app node cli.mjs status < /dev/null); then
    fail "Could not read the version from the app container. See what happened with: $PRODUCT_SLUG logs app"
  fi
  print_status "$json"
}

cmd_logs() {
  require_install
  if [ -n "$ARG" ]; then
    compose "$INSTALL_DIR" logs -f --tail 100 "$ARG"
  else
    compose "$INSTALL_DIR" logs -f --tail 100
  fi
}

cmd_backup() {
  no_arg
  require_install
  # The nightly job runs backup --quiet. With an external database the provider's backups are
  # often the main ones, so BACKUP_NIGHTLY=false turns it off. update always backs up.
  if [ "$QUIET" = true ] && [ "$(env_get BACKUP_NIGHTLY "$ENV_FILE")" = false ]; then
    return 0
  fi
  backup_now || exit 1
  if [ "$HOOK_FAILED" = true ]; then
    exit 1
  fi
}

# update_interrupted: the INT and TERM trap while update runs. Puts the old tag back and says how
# to start it and where the backup is.
update_interrupted() {
  trap - INT TERM
  env_set IMAGE "$UPDATE_OLD_IMAGE" "$ENV_FILE" || true
  warn ""
  warn "The update was interrupted, so $UPDATE_OLD_IMAGE is back in $ENV_FILE. The containers may still run the new version. Start the old one with: cd $INSTALL_DIR && docker compose up -d"
  warn "The backup taken before the update is $BACKUP_FILE. Restore it if the old version does not start: $PRODUCT_SLUG restore $BACKUP_FILE"
  exit 130
}

cmd_update() {
  require_install
  version=$(resolve_version "${ARG:-stable}") || exit 1
  new_image="$IMAGE_REPO:$version"
  old_image=$(env_get IMAGE "$ENV_FILE")
  say "Updating $PRODUCT_NAME from ${old_image##*:} to $version. Taking a backup first."
  if ! backup_now; then
    fail "The update stopped before changing anything, because the backup failed."
  fi
  # From here until the update succeeds or fails, Ctrl-C puts the old tag back.
  UPDATE_OLD_IMAGE=$old_image
  trap update_interrupted INT TERM
  env_set IMAGE "$new_image" "$ENV_FILE"
  if [ "${SKIP_PULL:-}" != 1 ]; then
    say "Downloading $new_image."
    if ! compose "$INSTALL_DIR" pull; then
      trap - INT TERM
      env_set IMAGE "$old_image" "$ENV_FILE"
      fail "Could not download $new_image. Nothing else was changed, and $old_image is still running."
    fi
  fi
  say "Starting $version. Waiting for it to become healthy, which can take a few minutes."
  if compose "$INSTALL_DIR" up -d && wait_healthy "$INSTALL_DIR" 300; then
    trap - INT TERM
    say "$PRODUCT_NAME $version is running. The backup taken before the update is $BACKUP_FILE."
    return 0
  fi

  # The new version failed. Put the old tag back. Migrations do not roll back, so the old version
  # may need the backup taken before the update.
  trap - INT TERM
  env_set IMAGE "$old_image" "$ENV_FILE"
  warn "$PRODUCT_NAME $version did not become healthy within 5 minutes, so $old_image is back in $ENV_FILE."
  warn "See what happened with: $PRODUCT_SLUG logs app"
  restore_command="$PRODUCT_SLUG restore $BACKUP_FILE"
  if [ "$YES" = false ]; then
    say "The new version may have changed the database, and those changes do not roll back."
    if confirm "Restore the backup taken before the update?"; then
      if restore_file "$BACKUP_FILE"; then
        warn "The update failed. $old_image is running with the backup taken before the update."
      fi
      exit 1
    fi
  fi
  say "Starting $old_image again."
  if compose "$INSTALL_DIR" up -d && wait_healthy "$INSTALL_DIR" 300; then
    say "$old_image is running."
  else
    warn "$old_image did not become healthy either."
  fi
  say "To restore the backup taken before the update, run: $restore_command"
  exit 1
}

cmd_restore() {
  require_install
  if [ -z "$ARG" ]; then
    usage_error "restore needs a backup file, for example: $PRODUCT_SLUG restore $BACKUP_DIR/<file>.dump"
  fi
  file=$ARG
  if [ ! -f "$file" ] && [ -f "$BACKUP_DIR/$file" ]; then
    file="$BACKUP_DIR/$file"
  fi
  if [ ! -f "$file" ]; then
    fail "There is no file $ARG."
  fi
  case $file in
    /*) ;;
    *) file="$(pwd)/$file" ;;
  esac
  if [ "$(head -c 5 "$file")" != PGDMP ]; then
    fail "$file is not a backup made by $PRODUCT_SLUG backup."
  fi
  say "This replaces everything in the $PRODUCT_NAME database with $file. The app stops while it runs."
  if ! confirm "Restore $file?"; then
    fail "Nothing was changed."
  fi
  restore_file "$file" || exit 1
}

cmd_config() {
  no_arg
  require_install
  editor=${VISUAL:-${EDITOR:-}}
  if [ -z "$editor" ]; then
    for candidate in editor nano vi; do
      if command -v "$candidate" > /dev/null 2>&1; then
        editor=$candidate
        break
      fi
    done
  fi
  if [ -z "$editor" ]; then
    fail "No editor found. Name one, for example: sudo EDITOR=nano $PRODUCT_SLUG config"
  fi
  before=$(cksum < "$ENV_FILE")
  # shellcheck disable=SC2086 # EDITOR can hold options, such as "code --wait"
  if ! $editor "$ENV_FILE"; then
    fail "The editor stopped with an error. Nothing was restarted."
  fi
  if [ "$(cksum < "$ENV_FILE")" = "$before" ]; then
    say "No changes, so nothing was restarted."
    return 0
  fi
  chmod 600 "$ENV_FILE"
  say "Applying the changes."
  compose "$INSTALL_DIR" up -d --remove-orphans
  if ! wait_healthy "$INSTALL_DIR" 300; then
    fail "$PRODUCT_NAME did not become healthy after the change. See what happened with: $PRODUCT_SLUG logs app"
  fi
  say "$PRODUCT_NAME is running with the new settings."
}

cmd_restart() {
  no_arg
  require_install
  compose "$INSTALL_DIR" restart
  if ! wait_healthy "$INSTALL_DIR" 300; then
    fail "$PRODUCT_NAME did not become healthy after the restart. See what happened with: $PRODUCT_SLUG logs app"
  fi
  say "$PRODUCT_NAME is running."
}

cmd_uninstall() {
  no_arg
  require_install
  domain=$(env_get DOMAIN "$ENV_FILE")
  host=""
  if [ "$DB_MODE" = external ]; then
    host=$(db_host "$(env_get DATABASE_URL "$ENV_FILE")")
  fi
  if [ "$PURGE" = false ]; then
    if ! confirm "Stop and remove the $PRODUCT_NAME containers? The data, .env and backups stay."; then
      fail "Nothing was changed."
    fi
    compose "$INSTALL_DIR" down
    rm -f "$CRON_PATH"
    say "The containers are removed, and the nightly backup is off. The data, .env and backups are still in $INSTALL_DIR."
    say "Start it again with: cd $INSTALL_DIR && docker compose up -d"
    say "Delete everything with: $PRODUCT_SLUG uninstall --purge"
    return 0
  fi

  case $INSTALL_DIR in
    / | "") fail "Refusing to delete $INSTALL_DIR." ;;
  esac
  say "This stops $PRODUCT_NAME and deletes $INSTALL_DIR, with .env and every backup in it."
  if [ "$DB_MODE" = external ]; then
    say "The external database at $host is not touched."
  else
    say "It also deletes the bundled database and all its data."
  fi
  # Typing the domain is asked even under --yes.
  printf 'Type the domain, %s, to confirm: ' "$domain"
  IFS= read -r answer || answer=""
  if [ ! -t 0 ]; then printf '\n'; fi
  if [ -z "$domain" ] || [ "$answer" != "$domain" ]; then
    fail "The domain did not match. Nothing was removed."
  fi
  # For an external database the compose files hold no database service or volume, so this
  # removes only the containers and Caddy's volumes.
  compose "$INSTALL_DIR" down -v --remove-orphans
  rm -f "$CRON_PATH"
  rm -rf "$INSTALL_DIR"
  rm -f "$BIN_PATH"
  say "$PRODUCT_NAME is removed."
  if [ "$DB_MODE" = external ]; then
    say "The database at $host still holds its data. Drop it there if you no longer need it."
  fi
}

# --- Main ----------------------------------------------------------------------------------------

if [ $# -eq 0 ]; then
  usage >&2
  exit 1
fi
COMMAND=$1
shift
case $COMMAND in
  help | --help | -h) usage ;;
  create-admin | set-license)
    require_install
    compose "$INSTALL_DIR" exec -T app node cli.mjs "$COMMAND" "$@"
    ;;
  status | logs | update | backup | restore | config | restart | uninstall)
    parse_options "$@"
    case $COMMAND in
      status) cmd_status ;;
      logs) cmd_logs ;;
      update) cmd_update ;;
      backup) cmd_backup ;;
      restore) cmd_restore ;;
      config) cmd_config ;;
      restart) cmd_restart ;;
      uninstall) cmd_uninstall ;;
    esac
    ;;
  *) usage_error "Unknown command: $COMMAND" ;;
esac
