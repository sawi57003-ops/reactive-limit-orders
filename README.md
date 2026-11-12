# Set-and-Forget Limit Orders

Limit-order bot without a server, built on **Reactive Network (Omni)** for the
**Reactive Omni Buildathon** (DoraHacks, 5 Nov – 5 Dec 2026), track
**Set It and Forget It**. A user escrows demo tokens against a price threshold;
a reactive contract watches the price feed and, when the threshold crosses,
fires a callback that executes the swap on-chain. No bot, no keeper, no server.

> Status (12 Nov 2026): code complete, **33/33 Foundry tests pass** (unit +
> invariant). **Not deployed yet — blocked on testnet faucets** (see
> [Blocker](#blocker-faucets-need-a-browser) below). No mainnet anywhere.

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
0.01 ETH) → wire `setExecutor` on both sides. The demo loop creates an ABOVE
order (sell 10 dETH at ≥ $2,100), moves the feed, waits for the fill, then
repeats with a BELOW order (≤ $1,900). All tx hashes land in `deploy-log.txt`
and `demo-log.txt`.

Funding needed: ~0.05 Unichain Sepolia ETH (deploys + demo) and 0.1 Sepolia
ETH (→ 10 lREACT via the faucet contract).

## Blocker: faucets need a browser

The deployer holds 0 testnet ETH (agent + burn wallets also hold 0 on Sepolia /
Unichain Sepolia / Lasna). CLI faucet attempts all failed:

- `https://faucet.unichain.org/` — unreachable from this VM (HTTP 000).
- `https://app.uniswap.org/faucet`, Alchemy / QuickNode / Google Cloud /
  Chainlink Sepolia faucets — pages load (HTTP 200) but are JS apps needing
  wallet-connect / captcha / login; no public claim API found.

To unblock: claim Unichain Sepolia ETH + Sepolia ETH for the deployer address
above from a browser, then run `bash script/deploy.sh` and
`bash script/demo-loop.sh`. After funding, the lREACT exchange is one CLI call:

```bash
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 --rpc-url https://ethereum-sepolia.publicnode.com --private-key <key> "request(address)" 0xf64712c04cd1D62322A09B4609F6F33Bc8335585 --value 0.1ether
```

## Submission (prepared, not submitted)

- Track: Set It and Forget It. Deadline: 5 Dec 2026 (DoraHacks).
- Repo: `reactive-limit-orders` (public). Submission needs: repo link,
  deployed addresses, tx hashes of the full loop, demo video < 3 min.
- Judging: Execution (on-chain reactive txs + callbacks), Integration,
  Usefulness, Craft — all equally weighted.
