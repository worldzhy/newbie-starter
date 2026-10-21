// Load .env before any module metadata is evaluated: Nest module decorators
// read process.env at import time. Real environment variables always win -
// dotenv never overrides keys already present in process.env.
import "dotenv/config";
import { NewbieFactory } from "@devbie/newbie";
import { ApplicationModule } from "@/application/application.module";

async function bootstrap(): Promise<void> {
  // NewbieFactory owns every bootstrap concern: body parsers, the CORS policy
  // (including routes decorated with @AllowAnyOrigin), port-race recovery in
  // development, and the env-gated heartbeat / module-hub / health reporters.
  // Hosts that need a different policy pass options here.
  await NewbieFactory.create(ApplicationModule);
}

void bootstrap();
