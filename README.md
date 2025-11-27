# devcon

`devcon` is an **opinionated** wrapper around Microsoft’s Dev Container CLI.

**devcon** features:

- automates git worktree <-> devcontainer creation
- avoids port collisions for multiple devcon managed containers
- ships with optional outbound firewall rules which is helpful for `yolo` agentic development.
- has a shareable, directory scoped config `.devcontainer/devcon.yaml`.

## Quick Start

1. Prerequisites
   - Docker Desktop / Docker Engine
   - Dev Container CLI → `pnpm install --global @devcontainers/cli`
   - Optional (recommended): `brew install yq`
2. Install the CLI
   ```bash
   pnpm install --global @geoffereth/devcon   # or npm install --global @geoffereth/devcon
   ```
3. Run it
   ```bash
   cd <repo>
   devcon up
   ```

## Everyday Commands

| Command                                                 | Description                                                                                                                                                 |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `devcon init`                                           | Copy the template `.devcontainer/` into the current repo.                                                                                                   |
| `devcon up [--name my-app] [--no-cleanup]`              | Start the container for the current directory. Ports are auto-assigned; `--name` customizes the container name; `--no-cleanup` keeps it running after exit. |
| `devcon worktree --branch feature/foo [--name foo-dev]` | Create a git worktree under `~/devcon-worktrees/<repo>/<branch>` (prompting to create the base directory if needed) and launch its container.               |
| `devcon status`                                         | List every container started by devcon plus port mappings.                                                                                                  |
| `devcon down` / `devcon remove`                         | Stop or stop+delete the containers associated with the current directory.                                                                                   |

## Configuration (single source of truth)

Everything lives in `.devcontainer/devcon.yaml`; keep `devcontainer.json` minimal (just the Dockerfile/customizations). Example:

```yaml
ports:
  app: 3000 # declare only what you need
  admin: 5555 # these can be removed and named however you'd like
  allocation_strategy: dynamic # use "static" to pin host ports and fail if busy

stack:
  node_version: "lts"
  # python_version: "3.11".    # opt-in
  # ruby_version: "3.3"        # opt-in
  # postgres_version: "16"     # opt-in
  global_packages:
    - "@anthropic-ai/claude-code@latest"
    - "@openai/codex"
  system_packages: [] # apt packages can go here

workflow:
  worktree_base: "devcon-worktrees" # local directory for connected git worktrees
  auto_cleanup: true # containers removed on exit unless --no-cleanup
  shell: "zsh"

doppler:
  enabled: false # optionally configure with doppler for secrets management

network:
  security:
    enabled: false # flip to true for outbound firewalling
```

Set `ports.allocation_strategy: static` to pin host ports (devcon aborts if any are busy); leave it `dynamic` to auto-reassign when ports are in use.
Use `stack.postgres_version` only when you need PostgreSQL .. devcon then installs it, auto-starts the service on container boot, and seeds a `devcon` superuser + database with passwordless local auth (`psql -h localhost -U devcon`).

## Why devcon

- **Git-worktree native** – `devcon worktree` creates the branch, worktree, and container in one step (default folder base: `~/devcon-worktrees`; devcon offers to create it if missing).
- **Dynamic networking** – `devcon up` inspects every port declared in the YAML and binds the first free host port, so parallel containers “just work.”
- **Policy-driven stack** – Node/Python/Ruby/Postgres versions, global npm packages, apt deps, Doppler/firewall toggles, etc., all live in one YAML file.
- **Agent-aware security** – optional outbound firewall and secret-handling rules so unsandboxed AI tooling stays safe.

## Development Workflow

```bash
pnpm install
pnpm build
npm link              # exposes this checkout as the global `devcon`

# edit scripts/*.sh → changes apply immediately
# edit src/devcon.ts → rerun `pnpm build`
```
