# Order Status: Salesforce Integration

Keeps Salesforce current with orders from the external **Orders** system, so a CX agent can open an Account and see its orders, their status, their lines, and every status event that came through, without leaving Salesforce.

```
 Orders ──POST /services/apexrest/orders/events──▶ OrdersWebhookResource      (authenticated Apex REST)
            Orders-Signature: hex(HMAC-SHA256)        │ 1. verify HMAC of the raw body ─ 401 if wrong
                                                      │ 2. parse + validate ─────────── 400 if malformed
                                                      ▼
                                               OrderEventService            (one transaction, row locks)
                                                      │ 3. duplicate?  → count the delivery, change nothing
                                                      │ 4. first time we see the order/account → create it
                                                      │ 5. newer than what we hold? → apply status, else record as Ignored
                                                      │ 6. write External_Order_Event__c (history)        ─ 200
                                                      ▼
                                               OrderDetailsSyncJob          (async Queueable, callouts)
 Orders ◀──GET /orders/{id}, /accounts/{id}───────────┘ amount, participant, lines, real account name

 Agent clicks "Sync Orders" on Account ──▶ AccountOrdersBackfillJob ──GET /accounts/{id}/orders (paged)──▶ Orders
                                          (orders that existed before the subscription / never sent an event)
```

---

## Setup

### Prerequisites
- A free **Salesforce Developer Edition** org.
- **Salesforce CLI** (`sf`). Recent versions are recommended. Older CLIs deploy correctly but may print a harmless `Missing message metadata.transfer:Finalizing` error against newer orgs. Check with `sf project deploy report`.
- `openssl` and `python3`, only for the curl simulation.

### 1. Deploy
```bash
git clone https://github.com/MarcosAugustoFl/salesforce-order-assignment.git
cd salesforce-order-assignment

sf org login web --alias order-assignment            # log in to your Developer Edition org
sf project deploy start --source-dir force-app --target-org order-assignment
```

> The deploy includes the **Account Layout** page layout, which adds the "Orders System" section, the *External Orders* related list and the *Sync Orders* button. It was retrieved from a fresh Developer Edition org and replaces that org's default Account layout.

### 2. Post-deploy configuration
```bash
# Give yourself access to the objects, the endpoint and the Sync button
sf org assign permset --name Orders_Integration --name Orders_Agent --target-org order-assignment

# Optional: run the tests (32 tests, ~92% coverage)
sf apex run test --test-level RunLocalTests --result-format human --code-coverage --target-org order-assignment
```

