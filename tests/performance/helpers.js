import http from "k6/http";
import { check } from "k6";
import { BASE_URL, TLS_SKIP_VERIFY } from "./config.js";

// Send a JSON-RPC request to the root endpoint
export function jsonRpc(method, params, tags = {}) {
  const payload = JSON.stringify({
    jsonrpc: "2.0",
    method: method,
    params: params,
    id: 1,
  });

  const res = http.post(`${BASE_URL}/`, payload, {
    headers: { "Content-Type": "application/json" },
    tags: { name: `jsonrpc_${method}`, ...tags },
    insecureSkipTLSVerify: TLS_SKIP_VERIFY,
  });

  check(res, {
    "status is 200": (r) => r.status === 200,
    "has jsonrpc response": (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.jsonrpc === "2.0";
      } catch {
        return false;
      }
    },
    "no error in response": (r) => {
      try {
        const body = JSON.parse(r.body);
        return !body.error;
      } catch {
        return false;
      }
    },
  });

  return res;
}

// Send a REST API request (GET or POST)
export function restGet(path, tags = {}) {
  const res = http.get(`${BASE_URL}${path}`, {
    tags: { name: `rest_GET_${path}`, ...tags },
    insecureSkipTLSVerify: TLS_SKIP_VERIFY,
  });

  check(res, {
    "status is 200": (r) => r.status === 200,
  });

  return res;
}

export function restPost(path, body, tags = {}) {
  const payload = typeof body === "string" ? body : JSON.stringify(body);

  const res = http.post(`${BASE_URL}${path}`, payload, {
    headers: { "Content-Type": "application/json" },
    tags: { name: `rest_POST_${path}`, ...tags },
    insecureSkipTLSVerify: TLS_SKIP_VERIFY,
  });

  check(res, {
    "status is 200": (r) => r.status === 200,
  });

  return res;
}
