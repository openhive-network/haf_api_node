// HAF FYP API benchmark
// REST API at /haf-fyp-api/ (the read path: PostgREST behind the rewriter)
//
// WHAT THIS MEASURES, AND WHAT IT DELIBERATELY DOES NOT. Only the READ path is
// benchmarked. haf_fyp also serves a write API on /haf-fyp-admin/ (interests, events,
// and a key-gated admin call), and driving that from a benchmark would write rows into
// a live node's database -- interest vectors and impression events that then feed the
// ranker. A load test must not change what it is measuring, so those are out of scope
// here and no amount of tuning below will reach them.
//
// THE TWO FEED ENDPOINTS ARE NOT INTERCHANGEABLE, and measuring only one of them tells
// you very little:
//
//   /v1/fyp/global             one shared, precomputed feed. It is served from a cache
//                              the ranker writes, so this is close to a constant-cost
//                              read no matter how many users exist.
//   /v1/fyp/feed/{username}    per-user. A user the ranker has already scored is served
//                              from the same kind of cache; a user it has NOT is the
//                              cold-start path, which is a different and much more
//                              expensive shape.
//
// So the accounts below decide what is being measured. The defaults are accounts that
// exist on mainnet, but whether they are warm in THIS node's feed cache depends on that
// node's ranker cycle -- there is no way for a benchmark to know. Set HAF_FYP_ACCOUNTS
// to accounts you know are warm to characterise the steady state, or to accounts you
// know are not to characterise cold start, and say which you did when reporting numbers.
// Mixing them silently averages two distributions and reports neither.

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
