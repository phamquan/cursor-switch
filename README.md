# cursor-switch

A small bash script that switches between saved Cursor logins from the terminal.

It only reads and writes the `cursorAuth/*` rows in Cursor's `state.vscdb`. Chat history, settings, and extensions stay shared. It does not install an app.

## Requirements

- macOS
- `sqlite3` (included with macOS)
- Cursor installed at `/Applications/Cursor.app`

## Usage

```bash
bash scripts/cursor-switch.sh status
bash scripts/cursor-switch.sh save work           # while that account is signed in
bash scripts/cursor-switch.sh add personal        # keep current login, clear it, open Cursor to sign in
# sign in, quit Cursor, then:
bash scripts/cursor-switch.sh save personal
bash scripts/cursor-switch.sh switch work
bash scripts/cursor-switch.sh list
bash scripts/cursor-switch.sh remove personal
```

Quit Cursor before `switch` or `add`. Use `--force` only if Cursor ignores a normal quit.

## Where things are stored

- Live login: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- Saved accounts: `~/.cursor-account-switch/accounts/<name>.tsv` (mode `600`)

Saved accounts contain access tokens. Do not commit or share them. The `accounts/` folder is git-ignored.

## Environment overrides

- `CURSOR_STATE_DB`: path to a different `state.vscdb`
- `CURSOR_SWITCH_HOME`: folder for saved accounts (default `~/.cursor-account-switch`)
- `CURSOR_APP_PATH`: path to `Cursor.app`

## Disclaimer

Not affiliated with Cursor or Anysphere. Use at your own risk. Test with a disposable account first.
