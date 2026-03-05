// Performance tests for JSON-RPC API endpoints
//
// Covers hived, HAfAH, and Hivemind JSON-RPC calls routed through
// the main POST / endpoint via Jussi/Drone.

import { sleep } from "k6";
import { getOptions, DEFAULT_THRESHOLDS } from "./config.js";
import { jsonRpc } from "./helpers.js";

export const options = {
  ...getOptions(),
  thresholds: DEFAULT_THRESHOLDS,
};

// --- hived (condenser_api) ---

function getBlock() {
  const blockNum = Math.floor(Math.random() * 1000) + 1;
  jsonRpc("condenser_api.get_block", [blockNum]);
}

function getBlockHeader() {
  const blockNum = Math.floor(Math.random() * 1000) + 1;
  jsonRpc("condenser_api.get_block_header", [blockNum]);
}

function getDynamicGlobalProperties() {
  jsonRpc("condenser_api.get_dynamic_global_properties", []);
}

// --- HAfAH (block_api / account_history_api) ---

function blockApiGetBlock() {
  const blockNum = Math.floor(Math.random() * 1000) + 1;
  jsonRpc("block_api.get_block", { block_num: blockNum });
}

function blockApiGetBlockRange() {
  const startBlock = Math.floor(Math.random() * 900) + 1;
  jsonRpc("block_api.get_block_range", {
    starting_block_num: startBlock,
    count: 10,
  });
}

function accountHistoryGetOpsInBlock() {
  const blockNum = Math.floor(Math.random() * 1000) + 1;
  jsonRpc("account_history_api.get_ops_in_block", {
    block_num: blockNum,
    only_virtual: false,
  });
}

// --- Hivemind (condenser_api social queries) ---

function getBlog() {
  jsonRpc("condenser_api.get_blog", ["steem", 0, 1]);
}

function getDiscussionsByTrending() {
  jsonRpc("condenser_api.get_discussions_by_trending", [{ limit: 5 }]);
}

function getFollowers() {
  jsonRpc("condenser_api.get_followers", ["steem", "", "blog", 10]);
}

// Weighted scenario distribution
const scenarios = [
  { fn: getBlock, weight: 20 },
  { fn: getBlockHeader, weight: 10 },
  { fn: getDynamicGlobalProperties, weight: 15 },
  { fn: blockApiGetBlock, weight: 15 },
  { fn: blockApiGetBlockRange, weight: 5 },
  { fn: accountHistoryGetOpsInBlock, weight: 5 },
  { fn: getBlog, weight: 10 },
  { fn: getDiscussionsByTrending, weight: 10 },
  { fn: getFollowers, weight: 10 },
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
