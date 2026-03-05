// Performance tests for JSON-RPC API endpoints
//
// Covers hived and HAfAH JSON-RPC calls routed through
// the main POST / endpoint via Jussi/Drone.
//
// Uses real blockchain data:
// - Block numbers in the 1M-80M range (where transactions exist)
// - Real account names: blocktrades, gtg, hiveio

import { sleep } from "k6";
import { getOptions, DEFAULT_THRESHOLDS } from "./config.js";
import { jsonRpc } from "./helpers.js";

export const options = {
  ...getOptions(),
  thresholds: DEFAULT_THRESHOLDS,
};

// Real account names active on the Hive blockchain
const ACCOUNTS = ["blocktrades", "gtg", "hiveio"];

function randomAccount() {
  return ACCOUNTS[Math.floor(Math.random() * ACCOUNTS.length)];
}

// Block range with real transaction data (early chain has empty blocks)
function randomBlockNum() {
  return Math.floor(Math.random() * 80000000) + 1000000;
}

// --- hived (condenser_api / database_api) ---

function getBlock() {
  jsonRpc("condenser_api.get_block", [randomBlockNum()]);
}

function getBlockHeader() {
  jsonRpc("condenser_api.get_block_header", [randomBlockNum()]);
}

function getDynamicGlobalProperties() {
  jsonRpc("condenser_api.get_dynamic_global_properties", []);
}

function getAccounts() {
  jsonRpc("condenser_api.get_accounts", [[randomAccount()]]);
}

function databaseApiGetDynamicGlobalProperties() {
  jsonRpc("database_api.get_dynamic_global_properties", {});
}

// --- HAfAH (block_api / account_history_api) ---

function blockApiGetBlock() {
  jsonRpc("block_api.get_block", { block_num: randomBlockNum() });
}

function blockApiGetBlockRange() {
  const startBlock = randomBlockNum();
  jsonRpc("block_api.get_block_range", {
    starting_block_num: startBlock,
    count: 10,
  });
}

function accountHistoryGetOpsInBlock() {
  jsonRpc("account_history_api.get_ops_in_block", {
    block_num: randomBlockNum(),
    only_virtual: false,
  });
}

function accountHistoryGetAccountHistory() {
  jsonRpc("account_history_api.get_account_history", {
    account: randomAccount(),
    start: -1,
    limit: 5,
  });
}

// Weighted scenario distribution
const scenarios = [
  { fn: getBlock, weight: 20 },
  { fn: getBlockHeader, weight: 10 },
  { fn: getDynamicGlobalProperties, weight: 15 },
  { fn: getAccounts, weight: 10 },
  { fn: databaseApiGetDynamicGlobalProperties, weight: 5 },
  { fn: blockApiGetBlock, weight: 15 },
  { fn: blockApiGetBlockRange, weight: 5 },
  { fn: accountHistoryGetOpsInBlock, weight: 10 },
  { fn: accountHistoryGetAccountHistory, weight: 10 },
];

const totalWeight = scenarios.reduce((sum, s) => sum + s.weight, 0);

function pickScenario() {
  let r = Math.random() * totalWeight;
  for (const s of scenarios) {
    r -= s.weight;
    if (r <= 0) return s.fn;
  }
  return scenarios[0].fn;
}

export default function () {
  pickScenario()();
  sleep(0.1);
}
