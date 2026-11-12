#!/usr/bin/env bash
# Deploy reactive-limit-orders to TESTNETS ONLY.
# Chains: Unichain Sepolia (1301) + Reactive Lasna (5318007). No mainnet anywhere.
# Usage: bash script/deploy.sh
# Resumes: addresses are saved to deployments.env after each step; re-running skips
# steps whose address is already recorded. Delete deployments.env to start over.
# The deployer key is read from deployer.key.json (testnet-only, chmod 600) and is
# never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

UNI_RPC="https://sepolia.unichain.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
SEPOLIA_RPC="https://ethereum-sepolia.publicnode.com"
UNI_CHAIN=1301
LASNA_CHAIN=5318007
PROXY_UNI="0x775c9B990ADe401060B78D0e98684eEf8d2466C1" # Unichain Sepolia callback proxy (docs)
DEPLOYER="0xf64712c04cd1D62322A09B4609F6F33Bc8335585"

KEY=$(python3 -c "
import json
d = json.load(open('deployer.key.json'))['data']
if isinstance(d, list): d = d[0]
print(d['private_key'])
")
test -n "$KEY"

touch deployments.env
# shellcheck disable=SC1091
source deployments.env

save() { # save KEY VALUE
    echo "$1=$2" >> deployments.env
    printf '%s=%s\n' "$1" "$2"
}

need_funds() { # need_funds CHAIN RPC ADDR MIN_ETHER
    bal=$(cast balance "$3" --rpc-url "$2")
    echo "[$1] $3 balance: $bal wei"
}

echo "== balances =="
need_funds "unichain-sepolia" "$UNI_RPC" "$DEPLOYER"
need_funds "lasna" "$LASNA_RPC" "$DEPLOYER"

deploy() { # deploy CHAIN RPC CONTRACT_PATH:NAME [VALUE] [ARGS...]
    local chain="$1" rpc="$2" path="$3" value="$4"; shift 4
    local out addr
    local args=()
    if [ "$#" -gt 0 ]; then args=(--constructor-args "$@"); fi
    if [ -n "$value" ]; then
        out=$(forge create --broadcast --rpc-url "$rpc" --private-key "$KEY" --chain-id "$chain" --value "$value" "$path" "${args[@]}" 2>&1)
    else
        out=$(forge create --broadcast --rpc-url "$rpc" --private-key "$KEY" --chain-id "$chain" "$path" "${args[@]}" 2>&1)
    fi
    echo "$out" | tee -a deploy-log.txt
    addr=$(echo "$out" | grep -oE "Deployed to: 0x[0-9a-fA-F]{40}" | awk '{print $3}')
    test -n "$addr"
    echo "$addr"
}

send() { # send CHAIN RPC TO SIG [ARGS...] ; value via VALUE env (default 0)
    local chain="$1" rpc="$2" to="$3" sig="$4"; shift 4
    cast send --rpc-url "$rpc" --private-key "$KEY" --chain-id "$chain" ${VALUE:+--value "$VALUE"} "$to" "$sig" "$@" 2>&1 | tee -a deploy-log.txt
}

echo "== 1. DemoToken dETH (Unichain Sepolia) =="
if [ -z "${TOKEN_A:-}" ]; then
    TOKEN_A=$(deploy "$UNI_CHAIN" "$UNI_RPC" "src/DemoToken.sol:DemoToken" "" "Demo ETH" "dETH")
    save TOKEN_A "$TOKEN_A"
fi
echo "== 2. DemoToken dUSD (Unichain Sepolia) =="
if [ -z "${TOKEN_B:-}" ]; then
    TOKEN_B=$(deploy "$UNI_CHAIN" "$UNI_RPC" "src/DemoToken.sol:DemoToken" "" "Demo USD" "dUSD")
    save TOKEN_B "$TOKEN_B"
fi
echo "== 3. Mint demo tokens to deployer =="
if [ -z "${MINTED:-}" ]; then
    send "$UNI_CHAIN" "$UNI_RPC" "$TOKEN_A" "mint(address,uint256)" "$DEPLOYER" 1000000ether
    send "$UNI_CHAIN" "$UNI_RPC" "$TOKEN_B" "mint(address,uint256)" "$DEPLOYER" 1000000000ether
    save MINTED 1
fi
echo "== 4. MockPriceFeed @ 2000e8 (Unichain Sepolia) =="
if [ -z "${FEED:-}" ]; then
    FEED=$(deploy "$UNI_CHAIN" "$UNI_RPC" "src/MockPriceFeed.sol:MockPriceFeed" "" 200000000000)
    save FEED "$FEED"
fi
echo "== 5. DemoAMM (Unichain Sepolia) =="
if [ -z "${AMM:-}" ]; then
    AMM=$(deploy "$UNI_CHAIN" "$UNI_RPC" "src/DemoAMM.sol:DemoAMM" "" "$TOKEN_A" "$TOKEN_B")
    save AMM "$AMM"
fi
echo "== 6. Seed AMM: 10,000 dETH + 20,000,000 dUSD =="
if [ -z "${SEEDED:-}" ]; then
    send "$UNI_CHAIN" "$UNI_RPC" "$TOKEN_A" "approve(address,uint256)" "$AMM" 10000ether
    send "$UNI_CHAIN" "$UNI_RPC" "$TOKEN_B" "approve(address,uint256)" "$AMM" 20000000ether
    send "$UNI_CHAIN" "$UNI_RPC" "$AMM" "addLiquidity(uint256,uint256)" 10000ether 20000000ether
    save SEEDED 1
fi
echo "== 7. LimitOrderRegistry (Unichain Sepolia) =="
if [ -z "${REGISTRY:-}" ]; then
    REGISTRY=$(deploy "$UNI_CHAIN" "$UNI_RPC" "src/LimitOrderRegistry.sol:LimitOrderRegistry" "")
    save REGISTRY "$REGISTRY"
fi
echo "== 8. LimitOrderReactive on Lasna (funded 2 lREACT) =="
if [ -z "${REACTIVE:-}" ]; then
    REACTIVE=$(deploy "$LASNA_CHAIN" "$LASNA_RPC" "src/LimitOrderReactive.sol:LimitOrderReactive" "2ether" "$UNI_CHAIN" "$REGISTRY" "$FEED")
    save REACTIVE "$REACTIVE"
fi
echo "== 9. LimitOrderExecutor on Unichain Sepolia (funded 0.01 ETH) =="
if [ -z "${EXECUTOR:-}" ]; then
    EXECUTOR=$(deploy "$UNI_CHAIN" "$UNI_RPC" "src/LimitOrderExecutor.sol:LimitOrderExecutor" "0.01ether" "$PROXY_UNI" "$REACTIVE" "$REGISTRY" "$AMM")
    save EXECUTOR "$EXECUTOR"
fi
echo "== 10. Wire: registry executor + reactive executor =="
if [ -z "${WIRED:-}" ]; then
    send "$UNI_CHAIN" "$UNI_RPC" "$REGISTRY" "setExecutor(address)" "$EXECUTOR"
    send "$LASNA_CHAIN" "$LASNA_RPC" "$REACTIVE" "setExecutor(address)" "$EXECUTOR"
    save WIRED 1
fi

echo
echo "== deployments =="
cat deployments.env
echo
echo "DONE. Next: run the demo loop with script/demo-loop.sh"
