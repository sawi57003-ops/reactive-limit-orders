#!/usr/bin/env bash
# Demo the full loop on testnet: order -> price move -> reactive trigger -> callback fill.
# Prereq: bash script/deploy.sh has run (deployments.env present).
# Usage: bash script/demo-loop.sh [ABOVE_THRESHOLD] [BELOW_THRESHOLD]
# Defaults: above order triggers at 2100e8, below order triggers at 1900e8.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

UNI_RPC="https://sepolia.unichain.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
UNI_CHAIN=1301
DEPLOYER="0xf64712c04cd1D62322A09B4609F6F33Bc8335585"
ABOVE_TH="${1:-210000000000}"
BELOW_TH="${2:-190000000000}"

KEY=$(python3 -c "
import json
d = json.load(open('deployer.key.json'))['data']
if isinstance(d, list): d = d[0]
print(d['private_key'])
")
# shellcheck disable=SC1091
source deployments.env
for v in TOKEN_A TOKEN_B FEED AMM REGISTRY REACTIVE EXECUTOR; do test -n "${!v:-}" || { echo "missing $v in deployments.env — run deploy.sh first"; exit 1; }; done

send_uni() { cast send --rpc-url "$UNI_RPC" --private-key "$KEY" --chain-id "$UNI_CHAIN" "$@" 2>&1 | tee -a demo-log.txt; }
call_uni() { cast call --rpc-url "$UNI_RPC" "$@"; }
call_lasna() { cast call --rpc-url "$LASNA_RPC" "$@"; }

EXPIRY=$(( $(date +%s) + 86400 ))

echo "== A. Create ABOVE order: sell 10 dETH if price >= $ABOVE_TH (8-dec) =="
send_uni "$TOKEN_A" "approve(address,uint256)" "$REGISTRY" 10ether
send_uni "$REGISTRY" "createOrder(address,address,uint256,uint256,bool,uint256)" "$TOKEN_A" "$TOKEN_B" 10ether "$ABOVE_TH" true "$EXPIRY"

echo "== B. Wait for the reactive contract to mirror order 1 (poll Lasna, 3 min max) =="
for i in $(seq 1 36); do
    sleep 5
    active=$(call_lasna "$REACTIVE" "getActiveOrders()(uint256[])" 2>/dev/null || true)
    echo "poll $i: activeOrders=$active"
    case "$active" in *"[1]"*|*"1"*) echo "MIRRORED: order 1 active on Lasna"; break;; esac
    if [ "$i" = 36 ]; then echo "TIMEOUT waiting for mirror"; exit 1; fi
done

echo "== C. Move the price on MockPriceFeed to $ABOVE_TH =="
send_uni "$FEED" "setPrice(int256)" "$ABOVE_TH"

echo "== D. Wait for the fill (poll registry order status + user dUSD, 5 min max) =="
for i in $(seq 1 60); do
    sleep 5
    status=$(call_uni "$REGISTRY" "orders(uint256)(address,address,address,uint256,uint256,bool,uint256,uint8)" 1 2>/dev/null | tail -1 || true)
    bal=$(call_uni "$TOKEN_B" "balanceOf(address)(uint256)" "$DEPLOYER" 2>/dev/null || true)
    echo "poll $i: order1 status=$status (1=Filled) deployer dUSD=$bal"
    if [ "$status" = "1" ]; then echo "FILLED: order 1 executed, user paid in dUSD"; break; fi
    if [ "$i" = 60 ]; then echo "TIMEOUT waiting for fill — check lasna.reactscan.net + executor events"; exit 1; fi
done

echo "== E. Create BELOW order: sell 10 dETH if price <= $BELOW_TH =="
send_uni "$REGISTRY" "createOrder(address,address,uint256,uint256,bool,uint256)" "$TOKEN_A" "$TOKEN_B" 10ether "$BELOW_TH" false "$EXPIRY"
echo "== F. Move the price to $BELOW_TH (triggers order 2) =="
send_uni "$FEED" "setPrice(int256)" "$BELOW_TH"
for i in $(seq 1 60); do
    sleep 5
    status=$(call_uni "$REGISTRY" "orders(uint256)(address,address,address,uint256,uint256,bool,uint256,uint8)" 2 2>/dev/null | tail -1 || true)
    echo "poll $i: order2 status=$status (1=Filled)"
    if [ "$status" = "1" ]; then echo "FILLED: order 2 executed"; break; fi
    if [ "$i" = 60 ]; then echo "TIMEOUT waiting for fill of order 2"; exit 1; fi
done

echo
echo "FULL LOOP PROVEN for both directions. See demo-log.txt for tx hashes."
