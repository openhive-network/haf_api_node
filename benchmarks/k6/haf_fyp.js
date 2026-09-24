// HAF FYP API benchmark
// REST API at /haf-fyp-api/ (the read path: PostgREST behind the rewriter)
//
// Only the read path is benchmarked: the write API on /haf-fyp-admin/ would write
// interests and telemetry into the node's database.
//
// /v1/fyp/global is one precomputed feed. /v1/fyp/feed/{username} is served from the
// cache for a user the ranker has scored and takes the far more expensive cold-start
// path for one it has not, so set HAF_FYP_ACCOUNTS to accounts you know are warm (or
// known cold) and say which when reporting numbers.

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import {
  HAF_FYP_URL, STRICT_THRESHOLDS, VUS, DURATION, RAMP_UP, RAMP_DOWN,
  randomItem,
} from "./config.js";

const errorRate = new Rate("haf_fyp_errors");
const latency = new Trend("haf_fyp_duration", true);

const ACCOUNTS = (__ENV.HAF_FYP_ACCOUNTS || "mcfarhat,blocktrades,arcange").split(",");

export const options = {
  stages: [
    { duration: RAMP_UP, target: VUS },
    { duration: DURATION, target: VUS },
    { duration: RAMP_DOWN, target: 0 },
  ],
  thresholds: STRICT_THRESHOLDS,
};

function measure(name, url) {
  const res = http.get(url, { tags: { endpoint: name } });
  const ok = check(res, {
    [`${name} status 200`]: (r) => r.status === 200,
  });
  errorRate.add(!ok);
  latency.add(res.timings.duration, { endpoint: name });
  return res;
}

export default function () {
  const account = randomItem(ACCOUNTS);

  group("feeds", () => {
    measure("global", `${HAF_FYP_URL}/v1/fyp/global`);
    measure("personalized", `${HAF_FYP_URL}/v1/fyp/feed/${account}`);
  });

  group("metadata", () => {
    // Cheap by construction, and worth keeping in the mix: these are what a client calls
    // on every page load, so their latency sits in front of the expensive calls above.
    measure("profile", `${HAF_FYP_URL}/v1/fyp/profile/${account}`);
    measure("feed-metrics", `${HAF_FYP_URL}/v1/fyp/feed-metrics`);
    measure("version", `${HAF_FYP_URL}/version`);
  });

  sleep(1);
}
