#!/usr/bin/env bash
# Switch Cursor logins from the terminal. Not an app bundle.
#
# Saves and restores only cursorAuth/* rows in Cursor's state.vscdb.
# Chat history, settings, and extensions stay shared.
# Snapshots contain access tokens. They stay in your home directory.
#
#   cursor-switch.sh status
#   cursor-switch.sh save work
#   cursor-switch.sh switch work
#   cursor-switch.sh add personal
#   cursor-switch.sh list
#   cursor-switch.sh remove personal
#
# After `add`, sign in inside Cursor, quit Cursor, then `save` that name.

set -euo pipefail

DB="${CURSOR_STATE_DB:-$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb}"
ROOT="${CURSOR_SWITCH_HOME:-$HOME/.cursor-account-switch}"
ACCOUNTS="${ROOT}/accounts"
CURSOR_APP="${CURSOR_APP_PATH:-/Applications/Cursor.app}"
FORCE=0

KEYS=(
  "cursorAuth/accessToken"
  "cursorAuth/refreshToken"
  "cursorAuth/cachedEmail"
  "cursorAuth/cachedSignUpType"
  "cursorAuth/stripeMembershipType"
  "cursorAuth/stripeSubscriptionStatus"
  "cursorAuth/cachedScopedProfile"
)

