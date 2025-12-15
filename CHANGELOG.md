# Changelog

## 0.0.3

- Configurable mounts: Share host directories via `mounts:` in devcon.yaml (claude, codex, cursor, azure, aws, gcloud, ssh, custom)
- Custom setup commands: Run arbitrary commands during build via `stack.setup_commands`
- Configurable Doppler token env var: `doppler.token_env` lets users specify which host env var contains their token
- Passwordless sudo: Node user now has full passwordless sudo access
- Removed `auto_inject`: Doppler requires explicit `doppler run -- <command>`

## 0.0.2

- Ensure `devcon worktree` copies the source repo’s `.devcontainer` directory so worktree containers use the same configuration and port mappings as `devcon up`.

## 0.0.1

- Initial release.
