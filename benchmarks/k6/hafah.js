// HAfAH (Account History API) benchmark
// REST API at /hafah-api/

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import {
  HAFAH_URL, DEFAULT_THRESHOLDS, VUS, DURATION, RAMP_UP, RAMP_DOWN,
  TEST_DATA, randomItem, randomInt,
} from "./config.js";

const errorRate = new Rate("hafah_errors");
const latency = new Trend("hafah_duration", true);

export const options = {
  scenarios: {
    hafah: {
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
  const res = http.get(`${HAFAH_URL}${path}`, {
    tags: { app: "hafah", endpoint: name },
  });
  check(res, { [`${name} status 200`]: (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  latency.add(res.timings.duration);
  return res;
}

export default function () {
  const account = randomItem(TEST_DATA.accounts);
  const blockNum = randomItem(TEST_DATA.block_nums);

  group("blocks", () => {
    restGet(`/blocks/${blockNum}`, "get_block");
    restGet(`/blocks/${blockNum}/header`, "get_block_header");
    restGet(`/blocks?from-block=${blockNum}&to-block=${blockNum + 10}`, "get_block_range");
  });

  group("operations", () => {
    restGet(`/accounts/${account}/operations?page-size=10`, "get_ops_by_account");
    restGet(`/accounts/${account}/operation-types`, "get_acc_op_types");
    restGet(`/blocks/${blockNum}/operations?page-size=10`, "get_ops_by_block");
    restGet(`/operation-types`, "get_op_types");
    restGet(`/operations?block-num=${blockNum}&page-size=5`, "get_operations");
  });

  group("metadata", () => {
    restGet(`/global-state`, "get_global_state");
    restGet(`/head-block-num`, "get_head_block_num");
    restGet(`/version`, "get_version");
  });

  sleep(Math.random() * 0.3);
}
