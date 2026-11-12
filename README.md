# Set-and-Forget Limit Orders

Limit-order bot without a server, built on **Reactive Network (Omni)** for the
**Reactive Omni Buildathon** (DoraHacks, 5 Nov – 5 Dec 2026), track
**Set It and Forget It**. A user escrows demo tokens against a price threshold;
a reactive contract watches the price feed and, when the threshold crosses,
fires a callback that executes the swap on-chain. No bot, no keeper, no server.

> Status (12 Nov 2026): **DEPLOYED + FULL LOOP PROVEN on testnet, both
> directions** — see [Live deployment](#live-deployment-12-nov-2026). Code
> complete, **33/33 Foundry tests pass** (unit + invariant). No mainnet
> anywhere.

## How it works

```
User ──createOrder──▶ LimitOrderRegistry (Unichain Sepolia, escrow)
                          │ emits OrderCreated / OrderCancelled
                          ▼
                  LimitOrderReactive (Lasna) ── mirrors orders from events
                          │ watches MockPriceFeed PriceUpdated (+ CRON100 tick)
                          │ threshold crossed → SYSTEM.requestCallbackV_1_0
                          ▼
                  LimitOrderExecutor (Unichain Sepolia)
                          │ onlyServiceProvider (official callback proxy)
                          │ + onlyCallbackSender (authorized reactive) + nonce
                          ▼
                  DemoAMM.swap ──▶ proceeds paid to the order owner
```

The reactive contract **cannot read Unichain Sepolia state** — it mirrors orders
purely from the registry's events, and re-checks them on every price event and
on a CRON100 tick (~2 min) as a backup for missed events. Expired orders are
swept and never filled.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `DemoToken` | Unichain Sepolia | Mintable demo ERC20 (dETH / dUSD, 18 dec) |
| `MockPriceFeed` | Unichain Sepolia | Chainlink-compatible feed; owner moves the price, emits `PriceUpdated` |
| `DemoAMM` | Unichain Sepolia | Constant-product AMM, 0.3% fee, real on-chain swaps |
| `LimitOrderRegistry` | Unichain Sepolia | Order escrow; create / cancel (refund) / fill (executor only, once) |
| `LimitOrderReactive` | Lasna | Event mirror + threshold check + callback request |
| `LimitOrderExecutor` | Unichain Sepolia | Callback receiver; proxy + reactive auth, anti-replay nonce, executes the swap |

## Live deployment (12 Nov 2026)

Deployer: `0xf64712c04cd1D62322A09B4609F6F33Bc8335585` (funded by the owner:
0.0099999 Unichain Sepolia ETH + 5.145 lREACT on Lasna).

| Contract | Chain | Address |
|---|---|---|
| DemoToken dETH | Unichain Sepolia | `0x325B2cDFF5f39f8DDA79fD5C2465706C620d64E8` |
| DemoToken dUSD | Unichain Sepolia | `0xE2B49f1024EDc7752A3db532aA86E64693e7eea8` |
| MockPriceFeed | Unichain Sepolia | `0xa5464dDB6e96AE3C65EB7711cf2e1baDa96ab9e9` |
| DemoAMM | Unichain Sepolia | `0xCA2Df071A1bB3D13cFD7792f095a6288fa5A5af5` |
| LimitOrderRegistry | Unichain Sepolia | `0xe42cf4340304Be622cc2f45dbc097D68b0164f3b` |
| LimitOrderReactive | Lasna | `0x325B2cDFF5f39f8DDA79fD5C2465706C620d64E8` (same address as dETH — CREATE from the same deployer at nonce 0 on both chains; different bytecode, verified) |
| LimitOrderExecutor | Unichain Sepolia | `0xF9fcA2ff15F4EF954B4dAc7F39e6920798EEF737` (funded 0.005 ETH) |

### Full loop, proven on-chain (12 Nov 2026)

**ABOVE order (sell 10 dETH at ≥ $2,100):** approve `0xd6727acc...` → createOrder
`0xcecffb7a...` (order 1) → mirrored on Lasna (activeOrders=[1]) → feed set to
$2,100 `0x2857c984...` (block 67612517) → **fill
`0x58483da350e42e88b921a34e86f51d8ff1fb683a62b90829bcc4f2f13713aa54`** (block
67612519): `OrderFilled` order 1, executor `0xF9fcA2...`; `OrderExecuted`
amountIn 10 dETH, amountOut ~19,920 dUSD.

**BELOW order (sell 10 dETH at ≤ $1,900):** approve `0xc7734d7f...` →
createOrder `0x8df89618...` (order 2) → mirrored on Lasna (activeOrders=[2])
→ feed set to $1,900 `0xbece147c...` (block 67612613) → **fill
`0xd8ac27792f0366d3f87e4d898d33e135bbc30d4f7576d0c7199e59559d45ef83`** (block
67612616): `OrderFilled` order 2; deployer dUSD 980,019,920 → 980,039,800
(+19,880 dUSD).

The execution price is set by the AMM pool (~$1,996 at the time), not the
feed — the feed only triggers. The 0.3% fee + constant-product slippage
explain the difference from the theoretical $21,000 / $19,000.

## Verified constants (checked live 12 Nov 2026)

| Item | Value |
|---|---|
| Unichain Sepolia | Chain ID 1301, RPC `https://sepolia.unichain.org` |
| Reactive Lasna | Chain ID 5318007, RPC `https://lasna-rpc.rnk.dev`, explorer `https://lasna.reactscan.net` |
| Ethereum Sepolia | Chain ID 11155111 |
| Reactive SYSTEM contract | `0x8888888888888888888888888888888888888888` (same on mainnet + Lasna) |
| Unichain Sepolia callback proxy | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` (current docs; the `0x9299…` address from a May 2026 example is outdated) |
| Chainlink ETH/USD, Sepolia (production feed) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` — `latestRoundData` returned $2,050.72 at check |
| lREACT faucet (Sepolia) | Send Sepolia ETH to `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` — 1 ETH → 100 lREACT, max 5 ETH/tx |
| reactive-lib | `Reactive-Network/reactive-lib-omni` v0.1.0 (`@reactive/=lib/reactive-lib-omni/`) |

## What is still a mock (honest stand-ins)

| Mock | Production replacement |
|---|---|
| `MockPriceFeed` (owner moves the price) | Real Chainlink ETH/USD Sepolia `0x694AA…` — same interface, feed address is a deploy-time parameter |
| `DemoAMM` (demo constant-product pool) | Real Uniswap v4 on Unichain Sepolia — executor only needs `getAmountOut` + `swap` |
| `DemoToken` dETH/dUSD | Real tokens |

## Run the tests

```bash
forge test
```

33 tests: AMM math/fees, registry lifecycle (create/cancel/fill/expiry),
executor auth (proxy-only, reactive-only, nonce replay, double fill),
reactive mirroring (above/below triggers, cancel, CRON sweep, unknown logs),
and a 256-run invariant suite (escrow accounting, order conservation, AMM
`k` non-decreasing). The reactive tests etch a `MockSystem` at the SYSTEM
address so subscribe/callback requests are observable.

## Deploy (testnet only)

Deployer (fresh, testnet-only key in `deployer.key.json`, chmod 600, never
used on mainnet): `0xf64712c04cd1D62322A09B4609F6F33Bc8335585`

```bash
bash script/deploy.sh      # deploys everything, saves addresses to deployments.env
bash script/demo-loop.sh   # order -> price move -> reactive trigger -> callback fill
```

Deploy order: tokens + feed + AMM + registry on Unichain Sepolia →
reactive on Lasna (funded 2 lREACT) → executor on Unichain Sepolia (funded
0.005 ETH) → wire `setExecutor` on both sides. The demo loop creates an ABOVE
order (sell 10 dETH at ≥ $2,100), moves the feed, waits for the fill, then
repeats with a BELOW order (≤ $1,900). All tx hashes land in `deploy-log.txt`
and `demo-log.txt`.

Funding used: 0.0099999 Unichain Sepolia ETH (deploys + demo) and 0.049 Sepolia
ETH (→ 5.145 lREACT via the faucet contract).

## Blocker: faucets (RESOLVED 12 Nov 2026)

The deployer held 0 testnet ETH until the owner claimed 0.01 Unichain Sepolia
ETH from the Superchain faucet (sign-in + connect wallet, 0.01 ETH/24h drip)
and 0.05 Sepolia ETH from the Google Cloud Web3 faucet; 0.049 Sepolia ETH was
swapped to 5.145 lREACT via the faucet contract
(`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`). `faucet.unichain.org` was down
entirely; paste-address-only routes (thirdweb, ethfaucet.com) all failed.

```bash
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 --rpc-url https://ethereum-sepolia.publicnode.com --private-key <key> "request(address)" 0xf64712c04cd1D62322A09B4609F6F33Bc8335585 --value 0.1ether
```

## Submission (ready — video + form left)

- Track: Set It and Forget It. Deadline: 5 Dec 2026 (DoraHacks).
- Repo: `reactive-limit-orders` (public). Deployed addresses + full-loop tx
  hashes: see [Live deployment](#live-deployment-12-nov-2026).
- Remaining: demo video < 3 min + DoraHacks submission form.
- Judging: Execution (on-chain reactive txs + callbacks), Integration,
  Usefulness, Craft — all equally weighted.
