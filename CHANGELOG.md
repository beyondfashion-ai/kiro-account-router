# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-09-26

First public release.

- Slot-based account selection across the Linux Kiro CLI, extra
  `XDG_DATA_HOME` login slots, and the Windows `kiro-cli.exe` via WSL interop.
- Parallel `whoami` + `/usage` checks with an overall deadline; fails closed
  when usage cannot be verified; identity re-checked right before each chat.
- Interactive picker (`kiro-auto`), `accounts`, `use`, `login`/`logout`,
  `account add`/`rm`, optional `pin_email`.
- Opt-in `kiro-cli` shim (`install.sh --shim`) routing `chat`, implicit chats,
  `translate`, and `acp`; self-heals after `kiro-cli update` with rollback on
  failed updates.
- `kiro-delegate` headless wrapper: prompt on stdin, clean stdout, exit code
  preserved, model set under a lock.
- Offline test suite and CI (shellcheck + tests).

[0.1.0]: https://github.com/beyondfashion-ai/kiro-account-router/releases/tag/v0.1.0
