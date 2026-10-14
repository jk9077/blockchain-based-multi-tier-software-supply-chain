import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { network } from "hardhat";
import { createPublicClient, http, type Address } from "viem";

const report = JSON.parse(await readFile(new URL("../deployments/local-besu/demo.json", import.meta.url), "utf8")) as {
  contract: Address;
  accounts: { A: Address; B: Address; C: Address };
  transactions: { block: string }[];
};
const connection = await network.create({ network: "besu" });
const registry = await connection.viem.getContractAt("DeliveryRegistry", report.contract);
console.log(`Contract: ${report.contract}`);
console.log(`A: ${report.accounts.A}\nB: ${report.accounts.B}\nC: ${report.accounts.C}`);
const blockNumber = BigInt(report.transactions.at(-1)!.block);
let blockHash: string | undefined;
for (const port of [8545, 21001, 21002, 21003, 21004]) {
  const client = createPublicClient({ transport: http(`http://127.0.0.1:${port}`) });
  assert.equal(await client.getChainId(), 1337);
  const block = await client.getBlock({ blockNumber });
  if (blockHash) assert.equal(block.hash, blockHash);
  blockHash = block.hash;
  const deliveries = [];
  for (const stage of [2n, 1n]) {
    const delivery = await client.readContract({ address: report.contract, abi: registry.abi, functionName: "getDelivery", args: [1n, stage, 1n], account: report.accounts.A, blockNumber });
    const previous = await client.readContract({ address: report.contract, abi: registry.abi, functionName: "getPreviousDeliveryIds", args: [1n, stage, 1n], account: report.accounts.A, blockNumber });
    assert.equal(delivery.deliveryId, `1-${stage}-1`);
    assert.equal(delivery.requirementId, `1-${stage}-1`);
    assert.equal(delivery.status, 1);
    assert.deepEqual(previous, stage === 1n ? ["1-2-1"] : []);
    deliveries.push({ deliveryId: delivery.deliveryId, requirementId: delivery.requirementId, status: "Approved", previous });
  }
  console.log(JSON.stringify({ node: port, block: blockNumber.toString(), blockHash, deliveries }, null, 2));
}
console.log("PASS: all five nodes have the same block and approved delivery records.");
await connection.close();
