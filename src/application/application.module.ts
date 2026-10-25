import { Module } from "@nestjs/common";
import { FrameworkModule } from "@devbie/newbie";
import { PrismaClient } from "@generated/prisma/client";
import { ModulesModule } from "@modules/modules.module";

@Module({
  imports: [FrameworkModule.forRoot({ prisma: { PrismaClient } }), ModulesModule],
})
export class ApplicationModule {}
