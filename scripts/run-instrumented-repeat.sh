#!/bin/bash
# Reproduces experiment 8: a clean repeat of the winning 20-replica / 2-backend
# layout (experiment 7), this time sampled end to end — per-replica fortio
# JSON plus per-container `docker stats` at 1Hz for the whole run, matching
# the "Full instrumentation" table in the post.
#
# Usage: run-instrumented-repeat.sh [duration-seconds]
set -euo pipefail

REPLICAS=20
CORES_PER_REPLICA=8
NUM_BACKENDS=2
DURATION="${1:-30}"

AGW_IMAGE="ghcr.io/agentgateway/agentgateway:v1.4.1"
MOCK_IMAGE="howardjohn/hyper-server:latest"
NET="agwbench"
RESULTS_DIR="${RESULTS_DIR:-$HOME/agwbench-results}/05-final-repeat"
CONFIG_DIR="$HOME/agwbench-cfg-$$"; mkdir -p "${CONFIG_DIR}"
FORTIO="$HOME/.local/bin/fortio"
DOCKER="sudo -n docker"
TOTAL_CONNECTIONS="${TOTAL_CONNECTIONS:-320}"
CONNS_PER_REPLICA=$(( TOTAL_CONNECTIONS / REPLICAS ))

mkdir -p "${RESULTS_DIR}"
${DOCKER} network create "${NET}" >/dev/null 2>&1 || true

PAYLOAD_JSON=$(python3 - <<'PY'
import json
content = "omnis ipsum non cum totam animi voluptatem tenetur ad quidem voluptate ipsa provident consectetur tempore sed pariatur nam dignissimos dolorum unde dolor nemo veritatis ex consequatur repellat laboriosam ab dicta vero reprehenderit magnam eveniet quas eos libero laudantium illum iste temporibus rerum velit cumque sunt sit delectus deserunt facilis magni doloremque hic obcaecati incidunt neque qui odit accusamus optio laborum ullam error assumenda itaque voluptatum fuga ipsam accusantium quod debitis iusto saepe quo possimus voluptas dolore harum quos facere adipisci repudiandae eu"
body = {"id":"chatcmpl-456","model":"openai/gpt-3.5-turbo","object":"chat.completion","created":123456,
        "choices":[{"index":0,"message":{"role":"assistant","content":content},"finish_reason":"stop"}],
        "usage":{"prompt_tokens":9,"completion_tokens":12,"total_tokens":21}}
print(json.dumps(body))
PY
)

SAMPLER_PID=""
cleanup() {
  [[ -n "${SAMPLER_PID}" ]] && kill "${SAMPLER_PID}" >/dev/null 2>&1 || true
  ${DOCKER} rm -f agwbench-mock agwbench-mock2 >/dev/null 2>&1 || true
  for k in $(seq 0 $((REPLICAS-1))); do ${DOCKER} rm -f "agwbench-agw-${k}" >/dev/null 2>&1 || true; done
  rm -rf "${CONFIG_DIR}"
}
trap cleanup EXIT
cleanup 2>/dev/null || true
mkdir -p "${CONFIG_DIR}"

${DOCKER} run -d --name agwbench-mock --network "${NET}" --network-alias mock-server \
  --cpuset-cpus 176-207 -e PORT=8081 -e PAYLOAD="${PAYLOAD_JSON}" "${MOCK_IMAGE}" >/dev/null
${DOCKER} run -d --name agwbench-mock2 --network "${NET}" --network-alias mock-server-2 \
  --cpuset-cpus 240-271 -e PORT=8081 -e PAYLOAD="${PAYLOAD_JSON}" "${MOCK_IMAGE}" >/dev/null

HALF=$(( REPLICAS / 2 ))
for k in $(seq 0 $((REPLICAS-1))); do
  start=$(( k * CORES_PER_REPLICA )); end=$(( start + CORES_PER_REPLICA - 1 ))
  hostport=$(( 4001 + k ))
  backend_host="mock-server"; [[ $k -ge $HALF ]] && backend_host="mock-server-2"
  cfg="${CONFIG_DIR}/agw-${k}.yaml"
  cat > "${cfg}" <<EOF
config:
  adminAddr: 0.0.0.0:23500
  statsAddr: 0.0.0.0:23501
  readinessAddr: 0.0.0.0:23502
llm:
  port: 4001
  models:
    - name: "openai/gpt-3.5-turbo"
      provider: openAI
      params:
        baseUrl: http://${backend_host}:8081/v1
        model: gpt-3.5-turbo
        apiKey: dummy
