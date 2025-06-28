# wpantimal
Simple AnitMalware script for WP.

### Usage

```
./wp_core_check.sh [--repair] [--dry-run] [--force] [--append] [--log-file=FILE] [--wp-cli=PATH] [--tidy]
```

Use the `--tidy` flag to automatically remove inactive themes and plugins from each WordPress install. Combine with `--dry-run` to preview actions without making changes.

The script automatically runs all WP-CLI commands with `--skip-plugins` and `--skip-themes` to prevent errors from faulty extensions.