| Item | What to do | Needed for |
|---|---|---|
| **Shared secret** | Already deployed as `Orders_Integration_Setting__mdt.Default` (protected Custom Metadata) with the exercise fixture `orders-takehome-2026`. To change it: Setup → Custom Metadata Types → Orders Integration Setting → Default. | Signature verification |
| **Permission sets** | `Orders_Integration` for the user Orders authenticates as. `Orders_Agent` for CX users. | Everything |
| **Named Credential `Orders_API`** | Deployed, pointing at the fictional `https://orders.example.test/v1`. To call a real or mock server: Setup → Named Credentials → *Orders API* → change the URL. Then on External Credentials → *Orders API* → principal *Orders_API_Principal*, add an Authentication Parameter named **`Token`** (any non-empty value for the mock). Secrets are never in source. | Optional live detail sync / backfill. Without it, callouts fail gracefully (see below). |
| **External Client App (OAuth)** | Only needed to call the endpoint the way a real Orders sender would. See [Authenticating as the integration user](#authenticating-as-the-integration-user). The simulation works without it. | Optional |

No Remote Site Setting is needed: callouts go through the Named Credential.

---

## Simulating events

Both options send the spec's sample sequence (five events, including the duplicate `evt_001` and the out-of-order `evt_003`) through the real handler, including signature verification.

### Option A: anonymous Apex (simplest)
```bash
sf apex run --file scripts/apex/simulate-sample-events.apex --target-org order-assignment | grep USER_DEBUG
```
Expected output (abridged):
```
HTTP 200 {"outcome":"APPLIED","eventId":"evt_001"}
HTTP 200 {"outcome":"APPLIED","eventId":"evt_002"}
HTTP 200 {"outcome":"DUPLICATE","eventId":"evt_001"}
HTTP 200 {"outcome":"APPLIED","eventId":"evt_004"}
HTTP 200 {"outcome":"APPLIED","eventId":"evt_003"}
Forged event -> HTTP 401 {"error":"invalid_signature", ...}
ORDER ord_52ab10 status=cleared ...
ORDER ord_77d1e9 status=sent ...
EVENT evt_001 inProgress outcome=Applied deliveries=2      ← processed once, delivered twice
```

### Option B: curl over HTTPS (real request to the deployed endpoint)
```bash
./scripts/curl/send-sample-events.sh order-assignment
```
It signs each line of `scripts/data/sample-events.ndjson` with `openssl` and POSTs it to `/services/apexrest/orders/events`. It then sends:
- a **late, older event** for `ord_77d1e9` (`inProgress` from 2026-10-11, arriving after `sent` from 2026-10-12). The response is `IGNORED` and the status stays `sent`.
- a **tampered body**. The response is `401`.

If you run it after Option A, every sample event returns `DUPLICATE`, which shows idempotency across requests.

By default it authenticates with your CLI session token. To authenticate the way Orders would, set `ORDERS_CLIENT_ID` and `ORDERS_CLIENT_SECRET` (see below).

**Reset:** `sf apex run --file scripts/apex/reset-demo-data.apex` deletes the demo Account, which cascades to its orders, lines and events.

### Seeing it
Open **Accounts → AC-260914-017-2231**. The account is created from the first event, and its name is replaced with the real one once Orders is reachable.
- The **External Orders** related list shows each order with status, amount and "status as of".
- Open an order to see its **Lines** and its **Events**: every event received, its outcome (*Applied* or *Ignored (older)*), the delivery count and the raw payload.
- **Sync Orders** (Account action button) pulls all of the account's orders from Orders.

With the default fictional Named Credential URL, the background detail sync retries 3 times, one minute apart, and then writes `Sync_Error__c` on the order ("Could not read order details…"). Status stays correct throughout. That is the intended degraded mode.

---

## Design

### What is stored vs. read live, and why

| Data | Where | Why |
|---|---|---|
| **Order header**: status, amount, currency, participant, created/updated dates (`External_Order__c`) | Stored | The ask is "never leave Salesforce". Stored data works in related lists, list views, reports, search, and when Orders is down. Status is what agents look at most, and events keep it current for free. |
| **Order lines** (`External_Order_Line__c`) | Stored, refreshed on every applied event | Same `GET /orders/{id}` call that gives us the amount, so no extra API cost. Reading them live would cost a callout per page view against a 60 requests/minute limit. |
| **Event history** (`External_Order_Event__c`) | Stored | Agents can see what came through and when. It also gives idempotency (unique `Event_Id__c`) and an audit trail (raw payload). |
| **Account** (standard `Account` + `Orders_*` fields) | Matched or created by `Orders_Account_Id__c` | Orders is where accounts are created. An event for an unknown account creates a placeholder, which is renamed from `GET /accounts/{id}`. |
| Nothing read live in the UI | n/a | A live read on every page view would add load, latency and failure modes for little gain, since events plus refresh keep the copy current. See left-out items. |

**Custom `External_Order__c`, not the standard `Order` object.** Standard `Order` needs a Contract or Pricebook and an `EffectiveDate`, and its Draft/Activated status model doesn't match these statuses. A custom object models exactly what Orders sends. All children are **master-detail**, so sharing follows the Account: an agent who can see the Account sees its orders.

### Correctness under at-least-once, out-of-order delivery
- **Duplicates:** `External_Order_Event__c.Event_Id__c` is a **unique** external ID. A redelivered event is detected, returns `200 DUPLICATE`, and only increments `Delivery_Count__c`. The unique index is the final guard if two copies arrive at the same instant: one insert fails, that request rolls back and returns 500, and the sender's retry is then a normal duplicate.
- **Ordering:** each order stores `Status_As_Of__c`, the timestamp of the information its status came from. `OrderStatus.supersedes()` applies a new status only if it is **newer**. On an exact tie, the status further along the lifecycle wins, since statuses only move forward, and `returned` ranks last. Older events are still stored in the history as *Ignored (older)*.
- **One rule for every source:** the webhook (event `occurredAt`), the detail sync and the backfill (API `updatedAt`) all go through `supersedes()`. An API response fetched before a newer event arrived can never undo that event.
- **Concurrency:** existing orders are read `FOR UPDATE`, so two requests for the same order run one after the other instead of both reading the old status.
- **No `order.created` event:** the first event for an order creates it. Orders that existed before the subscription, or whose events were lost (the sender suspends after 3 failed retries), are covered by the **Sync Orders** backfill.

### Endpoint exposure: authenticated Apex REST
Orders calls `/services/apexrest/orders/events` with an OAuth access token for a dedicated **integration user**, obtained with the Client Credentials flow from an External Client App. I chose this over a public Site because:
- There are **two independent layers**: OAuth identifies the caller, and the HMAC proves the body is authentic and unmodified. A leaked secret alone isn't enough.
- **Least privilege**: the integration user only has `Orders_Integration`. A Site guest user is a public, shared identity, and every grant to it is a grant to the internet.
- **Built-in audit and controls**: login history, IP restrictions, and token revocation without changing the secret.

The tradeoff is that the sender must support OAuth (get and refresh a token). Many webhook senders only support a static secret. That's the first question below, and if the answer is "static only", a Site endpoint with HMAC as the only check is the fallback. The code is the same; only the exposure changes.

### HTTP responses (matter because the sender retries non-2xx and then suspends)
| Code | When | Sender behavior |
|---|---|---|
| `200` | Applied, Ignored (older) or Duplicate | Done. All three are successful handling, so no retry storms. |
| `401` | Missing or invalid signature | Nothing is stored. |
| `400` | Signed but invalid (bad JSON, missing field, unknown type or version) | Sender bug; a retry won't help. Message names the field. |
| `500` | Unexpected failure (e.g. lock timeout) | Everything is **rolled back** (savepoint), so the retry starts clean. |

The webhook makes **no callouts**: it only does local work, comfortably inside the sender's 10-second timeout. Enrichment is async.

### Calling Orders (rate limit 60 requests/minute)
- `OrderDetailsSyncJob` makes at most **40 order callouts per run**. The rest continue in a follow-up job **1 minute later**.
- A **429** stops the run immediately and reschedules after `Retry-After`, rounded up to minutes (the platform delay is 0–10 minutes).
- **5xx and network errors** retry up to 3 attempts. **404 and other 4xx** are not retried. Either way the error is written to `Sync_Error__c`, so an agent can see the details may be stale. A failed enrichment never affects the status.
- All callouts in a run happen **before any DML**, because Apex doesn't allow a callout after uncommitted work.
- The backfill reads one page (50 orders) per run and chains the next page. When done, it hands orders that never had their details read to the detail sync.

### Code organization
| Layer | Classes | Responsibility |
|---|---|---|
| HTTP in | `OrdersWebhookResource` | HTTP ↔ service. Status codes, rollback. No business logic. |
| Security | `OrdersSignatureVerifier`, `OrdersIntegrationConfig` | HMAC over raw bytes, constant-time compare. Where the secret lives. |
| Domain | `OrderEvent`, `OrderStatus` | Parse and validate an event. The single "which information wins" rule. |
| Service | `OrderEventService` | Bulk-safe processing: dedupe, lock, create, apply, record history. |
| HTTP out | `OrdersApiClient` | Typed GETs through the Named Credential; errors carry status and Retry-After. Knows nothing about records. |
| Persistence | `ExternalOrderWriter` | Writes API snapshots (orders, lines, accounts) with the same supersede rule and locks. |
| Async | `OrderDetailsSyncJob`, `AccountOrdersBackfillJob`, `QueueableChain` | Enrichment, backfill, chaining, retries, rate limiting. |
| UI | `OrdersSyncController`, `syncOrders` (headless LWC quick action), layouts | Sync button; related lists. |
| Utility | `JsonReader` | Strict JSON reading with precise error messages ("event.occurredAt is required"). |

**Bulk safety:** `OrderEventService.process()` takes a list and uses a fixed number of queries and DML statements whatever its size. A test pushes 200 events across 100 orders, deliberately newest first, in one call and asserts ≤ 4 queries and ≤ 4 DML statements. The REST endpoint receives one event per request (that's the protocol), but the service doesn't assume it.

**Sharing:** integration services are `without sharing` on purpose. A system sync must see every Account and order to match correctly; a sharing-filtered query could miss a record and then fail on a unique key or create a duplicate. Access is controlled by permission sets instead. The agent-facing controller is `with sharing` and queries `WITH USER_MODE`, and its test runs as a Standard User with `Orders_Agent`.

**Secret storage:** the outbound Bearer token is in a **Named Credential / External Credential**. The inbound HMAC secret is in **protected Custom Metadata**, because Apex can never read Named or External Credential secrets (they're only injected into outbound callouts), and we need the secret to recompute the HMAC.

### Authenticating as the integration user
1. Create a user for the integration (ideally a *Salesforce Integration* license with the *Salesforce API Integration* permission set license) and assign **`Orders_Integration`**.
2. Setup → **External Client App Manager** → New External Client App → enable OAuth. Scope: *Manage user data via APIs (api)*. Enable **Client Credentials Flow**. A callback URL is required by the form but unused (`https://localhost`).
3. In the app's **Policies**: enable Client Credentials Flow and set **Run As** to the integration user.
4. Use the consumer key and secret:
   ```bash
   ORDERS_CLIENT_ID=... ORDERS_CLIENT_SECRET=... ./scripts/curl/send-sample-events.sh order-assignment
   ```
   The app isn't in source: its consumer secret is generated per org, and app creation policies differ between orgs.

---

## Questions I would have asked

| # | Question | Assumption I made | Why |
|---|---|---|---|
| 1 | **Can the Orders sender authenticate with OAuth (get and refresh a token), or only sign with a static secret?** | It can use OAuth Client Credentials, so I built an authenticated endpoint. | Two layers of security and least privilege. If it can't, the same code works behind a public Site with HMAC as the only check. |
| 2 | **Is there really no `order.created` event, and will we get events for orders that existed before we subscribed?** | No created event, and no history replay. | The event list starts at `inProgress`. So the first event creates the order, and **Sync Orders** backfills from the list API. |
| 3 | **Do Salesforce Accounts already exist for Orders accounts, and how should they be matched?** | Orders is the source of truth for accounts (the spec says accounts are created there). Match on `Orders_Account_Id__c` and create a placeholder if missing. | With no shared key, matching by name would be guesswork. Auto-creating guarantees no order is dropped. An admin can link an existing Account by filling in *Orders Account Id* before the first event. |
| 4 | **Are `occurredAt` (events) and `updatedAt` (API) from the same clock, and can two events for one order share a timestamp?** | Same clock, comparable. Ties are possible and broken by lifecycle position. | It's the only way to order information from two sources. The tie-break follows the spec ("statuses never move backward"). |
| 5 | **Does `updatedAt` change only on status changes, or on any edit (e.g. amount)?** | Any edit. | Safe either way: a newer snapshot with the same status just moves `Status_As_Of__c` forward. |
| 6 | **Should agents see order lines? Do lines have their own status events?** | Yes, show them. No separate line events; lines are refreshed whenever an order event is applied. | The spec returns lines from `GET /orders/{id}`, which we call anyway for amount and participant. Nobody said lines are unwanted, and they cost nothing extra. |
| 7 | **What should the endpoint return for a signed but malformed event?** Does a 4xx count toward suspending the subscription? | Return `400`. | A malformed event is a sender bug that a retry won't fix. If 4xx also counts toward suspension, I'd switch to `200` plus a dead-letter record, so one bad event can't stop the whole feed. |
| 8 | **Is a backward status change ever valid** (apart from `returned`, e.g. a correction)? | No. Order by time; the lifecycle is only a tie-breaker. | The spec says statuses never move backward. If corrections exist, the time-based rule already accepts them (the later event wins). |
| 9 | **Volume:** events per minute at peak, orders per account? | Moderate: tens of events per minute, hundreds of orders per account. | Decides between Queueables per event (built) and a batched, coalesced sync (see left out). |
| 10 | **Retention:** how long should event history and raw payloads be kept? Is any field PII (e.g. `participantRef`)? | Keep everything; `participantRef` is an opaque reference, not PII. | Storage in a Developer Edition org isn't a concern. In production I'd add an archive or purge job. |
| 11 | **Multi-currency:** do orders come in different currencies? | Possibly. Store the ISO code as text next to the amount. | Avoids requiring multi-currency in the org. Reports can still group by currency. |
| 12 | **Can an order move to a different account?** | No. | Master-detail is non-reparentable. If it can happen, reparenting would be enabled and handled in the writer. |

---

## What I deliberately left out (and what I'd do next)

- **Coalescing detail syncs.** Every applied event queues its own detail sync, so a burst of events for one order means several GETs for it. Next step: mark orders "needs refresh" and have one scheduled or chained job drain them in batches. That also gives a hard global rate limit instead of the per-chain one.
- **A global rate limiter.** Each job chain stays under 40 calls per minute, but several chains at once could exceed 60 per minute; a 429 is handled by rescheduling. A shared token bucket (Platform Cache or a custom setting) would prevent it.
- **Durable intake** (store the raw event first, process with a Platform Event or async job). Today processing happens inside the request, which is simpler and gives the sender a real result. If volume or processing time grew, I'd accept, store and return 202, then process async.
- **Error logging and alerting.** Errors go to `System.debug` and to `Sync_Error__c` and `Outcome_Detail__c` on records. Production would add a log object or Platform Event and an alert when the feed stops (the sender suspends after 3 failures, so silence is the failure mode to monitor).
- **Reconciliation job.** A nightly backfill of active accounts would catch events lost during a suspension without anyone clicking Sync.
- **Live "refresh now" in the UI** and a richer LWC (status timeline). A standard related list was enough per the brief.
- **Secret rotation** (accept two secrets during a rotation window), and **subscription id** validation (stored, not enforced).
- **External Client App as metadata.** Documented as a manual step instead (see above).
- **Backfill progress or error feedback to the agent.** The toast only confirms it started; failures are in debug logs.

## Repository layout
```
force-app/main/default/
  classes/              Apex (see "Code organization"); *Test.cls, OrdersTestData, OrdersApiMock are tests
  objects/              External_Order__c, External_Order_Line__c, External_Order_Event__c,
                        Account fields, Orders_Integration_Setting__mdt
  customMetadata/       Default setting (webhook secret fixture)
  namedCredentials/, externalCredentials/   Orders_API (outbound)
  permissionsets/       Orders_Integration, Orders_Agent
  layouts/, quickActions/, lwc/syncOrders   UI
scripts/
  apex/simulate-sample-events.apex   simulation via anonymous Apex
  apex/reset-demo-data.apex          remove demo data
  curl/send-sample-events.sh         simulation over HTTPS
  data/sample-events.ndjson          the spec's sample sequence, one event per line
```
