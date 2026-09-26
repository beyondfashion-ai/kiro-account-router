# Contributing

1. Keep scripts bash 4+ compatible and `shellcheck -S warning` clean.
2. Add or update a case in `test/run.sh` for behavior changes. Tests must run
   offline with the fake CLI (no real Kiro account).
3. Run before opening a PR:

   ```bash
   shellcheck -S warning bin/* install.sh uninstall.sh test/run.sh
   bash test/run.sh
   ```

4. Never add behavior that re-sends a started chat to another account.
