# Production image for newbie-starter-based NestJS backends.
#
# Multi-stage build keeps the final image small (~200MB): install + build
# in a Node build stage, then copy only the compiled dist and production
# node_modules into a clean Node runtime. Host repos that extend this
# template may layer in their own secrets handling, health checks, or
# database migrations — this is the minimum contract.
#
# The compose.application.yml uses this image via the
# ${ECR_REPOSITORY_PREFIX}/${APP_NAME}-backend:${IMAGE_TAG} substitution.

# Stage 1: install deps + compile
FROM node:22-alpine AS build
WORKDIR /app

# Copy manifest first so npm ci is cached across source edits.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .
RUN npx nest build

# Stage 2: slim runtime
FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
# Prisma queries are validated against the server; client libs are already
# compiled into dist, so we only need what npm ci pulls for production.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

# Fresh copy of compiled output (install stage may overwrite if deps include
# a prepare script, but that's rare for production npm packages).
COPY --from=build /app/dist ./dist

EXPOSE 3000
USER node
CMD ["node", "dist/src/main.js"]
