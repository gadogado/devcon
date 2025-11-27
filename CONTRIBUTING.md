# Contributing

Thanks for helping improve `devcon`. This repo favors small changes and minimal ceremony.

## Setup

```bash
git clone https://github.com/gadogado/devcon.git
cd devcon
pnpm install
pnpm build
npm link   # makes the local CLI available as `devcon`
```

Requirements: Node.js 18+, pnpm, Docker, git, and Microsoft's Dev Container CLI.

## Working Loop

1. Create a branch: `git checkout -b feat/my-change`.
2. Edit TypeScript (`src/devcon.ts`) and bash scripts (`scripts/*.sh`).
3. Rebuild when TS changes: `pnpm build`. Bash edits take effect immediately.
4. Spot-check with `devcon up`, `devcon status`, etc.
5. `git add -p`, `git commit -m "feat: explain change"`, then push and open a PR.

## Release Notes

- `pnpm build` is mandatory before publishing.
- `npm link` keeps your global CLI pointed at `dist/devcon.js`; unlink with `npm unlink --global devcon` if needed.
- We do not auto-publish - coordinate releases manually and never push to npm without a final review.
