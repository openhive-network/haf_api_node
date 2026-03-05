// Performance tests for REST API endpoints
//
// Covers the PostgREST-based REST APIs exposed by HAF applications:
// HAfAH, Balance Tracker, Block Explorer, Reputation Tracker, Status API.

import { sleep } from "k6";
import { getOptions, DEFAULT_THRESHOLDS } from "./config.js";
import { restGet, restPost } from "./helpers.js";

export const options = {
  ...getOptions(),
  thresholds: DEFAULT_THRESHOLDS,
};

// --- HAfAH REST API ---

function hafahVersion() {
  restGet("/hafah-api/version");
}

// --- Balance Tracker REST API ---

function balanceTrackerHealth() {
  restGet("/balance-api/");
}

// --- Block Explorer REST API ---

function blockExplorerLastSyncedBlock() {
  restGet("/hafbe-api/last-synced-block");
}

// --- Reputation Tracker REST API ---

function reputationTrackerLastSyncedBlock() {
  restGet("/reputation-api/last-synced-block");
}

// --- Status API ---

function statusApiHealth() {
  restGet("/status-api/health");
}

// Weighted scenario distribution
const scenarios = [
  { fn: hafahVersion, weight: 20 },
  { fn: balanceTrackerHealth, weight: 20 },
  { fn: blockExplorerLastSyncedBlock, weight: 20 },
  { fn: reputationTrackerLastSyncedBlock, weight: 20 },
  { fn: statusApiHealth, weight: 20 },
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
