# wpantimal

`wpantimal` is a Bash script that scans multiple WordPress installations for unexpected core files and known backdoors. It uses [WP-CLI](https://wp-cli.org/) to verify checksums, optionally repair installations, and tidy up unused themes and plugins.

## Features
- Verify WordPress core files with `wp core verify-checksums`.
- Remove files that should not exist and delete common backdoor filenames.
- Reset the main `.htaccess` to the default WordPress rules and remove rogue `.htaccess` files under `wp-content`.
- Optional repair mode to reinstall core files and reinstall active plugins and themes.
- Force mode to reinstall WordPress core for all detected sites.
- Tidy mode to delete inactive themes and plugins.
- Customizable log file and WP-CLI path.
- All WP-CLI calls run with `--skip-plugins --skip-themes` for safety.

## Requirements
- Bash shell
- WP-CLI installed and accessible
- Appropriate permissions to manage the WordPress installs

## Usage
```bash
./wp_core_check.sh [--repair] [--force] [--dry-run] [--append] [--log-file=FILE] [--wp-cli=PATH] [--tidy] [--base-dir=DIR] [--docroot=DIR] [--no-symlinks]
```

### Options
- `--repair` &mdash; reinstall missing core files and active extensions.
- `--force` &mdash; reinstall core for every site without verifying checksums first.
- `--dry-run` &mdash; print actions without making changes.
- `--append` &mdash; append output to the existing log file instead of replacing it.
- `--log-file=FILE` &mdash; path to save the log (defaults to `/var/www/clients/client1/core-checksums-report.log`).
- `--wp-cli=PATH` &mdash; use a specific WP-CLI binary.
- `--tidy` &mdash; remove inactive themes and plugins after verification.
- `--base-dir=DIR` &mdash; base directory containing site folders.
- `--docroot=DIR` &mdash; name of the docroot folder inside each site (defaults to `web`).
- `--no-symlinks` &mdash; skip directories that are symlinks.

### Example
```bash
./wp_core_check.sh --repair --tidy --log-file=/tmp/core-check.log
```

## Logs
Progress and results are timestamped and written to the specified log file. Use `--append` to preserve previous logs across runs.

## Directory layout
By default the script scans all directories under `/var/www/clients/client1` and expects each site to have a `web/` docroot. Both the base directory and docroot name can be changed with `--base-dir` and `--docroot`. Use `--no-symlinks` to skip any directories that are symbolic links.

## License
No explicit license is provided for this project.
