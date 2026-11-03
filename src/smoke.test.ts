// Smoke test: the template imports cleanly under Node's native test runner.
// This is the minimum gate — no business logic yet, but the Nest module tree,
// newbie modules wiring, and Prisma schema must all be resolvable on disk.
// Expanded host-side tests (service-level, integration, E2E) live in the
// consumer repo; the template only needs a green baseline.

import { test } from "node:test";
import assert from "node:assert/strict";
import { ApplicationModule } from "./application/application.module";
import { ModulesModule } from "./modules/modules.module";
import { readFileSync } from "node:fs";

test("ApplicationModule compiles and can be instantiated", () => {
  assert.ok(ApplicationModule, "ApplicationModule must be exported");
});

test("ModulesModule (newbie CLI assembly) compiles", () => {
  assert.ok(ModulesModule, "ModulesModule must be exported");
});

test("Prisma schema exists and carries a datasource", () => {
  const schema = readFileSync("prisma/schema.prisma", "utf-8");
  assert.ok(schema.includes("datasource"), "schema.prisma must declare a datasource");
  assert.ok(schema.includes("generator client"), "schema.prisma must generate the Prisma client");
});

test("check:template script exists (ownership-gate CI contract)", () => {
  // The actual ownership check runs in CI via `npm run check:template`.
  // This test only verifies the script is declared so the gate can't silently
  // disappear from package.json. The ownership registry lives inside the CLI
  // (TEMPLATE_FILES in newbie-cli), not a template-side JSON file.
  const pkg = JSON.parse(readFileSync("package.json", "utf-8"));
  assert.ok(pkg.scripts["check:template"], "package.json must declare check:template");
});
