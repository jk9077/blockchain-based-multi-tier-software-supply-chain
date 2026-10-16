import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createApp } from "./server.ts";

test("upload stores exact bytes and rejects invalid uploads without saving files", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sbom-upload-"));
  const app = createApp(directory);
  async function upload(files) {
    const form = new FormData();
    for (const [field, content, name] of files) {
      form.append(field, new Blob([content]), name);
    }
    const request = new Request("http://localhost/uploads", { method: "POST", body: form });
    return app.inject({
      method: "POST", url: "/uploads",
      headers: { "content-type": request.headers.get("content-type") },
      payload: Buffer.from(await request.arrayBuffer()),
    });
  }
  try {
    const bytes = Buffer.from('{"bomFormat":"CycloneDX"}\n');
    const first = await upload([["sbom", bytes, "../../sample.json"]]);
    assert.equal(first.statusCode, 201);
    assert.deepEqual(await readFile(join(directory, first.json().storedName)), bytes);
    assert.match(first.json().storedName, /^[a-f0-9-]+\.sbom$/);
    const second = await upload([["sbom", bytes, "../../sample.json"]]);
    assert.equal(second.statusCode, 201);
    assert.notEqual(first.json().storedName, second.json().storedName);
    assert.equal((await upload([["sbom", "", "empty.json"]])).statusCode, 400);
    assert.equal((await upload([["wrong", bytes, "sample.json"]])).statusCode, 400);
    assert.equal((await upload([["sbom", bytes, "one.json"], ["sbom", bytes, "two.json"]])).statusCode, 413);
    assert.equal((await upload([["sbom", Buffer.alloc(5 * 1024 * 1024 + 1), "large.json"]])).statusCode, 413);
    assert.equal((await app.inject({ method: "POST", url: "/uploads", payload: {} })).statusCode, 415);
    assert.equal((await readdir(directory)).length, 2);
    assert.equal((await app.inject("/health")).json().status, "ok");
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});
