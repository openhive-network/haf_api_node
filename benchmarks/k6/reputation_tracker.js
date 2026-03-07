// Reputation Tracker API benchmark
// REST API at /reputation-api/

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import {
  REPUTATION_URL, STRICT_THRESHOLDS, VUS, DURATION, RAMP_UP, RAMP_DOWN,
  TEST_DATA, randomItem,
} from "./config.js";

const errorRate = new Rate("reputation_errors");
const latency = new Trend("reputation_duration", true);

export const options = {
  scenarios: {
    reputation: {
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
  const res = http.get(`${REPUTATION_URL}${path}`, {
    tags: { app: "reputation_tracker", endpoint: name },
  });
  check(res, { [`${name} status 200`]: (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  latency.add(res.timings.duration);
  return res;
}

export default function () {
  const account = randomItem(TEST_DATA.accounts);

  group("reputation", () => {
    restGet(`/accounts/${account}/reputation`, "get_account_reputation");
  });

  group("metadata", () => {
    restGet(`/version`, "get_reptracker_version");
    restGet(`/last-synced-block`, "get_rep_last_synced_block");
  });

  sleep(Math.random() * 0.3);
}
