// HAF Block Explorer API benchmark
// REST API at /hafbe-api/

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import {
  HAFBE_URL, DEFAULT_THRESHOLDS, VUS, DURATION, RAMP_UP, RAMP_DOWN,
  TEST_DATA, randomItem,
} from "./config.js";

const errorRate = new Rate("hafbe_errors");
const latency = new Trend("hafbe_duration", true);

export const options = {
  scenarios: {
    hafbe: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: RAMP_UP, target: VUS },
        { duration: DURATION, target: VUS },
        { duration: RAMP_DOWN, target: 0 },
      ],
    },
  },
  thresholds: DEFAULT_THRESHOLDS,
};

function restGet(path, name) {
  const res = http.get(`${HAFBE_URL}${path}`, {
    tags: { app: "haf_block_explorer", endpoint: name },
  });
  check(res, { [`${name} status 200`]: (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  latency.add(res.timings.duration);
  return res;
}

export default function () {
  const account = randomItem(TEST_DATA.accounts);

  group("accounts", () => {
    restGet(`/accounts/${account}`, "get_account");
    restGet(`/accounts/${account}/authority`, "get_account_authority");
    restGet(`/accounts/${account}/comment-permlinks`, "get_comment_permlinks");
  });

  group("blocks", () => {
    restGet(`/operation-type-counts`, "get_latest_blocks");
    restGet(`/transaction-statistics`, "get_transaction_statistics");
  });

  group("witnesses", () => {
    restGet(`/witnesses`, "get_witnesses");
    restGet(`/witnesses/gtg`, "get_witness");
    restGet(`/witnesses/gtg/voters?_limit=10`, "get_witness_voters");
  });

  group("metadata", () => {
    restGet(`/version`, "get_hafbe_version");
    restGet(`/last-synced-block`, "get_hafbe_last_synced_block");
    restGet(`/input-type/${account}`, "get_input_type");
  });

  sleep(Math.random() * 0.3);
}
