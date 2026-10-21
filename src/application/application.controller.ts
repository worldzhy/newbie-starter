import { Controller, Get, HttpStatus, Redirect } from "@nestjs/common";
import { ApiFoundResponse, ApiTags } from "@nestjs/swagger";

@ApiTags("[Newbie]")
@Controller()
export class ApplicationController {
  @Get("")
  @ApiFoundResponse({ description: "Redirects to the Newbie project page" })
  @Redirect("https://github.com/worldzhy/devbie", HttpStatus.FOUND)
  hello(): string {
    return "<h1>Welcome to Newbie!</h1>";
  }

  /* End */
}
