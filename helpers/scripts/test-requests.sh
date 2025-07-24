#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# test-request.sh
#
# Description:
#   Quick smoke tests against your llm-d deployment:
#     1) GET  /v1/models      on the decode pod
#     2) POST /v1/completions on the decode pod
#     3) GET  /v1/models      via the gateway
#     4) POST /v1/completions via the gateway
# -----------------------------------------------------------------------------

set -euo pipefail

if ! command -v kubectl &>/dev/null; then
  echo "Error: 'kubectl' not found in PATH." >&2
  exit 1
fi

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Quick smoke tests against your llm-d deployment.

Options:
  -n, --namespace NAMESPACE   Kubernetes namespace to use (default: llm-d)
  -m, --model MODEL_ID        Model to query (optional; discovered if omitted)
  -v, --verbose               Display the kubectl run commands being executed
  -h, --help                  Show this help message and exit
EOF
  exit 0
}

NAMESPACE="llm-d"
CLI_MODEL_ID=""
VERBOSE=false
FAILED_COUNT=0

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -m|--model)
      CLI_MODEL_ID="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      ;;
  esac
done

MODEL_ID="${CLI_MODEL_ID:-}"

echo "Namespace: $NAMESPACE"
if [[ -n "$MODEL_ID" ]]; then
  echo "Model ID:  $MODEL_ID"
else
  echo "Model ID:  none; will be discovered from first entry in /v1/models"
fi
echo

# ── generate a unique suffix ───────────────────────────────────────
gen_id() { echo $(( RANDOM % 10000 + 1 )); }

# ── Extract all model IDs ──────────────
extract_models() {
  printf '%s' "$1" | grep -o '"id":"[^"]*"' | cut -d'"' -f4
}

# ── Grab the FIRST model ID ───────────────────────────────────
infer_first_model() {
  printf '%s' "$1" | grep -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4
}

