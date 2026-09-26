# Security policy

Please report security issues privately through GitHub's
"Report a vulnerability" (Security Advisories) on this repository instead of
opening a public issue.

Scope notes:

- The tool never reads or stores credentials itself; logins are handled by
  Kiro CLI. Extra login directories are created with mode `0700`.
- Lock files live under `~/.local/share/kiro-auto/locks`, mode `0700`.
- The slots file is trusted configuration owned by the user; do not point it
  at files writable by other users.
