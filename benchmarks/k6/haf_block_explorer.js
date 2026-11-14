// HAF Block Explorer API benchmark
// REST API at /hafbe-api/
//
// Endpoints and parameters follow the OpenAPI spec the block explorer serves at
// /hafbe-api/ (checked against steem-20, 2026-11-14). When a check fails on every
// call, diff the paths below against that spec first.

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import {
  HAFBE_URL, DEFAULT_THRESHOLDS, VUS, DURATION, RAMP_UP, RAMP_DOWN,
  TEST_DATA, randomItem, randomInt, fetchLastBlock, randomBlock,
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

export function setup() {
  const lastBlock = fetchLastBlock(`${HAFBE_URL}/last-synced-block`);
  const res = http.get(`${HAFBE_URL}/witnesses?page-size=100`, { tags: { endpoint: "setup" } });
  if (res.status !== 200) {
    throw new Error(`cannot list witnesses from ${HAFBE_URL}: ${res.status} ${res.body}`);
  }
  const witnesses = JSON.parse(res.body).witnesses.map((w) => w.witness_name);
  return { lastBlock, witnesses };
}

export default function (data) {
  const account = randomItem(TEST_DATA.accounts);
  const witness = randomItem(data.witnesses);
  const blockNum = randomBlock(data.lastBlock);

  group("accounts", () => {
    restGet(`/accounts/${account}`, "get_account");
    restGet(`/accounts/${account}/authority`, "get_account_authority");
    restGet(
      `/accounts/${account}/comment-permlinks?page-size=10&to-block=${blockNum}`,
      "get_comment_permlinks",
    );
  });

  group("blocks", () => {
    restGet(`/operation-type-counts?block-num=${blockNum}`, "get_latest_blocks");
    restGet(
      `/transaction-statistics?granularity=daily&from-block=${blockNum}&to-block=${blockNum + 200000}`,
      "get_transaction_statistics",
    );
  });

  group("witnesses", () => {
    restGet(`/witnesses?page-size=20&page=${randomInt(1, 20)}`, "get_witnesses");
    restGet(`/witnesses/${witness}`, "get_witness");
    restGet(`/witnesses/${witness}/voters?page-size=10`, "get_witness_voters");
  });

  group("metadata", () => {
    restGet(`/version`, "get_hafbe_version");
    restGet(`/last-synced-block`, "get_hafbe_last_synced_block");
    restGet(`/input-type/${account}`, "get_input_type");
  });

  sleep(Math.random() * 0.3);
}
