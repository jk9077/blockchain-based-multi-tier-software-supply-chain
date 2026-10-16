import { BadRequestException, Injectable } from "@nestjs/common";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, writeFile, rm } from "node:fs/promises";
import { join, resolve } from "node:path";

@Injectable()
export class AppService {
  private readonly storageDirectory = resolve("data/uploads");

  getHealthCheck() {
    return { status: "ok" };
  }

  async saveFile(file: Express.Multer.File | undefined) {
    if (!file?.size) {
      throw new BadRequestException("A non-empty SBOM file is required.");
    }

    const sbomHash = "0x" + createHash("sha256").update(file.buffer).digest("hex");
    const uploadId = randomUUID();
    const storedName = `${uploadId}.sbom`;
    await mkdir(this.storageDirectory, { recursive: true });
    const destination = join(this.storageDirectory, storedName);
    try {
      await writeFile(destination, file.buffer, { flag: "wx" });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
        await rm(destination, { force: true });
      }
      throw error;
    }

    return { uploadId, originalName: file.originalname, storedName, size: file.size, sbomHash, hashAlgorithm: "sha256" };
  }
}
