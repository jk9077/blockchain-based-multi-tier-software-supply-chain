import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import "reflect-metadata";
import { NestFactory } from "@nestjs/core";
import { AppModule } from "../dist/backend/src/app.module.js";

test("upload stores exact bytes and rejects invalid uploads without saving files", async () => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "sbom-upload-"));
  const originalDirectory = process.cwd();
  process.chdir(temporaryDirectory);
  const directory = join(temporaryDirectory, "data/uploads");
  let app;
  let url;
  async function upload(files) {
    const form = new FormData();
    for (const [field, content, name] of files) {
      form.append(field, new Blob([content]), name);
    }
    const response = await fetch(`${url}/uploads`, { method: "POST", body: form });
    const body = await response.json();
    return { statusCode: response.status, json: () => body };
  }
  try {
    app = await NestFactory.create(AppModule, { logger: false });
    await app.listen(0, "127.0.0.1");
    url = await app.getUrl();
    const bytes = Buffer.from('{"bomFormat":"CycloneDX"}\n');
    const first = await upload([["sbom", bytes, "../../sample.json"]]);
    assert.equal(first.statusCode, 201);
    assert.deepEqual(await readFile(join(directory, first.json().storedName)), bytes);
    assert.match(first.json().storedName, /^[a-f0-9-]+\.sbom$/);
    const second = await upload([["sbom", bytes, "renamed.json"]]);
    assert.equal(second.statusCode, 201);
    assert.notEqual(first.json().storedName, second.json().storedName);
    assert.equal(first.json().hashAlgorithm, "sha256");
    assert.match(first.json().sbomHash, /^0x[a-f0-9]{64}$/);
    assert.equal(first.json().sbomHash, second.json().sbomHash);
    const known = await upload([["sbom", "abc", "known.sbom"]]);
    assert.equal(known.statusCode, 201);
    assert.equal(known.json().sbomHash, "0xba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert.deepEqual(await readFile(join(directory, known.json().storedName)), Buffer.from("abc"));
    const changed = await upload([["sbom", "abd", "known.sbom"]]);
    assert.equal(changed.statusCode, 201);
    assert.notEqual(known.json().sbomHash, changed.json().sbomHash);
    assert.equal((await upload([["sbom", "", "empty.json"]])).statusCode, 400);
    assert.equal((await upload([["wrong", bytes, "sample.json"]])).statusCode, 400);
    assert.equal((await upload([["sbom", bytes, "one.json"], ["sbom", bytes, "two.json"]])).statusCode, 400);
    assert.equal((await upload([["sbom", Buffer.alloc(5 * 1024 * 1024 + 1), "large.json"]])).statusCode, 413);
    assert.equal((await fetch(`${url}/uploads`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status, 415);
    assert.equal((await readdir(directory)).length, 4);
    assert.equal((await (await fetch(`${url}/health`)).json()).status, "ok");
  } finally {
    await app?.close();
    process.chdir(originalDirectory);
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});
