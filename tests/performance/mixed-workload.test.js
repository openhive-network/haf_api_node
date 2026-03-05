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

// JSON-RPC scenarios (70% of traffic)
function jsonRpcWorkload() {
  const r = Math.random();
  const blockNum = Math.floor(Math.random() * 1000) + 1;

  if (r < 0.25) {
    jsonRpc("condenser_api.get_block", [blockNum]);
  } else if (r < 0.40) {
    jsonRpc("condenser_api.get_dynamic_global_properties", []);
  } else if (r < 0.55) {
    jsonRpc("block_api.get_block", { block_num: blockNum });
  } else if (r < 0.65) {
    jsonRpc("condenser_api.get_block_header", [blockNum]);
  } else if (r < 0.75) {
    jsonRpc("account_history_api.get_ops_in_block", {
      block_num: blockNum,
      only_virtual: false,
    });
  } else if (r < 0.85) {
    jsonRpc("condenser_api.get_blog", ["steem", 0, 1]);
  } else if (r < 0.95) {
    jsonRpc("condenser_api.get_discussions_by_trending", [{ limit: 5 }]);
  } else {
    jsonRpc("condenser_api.get_followers", ["steem", "", "blog", 10]);
  }
}

// REST scenarios (30% of traffic)
function restWorkload() {
  const r = Math.random();

  if (r < 0.25) {
    restGet("/hafah-api/version");
  } else if (r < 0.45) {
    restGet("/status-api/health");
  } else if (r < 0.60) {
    restGet("/balance-api/");
  } else if (r < 0.75) {
    restGet("/hafbe-api/last-synced-block");
  } else if (r < 0.90) {
    restGet("/reputation-api/last-synced-block");
  } else {
    restGet("/hafbe-api/rpc/get_hafbe_version");
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
