# Kleros Cross-Chain Arbitration for xDAI

Smart contract infrastructure to allow arbitrable dapps on xDAI to use Kleros on Ethereum as arbitrator.

## Architectural Overview

```

                                              +----------------+
                       +--------------------->+  Cross  Chain  |
                       v                      |   Arbitrable   |
            +----------+----------+           +----------------+
            |   Home Arbitration  |
            |        Proxy        |
            +----------+----------+
                       ^
  xDAI                 |
+----------------------|---------------------------------------------+
                       v
           +-----------+-------------------------------+
           |  xDAI/Ethereum AMB    +----------------+  |
           |                       |     Oracle     |  |
           |                       +----------------+  |
           |  +----------------+   +----------------+  |
           |  |     Oracle     |   |     Oracle     |  |
           |  +----------------+   +----------------+  |
           +-----------+-------------------------------+
                       ^
+----------------------|---------------------------------------------+
  Ethereum             |
                       v
            +----------+----------+
            | Foreign Arbitration |
            |        Proxy        |
            +----------+----------+
                       ^                      +------------+
                       +--------------------->+   Kleros   |
                                              +------------+
```

## Glossary

- **Home Proxy**: proxy on xDAI/Sokol.
- **Foreign Proxy**: proxy on Ethereum Mainnet/Goerli.

## High-Level Algorithm

1. Arbitrable items subject to dispute **MUST** be previously registered on the Home Proxy by the arbitrable contract.
   1. Registration **MUST** include the `MetaEvidence` for the arbitrable item.
   1. The `MetaEvidence` **MUST** be relayed to the Foreign Proxy.
1. In order to avoid pointless disputes, after registration the item is not disputable yet. It **MUST** be explicitly set as disputable by the arbitrable contract on xDAI.
   1. The arbitrable contract **MUST** provide a _deadline_ until which dispute requests are allowed.
1. Only after the Foreign Proxy receives the disputable status from the Home Proxy users **MIGHT** request a dispute.
   1. The _plaintiff_ (dispute requester) **MUST** pay for the arbitration cost beforehand.
1. If a dispute is requested on Ethereum, this is information **MUST** be relayed to the Home Proxy.
   1. The arbitrable contract **CAN** accept or reject the request according to its own rules.
   1. If the dispute request is accepted, the information **MUST** be relayed to the Foreign Proxy, which will proceed to create the dispute.
      1. The Home Proxy **MUST** inform the arbitrable contract of the dispute request.
      1. The Foreign Proxy **MUST** now wait for the _defendant_ to pay for the arbitration cost up to `feeDepositTimeout` seconds.
         1. If the _defendant_ pays the due amount in time, then the dispute **SHOULD** be created.
            1. If the dispute could be created
               1. Then the Foreign Proxy **MUST** relay that information to the Home Proxy.
                  1. The Home Proxy **MUST** inform the arbitrable contract that a dispute was created for that given arbitrable item.
               1. The dispute will follow the existing flow of the arbitrator.
                  1. Appeals (if any) **SHOULD** be handled exclusively on the Ethereum side.
               1. Once the final ruling is recived, it **MUST** be relayed to the Home Proxy.
                  1. The Home Proxy will rule over the arbitrable item.
            1. Otherwise, if the dispute creation fails
               1. Then the Foreign Proxy **MUST** relay that information to the Home Proxy.
                  1. The Home Proxy **MUST** inform the arbitrable contract that the dispute could not be created.
                  1. At this point, it will not be allowed any further dispute requests on Ethereum for that given arbitrable item.
                     1. The arbitrable contract **MIGHT** want to set the item as disputable once again, which will restart the flow at 2.
         1. Otherwise, the _plaintiff_ **MUST** be considered the winner
            1. The Foreign Proxy **MUST** forward the ruling to the Home Proxy.
            1. The Home Proxy will rule over the arbitrable item.
   1. Otherwise, the rejection **MUST** also relayed to the Foreign Proxy.
      1. The _plaintiff_ will be reimbursed of any deposited fees.
      1. No further dispute requests will be allowed for that given arbitrable item.

## State Charts

### Home Proxy

```
(I) Means the initial state.
(F) Means a final state.
(F~) Means a conditionally final state.
[x] Means a guard condition.

                                                                        [Request Rejected]
+----(I)-----+       +------------+       +----(F~)----+       +-----------+    |    +-----(F)----+
|    None    +------>+ Registered +------>+  Possible  +------>+ Requested +----+--->+  Rejected  |
+------------+   |   +-----+------+   |   +-----+------+   |   +-----+-----+    |    +------------+
            Registered     ^   Set Disputable     [Dispute Requested]           |
                           |                                                    | [Request Accepted]
                           |                                                    +----------+
                           |                                                               v
                           |                                                         +-----+------+   [Defendant did not pay]
                           |                                        +----------------+  Accepted  +----------------+
                           |                                        |                +-----+------+                |
                           |                                        |                      |                       |
                           |                                        |                      |                       |
                           |                                        | [Dispute Failed]     | [Defendant paid]      |
                           |                                        |                      |                       |
                           |                                        v                      v                       v
                           |                                  +----(F~)----+         +-----+-----+           +----(F)----+
                           -----------------------------------+   Failed   |         |  Ongoing  +---------->+   Ruled   |
                                  [Item is still disputable]  +------------+         +-----------+     |     +-----------+
```

### Foreign Proxy

```
(I) Means the initial state.
(F) Means a final state.
(F~) Means a conditionally final state.
[x] Means a guard condition.

                           [Received Disputable]       +---(F~)---+      [Before Deadline]        +-----------+
                                  +------------------->+ Possible +------------------------------>+ Requested |
                                  |                    +----+-----+       Request Dispute         +-----+-----+
                                  |                         ^                                           |
[Received Metadata]        +------+-----+                   | [Received Disputable]                     |
       +------------------>+ Registered |                   |                                           |
       |                   +------------+               +--(F~)--+       [Dispute Failed]               | [Dispute Created]
    +-(I)--+                                            | Failed +<-------------------------------------+
    | None |                                            +--------+                                      v
    +------+                                                                                   +--------+-------+
                                                                                    +----------+ DepositPending |
                                                                                    |          +-----------+----+
                                                                                    |                      |
                                                                                    |                      |
                                                                   [Defendant Paid] |                      | [Defendant did not pay]
                                                                                    |                      |
                                                                                    v                      v
                                                                                +---------+            +--(F)--+
                                                                                + Ongoing +------------| Ruled |
                                                                                +---------+    Rule    +-------+
```

## Available Proxies

### Binary Arbitration

Used by arbitrable contracts which expect a binary ruling for dispute.

#### Deployed Addresses

**Home Proxy:**

- Sokol: `<none>`
- xDai: `<none>`

**Foreign Proxy:**

- Goerli: `<none>`
- Mainnet: `<none>`

## Contributing

### Install Dependencies

```bash
yarn install
```

### Run Tests

```bash
yarn test
```

### Compile the Contracts

```bash
yarn build
```

### Run Linter on Files

```bash
yarn lint
```

### Fix Linter Issues on Files

```bash
yarn fix
```
