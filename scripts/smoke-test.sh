#!/usr/bin/env bash
# Contract smoke test for a running grpcbin instance.
#
# Covers the RPCs that downstream consumers (Kong Gateway busted and API
# tests, KIC chainsaw tests, docker-compose generator) depend on, over both
# the plaintext and the TLS listener, using server reflection only.
#
# Usage:
#   scripts/smoke-test.sh [HOST] [PLAINTEXT_PORT] [TLS_PORT]
#
# Examples:
#   docker run -d --name grpcbin -p 9000:9000 -p 9001:9001 kong/grpcbin:latest
#   scripts/smoke-test.sh localhost 9000 9001
#
#   GRPCURL="docker run --rm --network host fullstorydev/grpcurl:v1.9.3" \
#     scripts/smoke-test.sh localhost 9000 9001

set -euo pipefail

HOST="${1:-localhost}"
PLAIN_PORT="${2:-9000}"
TLS_PORT="${3:-9001}"
GRPCURL="${GRPCURL:-grpcurl}"

failures=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1" >&2; failures=$((failures + 1)); }

# call <label> <transport flag> <port> <expected substring> <method|list> [grpcurl flags...]
call() {
  local label="$1" transport="$2" port="$3" expected="$4" method="$5"
  shift 5
  local out
  # shellcheck disable=SC2086
  if out=$($GRPCURL $transport -max-time 20 "$@" "$HOST:$port" "$method" 2>&1) && [[ "$out" == *"$expected"* ]]; then
    pass "$label"
  else
    fail "$label"
    printf "%s\n" "$out" >&2
  fi
}

# call_error <label> <transport flag> <port> <expected code> <method> [grpcurl flags...]
call_error() {
  local label="$1" transport="$2" port="$3" expected="$4" method="$5"
  shift 5
  local out
  # shellcheck disable=SC2086
  if ! out=$($GRPCURL $transport -max-time 20 "$@" "$HOST:$port" "$method" 2>&1) && [[ "$out" == *"Code: $expected"* ]]; then
    pass "$label"
  else
    fail "$label"
    printf "%s\n" "$out" >&2
  fi
}

wait_ready() {
  local _
  for _ in $(seq 1 30); do
    # shellcheck disable=SC2086
    if $GRPCURL -plaintext -max-time 2 "$HOST:$PLAIN_PORT" list >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "[FAILED] grpcbin not ready on $HOST:$PLAIN_PORT after 30s" >&2
  exit 1
}

wait_ready

for mode in plaintext tls; do
  if [[ "$mode" == "plaintext" ]]; then
    transport="-plaintext"
    port="$PLAIN_PORT"
  else
    transport="-insecure"
    port="$TLS_PORT"
  fi

  call "[$mode] reflection lists hello.HelloService" "$transport" "$port" "hello.HelloService" list
  call "[$mode] reflection lists grpcbin.GRPCBin" "$transport" "$port" "grpcbin.GRPCBin" list
  call "[$mode] reflection lists addsvc.Add" "$transport" "$port" "addsvc.Add" list

  call "[$mode] hello.HelloService/SayHello" "$transport" "$port" \
    '"reply": "hello kong"' hello.HelloService/SayHello -d '{"greeting":"kong"}'
  call "[$mode] hello.HelloService/LotsOfReplies (server stream)" "$transport" "$port" \
    '"reply": "hello kong"' hello.HelloService/LotsOfReplies -d '{"greeting":"kong"}'
  call "[$mode] hello.HelloService/LotsOfGreetings (client stream)" "$transport" "$port" \
    '"reply": "hello a, b"' hello.HelloService/LotsOfGreetings -d '{"greeting":"a"} {"greeting":"b"}'
  call "[$mode] hello.HelloService/BidiHello (bidi stream)" "$transport" "$port" \
    '"reply": "hello kong"' hello.HelloService/BidiHello -d '{"greeting":"kong"}'

  call "[$mode] grpcbin.GRPCBin/DummyUnary" "$transport" "$port" \
    '"fString": "kong"' grpcbin.GRPCBin/DummyUnary -d '{"f_string":"kong"}'
  call "[$mode] grpcbin.GRPCBin/Empty" "$transport" "$port" \
    "{" grpcbin.GRPCBin/Empty
  call "[$mode] grpcbin.GRPCBin/HeadersUnary" "$transport" "$port" \
    "x-kong-smoke" grpcbin.GRPCBin/HeadersUnary -H 'x-kong-smoke: 1'
  call "[$mode] grpcbin.GRPCBin/DummyServerStream" "$transport" "$port" \
    '"fString": "kong"' grpcbin.GRPCBin/DummyServerStream -d '{"f_string":"kong"}'
  call_error "[$mode] grpcbin.GRPCBin/SpecificError returns requested code" "$transport" "$port" \
    "PermissionDenied" grpcbin.GRPCBin/SpecificError -d '{"code":7,"reason":"smoke"}'

  call "[$mode] addsvc.Add/Sum" "$transport" "$port" \
    '"v": "5"' addsvc.Add/Sum -d '{"a":2,"b":3}'
done

if [[ "$failures" -gt 0 ]]; then
  echo "[FAILED] $failures smoke check(s) failed" >&2
  exit 1
fi
echo "[SUCCESS] all smoke checks passed"