usage() {
  cat <<'EOF'
Usage: cursor-switch.sh [--force] <command> [name]

Commands:
  status              Show the current login and where Cursor and saved accounts are stored
  list                List saved accounts (name and email only)
  save <name>         Store the current Cursor login under <name>
  switch <name>       Quit Cursor, restore <name>, open Cursor
  add <name>          Keep the current login, clear it, open Cursor to sign in
  remove <name>       Delete a saved login snapshot

--force   If Cursor ignores a normal quit, terminate it

Accounts are files in ~/.cursor-account-switch/accounts/.
They contain auth tokens. Do not commit or share them.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_sqlite() {
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is not installed"
}

need_db() {
  need_sqlite
  [[ -f "$DB" ]] || die "Cursor database not found: $DB"
}

validate_name() {
  local name="$1"
  [[ -n "$name" ]] || die "account name required"
  [[ "$name" != "." && "$name" != ".." ]] || die "invalid account name"
  [[ "$name" =~ ^[A-Za-z0-9._@+-]+$ ]] || die "account name may use letters, numbers, and . _ @ + -"
}

key_sql() {
  local sql="" key
  for key in "${KEYS[@]}"; do
    if [[ -n "$sql" ]]; then
      sql="${sql},"
    fi
    sql="${sql}'${key}'"
  done
  printf '%s' "$sql"
}

KEY_SQL="$(key_sql)"

allowed_key() {
  local key="$1" item
  for item in "${KEYS[@]}"; do
    [[ "$item" == "$key" ]] && return 0
  done
  return 1
}

cursor_running() {
  local out
  out="$(killall -s Cursor 2>/dev/null || true)"
  [[ "$out" == *"kill "* ]]
}

quit_cursor() {
  if ! cursor_running; then
    return 0
  fi
  osascript -e 'tell application "Cursor" to quit' >/dev/null 2>&1 || true
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! cursor_running; then
      return 0
    fi
    sleep 0.25
  done
  if [[ "$FORCE" -eq 1 ]]; then
    killall Cursor >/dev/null 2>&1 || true
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      if ! cursor_running; then
        return 0
      fi
      sleep 0.25
    done
  fi
  die "Cursor is still running. Quit it, or re-run with --force"
}

sql() {
  sqlite3 -batch "$DB" "$@"
}

current_email() {
  sql "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key='cursorAuth/cachedEmail' LIMIT 1;" 2>/dev/null || true
}

has_token() {
  local hex
  hex="$(sql "SELECT hex(CAST(value AS TEXT)) FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1;" 2>/dev/null || true)"
  [[ -n "$hex" ]]
}

hex_to_text() {
  local hex="$1" i pair
  [[ -n "$hex" ]] || return 0
  [[ "$hex" =~ ^[0-9A-Fa-f]+$ ]] || return 1
  i=0
  while [[ "$i" -lt ${#hex} ]]; do
    pair="${hex:$i:2}"
    printf "\\x${pair}"
    i=$((i + 2))
  done
}

email_from_snapshot() {
  local file="$1" hex
  hex="$(awk -F '\t' '$1=="cursorAuth/cachedEmail" { print $2; exit }' "$file")"
  hex_to_text "$hex"
}

ensure_store() {
  mkdir -p "$ACCOUNTS"
  chmod 700 "$ROOT" "$ACCOUNTS"
}

write_snapshot() {
  local name="$1" tmp
  validate_name "$name"
  need_db
  has_token || die "no Cursor login found. Sign in, quit Cursor, then save"
  ensure_store
  tmp="$(mktemp "${TMPDIR:-/tmp}/cursor-switch.XXXXXX")"
  sql "SELECT key, hex(CAST(value AS TEXT)) FROM ItemTable WHERE key IN (${KEY_SQL});" \
    | awk -F '|' 'NF>=1 { print $1 "\t" $2 }' >"$tmp"
  mv "$tmp" "${ACCOUNTS}/${name}.tsv"
  chmod 600 "${ACCOUNTS}/${name}.tsv"
}

apply_snapshot() {
  local file="$1" key hex sql_file
  [[ -f "$file" ]] || die "saved account not found: $file"
  sql_file="$(mktemp "${TMPDIR:-/tmp}/cursor-switch-sql.XXXXXX")"
  {
    echo "BEGIN IMMEDIATE;"
    echo "DELETE FROM ItemTable WHERE key IN (${KEY_SQL});"
    while IFS="$(printf '\t')" read -r key hex; do
      [[ -n "$key" ]] || continue
      allowed_key "$key" || die "snapshot has an unexpected key"
      [[ "$hex" =~ ^[0-9A-Fa-f]*$ ]] || die "snapshot value is not hex"
      if [[ -z "$hex" ]]; then
        echo "INSERT INTO ItemTable(key, value) VALUES('${key}', '');"
      else
        echo "INSERT INTO ItemTable(key, value) VALUES('${key}', CAST(X'${hex}' AS TEXT));"
      fi
    done <"$file"
    echo "COMMIT;"
  } >"$sql_file"
  sql <"$sql_file"
  rm -f "$sql_file"
}

preserve_current() {
  local email slug file name saved
  has_token || return 0
  email="$(current_email)"
  if [[ -n "$email" && -d "$ACCOUNTS" ]]; then
    for file in "${ACCOUNTS}"/*.tsv; do
      [[ -f "$file" ]] || continue
      saved="$(email_from_snapshot "$file")"
      if [[ "$saved" == "$email" ]]; then
        name="$(basename "$file" .tsv)"
        write_snapshot "$name"
        echo "Updated saved login ${name}"
        return 0
      fi
    done
  fi
  slug="$(printf '%s' "$email" | tr -cd 'A-Za-z0-9._@+-')"
  [[ -n "$slug" ]] || slug="_previous"
  write_snapshot "$slug"
  echo "Saved the current login as ${slug}"
}

cmd_status() {
  need_db
  local email running="not running" file saved match=""
  email="$(current_email)"
  if cursor_running; then
    running="running"
  fi
  if [[ -n "$email" && -d "$ACCOUNTS" ]]; then
    for file in "${ACCOUNTS}"/*.tsv; do
      [[ -f "$file" ]] || continue
      saved="$(email_from_snapshot "$file")"
      if [[ "$saved" == "$email" ]]; then
        if [[ -n "$match" ]]; then
          match="${match}, ${file}"
        else
          match="$file"
        fi
      fi
    done
  fi
  if [[ -n "$email" ]]; then
    echo "login: ${email}"
  else
    echo "login: signed out"
  fi
  echo "cursor: ${running}"
  echo "database: ${DB}"
  echo "saved accounts: ${ACCOUNTS}"
  if [[ -n "$match" ]]; then
    echo "active snapshot: ${match}"
  else
    echo "active snapshot: none"
  fi
}

cmd_list() {
  ensure_store
  local file name email found=0
  for file in "${ACCOUNTS}"/*.tsv; do
    [[ -f "$file" ]] || continue
    found=1
    name="$(basename "$file" .tsv)"
    email="$(email_from_snapshot "$file")"
    if [[ -n "$email" ]]; then
      printf '%s\t%s\n' "$name" "$email"
    else
      printf '%s\n' "$name"
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "No saved accounts. Sign in to Cursor, then: cursor-switch.sh save work"
  fi
}

cmd_save() {
  local name="${1:-}"
  validate_name "$name"
  write_snapshot "$name"
  echo "Saved ${name} ($(email_from_snapshot "${ACCOUNTS}/${name}.tsv"))"
}

cmd_switch() {
  local name="${1:-}" file email
  validate_name "$name"
  file="${ACCOUNTS}/${name}.tsv"
  [[ -f "$file" ]] || die "unknown account '${name}'. Run: cursor-switch.sh list"
  need_db
  [[ -d "$CURSOR_APP" || -e "$CURSOR_APP" ]] || die "Cursor app not found: $CURSOR_APP"
  preserve_current
  quit_cursor
  sql "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
  apply_snapshot "$file"
  open "$CURSOR_APP"
  email="$(email_from_snapshot "$file")"
  echo "Switched to ${name} (${email})"
}

cmd_add() {
  local name="${1:-}"
  validate_name "$name"
  [[ ! -e "${ACCOUNTS}/${name}.tsv" ]] || die "account '${name}' already exists"
  need_db
  [[ -d "$CURSOR_APP" || -e "$CURSOR_APP" ]] || die "Cursor app not found: $CURSOR_APP"
  preserve_current
  quit_cursor
  sql "BEGIN IMMEDIATE; DELETE FROM ItemTable WHERE key IN (${KEY_SQL}); COMMIT;"
  open "$CURSOR_APP"
  cat <<EOF
Cursor is open with no saved login.
Sign in, quit Cursor, then run:

  cursor-switch.sh save ${name}
EOF
}

cmd_remove() {
  local name="${1:-}" file
  validate_name "$name"
  file="${ACCOUNTS}/${name}.tsv"
  [[ -f "$file" ]] || die "unknown account '${name}'"
  rm -f "$file"
  echo "Removed saved login ${name}. The login inside Cursor is unchanged."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) break ;;
  esac
done

cmd="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$cmd" in
  status) cmd_status ;;
  list) cmd_list ;;
  save) cmd_save "${1:-}" ;;
  switch) cmd_switch "${1:-}" ;;
  add) cmd_add "${1:-}" ;;
  remove) cmd_remove "${1:-}" ;;
  "") usage; exit 1 ;;
  *) die "unknown command '${cmd}'. Try --help" ;;
esac
