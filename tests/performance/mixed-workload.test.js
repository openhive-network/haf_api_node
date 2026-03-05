// Mixed workload performance test
//
// Simulates realistic traffic patterns combining JSON-RPC and REST API
// calls with weighted distribution matching typical production usage.

import { sleep } from "k6";
import { getOptions, DEFAULT_THRESHOLDS } from "./config.js";
import { jsonRpc, restGet } from "./helpers.js";

export const options = {
  ...getOptions(),
  thresholds: {
    ...DEFAULT_THRESHOLDS,
    "http_req_duration{name:jsonrpc_condenser_api.get_block}": ["p(95)<3000"],
    "http_req_duration{name:jsonrpc_block_api.get_block}": ["p(95)<3000"],
    "http_req_duration{name:rest_GET_/status-api/health}": ["p(95)<1000"],
  },
};

// Real account names and block range with transaction data
const ACCOUNTS = ["blocktrades", "gtg", "hiveio"];

function randomAccount() {
  return ACCOUNTS[Math.floor(Math.random() * ACCOUNTS.length)];
}

function randomBlockNum() {
  return Math.floor(Math.random() * 80000000) + 1000000;
}

// JSON-RPC scenarios (70% of traffic)
function jsonRpcWorkload() {
  const r = Math.random();
  const blockNum = randomBlockNum();

  if (r < 0.20) {
    jsonRpc("condenser_api.get_block", [blockNum]);
  } else if (r < 0.35) {
    jsonRpc("condenser_api.get_dynamic_global_properties", []);
  } else if (r < 0.50) {
    jsonRpc("block_api.get_block", { block_num: blockNum });
  } else if (r < 0.60) {
    jsonRpc("condenser_api.get_block_header", [blockNum]);
  } else if (r < 0.70) {
    jsonRpc("account_history_api.get_ops_in_block", {
      block_num: blockNum,
      only_virtual: false,
    });
  } else if (r < 0.80) {
    jsonRpc("condenser_api.get_accounts", [[randomAccount()]]);
  } else if (r < 0.90) {
    jsonRpc("account_history_api.get_account_history", {
      account: randomAccount(),
      start: -1,
      limit: 5,
    });
  } else {
    jsonRpc("database_api.get_dynamic_global_properties", {});
  }
}

// REST scenarios (30% of traffic)
function restWorkload() {
  const r = Math.random();

  if (r < 0.20) {
    restGet("/hafah-api/version");
  } else if (r < 0.40) {
    restGet("/status-api/health");
  } else if (r < 0.60) {
    restGet("/balance-api/");
  } else if (r < 0.80) {
    restGet("/hafbe-api/last-synced-block");
  } else {
    restGet("/reputation-api/last-synced-block");
  }
}

export default function () {
  if (Math.random() < 0.7) {
    jsonRpcWorkload();
  } else {
    restWorkload();
  }
  sleep(0.1);
}
