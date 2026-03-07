// Shared configuration for HAF stack k6 benchmarks

// Stack base URL (Caddy entrypoint)
export const STACK_URL = __ENV.STACK_URL || "http://localhost:8080";

// Per-app base URLs (override to target apps directly, bypassing Caddy/Varnish)
export const HAFAH_URL = __ENV.HAFAH_URL || `${STACK_URL}/hafah-api`;
export const HIVEMIND_URL = __ENV.HIVEMIND_URL || STACK_URL; // JSON-RPC at root
export const BALANCE_URL = __ENV.BALANCE_URL || `${STACK_URL}/balance-api`;
export const REPUTATION_URL = __ENV.REPUTATION_URL || `${STACK_URL}/reputation-api`;
export const HAFBE_URL = __ENV.HAFBE_URL || `${STACK_URL}/hafbe-api`;
export const NFT_URL = __ENV.NFT_URL || `${STACK_URL}/nft-tracker-api`;

// Test parameters
export const VUS = parseInt(__ENV.VUS || "10");
export const DURATION = __ENV.DURATION || "2m";
export const RAMP_UP = __ENV.RAMP_UP || "30s";
export const RAMP_DOWN = __ENV.RAMP_DOWN || "10s";
export const MAX_VUS = parseInt(__ENV.MAX_VUS || "50");

// Default thresholds
export const DEFAULT_THRESHOLDS = {
  http_req_duration: ["p(95)<2000", "p(99)<5000"],
  http_req_failed: ["rate<0.01"],
};

export const STRICT_THRESHOLDS = {
  http_req_duration: ["p(95)<500", "p(99)<1000"],
  http_req_failed: ["rate<0.01"],
};

// JSON-RPC 2.0 helper
let reqId = 0;
export function jsonRpc(method, params) {
  return JSON.stringify({
    jsonrpc: "2.0",
    id: ++reqId,
    method,
    params,
  });
}

export const JSON_HEADERS = { "Content-Type": "application/json" };

// Test data for 5M block dataset
export const TEST_DATA = {
  accounts: ["gtg", "blocktrades", "steemit", "curie", "smooth"],
  authors: ["gtg", "blocktrades", "steemit"],
  block_nums: [1000000, 2000000, 3000000, 4000000, 5000000],
  permlinks: { gtg: "witness-gtg" },
  tags: ["hive", "polish", "photography", "life", "blog"],
  communities: ["hive-117600"],
};

// Utilities
export function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

export function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}
