# wp-anti-mal (PantiMal)

Scan and **quarantine** WordPress malware across many site docroots. Uses [WP-CLI](https://wp-cli.org/) for checksums and optional repair. Designed so the scheduled job can pull implants out **without** giving leftover PHP a root shell.

This is not a substitute for keeping core/plugins/themes updated or rotating compromised passwords.

## What it does on a normal scan

For each WordPress docroot, **before** any `wp` command loads the site:

1. Quarantine known webshell / restorer filenames (move, do not `rm`).
2. Quarantine unexpected drop-ins (`db.php`, `advanced-cache.php`, `object-cache.php`) unless they are Query Monitor or W3 Total Cache.
3. Quarantine must-use plugins other than the optional hardening pair in `mu-plugins/`.
4. Strip `@eval($_SERVER[...])` backdoors from `wp-config.php`.
5. If you set `SNIPPET_OWNER_MARK`, deactivate Code Snippets that do not contain that mark.
6. Delete known restorer option blobs (`_wp_recovery_mode_data`, `_site_transient_health`, `_wp_core_settings_cache*`).
7. Log leftover administrator logins that match common attacker name patterns.

Then it runs `wp core verify-checksums`. Extra “file should not exist” files are **left in place** unless they match a malware signature (new official core files are no longer deleted blindly).

`--repair` and `--tidy` still exist for a **manual** run. Do not put them on cron.

## Requirements

- Bash, `flock`, WP-CLI
- Permission to read/write the site trees (typically root on shared hosting panels)
- `mail` or `mailx` only if you want email alerts

## Quick start

```bash
sudo cp -a wp-anti-mal /opt/wp-anti-mal
sudo cp /opt/wp-anti-mal/pantimal.conf.example /etc/pantimal.conf
sudo editor /etc/pantimal.conf
sudo /opt/wp-anti-mal/wp_core_check.sh --dry-run --no-mail --no-symlinks
```

Suggested cron (scan + quarantine only):

```cron
*/15 * * * * /usr/bin/flock -n /var/lock/pantimal.lock /opt/wp-anti-mal/wp_core_check.sh --no-symlinks --append --log-file=/var/log/wp-check.log >/dev/null 2>&1
```

The script also takes its own flock; the cron `flock` is extra safety.

## Configuration

Edit the `CONFIG` block at the top of `wp_core_check.sh`, **or** (preferred) use a file that is not committed:

| File | When to use |
|---|---|
| `/etc/pantimal.conf` | System-wide on a server |
| `./pantimal.conf` next to the script | Per-checkout overrides |

See `pantimal.conf.example`. Command-line flags override the file.

Important variables:

| Variable | Default | Meaning |
|---|---|---|
| `ALERT_EMAIL` | empty | Digest recipient. Empty = no mail. |
| `BASE_DIR` | `/var/www/clients` | Walks `client*/web*` (ISPConfig) or `web*` if those exist directly. |
| `DOCROOT_NAME` | `web` | Folder inside each site that holds WordPress. |
| `SNIPPET_OWNER_MARK` | empty | If set, any *active* Code Snippet without this string is deactivated. |
| `QUARANTINE_BASE` | `/var/log/pantimal-quarantine` | Moved files land in `$QUARANTINE_BASE/YYYYMMDD/<site>/`. |
| `ALLOWED_MU_PLUGINS` | `guard-users.php` `disable-rest-api.php` | Other `mu-plugins/*.php` files are quarantined. |

### Email

Set `ALERT_EMAIL` or pass `--alert-email=you@example.com`. A single digest is sent **only when there are findings** (quarantine, checksum fail, unowned snippet, attacker-shaped admin, restorer option). `--no-mail` skips sending.

### Code Snippets owner tag

If you are the only person who should add snippets, set a private mark and put it in the snippet name, description, or a code comment:

```php
/* CTS-SNIPPET-OWNER:yourname */
```

This is an ownership tag, not a secret. It stops commodity malware that inserts snippets. Someone with admin who reads an existing snippet could copy it.

Leave `SNIPPET_OWNER_MARK` empty to disable that check (default in this repo).

## Options

```bash
./wp_core_check.sh [--repair] [--force] [--dry-run] [--append]
  [--log-file=FILE] [--wp-cli=PATH] [--tidy]
  [--base-dir=DIR] [--docroot=DIR] [--single-docroot=DIR]
  [--no-symlinks] [--alert-email=ADDR] [--no-mail] [--help]
```

| Flag | Purpose |
|---|---|
| `--repair` | Reinstall core if checksums fail; force-reinstall active plugins/themes from wordpress.org. |
| `--force` | Reinstall core on every site. |
| `--tidy` | Delete inactive plugins/themes (keeps one default Twenty\* theme). |
| `--dry-run` | Log actions only. |
| `--append` | Append to the log file. |
| `--no-symlinks` | Skip symlink site directories (ISPConfig domain aliases). |
| `--single-docroot=DIR` | Scan one WordPress root. Ignores `--base-dir` / `--docroot`. |
| `--alert-email=ADDR` | Override `ALERT_EMAIL`. |
| `--no-mail` | Do not send mail. |

## Optional must-use plugins

`mu-plugins/` is hardening you can drop into each site’s `wp-content/mu-plugins/` (root-owned `0644` so the web user cannot overwrite them):

- **guard-users.php** — block known-bad usernames, demote stealth administrators unless a trusted admin (or WP-CLI) created them, remove `_pre_user_id` persistence.
- **disable-rest-api.php** — disable XML-RPC; require login for REST except storefront namespaces that are actually installed (SureCart, WooCommerce, Forminator). Does **not** flush rewrite rules on every request.

PantiMal will quarantine any *other* mu-plugin. If you have legitimate extra mu-plugins, add their filenames to `ALLOWED_MU_PLUGINS`.

## Why `--repair` is not on cron

`--skip-plugins --skip-themes` still loads drop-ins and mu-plugins. A leftover `db.php` restorer that runs under a root WP-CLI job will rewrite shells as root. This version quarantines those files *before* WP-CLI. Even so, core/plugin reinstall is a large change and stays opt-in.

## Logs

Default log: `/var/log/wp-check.log`. Use `--append` on cron so history is kept.

## License

Public domain under the [Unlicense](LICENSE).
