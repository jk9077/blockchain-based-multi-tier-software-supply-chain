import {
  Controller, Get, Post, UploadedFile, UseInterceptors,
  Req, UnsupportedMediaTypeException,
} from "@nestjs/common";
import { FileInterceptor } from "@nestjs/platform-express";
import type { Request } from "express";
import { AppService } from "./app.service.js";

@Controller()
export class AppController {
  constructor(private readonly appService: AppService) {}

  @Get("health")
  health() {
    return this.appService.getHealthCheck();
  }

  @Post("uploads")
  @UseInterceptors(FileInterceptor("sbom", {
    limits: { files: 1, fields: 0, fileSize: 5 * 1024 * 1024 },
  }))
  upload(@UploadedFile() file: Express.Multer.File | undefined, @Req() request: Request) {
    if (!request.is("multipart/form-data")) {
      throw new UnsupportedMediaTypeException("Send a multipart/form-data file named sbom.");
    }
    return this.appService.saveFile(file);
  }
}
