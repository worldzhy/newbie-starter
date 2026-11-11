# Production image for newbie-starter-based NestJS backends.
#
# The image is the single distribution channel for host-side operations:
#   - app start:  node dist/src/main.js
#   - migrations: npx prisma migrate deploy (one-shot "postgres-migrate" service,
#                 applied from the host's prisma/migrations; ADR-036)
#   - first seed: npx prisma db seed  (one-shot "db-seed" service)
#   - deploy/:    extracted from the image onto the host by start.sh
# The full devDependencies are therefore kept in the runtime image (prisma CLI
# and tsx are devDependencies), mirroring the proven nightwatch-backend
# production image. Host repos that extend this template may layer in their
# own secrets handling, health checks, or database migrations — this is the
# minimum contract.

# bookworm-slim (glibc) keeps native prebuilds (e.g. bcrypt) working; the
# previous alpine image forced musl rebuilds that need a compiler toolchain.
FROM node:22-bookworm-slim AS base
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl ca-certificates tini \
  && rm -rf /var/lib/apt/lists/*

FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM base AS build
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Freshly created projects enable modules later; materialize an empty install
# manifest when the template itself is built so the runtime COPY never fails.
RUN if [ ! -f newbie-modules.json ]; then printf '{"registry":null,"modules":[]}\n' > newbie-modules.json; fi
# prisma.config.ts evaluates PRISMA_DATABASE_URL eagerly; generation itself
# never connects, a placeholder URL is enough.
ENV PRISMA_DATABASE_URL=postgresql://placeholder:placeholder@localhost:5432/placeholder
RUN npx prisma generate && npm run build

FROM base AS runtime
ENV NODE_ENV=production
ENV PORT=3000
# node_modules carries prisma + tsx used by the migrate/seed one-shots.
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/generated ./generated
# Module-hub reporter reads the install manifest and per-module manifests at
# runtime (readModuleSnapshot on process.cwd()).
COPY --from=build /app/newbie-modules.json ./newbie-modules.json
COPY --from=build /app/src/modules ./src/modules
COPY --from=build /app/prisma ./prisma
COPY --from=build /app/prisma.config.ts ./prisma.config.ts
# tsx resolves the @generated/* alias for prisma/seed.ts through tsconfig.json.
COPY --from=build /app/tsconfig.json ./tsconfig.json
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/package-lock.json ./package-lock.json
# deploy/ is extracted from this image onto the host (compose files, Caddyfile
# template, operational scripts). The host never clones the repository.
COPY --from=build /app/deploy /deploy

USER node
EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "dist/src/main.js"]
