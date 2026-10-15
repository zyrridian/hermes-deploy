# Contributing

This project is deliberately small: a `compose.yaml` and one Bash script, `manage.sh`.
Changes that keep it that way are the easiest to merge.

Before opening a PR:

```bash
shellcheck -x manage.sh test/roundtrip.sh
shfmt -d -i 2 -ci manage.sh test/roundtrip.sh     # `shfmt -w -i 2 -ci ...` to fix
test/roundtrip.sh                                  # needs Docker; uses a tiny alpine image
```

Guidelines:

- Backup and restore are the part people trust their agent to; any change there needs a test in `test/roundtrip.sh`.
- Don't add a dependency on a specific VPS provider; provider notes belong in the README's troubleshooting section.
- Don't make the script modify SSH, firewall or other host settings.
- Never commit secrets, backups or a data directory (`.gitignore` covers them).
