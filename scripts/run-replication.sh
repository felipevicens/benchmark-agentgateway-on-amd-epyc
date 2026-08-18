#!/bin/bash
# Reproduces the "replicate, don't enlarge" experiments (5, 6, 7 in the post):
# N independent, cache-domain-pinned agentgateway replicas, each hit by its own
# pinned fortio client, sharing 1 or 2 independently-pinned mock-server backends.
#
# Usage: run-replication.sh <label> <replicas> <cores-per-replica> <num-backends> [duration-seconds]
#
#   ./run-replication.sh 4-replicas-32cores            4  32 1
#   ./run-replication.sh 10-replicas-16cores           10 16 1
#   ./run-replication.sh 20-replicas-8cores-2backends  20  8 2
#
# Core layout on the 160-physical-core / 320-logical-thread EPYC 9845:
#   - Replicas are packed contiguously across physical cores 0-159 (no SMT),
#     `cores-per-replica` wide each, in domain order.
#   - Backend(s) are pinned to the SMT-sibling range (160-319), well clear of
#     any replica's physical cores: backend A -> 176-207, backend B -> 240-271 (avoiding CPU 160, hard-pinned by an unrelated resident workload).
#   - Each fortio client gets one dedicated core from the remaining SMT-sibling
#     range (208-227), so load generation never contends with the servers.
set -euo pipefail

LABEL="${1:?usage: run-replication.sh <label> <replicas> <cores-per-replica> <num-backends> [duration]}"
REPLICAS="${2:?}"
CORES_PER_REPLICA="${3:?}"
NUM_BACKENDS="${4:?}"
DURATION="${5:-15}"

AGW_IMAGE="ghcr.io/agentgateway/agentgateway:v1.4.1"
MOCK_IMAGE="howardjohn/hyper-server:latest"
NET="agwbench"
RESULTS_DIR="${RESULTS_DIR:-$HOME/agwbench-results}/04-replication/${LABEL}"
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

cleanup() {
  ${DOCKER} rm -f agwbench-mock agwbench-mock2 >/dev/null 2>&1 || true
  for k in $(seq 0 $((REPLICAS-1))); do ${DOCKER} rm -f "agwbench-agw-${k}" >/dev/null 2>&1 || true; done
  rm -rf "${CONFIG_DIR}"
}
trap cleanup EXIT
cleanup 2>/dev/null || true
mkdir -p "${CONFIG_DIR}"

# --- backend(s) ---
${DOCKER} run -d --name agwbench-mock --network "${NET}" --network-alias mock-server \
  --cpuset-cpus 176-207 -e PORT=8081 -e PAYLOAD="${PAYLOAD_JSON}" "${MOCK_IMAGE}" >/dev/null
if [[ "${NUM_BACKENDS}" == "2" ]]; then
  ${DOCKER} run -d --name agwbench-mock2 --network "${NET}" --network-alias mock-server-2 \
    --cpuset-cpus 240-271 -e PORT=8081 -e PAYLOAD="${PAYLOAD_JSON}" "${MOCK_IMAGE}" >/dev/null
fi

# --- replicas ---
HALF=$(( REPLICAS / 2 ))
for k in $(seq 0 $((REPLICAS-1))); do
  start=$(( k * CORES_PER_REPLICA ))
  end=$(( start + CORES_PER_REPLICA - 1 ))
  hostport=$(( 4001 + k ))
  if [[ "${NUM_BACKENDS}" == "2" && $k -ge $HALF ]]; then
    backend_host="mock-server-2"
  else
    backend_host="mock-server"
  fi
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
    --cpuset-cpus "${start}-${end}" \
    -p "${hostport}:4001" \
    -v "${cfg}:/app/config.yaml:ro" \
    "${AGW_IMAGE}" -f /app/config.yaml >/dev/null
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

# Free SMT-sibling cores (not used by either backend): 160-175, 208-239, 272-319.
# Spread clients thinly across all of it instead of packing them into one
# contiguous block -- a dense block of clients shares SMT siblings with just
# 2-3 replicas' physical cores, visibly starving those specific replicas.
FREE_CORES=()
for c in $(seq 160 175) $(seq 208 239) $(seq 272 319); do FREE_CORES+=("$c"); done
FREE_COUNT=${#FREE_CORES[@]}
STRIDE=$(( FREE_COUNT / REPLICAS ))

REQ_FILE="${REQ_FILE:-$HOME/litellm-agw-perf/payloads/req-1024.json}"
echo "launching ${REPLICAS} pinned fortio clients (${CONNS_PER_REPLICA} conns each, ${DURATION}s)..."
pids=()
for k in $(seq 0 $((REPLICAS-1))); do
  hostport=$(( 4001 + k ))
  client_core="${FREE_CORES[$(( k * STRIDE ))]}"
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

{
  echo "PAYLOAD,CONTAINER,AVG_CPU%,PEAK_CPU%,AVG_MEM,PEAK_MEM"
  names="agwbench-mock"
  [[ "${NUM_BACKENDS}" == "2" ]] && names="agwbench-mock agwbench-mock2"
  for k in $(seq 0 $((REPLICAS-1))); do names="${names} agwbench-agw-${k}"; done
  ${DOCKER} stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' ${names}
} > "${RESULTS_DIR}/resources.csv"

total_qps=0
{
  echo "replica,qps,p50,p90,p99,successes"
  for k in $(seq 0 $((REPLICAS-1))); do
    f="${RESULTS_DIR}/fortio-replica-$(printf '%02d' "$k").json"
    qps=$(jq -r '.ActualQPS' "${f}")
    p50=$(jq -r '.DurationHistogram.Percentiles[] | select(.Percentile==50).Value' "${f}")
    p90=$(jq -r '.DurationHistogram.Percentiles[] | select(.Percentile==90).Value' "${f}")
    p99=$(jq -r '.DurationHistogram.Percentiles[] | select(.Percentile==99).Value' "${f}")
    ok=$(jq -r '.RetCodes."200" // 0' "${f}")
    echo "${k},${qps},${p50},${p90},${p99},${ok}"
    total_qps=$(python3 -c "print(${total_qps} + ${qps})")
  done
} > "${RESULTS_DIR}/per-replica-summary.csv"

echo "${LABEL}: aggregate ${total_qps} qps across ${REPLICAS} replicas" | tee "${RESULTS_DIR}/summary.txt"
