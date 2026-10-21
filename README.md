# newbie-basic-template

Backend project skeleton for the [newbie](https://github.com/worldzhy/devbie) framework (NestJS + Prisma). Framework runtime code ships as the `@devbie/newbie` npm package; modules are copied in from the `newbie-modules` registry by the CLI.

## Create a project

```bash
npx @devbie/newbie-cli create my-service
cd my-service
```

`create` copies this template and runs `git init`. Useful flags:

- `--template-ref <ref>` — scaffold from a specific git branch or tag (see Pinning below)
- `--template-path <dir>` — use a local template checkout (offline / development)
- `--no-git-init` — skip `git init`

## Install and start

```bash
npm install
cp .env.example .env        # fill in PRISMA_DATABASE_URL
npx prisma generate
npm run start:dev           # Swagger UI at /api
```

Enable modules from the registry at any time:

```bash
npx newbie                  # interactive enable/disable
npx newbie config --add <module>
npx newbie doctor           # audit wiring / drift / env
```

## Updating the skeleton

The framework-managed skeleton files (`src/main.ts`, `tsconfig*.json`, `nest-cli.json`, `prisma.config.ts`, the `@@newbie-framework-start/end` block inside `prisma/schema.prisma`, and the framework deploy assets under `deploy/`) evolve with the template. To pull updates:

```bash
npx newbie update-template            # review a diff against the latest template
npx newbie update-template --write    # apply it (then commit on a branch and open a PR)
```

Business code — `src/application/`, `src/modules/`, your Prisma models outside the marker block, `.env` — is never touched.

## Production deploy assets (`deploy/`)

`deploy/` ships a reference single-host production stack (Docker Compose behind Caddy, S3 backups, CloudWatch metrics). Files fall into three ownership classes:

- **Framework-synced** — `scripts/*.sh`, `compose.framework.yml`, `Caddyfile.tmpl`: owned by this template and kept byte-identical in consuming projects via `newbie update-template`; never edit them downstream.
- **Generated / host-owned compose layers** — `compose.modules.yml` is rendered by `newbie assemble` from the enabled module set (ADR-008; never hand-edit), and `compose.application.yml` is the host-private overlay tooling never touches. Scripts always run docker compose with all three `-f` flags in that order.
- **Scaffold defaults** — `clickhouse/config.d/memory.xml`: copied by `create` but never synced; tune per host.
- **Not in the template** — `env.template` (secret manifest), `aws/stack.yml` (CloudFormation), and the two host config JSONs (`deploy.config.json` / `env.config.json`; schema in `scripts/lib.sh`) are host-owned and live outside the template.

## Built-in monitoring (optional, env-gated)

`NewbieFactory` starts the built-in reporters automatically after the HTTP server is accepting traffic. Every reporter is a silent no-op unless its two variables are set, so no code wiring is required:

- module-hub self-registration: `MODULE_HUB_ENDPOINT` + `MODULE_HUB_TOKEN`
- dependency health snapshots: `HEALTH_ENDPOINT` + `HEALTH_TOKEN`
- backend request monitoring: `BACKEND_MONITOR_ENDPOINT` + `BACKEND_MONITOR_TOKEN`

Commented placeholders for all of them live in `.env.example`.

## Pinning to a template revision

`create` and `update-template` scaffold from the repository tip by default. The skeleton evolves in the same repository as `@devbie/newbie`, so the tip skeleton always matches the current framework line; there is no separate template version sequence.

To scaffold from a specific git branch or tag, pass `--template-ref` (any ref accepted by `git clone --branch`):

```bash
npx @devbie/newbie-cli create my-service --template-ref dev
npx newbie update-template --template-ref dev
```

For a fully reproducible historical checkout, also pin the `@devbie/newbie` and `@devbie/newbie-cli` versions in `package.json` to the framework release contemporary with that ref.

## License

MIT
