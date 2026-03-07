// Balance Tracker API benchmark
// REST API at /balance-api/

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import {
  BALANCE_URL, STRICT_THRESHOLDS, VUS, DURATION, RAMP_UP, RAMP_DOWN,
  TEST_DATA, randomItem,
} from "./config.js";

const errorRate = new Rate("balance_errors");
const latency = new Trend("balance_duration", true);

export const options = {
  scenarios: {
    balance: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: RAMP_UP, target: VUS },
        { duration: DURATION, target: VUS },
        { duration: RAMP_DOWN, target: 0 },
      ],
    },
  },
  thresholds: STRICT_THRESHOLDS,
};

function restGet(path, name) {
  const res = http.get(`${BALANCE_URL}${path}`, {
    tags: { app: "balance_tracker", endpoint: name },
  });
  check(res, { [`${name} status 200`]: (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  latency.add(res.timings.duration);
  return res;
}

export default function () {
  const account = randomItem(TEST_DATA.accounts);

  group("balances", () => {
    restGet(`/accounts/${account}/balances`, "get_account_balances");
    restGet(`/accounts/${account}/balance-history`, "get_balance_history");
    restGet(`/accounts/${account}/aggregated-history`, "get_balance_aggregation");
  });

  group("delegations", () => {
    restGet(`/accounts/${account}/delegations`, "get_balance_delegations");
    restGet(`/accounts/${account}/rc-delegations`, "get_rc_delegations");
    restGet(`/accounts/${account}/recurrent-transfers`, "get_recurrent_transfers");
  });

  group("global", () => {
    restGet(`/top-holders`, "get_top_holders");
    restGet(`/total-value-locked`, "get_total_value_locked");
  });

  group("metadata", () => {
    restGet(`/version`, "get_btracker_version");
    restGet(`/last-synced-block`, "get_btracker_last_synced_block");
  });

  sleep(Math.random() * 0.3);
}
