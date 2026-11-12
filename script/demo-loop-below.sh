#!/usr/bin/env bash
# Continuation of demo-loop.sh: BELOW order only (order 1 ABOVE already FILLED).
# Created because demo r2 stopped at step E: registry allowance for order 2
# was consumed by order 1 (script only approved once). This script re-approves.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

UNI_RPC="https://unichain-sepolia-rpc.publicnode.com"
LASNA_RPC="https://lasna-rpc.rnk.dev"
UNI_CHAIN=1301
DEPLOYER="0xf64712c04cd1D62322A09B4609F6F33Bc8335585"
BELOW_TH="${1:-190000000000}"

KEY=$(python3 -c "
import json
d = json.load(open('deployer.key.json'))['data']
if isinstance(d, list): d = d[0]
print(d['private_key'])
")
# shellcheck disable=SC1091
source deployments.env
for v in TOKEN_A TOKEN_B FEED AMM REGISTRY REACTIVE EXECUTOR; do test -n "${!v:-}" || { echo "missing $v in deployments.env"; exit 1; }; done

send_uni() { # explicit nonce + retry 3x
    local attempt nonce
    for attempt in 1 2 3; do
        nonce=$(cast nonce "$DEPLOYER" --rpc-url "$UNI_RPC")
        if cast send --rpc-url "$UNI_RPC" --private-key "$KEY" --chain-id "$UNI_CHAIN" --nonce "$nonce" "$@" 2>&1 | tee -a demo-log.txt; then
            return 0
        fi
        echo "send_uni attempt $attempt failed, retrying in 10s..." | tee -a demo-log.txt
        sleep 10
    done
    echo "send_uni FAILED after 3 attempts: $*" | tee -a demo-log.txt
    exit 1
}
call_uni() { cast call --rpc-url "$UNI_RPC" "$@"; }
call_lasna() { cast call --rpc-url "$LASNA_RPC" "$@"; }

EXPIRY=$(( $(date +%s) + 86400 ))

echo "== E2. Re-approve 10 dETH + create BELOW order (id 2, price <= $BELOW_TH) =="
send_uni "$TOKEN_A" "approve(address,uint256)" "$REGISTRY" 10ether
send_uni "$REGISTRY" "createOrder(address,address,uint256,uint256,bool,uint256)" "$TOKEN_A" "$TOKEN_B" 10ether "$BELOW_TH" false "$EXPIRY"

echo "== F2. Wait for mirror of order 2 on Lasna (3 min max) =="
for i in $(seq 1 36); do
    sleep 5
    active=$(call_lasna "$REACTIVE" "getActiveOrders()(uint256[])" 2>/dev/null || true)
    echo "poll $i: activeOrders=$active"
    case "$active" in *"2"*) echo "MIRRORED: order 2 active on Lasna"; break;; esac
    if [ "$i" = 36 ]; then echo "TIMEOUT waiting for mirror"; exit 1; fi
done

echo "== G2. Move the price to $BELOW_TH =="
send_uni "$FEED" "setPrice(int256)" "$BELOW_TH"

echo "== H2. Wait for the fill of order 2 (5 min max) =="
for i in $(seq 1 60); do
    sleep 5
    status=$(call_uni "$REGISTRY" "orders(uint256)(address,address,address,uint256,uint256,bool,uint256,uint8)" 2 2>/dev/null | tail -1 || true)
    bal=$(call_uni "$TOKEN_B" "balanceOf(address)(uint256)" "$DEPLOYER" 2>/dev/null || true)
    echo "poll $i: order2 status=$status (1=Filled) deployer dUSD=$bal"
    if [ "$status" = "1" ]; then echo "FILLED: order 2 executed, user paid in dUSD"; break; fi
    if [ "$i" = 60 ]; then echo "TIMEOUT waiting for fill of order 2"; exit 1; fi
done

echo
echo "BELOW LOOP PROVEN. See demo-log.txt for tx hashes."
