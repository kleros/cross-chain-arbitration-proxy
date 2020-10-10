const {ethers} = require("@nomiclabs/buidler");
const {solidity} = require("ethereum-waffle");
const {use, expect} = require("chai");
const {getEmittedEvent} = require("./helpers/events");
const {latestTime, increaseTime} = require("./helpers/time");
const HP = require("./helpers/HomeProxy");
const FP = require("./helpers/ForeignProxy");

use(solidity);

const {BigNumber} = ethers;

let arbitrator;
let arbitrable;
let homeProxy;
let foreignProxy;
let amb;

let governor;
let defendant;
let plaintiff;
let crowdfunderDefendant;

const contractMetaEvidence = "ipfs/X";
const contractArbitratorExtraData = "0x83";
const itemMetaEvidence = "ipfs/Y";
const itemArbitratorExtraData = "0x20";
const disputeTimeout = 600;

const feeDepositTimeout = 100;
const appealTimeout = 3600;
const sharedMultiplier = BigNumber.from(10000);
const winnerMultiplier = BigNumber.from(5000);
const loserMultiplier = BigNumber.from(20000);

const arbitrationFee = BigNumber.from(BigInt(1e18));

describe("Cross-Chain Binary Arbitration Proxies", () => {
  beforeEach("Setup contract", async () => {
    [governor, defendant, plaintiff, crowdfunderDefendant] = await ethers.getSigners();

    const Arbitrator = await ethers.getContractFactory("EnhancedAppealableArbitrator", governor);
    arbitrator = await Arbitrator.deploy(
      String(arbitrationFee),
      ethers.constants.AddressZero,
      contractArbitratorExtraData,
      appealTimeout
    );

    await arbitrator.deployed();
    // Make appeals go to the same arbitrator
    await arbitrator.changeArbitrator(arbitrator.address);

    const AMB = await ethers.getContractFactory("MockAMB", governor);
    amb = await AMB.deploy();

    const HomeProxy = await ethers.getContractFactory("HomeBinaryArbitrationProxy", governor);
    homeProxy = await HomeProxy.deploy(amb.address);

    const ForeignProxy = await ethers.getContractFactory("ForeignBinaryArbitrationProxy", governor);
    foreignProxy = await ForeignProxy.deploy(
      amb.address,
      arbitrator.address,
      feeDepositTimeout,
      sharedMultiplier,
      winnerMultiplier,
      loserMultiplier
    );

    const changeHomeProxyTx = await foreignProxy.changeHomeProxy(homeProxy.address);
    await changeHomeProxyTx.wait();

    const changeForeignProxyTx = await homeProxy.changeForeignProxy(foreignProxy.address);
    await changeForeignProxyTx.wait();

    const initializeTx = await homeProxy.initialize();
    await initializeTx.wait();

    const Arbitrable = await ethers.getContractFactory("MockArbitrable", governor);
    arbitrable = await Arbitrable.deploy(
      contractMetaEvidence,
      homeProxy.address,
      contractArbitratorExtraData,
      disputeTimeout
    );
  });

  afterEach("Advance block", async () => {
    // await advanceBlock();
  });

  describe("Handshaking", () => {
    it("Should emit the register events for the arbitrable contract on the home proxy after deploy and relay the data to the foreign proxy", async () => {
      const homeProxyEvents = await homeProxy.queryFilter(homeProxy.filters.ContractRegistered(arbitrable.address));
      const foreignProxyEvents = await foreignProxy.queryFilter(
        foreignProxy.filters.ContractReceived(arbitrable.address)
      );

      expect(homeProxyEvents.length == 1, "Did not register the arbitrable contract on the home proxy");
      expect(foreignProxyEvents.length == 1, "Did not relayed the arbitrable contract to the home proxy");
    });

    it("Should set the dispute params for the contract on the home proxy after deploy and relay the data to the foreign proxy", async () => {
      const actualParams = await foreignProxy.contractDisputeParams(arbitrable.address);

      expect(actualParams.metaEvidence).to.equal(contractMetaEvidence);
      expect(actualParams.arbitratorExtraData).to.equal(contractArbitratorExtraData);
    });

    it("Should not emit the register event for the arbitrable item when it does not have its own dispute params", async () => {
      const {txPromise} = await createItemNoParams();

      await expect(txPromise).not.to.emit(homeProxy, "ItemRegistered");
    });

    it("Should not set the dispute params for the arbitrable item when it does not have its own dispute params", async () => {
      const {receipt} = await createItemNoParams();
      const arbitrableItemID = getEmittedEvent("ItemCreated", receipt).args._arbitrableItemID;

      const actualParams = await foreignProxy.itemDisputeParams(
        foreignProxy.getArbitrationID(arbitrable.address, arbitrableItemID)
      );

      expect(actualParams.metaEvidence).to.equal("");
      expect(actualParams.arbitratorExtraData).to.equal("0x");
    });

    it("Should emit the register event for the arbitrable item when it has its own dispute params", async () => {
      const {txPromise, receipt} = await createItem(itemMetaEvidence, itemArbitratorExtraData);
      const arbitrableItemID = getEmittedEvent("ItemCreated", receipt).args._arbitrableItemID;

      await expect(txPromise)
        .to.emit(homeProxy, "ItemRegistered")
        .withArgs(arbitrable.address, arbitrableItemID, itemMetaEvidence, itemArbitratorExtraData);
      await expect(txPromise)
        .to.emit(foreignProxy, "ItemReceived")
        .withArgs(arbitrable.address, arbitrableItemID, itemMetaEvidence, itemArbitratorExtraData);
    });

    it("Should register the dispute params for the arbitrable item when it has its own dispute params", async () => {
      const {receipt} = await createItem(itemMetaEvidence, itemArbitratorExtraData);
      const arbitrableItemID = getEmittedEvent("ItemCreated", receipt).args._arbitrableItemID;

      const actualParams = await foreignProxy.itemDisputeParams(
        foreignProxy.getArbitrationID(arbitrable.address, arbitrableItemID)
      );

      expect(actualParams.metaEvidence).to.equal(itemMetaEvidence);
      expect(actualParams.arbitratorExtraData).to.equal(itemArbitratorExtraData);
    });

    it("Should emit the item disputable event on both home and foreign proxies when disputable is set", async () => {
      const {receipt} = await createItem(itemMetaEvidence, itemArbitratorExtraData);
      const arbitrableItemID = getEmittedEvent("ItemCreated", receipt).args._arbitrableItemID;
      const {txPromise} = await setDisputableItem(arbitrableItemID);

      await expect(txPromise).to.emit(homeProxy, "DisputableItem").withArgs(arbitrable.address, arbitrableItemID);
      await expect(txPromise)
        .to.emit(foreignProxy, "DisputableItemReceived")
        .withArgs(arbitrable.address, arbitrableItemID);
    });

    it("Should set the arbitrable item as disputable on the foreign proxies when disputable is set", async () => {
      const {receipt} = await createItem(itemMetaEvidence, itemArbitratorExtraData);
      const arbitrableItemID = getEmittedEvent("ItemCreated", receipt).args._arbitrableItemID;
      await setDisputableItem(arbitrableItemID);

      const disputable = await foreignProxy.disputables(
        foreignProxy.getArbitrationID(arbitrable.address, arbitrableItemID)
      );

      expect(disputable).to.be.true;
    });
  });

  describe("Handshaking is not completed", () => {
    it("Should not allow to request a dispute for an unexisting item", async () => {
      const {txPromise} = await requestDispute(arbitrable.address, 1234);

      await expect(txPromise).to.be.revertedWith("Dispute params not registered");
    });

    it("Should not allow to request a dispute for a non disputable item", async () => {
      const {receipt} = await createItem(itemMetaEvidence, itemArbitratorExtraData);
      const arbitrableItemID = getEmittedEvent("ItemCreated", receipt).args._arbitrableItemID;

      const {txPromise} = await requestDispute(arbitrable.address, arbitrableItemID);

      await expect(txPromise).to.be.revertedWith("Item is not disputable");
    });
  });

  describe("Dispute Workflow", () => {
    let arbitrableItemID;
    let arbitrationID;

    beforeEach("Perform handshaking", async () => {
      const {receipt} = await createItem(itemMetaEvidence, itemArbitratorExtraData);
      arbitrableItemID = getEmittedEvent("ItemCreated", receipt).args._arbitrableItemID;
      arbitrationID = await foreignProxy.getArbitrationID(arbitrable.address, arbitrableItemID);

      await setDisputableItem(arbitrableItemID);
    });

    describe("Request dispute", () => {
      it("Should set the arbitration params after requesting the dispute", async () => {
        await requestDispute(arbitrable.address, arbitrableItemID);

        const arbitration = await foreignProxy.arbitrations(arbitrationID);

        expect(arbitration.arbitrable).to.equal(arbitrable.address, "Invalid arbitrable address");
        expect(arbitration.arbitrableItemID).to.equal(arbitrableItemID, "Invalid arbitrable item ID");
        expect(arbitration.status).to.equal(FP.Status.Requested, "Invalid status");
        expect(arbitration.plaintiff).to.equal(await plaintiff.getAddress(), "Invalid status");
      });

      it("Should relay the dispute request to the home proxy", async () => {
        const {txPromise} = await requestDispute(arbitrable.address, arbitrableItemID);

        await expect(txPromise)
          .to.emit(homeProxy, "DisputeRequest")
          .withArgs(arbitrable.address, arbitrableItemID, await plaintiff.getAddress());
      });

      it("Should notify the arbitrable contract of the dispute request", async () => {
        const {txPromise} = await requestDispute(arbitrable.address, arbitrableItemID);

        await expect(txPromise)
          .to.emit(arbitrable, "DisputeRequest")
          .withArgs(arbitrableItemID, await plaintiff.getAddress());
      });

      describe("When the dispute is accepted", () => {
        it("Should set the status for the arbitrable item on the home chain", async () => {
          await requestDispute(arbitrable.address, arbitrableItemID);

          const arbitrableItem = await homeProxy.arbitrableItems(arbitrable.address, arbitrableItemID);

          expect(arbitrableItem.status).to.equal(HP.Status.Accepted);
        });

        it("Should relay to the foreign proxy that the dispute was accepted", async () => {
          await requestDispute(arbitrable.address, arbitrableItemID);
          const {txPromise} = await relayDisputeAccepted(arbitrable.address, arbitrableItemID);

          await expect(txPromise)
            .to.emit(homeProxy, "DisputeAccepted")
            .withArgs(arbitrable.address, arbitrableItemID, await defendant.getAddress());
          await expect(txPromise).to.emit(foreignProxy, "DisputeAccepted");
        });

        it("Should advance to the DepositPending state on the foreign proxy", async () => {
          await requestDispute(arbitrable.address, arbitrableItemID);
          await relayDisputeAccepted(arbitrable.address, arbitrableItemID);

          const arbitration = await foreignProxy.arbitrations(arbitrationID);

          expect(arbitration.status).to.equal(FP.Status.DepositPending, "Invalid status");
          expect(arbitration.acceptedAt).to.equal(await latestTime(), "Invalid acceptedAt");
        });

        it("Should register the plaintiff contribution to his side", async () => {
          await requestDispute(arbitrable.address, arbitrableItemID);
          await relayDisputeAccepted(arbitrable.address, arbitrableItemID);

          const [_, defendantContrib, plaintiffContrib] = await foreignProxy.getContributions(
            arbitrationID,
            await plaintiff.getAddress(),
            0
          );

          expect(defendantContrib).to.equal(0);
          expect(plaintiffContrib).to.equal(arbitrationFee);
        });
      });

      describe("When the dispute is rejected", () => {
        beforeEach("Increase time so the item cannot be disputed anymore", async () => {
          await increaseTime(disputeTimeout + 1);
          await requestDispute(arbitrable.address, arbitrableItemID);
        });

        it("Should set the status for the arbitrable item on the home chain", async () => {
          const arbitrableItem = await homeProxy.arbitrableItems(arbitrable.address, arbitrableItemID);

          expect(arbitrableItem.status).to.equal(HP.Status.Rejected);
        });

        it("Should relay to the foreign proxy the dispute was rejected", async () => {
          const {txPromise} = await relayDisputeRejected(arbitrable.address, arbitrableItemID);

          await expect(txPromise).to.emit(homeProxy, "DisputeRejected").withArgs(arbitrable.address, arbitrableItemID);
          await expect(txPromise).to.emit(foreignProxy, "DisputeRejected");
        });

        it("Should advance to the Failed state on the foreign proxy", async () => {
          await relayDisputeRejected(arbitrable.address, arbitrableItemID);

          const arbitration = await foreignProxy.arbitrations(arbitrationID);

          expect(arbitration.status).to.equal(FP.Status.Failed, "Invalid status");
        });

        it("Should reimburse the plaintiff of the arbitration fee", async () => {
          const {tx} = await relayDisputeRejected(arbitrable.address, arbitrableItemID);

          await expect(tx).to.changeBalance(plaintiff, arbitrationFee);
        });
      });
    });

    describe("Fund dispute defendant", () => {
      beforeEach("Request and accept the dispute", async () => {
        await requestDispute(arbitrable.address, arbitrableItemID);
        await relayDisputeAccepted(arbitrable.address, arbitrableItemID);
      });

      describe("When the defendant pays the arbitration cost within the deadline for deposit", () => {
        it("Should emit fee related events on the foreign proxy", async () => {
          const {txPromise} = await fundDisputeDefendant(arbitrationID);

          await expect(txPromise)
            .to.emit(foreignProxy, "FeeContribution")
            .withArgs(arbitrationID, FP.Party.Defendant, await defendant.getAddress(), arbitrationFee, 0);
          await expect(txPromise).to.emit(foreignProxy, "FeePaid").withArgs(arbitrationID, FP.Party.Defendant, 0);
        });

        it("Should register the defendant contribution to his side", async () => {
          await fundDisputeDefendant(arbitrationID);

          const [_, defendantContrib, plaintiffContrib] = await foreignProxy.getContributions(
            arbitrationID,
            await defendant.getAddress(),
            0
          );

          expect(defendantContrib).to.equal(arbitrationFee);
          expect(plaintiffContrib).to.equal(0);
        });

        it("Should create the dispute on the arbitrator", async () => {
          const {txPromise} = await fundDisputeDefendant(arbitrationID);

          await expect(txPromise).to.emit(arbitrator, "DisputeCreation");
        });

        it("Should notify the home proxy that the dispute was created", async () => {
          const {txPromise} = await fundDisputeDefendant(arbitrationID);

          await expect(txPromise).to.emit(homeProxy, "DisputeCreated");
        });

        it("Should set the arbitrator and dispute ID in the arbitrable item state in the home proxy", async () => {
          const {receipt} = await fundDisputeDefendant(arbitrationID);
          const arbitratorDisputeID = getEmittedEvent("Dispute", receipt).args._disputeID;

          const arbitrableItem = await homeProxy.arbitrableItems(arbitrable.address, arbitrableItemID);

          expect(arbitrableItem.arbitrator).to.equal(arbitrator.address);
          expect(arbitrableItem.arbitratorDisputeID).to.equal(arbitratorDisputeID);
        });
      });

      describe("When the deadline for deposit has passed and the defendant did not pay the arbitration cost", () => {
        beforeEach("Advance time", async () => {
          await increaseTime(feeDepositTimeout + 1);
        });

        it("Should rule in favor of the plaintiff", async () => {
          const {txPromise} = await claimPlaintiffWin(arbitrationID);

          const arbitration = await foreignProxy.arbitrations(arbitrationID);

          await expect(txPromise).to.emit(foreignProxy, "DisputeRuled").withArgs(arbitrationID, FP.Party.Plaintiff);
          expect(arbitration.status).to.equal(FP.Status.Ruled);
          expect(arbitration.ruling).to.equal(FP.Party.Plaintiff);
        });

        it("Should relay the ruling in favor of the plaintiff to the home proxy", async () => {
          const {txPromise} = await claimPlaintiffWin(arbitrationID);

          await expect(txPromise)
            .to.emit(homeProxy, "DisputeRuled")
            .withArgs(arbitrable.address, arbitrableItemID, FP.Party.Plaintiff);
        });

        it("Should rule the arbitrable contract in favor of the plaintiff", async () => {
          const {txPromise} = await claimPlaintiffWin(arbitrationID);

          await expect(txPromise).to.emit(arbitrable, "DisputeRuled").withArgs(arbitrableItemID, FP.Party.Plaintiff);
        });

        it("Should reimburse the plaintiff of the arbitration fee", async () => {
          const {tx} = await claimPlaintiffWin(arbitrationID);

          await expect(tx).to.changeBalance(plaintiff, arbitrationFee);
        });
      });
    });

    describe("Arbitrator gives final ruling", () => {
      beforeEach("Request and accept the dispute, pay defendant's side fee", async () => {
        await requestDispute(arbitrable.address, arbitrableItemID);
        await relayDisputeAccepted(arbitrable.address, arbitrableItemID);
        await fundDisputeDefendant(arbitrationID);
      });

      it("Should accept the arbitrator ruling on the foreign proxy", async () => {
        const expectedRuling = FP.Party.Defendant;
        const {txPromise} = await giveFinalRuling(arbitrationID, expectedRuling);

        const arbitration = await foreignProxy.arbitrations(arbitrationID);

        await expect(txPromise).to.emit(foreignProxy, "DisputeRuled").withArgs(arbitrationID, FP.Party.Defendant);
        expect(arbitration.status).to.equal(FP.Status.Ruled);
        expect(arbitration.ruling).to.equal(expectedRuling);
      });

      it("Should relay the arbitrator ruling to the home proxy", async () => {
        const expectedRuling = FP.Party.Defendant;
        const {txPromise} = await giveFinalRuling(arbitrationID, expectedRuling);

        await expect(txPromise)
          .to.emit(homeProxy, "DisputeRuled")
          .withArgs(arbitrable.address, arbitrableItemID, expectedRuling);
      });

      it("Should set the status for the arbitrable item as ruled and store the ruling on the home proxy", async () => {
        const expectedRuling = FP.Party.Defendant;
        await giveFinalRuling(arbitrationID, expectedRuling);

        const arbitrableItem = await homeProxy.arbitrableItems(arbitrable.address, arbitrableItemID);

        expect(arbitrableItem.status).to.equal(HP.Status.Ruled);
        expect(arbitrableItem.ruling).to.equal(expectedRuling);
      });

      it("Should rule the arbitrable contract with the ruling from the arbitrator", async () => {
        const expectedRuling = FP.Party.Defendant;
        const {txPromise} = await giveFinalRuling(arbitrationID, expectedRuling);

        await expect(txPromise).to.emit(arbitrable, "DisputeRuled").withArgs(arbitrableItemID, expectedRuling);
      });

      it("Should allow the winning party to withdraw the respective fees and rewards", async () => {
        const expectedRuling = FP.Party.Defendant;
        await giveFinalRuling(arbitrationID, expectedRuling);

        const {tx} = await batchWithdrawFeesAndRewards(arbitrationID, defendant);
        await expect(tx).to.changeBalance(defendant, arbitrationFee);
      });

      it("Should not have any withdrawable amount for the losing party", async () => {
        const expectedRuling = FP.Party.Defendant;
        await giveFinalRuling(arbitrationID, expectedRuling);

        const amount = await foreignProxy.getTotalWithdrawableAmount(arbitrationID, await plaintiff.getAddress());

        expect(amount).to.equal(0);
      });
    });

    describe("Crowdfund dispute defendant", () => {
      beforeEach("Request and accept the dispute", async () => {
        await requestDispute(arbitrable.address, arbitrableItemID);
        await relayDisputeAccepted(arbitrable.address, arbitrableItemID);
      });

      describe("When the crowdfunding succeeds to pay for the full arbitration cost", () => {
        let txPromise;
        const contribution = arbitrationFee.div(BigNumber.from(2));

        beforeEach("Request and accept the dispute", async () => {
          await fundDisputeDefendant(arbitrationID, contribution, defendant);
          ({txPromise} = await fundDisputeDefendant(arbitrationID, contribution, crowdfunderDefendant));
        });

        it("Should register all contributions to the defendant's side", async () => {
          const fromDefendant = await foreignProxy.getContributions(arbitrationID, await defendant.getAddress(), 0);

          const fromCrowdfunder = await foreignProxy.getContributions(
            arbitrationID,
            await crowdfunderDefendant.getAddress(),
            0
          );

          expect(fromDefendant[FP.Party.Defendant]).to.equal(contribution);
          expect(fromCrowdfunder[FP.Party.Defendant]).to.equal(contribution);
        });

        it("Should create the dispute on the arbitrator", async () => {
          await expect(txPromise).to.emit(arbitrator, "DisputeCreation");
        });

        it("Should notify the home proxy that the dispute was created", async () => {
          await expect(txPromise).to.emit(homeProxy, "DisputeCreated");
        });
      });

      describe("When the arbitrator rules in favor of the crowdfunded side", () => {
        const expectedRuling = FP.Party.Defendant;
        const contribution = arbitrationFee.div(BigNumber.from(2));

        beforeEach(
          "Request and accept the dispute, crowdfund defentant's side and rule in favor of the defendant",
          async () => {
            await fundDisputeDefendant(arbitrationID, contribution, defendant);
            await fundDisputeDefendant(arbitrationID, contribution, crowdfunderDefendant);
            await giveFinalRuling(arbitrationID, expectedRuling);
          }
        );

        it("Should allow each contributor to the winning party to withdraw fees and rewards proportional to their contribution", async () => {
          const defendantResult = await batchWithdrawFeesAndRewards(arbitrationID, defendant);
          const crowdfunderResult = await batchWithdrawFeesAndRewards(arbitrationID, crowdfunderDefendant);

          await expect(defendantResult.tx).to.changeBalance(defendant, contribution);
          await expect(crowdfunderResult.tx).to.changeBalance(crowdfunderDefendant, contribution);
        });

        it("Should not have any withdrawable amount for the losing party", async () => {
          const amount = await foreignProxy.getTotalWithdrawableAmount(arbitrationID, await plaintiff.getAddress());

          expect(amount).to.equal(0);
        });
      });

      describe("When the crowdfunding fails to pay for the full arbitration cost before the deadline", () => {
        const incompleteContribution = arbitrationFee.div(BigNumber.from(4));

        beforeEach(
          "Request and accept the dispute, partially crowdfund defentant's side, avance time and claim plaintiff win",
          async () => {
            await fundDisputeDefendant(arbitrationID, incompleteContribution, defendant);
            await fundDisputeDefendant(arbitrationID, incompleteContribution, crowdfunderDefendant);
            await increaseTime(feeDepositTimeout + 1);
            await claimPlaintiffWin(arbitrationID);
          }
        );

        it("Should allow contributors of the incomplete crowdfunding to withdraw their respective contributions", async () => {
          const defendantResult = await batchWithdrawFeesAndRewards(arbitrationID, defendant);
          const crowdfunderResult = await batchWithdrawFeesAndRewards(arbitrationID, crowdfunderDefendant);

          await expect(defendantResult.tx).to.changeBalance(defendant, incompleteContribution);
          await expect(crowdfunderResult.tx).to.changeBalance(crowdfunderDefendant, incompleteContribution);
        });
      });
    });

    describe("Appeal dispute", () => {
      const currentRound = 1;
      const firstRuling = FP.Party.Plaintiff;
      const finalRuling = FP.Party.Defendant;

      beforeEach("Request and accept the dispute, fund defendant's side and give appealable ruling", async () => {
        await requestDispute(arbitrable.address, arbitrableItemID);
        await relayDisputeAccepted(arbitrable.address, arbitrableItemID);
        await fundDisputeDefendant(arbitrationID);
        await giveAppealableRuling(arbitrationID, firstRuling);
      });

      describe("When both parties pay the full appeal fee", () => {
        let defendantFee;
        let plaintiffFee;
        let txPromise;

        beforeEach("Pay both appeal fee", async () => {
          defendantFee = await foreignProxy.getAppealFee(arbitrationID, FP.Party.Defendant);
          plaintiffFee = await foreignProxy.getAppealFee(arbitrationID, FP.Party.Plaintiff);

          await fundAppeal(arbitrationID, FP.Party.Defendant, defendantFee);
          ({txPromise} = await fundAppeal(arbitrationID, FP.Party.Plaintiff, plaintiffFee));
        });

        it("Should issue an appeal on the arbitrator", async () => {
          await expect(txPromise).to.emit(arbitrator, "AppealDecision");
        });

        it("Should register the contributions for each party in the specific round", async () => {
          const defendantContrib = await foreignProxy.getContributions(
            arbitrationID,
            await defendant.getAddress(),
            currentRound
          );
          const plaintiffContrib = await foreignProxy.getContributions(
            arbitrationID,
            await plaintiff.getAddress(),
            currentRound
          );

          expect(defendantContrib[FP.Party.Defendant]).to.equal(defendantFee);
          expect(plaintiffContrib[FP.Party.Plaintiff]).to.equal(plaintiffFee);
        });

        it("Should allow the winner of the final ruling to withdraw fees and rewards for all rounds", async () => {
          await giveFinalRuling(arbitrationID, finalRuling);

          const {tx} = await batchWithdrawFeesAndRewards(arbitrationID, defendant);

          const disputeFeeRewards = arbitrationFee;
          const appealFeeRewards = defendantFee.add(plaintiffFee).sub(arbitrationFee);
          const expectedBalanceChange = disputeFeeRewards.add(appealFeeRewards);

          await expect(tx).to.changeBalance(defendant, expectedBalanceChange);
        });
      });

      describe("When one of the parties fails to pay the appeal fee", () => {
        const firstRuling = FP.Party.Plaintiff;
        const finalRuling = FP.Party.Plaintiff;
        let defendantFee;
        let plaintiffFee;
        let plaintiffContribution;
        let txPromise;

        beforeEach("Setup ruling to be reverted", async () => {
          await requestDispute(arbitrable.address, arbitrableItemID);
          await relayDisputeAccepted(arbitrable.address, arbitrableItemID);
          await fundDisputeDefendant(arbitrationID);
          await giveAppealableRuling(arbitrationID, firstRuling);

          defendantFee = await foreignProxy.getAppealFee(arbitrationID, FP.Party.Defendant);
          await fundAppeal(arbitrationID, FP.Party.Defendant, defendantFee);

          plaintiffFee = await foreignProxy.getAppealFee(arbitrationID, FP.Party.Plaintiff);
          plaintiffContribution = plaintiffFee.div(BigNumber.from(2));
          await fundAppeal(arbitrationID, FP.Party.Plaintiff, plaintiffContribution);

          ({txPromise} = await giveFinalRuling(arbitrationID, finalRuling));
        });

        it("Should consider the party which fully paid the winner of the arbitration even when the arbitrator rules differently", async () => {
          const expectedRuling = FP.Party.Defendant;

          await expect(txPromise)
            .to.emit(homeProxy, "DisputeRuled")
            .withArgs(arbitrable.address, arbitrableItemID, expectedRuling);
        });

        it("Should allow winner to withdraw their contributions", async () => {
          const {tx} = await batchWithdrawFeesAndRewards(arbitrationID, defendant);
          const expectedBalanceChange = arbitrationFee.add(defendantFee);

          await expect(tx).to.changeBalance(defendant, expectedBalanceChange);
        });

        it("Should allow the contributors to the incomplete crowddfunding to withdraw their respective contributions", async () => {
          const {tx} = await batchWithdrawFeesAndRewards(arbitrationID, plaintiff);

          await expect(tx).to.changeBalance(plaintiff, plaintiffContribution);
        });
      });
    });
  });

  function createItemNoParams(signer = defendant) {
    return submitTransaction(arbitrable.connect(signer)["createItem()"]());
  }

  function createItem(metaEvidence, arbitratorExtraData, signer = defendant) {
    return submitTransaction(arbitrable.connect(signer)["createItem(string,bytes)"](metaEvidence, arbitratorExtraData));
  }

  function setDisputableItem(arbitrableItemID, signer = defendant) {
    return submitTransaction(arbitrable.connect(signer).setDisputableItem(arbitrableItemID));
  }

  function requestDispute(arbitrableAddress, arbitrableItemID, signer = plaintiff) {
    return submitTransaction(
      foreignProxy.connect(signer).requestDispute(arbitrableAddress, arbitrableItemID, {value: arbitrationFee})
    );
  }

  function relayDisputeAccepted(arbitrableAddress, arbitrableItemID, signer = governor) {
    return submitTransaction(homeProxy.connect(signer).relayDisputeAccepted(arbitrableAddress, arbitrableItemID));
  }

  function relayDisputeRejected(arbitrableAddress, arbitrableItemID, signer = governor) {
    return submitTransaction(homeProxy.connect(signer).relayDisputeRejected(arbitrableAddress, arbitrableItemID));
  }

  function fundDisputeDefendant(arbitrationID, amount = arbitrationFee, signer = defendant) {
    return submitTransaction(foreignProxy.connect(signer).fundDisputeDefendant(arbitrationID, {value: amount}));
  }

  function claimPlaintiffWin(arbitrationID, signer = governor) {
    return submitTransaction(foreignProxy.connect(signer).claimPlaintiffWin(arbitrationID));
  }

  async function giveAppealableRuling(arbitrationID, ruling) {
    const {arbitratorDisputeID} = await foreignProxy.arbitrations(arbitrationID);
    return submitTransaction(arbitrator.giveRuling(arbitratorDisputeID, ruling));
  }

  async function fundAppeal(
    arbitrationID,
    party,
    amount,
    signer = party === FP.Party.Defendant ? defendant : plaintiff
  ) {
    amount = amount || (await arbitrator.getAppealFee(arbitrationID, party));
    return submitTransaction(foreignProxy.connect(signer).fundAppeal(arbitrationID, party, {value: amount}));
  }

  async function giveFinalRuling(arbitrationID, ruling) {
    const {arbitratorDisputeID} = await foreignProxy.arbitrations(arbitrationID);
    const appealDisputeID = await arbitrator.getAppealDisputeID(arbitratorDisputeID);
    await submitTransaction(arbitrator.giveRuling(appealDisputeID, ruling));

    await increaseTime(appealTimeout + 1);

    return submitTransaction(arbitrator.giveRuling(appealDisputeID, ruling));
  }

  async function batchWithdrawFeesAndRewards(arbitrationID, beneficiary, cursor = 0, count = 0, signer = governor) {
    return submitTransaction(
      foreignProxy
        .connect(signer)
        .batchWithdrawFeesAndRewards(arbitrationID, await beneficiary.getAddress(), cursor, count)
    );
  }

  async function submitTransaction(txPromise) {
    try {
      const tx = await txPromise;
      const receipt = await tx.wait();

      return {txPromise, tx, receipt};
    } catch (err) {
      return {txPromise};
    }
  }
});
