#!/bin/bash
# Reproduces experiments 2 ("CPU-quota") and 3 ("quota vs pinning") from the post:
# a single agentgateway instance behind a single mock-server, hit with a fixed
# 320-connection fortio load, varying only how the container's CPU visibility
# is constrained (--cpus vs --cpuset-cpus).
#
# Usage: run-cpu-quota.sh <label> <docker-cpu-flag>
#   label            short name used for the results subfolder, e.g. cpus-8
#   docker-cpu-flag  the flag(s) to pass to `docker run` for agentgateway,
#                    e.g. "--cpus=8", "--cpuset-cpus=0-31", or "" (unconstrained)
#
# Run once per configuration:
#   ./run-cpu-quota.sh cpus-8                  --cpus=8
#   ./run-cpu-quota.sh cpus-32                  --cpus=32
#   ./run-cpu-quota.sh cpus-320-unconstrained    ""
#   ./run-cpu-quota.sh cpuset-1domain-smt        --cpuset-cpus=0-15,160-175
#   ./run-cpu-quota.sh cpuset-2domains-nosmt     --cpuset-cpus=0-31
set -euo pipefail

LABEL="${1:?usage: run-cpu-quota.sh <label> <docker-cpu-flag>}"
CPU_FLAG="${2:-}"

AGW_IMAGE="ghcr.io/agentgateway/agentgateway:v1.4.1"
MOCK_IMAGE="howardjohn/hyper-server:latest"
NET="agwbench"
RESULTS_DIR="${RESULTS_DIR:-$HOME/agwbench-results}/02-cpu-quota/${LABEL}"
CONFIG_DIR="$HOME/agwbench-cfg-$$"; mkdir -p "${CONFIG_DIR}"
FORTIO="$HOME/.local/bin/fortio"
DOCKER="sudo -n docker"

mkdir -p "${RESULTS_DIR}"
${DOCKER} network create "${NET}" >/dev/null 2>&1 || true

cat > "${CONFIG_DIR}/agentgateway.yaml" <<'EOF'
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
        baseUrl: http://mock-server:8081/v1
        model: gpt-3.5-turbo
        apiKey: dummy
EOF

cleanup() {
  ${DOCKER} rm -f agwbench-mock agwbench-agw >/dev/null 2>&1 || true
  rm -rf "${CONFIG_DIR}"
}
trap cleanup EXIT

${DOCKER} rm -f agwbench-mock agwbench-agw >/dev/null 2>&1 || true

# Mock backend: 1024-char JSON payload, same shape used for the whole investigation.
${DOCKER} run -d --name agwbench-mock --network "${NET}" --network-alias mock-server \
  --cpuset-cpus 280-295 \
  -e PORT=8081 \
  -e PAYLOAD="$(python3 - <<'PY'
import json
content = "omnis ipsum non cum totam animi voluptatem tenetur ad quidem voluptate ipsa provident consectetur tempore sed pariatur nam dignissimos dolorum unde dolor nemo veritatis ex consequatur repellat laboriosam ab dicta vero reprehenderit magnam eveniet quas eos libero laudantium illum iste temporibus rerum velit cumque sunt sit delectus deserunt facilis magni doloremque hic obcaecati incidunt neque qui odit accusamus optio laborum ullam error assumenda itaque voluptatum fuga ipsam accusantium quod debitis iusto saepe quo possimus voluptas dolore harum quos facere adipisci repudiandae eu"
body = {"id":"chatcmpl-456","model":"openai/gpt-3.5-turbo","object":"chat.completion","created":123456,
        "choices":[{"index":0,"message":{"role":"assistant","content":content},"finish_reason":"stop"}],
        "usage":{"prompt_tokens":9,"completion_tokens":12,"total_tokens":21}}
print(json.dumps(body))
PY
)" \
  "${MOCK_IMAGE}" >/dev/null

${DOCKER} run -d --name agwbench-agw --network "${NET}" \
  ${CPU_FLAG} \
  -p 4001:4001 \
  -v "${CONFIG_DIR}/agentgateway.yaml:/app/config.yaml:ro" \
  "${AGW_IMAGE}" -f /app/config.yaml >/dev/null

echo "waiting for agentgateway to accept connections..."
for i in $(seq 1 30); do
  curl -sf -o /dev/null -X POST http://localhost:4001/v1/chat/completions \
    -H 'Content-type: application/json' \
    -d '{"model":"openai/gpt-3.5-turbo","messages":[{"role":"user","content":"hi"}]}' && break
  sleep 1
done

REQ_FILE="${REQ_FILE:-$HOME/litellm-agw-perf/payloads/req-1024.json}"
echo "running fortio (320 connections, 15s, max qps)..."
"${FORTIO}" load -uniform=true -qps 0 -t 15s -c 320 \
  -X POST -payload-file "${REQ_FILE}" -httpccch -https-insecure \
  -H Content-type:application/json \
  -json "${RESULTS_DIR}/fortio-agentgateway.json" -r 0.000001 \
  http://localhost:4001/v1/chat/completions | tee "${RESULTS_DIR}/fortio.log"

{
  echo "PAYLOAD,CONTAINER,AVG_CPU%,PEAK_CPU%,AVG_MEM,PEAK_MEM"
  ${DOCKER} stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' agwbench-agw agwbench-mock
} > "${RESULTS_DIR}/resources.csv"

qps=$(jq -r '.ActualQPS' "${RESULTS_DIR}/fortio-agentgateway.json")
p50=$(jq -r '.DurationHistogram.Percentiles[] | select(.Percentile==50).Value' "${RESULTS_DIR}/fortio-agentgateway.json")
p99=$(jq -r '.DurationHistogram.Percentiles[] | select(.Percentile==99).Value' "${RESULTS_DIR}/fortio-agentgateway.json")
echo "${LABEL}: ${qps} qps, p50=${p50}s p99=${p99}s" | tee "${RESULTS_DIR}/summary.txt"
