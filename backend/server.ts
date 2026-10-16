import Fastify from "fastify";
import multipart from "@fastify/multipart";
import { randomUUID } from "node:crypto";
import { mkdir, writeFile, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";

export function createApp(storageDirectory = resolve("data/uploads")) {
  const app = Fastify({ logger: true });

  app.register(multipart, {
    limits: { files: 1, fields: 0, parts: 1, fileSize: 5 * 1024 * 1024 },
  });

  app.get("/health", async () => ({ status: "ok" }));

  app.post("/uploads", async (request, reply) => {
    if (!request.isMultipart()) {
      return reply.code(415).send({ error: "Send a multipart/form-data file named sbom." });
    }

    let content: Buffer | undefined;
    let originalName = "";
    for await (const part of request.parts()) {
      if (part.type !== "file" || part.fieldname !== "sbom") {
        if (part.type === "file") await part.toBuffer();
        return reply.code(400).send({ error: "Upload exactly one file named sbom." });
      }
      content = await part.toBuffer();
      originalName = part.filename;
    }

    if (!content?.length) {
      return reply.code(400).send({ error: "A non-empty SBOM file is required." });
    }

    const uploadId = randomUUID();
    const storedName = `${uploadId}.sbom`;
    await mkdir(storageDirectory, { recursive: true });
    const destination = join(storageDirectory, storedName);
    try {
      await writeFile(destination, content, { flag: "wx" });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
        await rm(destination, { force: true });
      }
      throw error;
    }

    return reply.code(201).send({ uploadId, originalName, storedName, size: content.length });
  });

  app.setErrorHandler((error, request, reply) => {
    const status = (error as { statusCode?: number }).statusCode ?? 500;
    if (status >= 500) request.log.error(error);
    reply.code(status).send({ error: status >= 500 ? "Unable to save the upload." : (error as Error).message });
  });

  return app;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const app = createApp();
  try {
    await app.listen({ host: "127.0.0.1", port: 3001 });
  } catch (error) {
    app.log.error(error);
    process.exitCode = 1;
  }
}
