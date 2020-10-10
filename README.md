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

-   **Home Proxy**: proxy on xDAI/Sokol.
-   **Foreign Proxy**: proxy on Ethereum Mainnet/Goerli.
-   **Plaintiff**: the dispute requester, interested in changing the current arbitrable outcome.
-   **Defendant**: the user interested in keeping the current arbitrable outcome.

## Disclaimers

-   Users willing to request a dispute **SHOULD** watch the arbitrable contract on the Home Network to know when requesting dispute is possible.
-   However, if there is a time limit for when the dispute can be requested, the Arbitration Proxies **CANNOT** guarantee the dispute request will be notified in time. This is due to the asynchonous nature of cross-chain communication.
-   Once the dispute is created, their lifecycle will happen entirely on Ethereum.

## High-Level Algorithm

### Handshaking

1. Arbitrable contracts **MUST** register themselves in the _Home Proxy_ before any dispute can be created.
    1. Contracts **CAN** register the dispute params (namely `metaEvidence`, and `arbitratorExtraData`) at a contract level or on a per-item basis or a mix of both.
1. The _Home Proxy_ **MUST** forward the params to the _Foreign Proxy_.
1. Once an arbitrable item is subject to a dispute, the arbitrable contract **SHOULD** inform the _Home Proxy_.
1. The _Home Proxy_ **MUST** forward the disputable status of the item to the _Foreign Proxy_.

At this point users **CAN** request a dispute for that given arbitrable item.

### Dispute Request

1. In order to request a dispute, the _plaintiff_ **MUST** pay for the current arbitration cost beforehand.
1. The dispute request **MUST** be relayed to the _Home Proxy_.
1. The _Home Proxy_ **MUST** check if the _Arbitrable_ contract accepts the dispute.
    1. The arbitrable contract **CAN** accept or reject the request according to its own rules.
    1. If the dispute request is accepted, the information **MUST** be relayed to the _foreign proxy_, which will proceed to create the dispute.
        1. The _home proxy_ **MUST** inform the arbitrable contract of the dispute request.
        1. The _foreign proxy_ **MUST** now wait for the _defendant_ to pay for the arbitration cost up to `feeDepositTimeout` seconds.
            1. If the _defendant_ pays the due amount in time, then the dispute **SHOULD** be created.
                1. If the dispute could be created
                    1. Then the _foreign proxy_ **MUST** relay that information to the _home proxy_.
                    1. Once the final ruling is recived, it **MUST** be relayed to the _home proxy_.
                        1. The _home proxy_ **MUST** rule over the arbitrable item.
                1. Otherwise, if the dispute creation fails
                    1. Then the _foreign proxy_ **MUST** relay that information to the _home proxy_.
                        1. The _home proxy_ **MUST** inform the arbitrable contract that the dispute could not be created.
            1. Otherwise, the _plaintiff_ **MUST** be considered the winner
                1. The _foreign proxy_ **MUST** forward the ruling to the _home proxy_.
                1. The _home proxy_ will rule over the arbitrable item.
    1. Otherwise, the rejection **MUST** also relayed to the _foreign proxy_.
        1. The _plaintiff_ will be reimbursed of any deposited fees.

## State Charts

### Home Proxy

```
(I) Means the initial state.
[condition] Means a guard condition.

     Receive Request     +----------+
   +-------------------->+ Rejected |
   |   [Rejected]        +-----+----+
   |                           |
   |                           |
   |                           | Relay Rejected
+-(I)--+                       |
| None +<----------------------+
+--+---+                       |
   |                           |
   |                           | Receive Dispute Failed
   |                           |
   | Receive Request     +-----+----+                     +--(F)--+
   +-------------------->+ Accepted +-------------------->+ Ruled |
      [Accepted]         +----------+   Receive Ruling    +-------+
```

### Foreign Proxy

```
(I) Means the initial state.
(F) Means a final state.
[condition] Means a guard condition.

                                                                               [Defendant did not pay]
                                                                                      |
+-(I)--+   Request Dispute   +-----------+                  +----------------+        |        +--(F)--+
| None +-------------------->+ Requested +----------------->+ DepositPending +---------------->+ Ruled |
+------+    [Registered]     +-----+-----+    [Accepted]    +-------+--------+                 +---+---+
            [Disputable]           |                                |                              ^
                                   |                                |                              |
                                   | [Rejected]                     | [Defendant Paid]             |
                                   |                                |                              | Rule
                                   |                                |                              |
                                   |          +--(F)---+            |          +---------+         |
                                   +--------->+ Failed +<-----------+--------->+ Ongoing +---------+
                                              +--------+      |           |    +---------+
                                                              |           |
                                                  [Dispute Failed]      [Dispute Created]
```

## Available Proxies

### Binary Arbitration

Used by arbitrable contracts which expect a binary ruling for dispute.

#### Deployed Addresses

**Home Proxy:**

-   Sokol: `<none>`
-   xDai: `<none>`

**Foreign Proxy:**

-   Goerli: `<none>`
-   Mainnet: `<none>`

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