validation() {
  # Discover the decode pod IP
  echo "-> Discovering decode pod…"
  POD_IP=$(kubectl get pods -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{"\n"}{end}' \
    | grep decode | awk '{print $2}' | head -1)

  if [[ -z "$POD_IP" ]]; then
    echo "❌ Failed: No decode pod found in namespace $NAMESPACE"
    ((FAILED_COUNT++))
    return
  else
    echo "✅ Success: Found decode pod at ${POD_IP}"
  fi
  echo

  # ── 1) GET /v1/models on decode pod ─────────────────────────────────────────
  echo "1 -> GET /v1/models from decode pod…"
  ID=$(gen_id)
  if [[ "$VERBOSE" == true ]]; then
    cat <<CMD
  - Running command:
    kubectl run --rm -i curl-${ID} \\
      --namespace "${NAMESPACE}" \\
      --image=curlimages/curl --restart=Never -- \\
      curl -sS --fail http://${POD_IP}:8000/v1/models \\
        -H 'accept: application/json' \\
        -H 'Content-Type: application/json'

CMD
  fi
  set +e
  LIST_JSON=$(kubectl run --rm -i curl-"$ID" \
    --namespace "$NAMESPACE" \
    --image=curlimages/curl --restart=Never -- \
    curl -sS --fail http://${POD_IP}:8000/v1/models \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json')
  EXIT_CODE=$?
  set -e

  if [[ $EXIT_CODE -eq 0 ]]; then
    echo "✅ Success"
    echo "$LIST_JSON"
  else
    echo "❌ Failed (Exit Code: $EXIT_CODE)"
    ((FAILED_COUNT++))
    return # Cannot proceed without a model list
  fi
  echo

  # Validate or infer model
  echo "-> Validating model ID…"
  if [[ -z "$MODEL_ID" ]]; then
    MODEL_ID=$(infer_first_model "$LIST_JSON")
    echo "✅ Success: Discovered model to use: $MODEL_ID"
  else
    if ! grep -q "\"id\":\"$MODEL_ID\"" <<<"$LIST_JSON"; then
      echo "❌ Failed: Requested model '$MODEL_ID' not found in available models:"
      extract_models "$LIST_JSON"
      ((FAILED_COUNT++))
    else
      echo "✅ Success: Model '$MODEL_ID' is available."
    fi
  fi
  echo

  # ── 2) POST /v1/completions on decode pod ──────────────────────────────────
  if [[ $FAILED_COUNT -eq 0 ]]; then
    echo "2 -> POST /v1/completions to decode pod…"
    ID=$(gen_id)
    if [[ "$VERBOSE" == true ]]; then cat <<CMD
  - Running command:
    kubectl run --rm -i curl-${ID} \\
      --namespace "${NAMESPACE}" \\
      --image=curlimages/curl --restart=Never -- \\
      curl -sS --fail -X POST http://${POD_IP}:8000/v1/completions \\
        -H 'accept: application/json' \\
        -H 'Content-Type: application/json' \\
        -d '{
          "model":"${MODEL_ID}",
          "prompt":"Who are you?"
        }'

CMD
    fi
    set +e
    COMPLETION_JSON=$(kubectl run --rm -i curl-"$ID" --namespace "$NAMESPACE" --image=curlimages/curl --restart=Never -- curl -sS --fail -X POST http://${POD_IP}:8000/v1/completions -H 'accept: application/json' -H 'Content-Type: application/json' -d '{"model":"'"$MODEL_ID"'","prompt":"Who are you?"}')
    EXIT_CODE=$?
    set -e

    if [[ $EXIT_CODE -eq 0 ]]; then
      echo "✅ Success"
      echo "$COMPLETION_JSON"
    else
      echo "❌ Failed (Exit Code: $EXIT_CODE)"
      ((FAILED_COUNT++))
      echo "$COMPLETION_JSON"
    fi
    echo
  fi

  # ── 3) Discover gateway ────────────────────────────────────────────────────
  echo "-> Discovering gateway…"
  set +e
  GATEWAY_NAME=$(kubectl get gateway -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  GATEWAY_ADDR=$(kubectl get gateway -n "$NAMESPACE" -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null)
  set -e
  if [[ -z "$GATEWAY_ADDR" ]] || [[ -z "$GATEWAY_NAME" ]]; then
    echo "❌ Failed: Could not discover Gateway in namespace $NAMESPACE"
    ((FAILED_COUNT++))
    return
  else
    echo "✅ Success: Found gateway '${GATEWAY_NAME}' at ${GATEWAY_ADDR}"
  fi
  echo

  # ── 3) GET /v1/models via the gateway ─────────────────────────────────────
  echo "3 -> GET /v1/models via gateway…"
  ID=$(gen_id)
  if [[ "$VERBOSE" == true ]]; then cat <<CMD
  - Running command:
    kubectl run --rm -i curl-${ID} \\
      --namespace "${NAMESPACE}" \\
      --image=curlimages/curl --restart=Never -- \\
      curl -sS --fail http://${GATEWAY_ADDR}/v1/models \\
        -H 'accept: application/json' \\
        -H 'Content-Type: application/json'

CMD
  fi
  set +e
  GW_JSON=$(kubectl run --rm -i curl-"$ID" --namespace "$NAMESPACE" --image=curlimages/curl --restart=Never -- curl -sS --fail http://${GATEWAY_ADDR}/v1/models -H 'accept: application/json' -H 'Content-Type: application/json')
  EXIT_CODE=$?
  set -e

  if [[ $EXIT_CODE -eq 0 ]]; then
    echo "✅ Success"
    echo "$GW_JSON"
  else
    echo "❌ Failed (Exit Code: $EXIT_CODE)"
    ((FAILED_COUNT++))
  fi
  echo

  # ── 4) POST /v1/completions via gateway ────────────────────────────────────
  if [[ $FAILED_COUNT -eq 0 ]]; then
    echo "4 -> POST /v1/completions via gateway…"
    ID=$(gen_id)
    if [[ "$VERBOSE" == true ]]; then cat <<CMD
  - Running command:
    kubectl run --rm -i curl-${ID} \\
      --namespace "${NAMESPACE}" \\
      --image=curlimages/curl --restart=Never -- \\
      curl -sS --fail -X POST http://${GATEWAY_ADDR}/v1/completions \\
        -H 'accept: application/json' \\
        -H 'Content-Type: application/json' \\
        -d '{
          "model":"${MODEL_ID}",
          "prompt":"Who are you?"
        }'

CMD
    fi
    set +e
    GW_COMPLETION_JSON=$(kubectl run --rm -i curl-"$ID" --namespace "$NAMESPACE" --image=curlimages/curl --restart=Never -- curl -sS --fail -X POST http://${GATEWAY_ADDR}/v1/completions -H 'accept: application/json' -H 'Content-Type: application/json' -d '{"model":"'"$MODEL_ID"'","prompt":"Who are you?"}')
    EXIT_CODE=$?
    set -e

    if [[ $EXIT_CODE -eq 0 ]]; then
      echo "✅ Success"
      echo "$GW_COMPLETION_JSON"
    else
      echo "❌ Failed (Exit Code: $EXIT_CODE)"
      ((FAILED_COUNT++))
      echo "$GW_COMPLETION_JSON"
    fi
    echo
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
validation

echo "────────────────────────────────────────────────────────────────"
if [[ $FAILED_COUNT -gt 0 ]]; then
  echo "${FAILED_COUNT} test(s) failed."
  exit 1
else
  echo "🚀 All tests passed."
fi