EOF
  ${DOCKER} run -d --name "agwbench-agw-${k}" --network "${NET}" \
    --cpuset-cpus "${start}-${end}" -p "${hostport}:4001" \
    -v "${cfg}:/app/config.yaml:ro" "${AGW_IMAGE}" -f /app/config.yaml >/dev/null
done

echo "waiting for all ${REPLICAS} replicas to accept connections..."
for k in $(seq 0 $((REPLICAS-1))); do
  hostport=$(( 4001 + k ))
  for i in $(seq 1 30); do
    curl -sf -o /dev/null -X POST "http://localhost:${hostport}/v1/chat/completions" \
      -H 'Content-type: application/json' \
      -d '{"model":"openai/gpt-3.5-turbo","messages":[{"role":"user","content":"hi"}]}' && break
    sleep 1
  done
done

# 1Hz docker-stats sampler for the whole run
ALL_NAMES="agwbench-mock agwbench-mock2"
for k in $(seq 0 $((REPLICAS-1))); do ALL_NAMES="${ALL_NAMES} agwbench-agw-${k}"; done
echo "ts,name,cpu_perc,mem_usage" > "${RESULTS_DIR}/docker-stats-1hz.csv"
(
  while true; do
    ts=$(date +%s)
    ${DOCKER} stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" ${ALL_NAMES} \
      | sed "s/^/${ts},/" >> "${RESULTS_DIR}/docker-stats-1hz.csv"
    sleep 1
  done
) &
SAMPLER_PID=$!

# Free SMT-sibling cores (not used by either backend): 160-175, 208-239, 272-319.
# Spread clients thinly instead of packing them into one contiguous block --
# a dense client block shares SMT siblings with only 2-3 replicas' physical
# cores and visibly starves those specific replicas.
FREE_CORES=()
for c in $(seq 160 175) $(seq 208 239) $(seq 272 319); do FREE_CORES+=("$c"); done
STRIDE=$(( ${#FREE_CORES[@]} / REPLICAS ))

REQ_FILE="${REQ_FILE:-$HOME/litellm-agw-perf/payloads/req-1024.json}"
echo "launching ${REPLICAS} pinned fortio clients (${CONNS_PER_REPLICA} conns each, ${DURATION}s)..."
pids=()
for k in $(seq 0 $((REPLICAS-1))); do
  hostport=$(( 4001 + k )); client_core="${FREE_CORES[$(( k * STRIDE ))]}"
  out="${RESULTS_DIR}/fortio-replica-$(printf '%02d' "$k").json"
  taskset -c "${client_core}" "${FORTIO}" load -uniform=true -qps 0 -t "${DURATION}s" -c "${CONNS_PER_REPLICA}" \
    -X POST -payload-file "${REQ_FILE}" -httpccch -https-insecure \
    -H Content-type:application/json \
    -json "${out}" -r 0.000001 \
    "http://localhost:${hostport}/v1/chat/completions" \
    > "${RESULTS_DIR}/fortio-replica-$(printf '%02d' "$k").log" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "${pid}"; done

kill "${SAMPLER_PID}" >/dev/null 2>&1 || true
SAMPLER_PID=""

total_qps=0
{
  echo "replica,port,cores,backend,qps,p50_ms,p90_ms,p99_ms,successes"
  for k in $(seq 0 $((REPLICAS-1))); do
    start=$(( k * CORES_PER_REPLICA )); end=$(( start + CORES_PER_REPLICA - 1 ))
    backend_host="mock-server"; [[ $k -ge $HALF ]] && backend_host="mock-server-2"
    f="${RESULTS_DIR}/fortio-replica-$(printf '%02d' "$k").json"
    qps=$(jq -r '.ActualQPS' "${f}")
    p50=$(jq -r '(.DurationHistogram.Percentiles[] | select(.Percentile==50).Value)*1000' "${f}")
    p90=$(jq -r '(.DurationHistogram.Percentiles[] | select(.Percentile==90).Value)*1000' "${f}")
    p99=$(jq -r '(.DurationHistogram.Percentiles[] | select(.Percentile==99).Value)*1000' "${f}")
    ok=$(jq -r '.RetCodes."200" // 0' "${f}")
    echo "${k},$((4001+k)),${start}-${end},${backend_host},${qps},${p50},${p90},${p99},${ok}"
    total_qps=$(python3 -c "print(${total_qps} + ${qps})")
  done
} > "${RESULTS_DIR}/per-replica-summary.csv"

echo "final-repeat: aggregate ${total_qps} qps across ${REPLICAS} replicas" | tee "${RESULTS_DIR}/summary.txt"
