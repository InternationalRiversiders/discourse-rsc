# Event prediction settlement and navigation (2026-10-06)

Polymarket `/v2/resolutions` serves multiple result shapes. Native V2/terminal
CTF rows provide `payouts`, `resolved_at`, and `resolved_block`. UMA lifecycle
rows instead provide a final oracle `price`, `question_id`, transaction/log
provenance, and `last_update_timestamp`. Requiring only the first shape left
resolved UMA positions awaiting confirmation indefinitely.

The adapter now accepts final UMA values 0, 0.5e18 and 1e18, corresponding to
[0,1], [1,1] and [1,0]. These are oracle settlement amounts, never market prices.
A resolved status, no extended review, valid provenance and a past timestamp
are required. The provider also checks the CLOB condition ID, held token IDs,
and winner flags. Neg-risk adapters may use different question IDs for the
same condition, so cross-provider matching uses the condition and tokens.
An unfamiliar final result stays pending and is logged rather than guessed.

Official references:
- https://data-api.polymarket.com/v2/docs
- https://github.com/Polymarket/uma-ctf-adapter/blob/main/src/UmaCtfAdapter.sol

Settlement runs daily by user preference. Each batch covers all unsettled
watched markets, with holdings first, spacing jobs five seconds apart. A newly
observed final result gets one follow-up after 125 seconds in the same batch;
matching observations at least two minutes apart are required. Errors use the
regular job retry mechanism. Markets which are still unresolved wait for the
next daily batch. Catalog discovery remains independent at ten minutes, and
trade quotes still fetch current data and check resolution before trading.
No real Polymarket orders or wallet keys are involved.

Existing market locks, balanced ledger postings, per-position idempotency,
settlement trades, and notification outbox delivery remain in place. Winning
shares redeem at their final payout; losing shares redeem at zero. A split
result redeems half the shares, not a refund of the original purchase cost.

The landing route now opens market trading. Member tabs are 行情交易, 赛事预测,
事件预测, 排行榜, RSC钱包. The wallet page is `/rsc/account`; the existing
`/rsc/wallet.json` API stays compatible. Old `/rsc?journal_id=...` notifications
redirect to the wallet with their journal parameter. Only the wallet route
owns that Ember query parameter, avoiding aborted index transitions clearing it.

Regression coverage includes actual UMA-shaped results, pending/invalid
provenance rejection, CLOB disagreement/token mismatch, delayed confirmation,
split payouts, idempotency, balanced entries, all-market daily batches and
one follow-up per batch. Browser coverage uses intercepted money APIs and
checks landing/sidebar navigation, legacy journal redirects, tab order,
wallet/sports/market isolation, paging/search, desktop/mobile and light/dark.
