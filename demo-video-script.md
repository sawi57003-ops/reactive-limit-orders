# Demo video script — Set-and-Forget Limit Orders

**Video:** [demo-video.mp4](https://raw.githubusercontent.com/sawi57003-ops/reactive-limit-orders/master/demo-video.mp4)
(1920x1080, H.264, 2:05, English narration, one voice)

**Repo:** https://github.com/sawi57003-ops/reactive-limit-orders
**Track:** Set It and Forget It — Reactive Omni Buildathon (DoraHacks, 5 Nov – 5 Dec 2026)

## Slide 1 — Title (~10s)

> Set-and-Forget Limit Orders. A limit-order bot with no server, no keeper, no one watching the charts — built on Reactive Network for the Reactive Omni Buildathon.

## Slide 2 — Problem (~17s)

> Today, a limit order means trusting a bot. You run a server, or you pay a keeper, or you leave funds on a centralized exchange. If the bot dies, the order dies with it. We wanted the opposite: set the price once, walk away, and let the chain itself do the watching.

## Slide 3 — How it works (~22s)

> Here's the loop. You escrow tokens in the Limit Order Registry on Unichain Sepolia. A reactive contract on Reactive's Lasna testnet mirrors your order from the registry's events. It watches the price feed — and when your threshold crosses, it fires a callback that executes the swap on-chain and pays you. No server. No keeper. The chain watches itself.

## Slide 4 — Security (~19s)

> The executor only accepts callbacks from Reactive's official proxy, only from our reactive contract, and only once per nonce — so a fill can't be replayed or faked. Escrow is returned if you cancel, expired orders are swept by a built-in cron, and the whole flow is covered by thirty-three Foundry tests.

## Slide 5 — Live deployment (~11s)

> This isn't a mockup. It's deployed on Unichain Sepolia and Lasna testnets, with real contracts, real callbacks, and real transactions you can verify on the explorers.

## Slide 6 — Proof: Order 1, ABOVE (~20s)

> Order one: sell ten d-E-T-H if the price reaches twenty-one hundred dollars. The order mirrored to Lasna instantly. We moved the feed to twenty-one hundred, and the reactive contract fired. Fill confirmed on-chain: ten d-E-T-H sold for about nineteen thousand nine hundred twenty d-U-S-D.

Full hashes: approve `0xd6727acc1eec37d77892f7c7a51c84d7c86eeb9baa32e3ea1d9757ae1a92a7a7`,
createOrder `0xcecffb7ad206f6a3fcce190100ae42fb49245d6962fec5bccfd514f8f6c300d9`,
feed → $2,100 `0x2857c984d9ef9d0684a1284a9f047313c5f897b0c23d7cab913b2aee065290b3` (block 67612517),
fill `0x58483da350e42e88b921a34e86f51d8ff1fb683a62b90829bcc4f2f13713aa54` (block 67612519).

## Slide 7 — Proof: Order 2, BELOW (~17s)

> Order two: the other direction. Sell ten d-E-T-H if the price falls to nineteen hundred. Same loop, same result — filled on-chain for about nineteen thousand eight hundred eighty d-U-S-D. Both directions work, with zero infrastructure in between.

Full hashes: approve `0xc7734d7f9362ae620fea9feb35984aa57c72b164eb730344ab048d062d1e9c1f`,
createOrder `0x8df896186d796fe0bdadf8ac0f48e91b2547fc8276c85375c7a9f0eb30dbbcb6`,
feed → $1,900 `0xbece147c388b76d707cf236c1c11d1c0e233025721a8e8cb0ec1772100d51b89` (block 67612613),
fill `0xd8ac27792f0366d3f87e4d898d33e135bbc30d4f7576d0c7199e59559d45ef83` (block 67612616).

## Slide 8 — Closing (~9s)

> Set it and forget it. The code is open source — link in the description. Built during the Reactive Omni Buildathon, November twenty twenty-six.

## Production notes

- Slides rendered with Python PIL (Noto Sans), dark theme `#0B1220`, teal/green accent.
- Narration: single English voice (Helio, `avocado_v2:MAI_03`) via Meta Shortwave TTS.
- Assembled with ffmpeg 8.1.2 (H.264, CRF 23, 30 fps, AAC). No background music.
- Source files: `video/render_slides.py`, `video/narration/`, `video/audio/`, `video/assemble.sh`.
