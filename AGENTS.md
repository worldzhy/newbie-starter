<!-- @@newbie-framework-start -->

# Agent instructions

This repository is a [newbie](https://github.com/worldzhy/devbie) application (NestJS + Prisma). The skeleton is owned by the newbie CLI; follow this contract to keep `newbie template update` and `newbie doctor` green.

## Do

- Manage modules exclusively through the CLI: `npx newbie modules` (interactive) or `npx newbie modules add <module>`.
- Put business code in `src/application/`; add Prisma models below the framework block in `prisma/schema.prisma`.
- Pull skeleton updates with `npx newbie template update`, then review with `git diff`.
- Verify changes with `npm run build` and `npx newbie doctor`.

## Don't

- Never hand-edit `src/modules/` or `deploy/compose.modules.yml`; they are rendered by `newbie modules apply`.
- Never edit inside `@@newbie-framework-start/end` blocks (`prisma/schema.prisma`, `.env.example`, `.gitignore`, this file).
- Never edit framework-synced files: `src/main.ts`, `tsconfig.json`, `tsconfig.build.json`, `nest-cli.json`, `prisma.config.ts`, `deploy/compose.framework.yml`, `deploy/Caddyfile.tmpl`, `deploy/scripts/*.sh`. Propose skeleton changes in the [newbie-starter](https://github.com/worldzhy/newbie-starter) template instead.

<!-- @@newbie-framework-end -->

<!-- Project-specific agent instructions go below; template update never rewrites this area. -->

## Workflow conventions (see `user_profile.md` for full text)

- Git branch: dev, never main
- Pre-commit gate: `npm run format:check` must pass; never bare `git add -A`
- This repo is a starter template, not an npm publisher; skeleton updates via `newbie template update`
- Verify starter changes with `npm run build` and `npx newbie doctor`

## Env facts

Executable operation manuals live in devbie `.trae/documents/env-setup.md`. Read that file before any Shell call.

## Backlog convention

Unfinished engineering tasks live in the backlog file under .trae/documents (backlog.md). At session end, append leftover tasks there; at session start, check it for pending work. Delete items when done.
