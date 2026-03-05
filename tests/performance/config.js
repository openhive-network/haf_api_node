// Shared configuration for k6 performance tests

// Base URL for the API node under test
export const BASE_URL = __ENV.BASE_URL || "https://localhost";

// TLS verification (disabled by default for self-signed certs)
export const TLS_SKIP_VERIFY = (__ENV.TLS_SKIP_VERIFY || "true") === "true";

// Common k6 options presets
export const SMOKE_TEST = {
  vus: 1,
  duration: "10s",
};

export const LOAD_TEST = {
  stages: [
    { duration: "30s", target: 10 },
    { duration: "1m", target: 50 },
    { duration: "1m", target: 50 },
    { duration: "30s", target: 0 },
  ],
};

export const STRESS_TEST = {
  stages: [
    { duration: "30s", target: 50 },
    { duration: "1m", target: 100 },
    { duration: "1m", target: 200 },
    { duration: "1m", target: 200 },
    { duration: "30s", target: 0 },
  ],
};

// Pick test profile from environment
export function getOptions() {
  const profile = __ENV.TEST_PROFILE || "smoke";
  switch (profile) {
    case "load":
      return LOAD_TEST;
    case "stress":
      return STRESS_TEST;
    case "smoke":
    default:
      return SMOKE_TEST;
  }
}

// Common thresholds
export const DEFAULT_THRESHOLDS = {
  http_req_duration: ["p(95)<5000", "p(99)<10000"],
  http_req_failed: ["rate<0.05"],
};
