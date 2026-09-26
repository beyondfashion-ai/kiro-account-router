# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-09-26

Faster starts.

- Usage results are cached per slot for 5 minutes (`KIRO_AUTO_CACHE_TTL`);
  within that window a chat starts on the preferred slot without re-running
  `/usage` (the identity check before the chat still runs).
- `kiro-usage` polls every 0.2 s instead of 1 s.
- `kiro accounts --refresh`; `r` in the picker bypasses the cache; login,
  logout, and `account rm` clear the slot's cache; cached rows show their age.
- Typical start: about 1-2 s with a warm cache, about 5 s cold (was 12-18 s).

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

[0.2.0]: https://github.com/beyondfashion-ai/kiro-account-router/releases/tag/v0.2.0
[0.1.0]: https://github.com/beyondfashion-ai/kiro-account-router/releases/tag/v0.1.0
