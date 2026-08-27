# Microsoft Store listing draft

## Product identity

- Display name: **Quant Scenario Studio by LAI ZEYU**
- Partner Center Publisher display name: **LAI ZEYU**
- Author credit shown in product/listing: **LAI ZEYU（来泽宇）**
- Internal/source engine: Aegis Forecast
- Category: Education (final choice remains a Partner Center input)
- Package/UI language: Simplified Chinese only (`zh-CN`)
- Supported architecture: x64
- Minimum OS: Windows 10 version 2004 (build 19041)
- Pricing: Free; no in-app purchases or subscriptions
- Account requirement: None

The reserved `Identity Name`, hard-locked technical Publisher
`CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8`, and `PublisherDisplayName` must be
compared with Partner Center immediately before packaging. The reserved product
is Store ID `9NWTH4KJX5GW` and Identity Name
`LAIZEYU.QuantScenarioStudiobyLAIZEYU`.
`PublisherDisplayName` is an identity field and must remain exactly `LAI ZEYU`;
the bilingual author credit belongs in About, listing copy and legal evidence.

## English Store listing

Language disclosure (place first):

> **The application interface is available in Simplified Chinese only.**

Short description:

> An offline Nasdaq-100 education studio with stable-hash deterministic
> synthetic scenarios, illustrative factor ranking and transparent limitations.

Full description:

> Quant Scenario Studio is a local scenario-research and education application
> authored by **LAI ZEYU（来泽宇）** and powered by the Aegis Forecast
> research engine. It uses the official Nasdaq-100 constituent snapshot dated
> 26 August 2026 (100 companies, 102 securities) together with deterministic
> synthetic values. It does not display live or latest market data.
>
> Explore transparent illustrative factor dimensions, neutral
> confirmation/invalidation references, generated-sample consistency checks and
> product limitations without creating an account or connecting to a network
> data service. The app contains no historical market observations or model training.
>
> Deterministic synthetic demo only. Not market data, investment advice, an
> order tool or a promise of future performance. The Store package contains no
> brokerage SDK, financial-account connector, order/cancellation capability,
> scheduler or automatic execution.

## 中文商店文案

短说明：

离线 Nasdaq-100 情景教育工具，内置稳定哈希确定性合成演示、说明性因子排名、生成样本一致性核对与本地隐私控制。

完整说明：

Quant Scenario Studio by LAI ZEYU 是一款由 **LAI ZEYU（来泽宇）**
创作的本地 Nasdaq-100 量化情景研究与教育工具，源自 Aegis Forecast
研究引擎。应用使用 Nasdaq 官方 **2026-08-26** 成分快照（100 家公司、
102 只成分证券）和确定性合成数值，不展示实时或最新市场数据。

主要功能：

- 完全离线使用随应用提供的确定性合成数据；
- 展示稳定哈希生成的说明性趋势、动量、相对、活动、结构与变化维度；
- 展示确认、参考、失效和敏感度阈值，不生成买卖指令；
- 从全部300行随包说明性结果实时重算指标，并展示生成边界、产品限制与防篡改本地审计记录；
- 无遥测、无云端账户、无券商 SDK 或金融账户连接；
- 可在隐私页面删除应用自有的 LocalState 运行数据。

本应用仅用于 research、education 和确定性 synthetic demo。它不提供投资建议、
收益保证、下单、撤单、自动交易或实盘执行。所有合成结果都不代表真实行情或
未来表现。

## Features

- 简体中文离线研究工作站
- 2026-08-26 Nasdaq-100 成分快照
- 确定性合成数据与可复现结果
- 说明性因子排名与生成样本一致性核对
- 中性研究阈值和明确限制说明
- 无遥测、无金融账户数据、可删除本地数据
- WinUI 3 与 WebView2 Windows 桌面体验

## Keywords

Exactly seven keywords (the current Partner Center field maximum; each is under
40 characters and the combined set is under 21 words):

`quant research`, `scenario analysis`, `Nasdaq-100`, `education`,
`synthetic data`, `technical factors`, `reproducible demo`

Official MSIX listing-field reference (checked 2026-08-27):
<https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/add-additional-information>.

## Required declarations

- Simplified-Chinese UI only.
- Deterministic synthetic demo; not live, latest or observed market data.
- Stable-hash generated values; no historical observations or model training.
- Research and education only; not investment advice.
- No account, brokerage software or network connection is needed.
- No financial-account access, transaction capability or personalized advice.
- No telemetry, advertising ID, cloud synchronization or background execution.

## URLs for submission

- Privacy policy: use the public URL for `docs/windows/PRIVACY_POLICY.md` only
  after merge and a signed-out browser test.
- Support: `https://github.com/lzy2767865503-pixel/aegis-forecast/issues`
- Website/source: `https://github.com/lzy2767865503-pixel/aegis-forecast`

Do not enter a branch-only or inaccessible privacy URL in Partner Center.

## Screenshot plan

The repository image `docs/assets/dashboard-demo.png` is a documentation-only
concept/demo image and must never be submitted or cited as Store acceptance
evidence.

The protected Windows Store workflow captures four different real views
(home, scenario ranking, privacy and About) directly through the exact installed
signed-development candidate's WebView2 at 100% Windows scaling. Both native QA
rounds must independently produce four distinct metadata-free PNGs of at least
1366x768, bound to the candidate SHA-256 and source commit. Only round 2 is
staged as four exact files under `artifacts/store-listing-public/`; after all
certificate/private-work-product cleanup those four PNGs are the sole files in
the Actions artifact `aegis-store-listing-screenshot-<run-id>-<run-attempt>`.
No MSIX, unsigned submission, certificate, WACK report or private lineage JSON
enters that artifact. Until that protected Windows run succeeds, the final Store
screenshots are explicitly **not ready**. The artifact is a short-lived transfer
bundle only: an operator must review and upload these exact PNGs in Partner Center.
It does not prove Microsoft validation, submission, certification or acceptance.

Any additional listing views, if later captured manually, must come from the same
exact verified candidate at 100% Windows scaling:

1. Home with the prominent deterministic-synthetic/non-market-data label.
2. Research detail with neutral confirmation/invalidation thresholds.
3. Generated-sample consistency view and limitations.
4. Privacy page showing no telemetry/no account connector and local deletion.
5. About page showing product, **LAI ZEYU（来泽宇）** and legal location.

Screenshots must contain no account identifiers, personal data, developer
overlays or unimplemented/live-market claims.

## Partner Center classification

Complete the live IARC and financial-content questionnaires from actual package
behavior. Select no transaction or financial-account capability. Final category,
markets and age rating remain Partner Center inputs.
