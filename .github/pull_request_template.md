## Summary

<!-- What changes and why. -->

## Checklist

- [ ] `shellcheck -S warning bin/* install.sh uninstall.sh test/run.sh` is clean
- [ ] `bash test/run.sh` passes, with a new test for changed behavior
- [ ] No behavior re-sends a started chat to another account
- [ ] No real emails, tokens, or personal paths in code, tests, or docs
