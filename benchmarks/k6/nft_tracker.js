// NFT Tracker API benchmark
// REST API at /nft-tracker-api/

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import {
  NFT_URL, STRICT_THRESHOLDS, VUS, DURATION, RAMP_UP, RAMP_DOWN,
  randomItem,
} from "./config.js";

const errorRate = new Rate("nft_errors");
const latency = new Trend("nft_duration", true);

// NFT-specific test data
const CREATORS = (__ENV.NFT_CREATORS || "zingtoken,omgomg").split(",");
const SYMBOLS = (__ENV.NFT_SYMBOLS || "ZING,HERO").split(",");
const CREATOR_SYMBOL_PAIRS = [
  { creator: "zingtoken", symbol: "ZING" },
  { creator: "omgomg", symbol: "HERO" },
];

export const options = {
  scenarios: {
    nft: {
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
  const res = http.get(`${NFT_URL}${path}`, {
    tags: { app: "nft_tracker", endpoint: name },
  });
  check(res, { [`${name} status 200`]: (r) => r.status === 200 });
  errorRate.add(res.status !== 200);
  latency.add(res.timings.duration);
  return res;
}

export default function () {
  const pair = randomItem(CREATOR_SYMBOL_PAIRS);

  group("nft_types", () => {
    restGet(`/nfts`, "get_nfts");
    restGet(`/nfts?count=10`, "get_nfts_paginated");
  });

  group("nft_instances", () => {
    restGet(`/nfts/${pair.creator}/${pair.symbol}`, "get_instances");
    restGet(`/nfts/${pair.creator}/${pair.symbol}?count=5`, "get_instances_paginated");
  });

  group("metadata", () => {
    restGet(`/version`, "get_version");
  });

  sleep(Math.random() * 0.3);
}
