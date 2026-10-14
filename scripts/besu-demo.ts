import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { network } from "hardhat";
import { createPublicClient, http, keccak256, stringToHex, type Address, type Hash } from "viem";

const connection = await network.create({ network: "besu" });
const { viem } = connection;
const client = await viem.getPublicClient();
assert.equal(await client.getChainId(), 1337, "Expected local Besu chain 1337");
const version = await client.request({ method: "web3_clientVersion" });
assert.match(version, /besu/i, "Expected a Besu node");
const [a, b, c, outsider] = await viem.getWalletClients();
assert.ok(a && b && c && outsider, "Four local Besu test accounts are required");
const directory = new URL("../deployments/local-besu/", import.meta.url);
await mkdir(directory, { recursive: true });
const reportFile = new URL("demo.json", directory);
type Report = {
  chainId: number;
  contract: Address;
  accounts: { A: Address; B: Address; C: Address };
  transactions: { action: string; hash: Hash; block: string }[];
  checks: string[];
  completed: boolean;
};

let previous: Report | undefined;
try {
  previous = JSON.parse(await readFile(reportFile, "utf8"));
} catch (error) {
  if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
}
if (previous && await client.getCode({ address: previous.contract }) !== undefined) {
  throw new Error(`An existing deployment is recorded at ${previous.contract}. Use scripts/besu-verify.ts to inspect it. A new deployment requires moving deployments/local-besu/demo.json aside first.`);
}

const registry = await viem.deployContract("DeliveryRegistry", [], { client: { wallet: a } });
const report: Report = {
  chainId: 1337,
  contract: registry.address,
  accounts: { A: a.account.address, B: b.account.address, C: c.account.address },
  transactions: [],
  checks: [],
  completed: false,
};
const save = () => writeFile(reportFile, JSON.stringify(report, null, 2) + "\n");
await save();
console.log(`Deployed DeliveryRegistry: ${registry.address}`);
console.log(`A: ${report.accounts.A}\nB: ${report.accounts.B}\nC: ${report.accounts.C}`);

async function transact(action: string, transaction: Promise<Hash>) {
  const hash = await transaction;
  const receipt = await client.waitForTransactionReceipt({ hash, timeout: 120_000 });
  assert.equal(receipt.status, "success", action);
  report.transactions.push({ action, hash, block: receipt.blockNumber.toString() });
  await save();
  console.log(`${action}: block ${receipt.blockNumber}, ${hash}`);
}

await transact("A registers company", registry.write.registerCompany({ account: a.account }));
await transact("A creates Demo project", registry.write.createProject(["Demo"], { account: a.account }));
await transact("A adds B", registry.write.addSupplier([1n, b.account.address], { account: a.account }));
await transact("B adds C", registry.write.addSupplier([1n, c.account.address], { account: b.account }));
await transact("B creates requirement 1-2-1", registry.write.createRequirement([1n, c.account.address, "Module", ["Core", "Login"]], { account: b.account }));
await transact("A creates requirement 1-1-1", registry.write.createRequirement([1n, b.account.address, "FinalProduct", ["Core", "Login"]], { account: a.account }));

const sbom = keccak256(stringToHex("demo-sbom"));
const file = keccak256(stringToHex("demo-file"));
await assert.rejects(
  registry.simulate.submitDelivery(["1-2-1", "1.0", sbom, file, ["Core"], []], { account: c.account.address }),
  /RequiredComponentMissing/,
);
assert.equal(await registry.read.deliveryCount(), 0n);
report.checks.push("Missing component rejected by Besu simulation without creating a delivery");
await transact("C submits delivery 1-2-1", registry.write.submitDelivery(["1-2-1", "1.0", sbom, file, ["Core", "Login"], []], { account: c.account }));
await transact("B approves delivery 1-2-1", registry.write.reviewDelivery([1n, 2n, 1n, 1, "Accepted"], { account: b.account }));
await transact("B submits delivery 1-1-1 linked to 1-2-1", registry.write.submitDelivery(["1-1-1", "1.0", sbom, file, ["Core", "Login"], ["1-2-1"]], { account: b.account }));
await transact("A approves delivery 1-1-1", registry.write.reviewDelivery([1n, 1n, 1n, 1, "Accepted"], { account: a.account }));
await assert.rejects(registry.read.getProject([1n, 0n, 10n], { account: outsider.account.address }), /Not a project member/);
report.checks.push("Nonparticipant cannot call project view");

const finalBlock = BigInt(report.transactions.at(-1)!.block);
const expectedBlock = await client.getBlock({ blockNumber: finalBlock });
for (const port of [21001, 21002, 21003, 21004]) {
  const node = createPublicClient({ transport: http(`http://127.0.0.1:${port}`) });
  const deadline = Date.now() + 30_000;
  while (await node.getBlockNumber({ cacheTime: 0 }) < finalBlock) {
    assert.ok(Date.now() < deadline, `Node ${port} did not synchronize`);
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  assert.equal((await node.getBlock({ blockNumber: finalBlock })).hash, expectedBlock.hash);
  const delivery = await node.readContract({ address: registry.address, abi: registry.abi, functionName: "getDelivery", args: [1n, 1n, 1n], account: a.account.address, blockNumber: finalBlock });
  assert.equal(delivery.deliveryId, "1-1-1");
  assert.equal(delivery.requirementId, "1-1-1");
  assert.equal(delivery.status, 1);
  const links = await node.readContract({ address: registry.address, abi: registry.abi, functionName: "getPreviousDeliveryIds", args: [1n, 1n, 1n], account: a.account.address, blockNumber: finalBlock });
  assert.deepEqual(links, ["1-2-1"]);
  report.checks.push(`Node ${port}: same block hash, Approved delivery 1-1-1, requirement 1-1-1, previous delivery 1-2-1`);
  console.log(`Node ${port}: matching block and delivery records`);
}
report.completed = true;
await save();
console.log("Besu deployment and cross-node verification complete. Report: deployments/local-besu/demo.json");
await connection.close();
