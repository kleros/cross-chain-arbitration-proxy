const { ethers } = require("@nomiclabs/buidler");
const { solidity } = require("ethereum-waffle");
const { use, expect } = require("chai");
const { getEmittedEvent } = require("./helpers/events");
const { latestTime, increaseTime } = require("./helpers/time");
const HP = require("./helpers/HomeProxy");
const FP = require("./helpers/ForeignProxy");

use(solidity);

const { BigNumber } = ethers;

let arbitrator;
let arbitrable;
let homeProxy;
let foreignProxy;
let amb;

let governor;
let plaintiff;
let defendant;

const metaEvidence = "ipfs/X";
const arbitratorExtraData = "0x00";
const disputeTimeout = 600;

const feeDepositTimeout = 100;
const appealTimeout = 3600;
const sharedMultiplier = BigNumber.from(10000);
const winnerMultiplier = BigNumber.from(5000);
const loserMultiplier = BigNumber.from(20000);

const arbitrationFee = BigNumber.from(BigInt(1e18));

describe("Cross-Chain Binary Arbitration Proxies", () => {
  beforeEach("Setup contract", async () => {
    [governor, plaintiff, defendant] = await ethers.getSigners();

    // const Arbitrator = await ethers.getContractFactory("MockArbitrator", governor);
    // arbitrator = await Arbitrator.deploy(
    //   String(arbitrationFee),
    //   ethers.constants.AddressZero,
    //   arbitratorExtraData,
    //   appealTimeout
    // );

    const Arbitrator = await ethers.getContractFactory("MockAppealableArbitrator", governor);
    arbitrator = await Arbitrator.deploy(arbitrationFee, appealTimeout);

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

    const setHomeProxyTx = await foreignProxy.setHomeProxy(homeProxy.address, "0");
    await setHomeProxyTx.wait();

    const setForeignProxyTx = await homeProxy.setForeignProxy(foreignProxy.address, "0");
    await setForeignProxyTx.wait();

    const Arbitrable = await ethers.getContractFactory("MockArbitrable", governor);
    arbitrable = await Arbitrable.deploy(metaEvidence, homeProxy.address, arbitratorExtraData, disputeTimeout);
  });

  afterEach("Advance block", async () => {
    // await advanceBlock();
  });

  describe("Handshaking", () => {
    it("Should emit the register events for the arbitrable contract on the home proxy after deploy and relay the data to the foreign proxy", async () => {
      const { txPromise } = await registerForArbitration();

      await expect(txPromise)
        .to.emit(homeProxy, "MetaEvidenceRegistered")
        .withArgs(arbitrable.address, "0", metaEvidence);
      await expect(txPromise)
        .to.emit(homeProxy, "ArbitratorExtraDataRegistered")
        .withArgs(arbitrable.address, "0", arbitratorExtraData);
      await expect(txPromise)
        .to.emit(foreignProxy, "MetaEvidenceReceived")
        .withArgs(arbitrable.address, "0", metaEvidence);
      await expect(txPromise)
        .to.emit(foreignProxy, "ArbitratorExtraDataReceived")
        .withArgs(arbitrable.address, "0", arbitratorExtraData);
    });

    it("Should set the dispute params for the contract on the home proxy after deploy and relay the data to the foreign proxy", async () => {
      await registerForArbitration();

      const actualParams = await foreignProxy.getDisputeParams(arbitrable.address, 0);

      expect(actualParams.metaEvidence).to.equal(metaEvidence);
      expect(actualParams.arbitratorExtraData).to.equal(arbitratorExtraData);
    });

    it("Should not emit the register event for the arbitrable item when it does not have its own dispute params", async () => {
      await registerForArbitration();

      const { txPromise } = await createItem({ reportGas: true });

      await expect(txPromise).not.to.emit(homeProxy, "MetaEvidenceRegistered");
      await expect(txPromise).not.to.emit(homeProxy, "ArbitratorExtraDataRegistered");
    });
  });

  describe("Handshaking is not completed", () => {
    it("Should not allow to request a dispute for an unregistered contract", async () => {
      const { txPromise } = await requestDispute(arbitrable.address, 1234);

      await expect(txPromise).to.be.reverted;
    });

    it("Should not allow to request a dispute for an item whose ID is lower than the first registered", async () => {
      await registerForArbitration({ id: 1234 });

      const { txPromise } = await requestDispute(arbitrable.address, 0);

      await expect(txPromise).to.be.reverted;
    });
  });

  describe("Dispute Workflow", () => {
    let arbitrableItemID;
    let arbitrationID;

    beforeEach("Perform handshaking", async () => {
      await registerForArbitration();
      const { receipt } = await createItem();
      arbitrableItemID = getEmittedEvent("ItemCreated", receipt).args._arbitrableItemID;
      arbitrationID = await foreignProxy.getArbitrationID(arbitrable.address, arbitrableItemID);
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
        const { txPromise } = await requestDispute(arbitrable.address, arbitrableItemID);

        await expect(txPromise).not.to.be.reverted;
        await expect(txPromise).not.to.emit(homeProxy, "DisputeRejected");
        await expect(txPromise).to.emit(homeProxy, "DisputeAccepted").withArgs(arbitrable.address, arbitrableItemID);
      });

      it("Should notify the arbitrable contract of the dispute request", async () => {
        const { txPromise } = await requestDispute(arbitrable.address, arbitrableItemID);

        await expect(txPromise)
          .to.emit(arbitrable, "ItemDisputeRequest")
          .withArgs(arbitrableItemID, await plaintiff.getAddress());
      });

      describe("When the dispute is accepted", () => {
        it("Should set the status for the arbitrable item on the home chain and emit the DisputeAccepted event", async () => {
          const { txPromise } = await requestDispute(arbitrable.address, arbitrableItemID);

          const arbitrableItem = await homeProxy.arbitrableItems(arbitrable.address, arbitrableItemID);

          await expect(txPromise).to.emit(homeProxy, "DisputeAccepted").withArgs(arbitrable.address, arbitrableItemID);
          expect(arbitrableItem.status).to.equal(HP.Status.Accepted);
        });

        it("Should relay to the foreign proxy that the dispute was accepted", async () => {
          await requestDispute(arbitrable.address, arbitrableItemID);
          const { txPromise } = await relayDisputeAccepted(arbitrable.address, arbitrableItemID);

          await expect(txPromise).to.emit(foreignProxy, "DisputeAccepted");
        });

        it("Should advance to the DepositPending state on the foreign proxy", async () => {
          await requestDispute(arbitrable.address, arbitrableItemID);
          await relayDisputeAccepted(arbitrable.address, arbitrableItemID);

          const arbitration = await foreignProxy.arbitrations(arbitrationID);

          expect(arbitration.status).to.equal(FP.Status.DepositPending, "Invalid status");
          expect(arbitration.acceptedAt).to.equal(await latestTime(), "Invalid acceptedAt");
        });

        it("Should register the plaintiff deposit", async () => {
          await requestDispute(arbitrable.address, arbitrableItemID);
          await relayDisputeAccepted(arbitrable.address, arbitrableItemID);

          const { sumDeposit } = await foreignProxy.arbitrations(arbitrationID);

          expect(sumDeposit).to.equal(arbitrationFee);
        });
      });

      describe("When the dispute is rejected", () => {
        let txPromise;
        beforeEach("Increase time so the item cannot be disputed anymore", async () => {
          await increaseTime(disputeTimeout + 1);
          ({ txPromise } = await requestDispute(arbitrable.address, arbitrableItemID));
        });

        it("Should set the status for the arbitrable item on the home chain", async () => {
          const arbitrableItem = await homeProxy.arbitrableItems(arbitrable.address, arbitrableItemID);

          await expect(txPromise).to.emit(homeProxy, "DisputeRejected").withArgs(arbitrable.address, arbitrableItemID);
          expect(arbitrableItem.status).to.equal(HP.Status.Rejected);
        });

        it("Should relay to the foreign proxy the dispute was rejected", async () => {
          const { txPromise } = await relayDisputeRejected(arbitrable.address, arbitrableItemID);

          await expect(txPromise).to.emit(foreignProxy, "DisputeRejected");
        });

        it("Should reset to the arbitration state on the foreign proxy", async () => {
          await relayDisputeRejected(arbitrable.address, arbitrableItemID);

          const arbitration = await foreignProxy.arbitrations(arbitrationID);

          expect(arbitration.status).to.equal(FP.Status.None, "Did not reset the status");
          expect(arbitration.plaintiff).to.equal(ethers.constants.AddressZero, "Did not reset the plaintiff");
          expect(arbitration.sumDeposit).to.equal(0, "Did not reset the sumDeposit");
        });

        it("Should reimburse the plaintiff of the arbitration fee", async () => {
          const { tx } = await relayDisputeRejected(arbitrable.address, arbitrableItemID);

          await expect(tx).to.changeBalance(plaintiff, arbitrationFee);
        });
      });
    });

    describe("Pay defendant fee", () => {
      beforeEach("Request and accept the dispute", async () => {
        await requestDispute(arbitrable.address, arbitrableItemID);
        await relayDisputeAccepted(arbitrable.address, arbitrableItemID);
      });

      describe("When the defendant pays the arbitration cost within the deadline for deposit", () => {
        it("Should create the dispute on the arbitrator and emit the MetaEvidence, Dispute and DisputeOngoing events", async () => {
          const { txPromise } = await payDefendantFee(arbitrationID);

          await expect(txPromise).to.emit(foreignProxy, "MetaEvidence");
          await expect(txPromise).to.emit(foreignProxy, "Dispute");
          await expect(txPromise).to.emit(foreignProxy, "DisputeOngoing");
          await expect(txPromise).to.emit(arbitrator, "DisputeCreation");
        });

        it("Should notify the home proxy that the dispute was created", async () => {
          const { txPromise } = await payDefendantFee(arbitrationID);

          await expect(txPromise).to.emit(homeProxy, "DisputeCreated");
        });

        it("Should set the arbitrator and dispute ID in the arbitrable item on the home proxy", async () => {
          const { receipt } = await payDefendantFee(arbitrationID);
          const arbitratorDisputeID = getEmittedEvent("Dispute", receipt).args._disputeID;

          const arbitrableItem = await homeProxy.arbitrableItems(arbitrable.address, arbitrableItemID);

          expect(arbitrableItem.arbitrator).to.equal(arbitrator.address);
          expect(arbitrableItem.arbitratorDisputeID).to.equal(arbitratorDisputeID);
        });
      });

      describe("When the defendant pays the arbitration cost within the deadline, but the dispute creation fails", () => {
        beforeEach("Request and accept the dispute", async () => {
          await requestDispute(arbitrable.address, arbitrableItemID);
          await relayDisputeAccepted(arbitrable.address, arbitrableItemID);
          await deactivateArbitrator();
        });

        it("Should notify the home proxy that the dispute creation failed", async () => {
          const { txPromise } = await payDefendantFee(arbitrationID);

          await expect(txPromise)
            .to.emit(foreignProxy, "DisputeFailed")
            .withArgs(arbitrationID, arbitrator.address, arbitratorExtraData);
          await expect(txPromise).to.emit(homeProxy, "DisputeFailed").withArgs(arbitrable.address, arbitrableItemID);
        });

        it("Should reiburse both the plaintiff and the requester", async () => {
          const { tx } = await payDefendantFee(arbitrationID);

          // The defendant just submitted the value, so when reimbursed her balance should not change
          await expect(() => tx).to.changeEtherBalances([plaintiff, defendant], [arbitrationFee, 0]);
        });

        it("Should reset the arbitration state on the foreign proxy", async () => {
          await payDefendantFee(arbitrationID);

          const arbitration = await foreignProxy.arbitrations(arbitrationID);

          expect(arbitration.status).to.equal(FP.Status.None);
          expect(arbitration.plaintiff).to.equal(ethers.constants.AddressZero);
          expect(arbitration.defendant).to.equal(ethers.constants.AddressZero);
          expect(arbitration.sumDeposit).to.equal(0);
        });

        it("Should reset the arbitration state on the home proxy", async () => {
          await payDefendantFee(arbitrationID);

          const arbitrableItem = await homeProxy.arbitrableItems(arbitrable.address, arbitrableItemID);

          expect(arbitrableItem.status).to.equal(HP.Status.None);
          expect(arbitrableItem.arbitrator).to.equal(ethers.constants.AddressZero);
          expect(arbitrableItem.arbitratorDisputeID).to.equal(0);
          expect(arbitrableItem.ruling).to.equal(0);
        });
      });

      describe("When the deadline for deposit has passed and the defendant did not pay the arbitration cost", () => {
        beforeEach("Advance time", async () => {
          await increaseTime(feeDepositTimeout + 1);
        });

        it("Should rule in favor of the plaintiff", async () => {
          const { txPromise } = await claimPlaintiffWin(arbitrationID);

          const arbitration = await foreignProxy.arbitrations(arbitrationID);

          await expect(txPromise).to.emit(foreignProxy, "DisputeRuled").withArgs(arbitrationID, FP.Party.Plaintiff);
          expect(arbitration.status).to.equal(FP.Status.Ruled);
          expect(arbitration.ruling).to.equal(FP.Party.Plaintiff);
        });

        it("Should relay the ruling in favor of the plaintiff to the home proxy", async () => {
          const { txPromise } = await claimPlaintiffWin(arbitrationID);

          await expect(txPromise)
            .to.emit(homeProxy, "DisputeRuled")
            .withArgs(arbitrable.address, arbitrableItemID, FP.Party.Plaintiff);
        });

        it("Should rule the arbitrable contract in favor of the plaintiff", async () => {
          const { txPromise } = await claimPlaintiffWin(arbitrationID);

          await expect(txPromise)
            .to.emit(arbitrable, "ItemDisputeRuled")
            .withArgs(arbitrableItemID, FP.Party.Plaintiff);
        });

        it("Should reimburse the plaintiff of the arbitration fee", async () => {
          const { tx } = await claimPlaintiffWin(arbitrationID);

          await expect(tx).to.changeBalance(plaintiff, arbitrationFee);
        });
      });
    });

    describe("Arbitrator gives final ruling", () => {
      beforeEach("Request and accept the dispute, pay defendant's side fee", async () => {
        await requestDispute(arbitrable.address, arbitrableItemID);
        await relayDisputeAccepted(arbitrable.address, arbitrableItemID);
        await payDefendantFee(arbitrationID);
      });

      it("Should accept the arbitrator ruling on the foreign proxy", async () => {
        const expectedRuling = FP.Party.Defendant;
        const { txPromise } = await giveFinalRuling(arbitrationID, expectedRuling);

        const arbitration = await foreignProxy.arbitrations(arbitrationID);

        await expect(txPromise).to.emit(foreignProxy, "DisputeRuled").withArgs(arbitrationID, FP.Party.Defendant);
        expect(arbitration.status).to.equal(FP.Status.Ruled);
        expect(arbitration.ruling).to.equal(expectedRuling);
      });

      it("Should relay the arbitrator ruling to the home proxy", async () => {
        const expectedRuling = FP.Party.Defendant;
        const { txPromise } = await giveFinalRuling(arbitrationID, expectedRuling);

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
        const { txPromise } = await giveFinalRuling(arbitrationID, expectedRuling);

        await expect(txPromise).to.emit(arbitrable, "ItemDisputeRuled").withArgs(arbitrableItemID, expectedRuling);
      });

      it("Should reimburse the winning party of the arbitration fee", async () => {
        const expectedRuling = FP.Party.Defendant;
        const { tx } = await giveFinalRuling(arbitrationID, expectedRuling);

        await expect(tx).to.changeBalance(defendant, arbitrationFee);
      });

      it("Should not reimburse the losing party", async () => {
        const expectedRuling = FP.Party.Defendant;
        const { tx } = await giveFinalRuling(arbitrationID, expectedRuling);

        await expect(tx).to.changeBalance(plaintiff, 0);
      });

      it("Should reimburse both the plaintiff and the defendant half of the arbitration cost when the arbitrator refuses to rule", async () => {
        const expectedRuling = FP.Party.None;
        const { tx } = await giveFinalRuling(arbitrationID, expectedRuling);

        const halfArbitrationFee = arbitrationFee.div(2);
        await expect(tx).to.changeBalances([plaintiff, defendant], [halfArbitrationFee, halfArbitrationFee]);
      });
    });

    describe("Appeal dispute", () => {
      const currentRound = 0;
      const firstRuling = FP.Party.Plaintiff;
      const finalRuling = FP.Party.Defendant;

      beforeEach("Request and accept the dispute, fund defendant's side and give appealable ruling", async () => {
        await requestDispute(arbitrable.address, arbitrableItemID);
        await relayDisputeAccepted(arbitrable.address, arbitrableItemID);
        await payDefendantFee(arbitrationID);
        await giveAppealableRuling(arbitrationID, firstRuling);
      });

      describe("When both parties pay the full appeal fee", () => {
        let appealFee;
        let defendantFee;
        let plaintiffFee;
        let txPromise;

        beforeEach("Pay both appeal fee", async () => {
          const { arbitratorDisputeID } = await foreignProxy.arbitrations(arbitrationID);
          appealFee = await arbitrator.appealCost(arbitratorDisputeID, arbitratorExtraData);
          defendantFee = await foreignProxy.getAppealFee(arbitrationID, FP.Party.Defendant);
          plaintiffFee = await foreignProxy.getAppealFee(arbitrationID, FP.Party.Plaintiff);

          await fundAppeal(arbitrationID, FP.Party.Defendant, defendantFee);
          ({ txPromise } = await fundAppeal(arbitrationID, FP.Party.Plaintiff, plaintiffFee));
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

          const { tx } = await batchWithdrawFeesAndRewards(arbitrationID, defendant);

          const appealFeeRewards = defendantFee.add(plaintiffFee).sub(appealFee);

          await expect(() => tx).to.changeBalance(defendant, appealFeeRewards);
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
          await payDefendantFee(arbitrationID);
          await giveAppealableRuling(arbitrationID, firstRuling);

          defendantFee = await foreignProxy.getAppealFee(arbitrationID, FP.Party.Defendant);
          await fundAppeal(arbitrationID, FP.Party.Defendant, defendantFee);

          plaintiffFee = await foreignProxy.getAppealFee(arbitrationID, FP.Party.Plaintiff);
          plaintiffContribution = plaintiffFee.div(BigNumber.from(2));
          await fundAppeal(arbitrationID, FP.Party.Plaintiff, plaintiffContribution);

          ({ txPromise } = await giveFinalRuling(arbitrationID, finalRuling));
        });

        it("Should consider the party which fully paid the winner of the arbitration even when the arbitrator rules differently", async () => {
          const expectedRuling = FP.Party.Defendant;

          await expect(txPromise)
            .to.emit(homeProxy, "DisputeRuled")
            .withArgs(arbitrable.address, arbitrableItemID, expectedRuling);
        });

        it("Should allow winner to withdraw their contributions", async () => {
          const { tx } = await batchWithdrawFeesAndRewards(arbitrationID, defendant);
          const expectedBalanceChange = defendantFee;

          await expect(tx).to.changeBalance(defendant, expectedBalanceChange);
        });

        it("Should allow the contributors to the incomplete crowddfunding to withdraw their respective contributions", async () => {
          const { tx } = await batchWithdrawFeesAndRewards(arbitrationID, plaintiff);

          await expect(tx).to.changeBalance(plaintiff, plaintiffContribution);
        });
      });
    });
  });

  async function registerForArbitration({ id = 0, signer = governor } = {}) {
    return await submitTransaction(arbitrable.connect(signer).registerForArbitration(id));
  }

  async function createItem({ signer = defendant, reportGas = false } = {}) {
    if (reportGas) {
      console.info("\tGas usage -> createItem():", Number(await arbitrable.estimateGas["createItem()"]()));
    }
    return await submitTransaction(arbitrable.connect(signer).createItem());
  }

  async function requestDispute(arbitrableAddress, arbitrableItemID, { signer = plaintiff } = {}) {
    return await submitTransaction(
      foreignProxy.connect(signer).requestDispute(arbitrableAddress, arbitrableItemID, { value: arbitrationFee })
    );
  }

  async function relayDisputeAccepted(arbitrableAddress, arbitrableItemID, { signer = governor } = {}) {
    return await submitTransaction(homeProxy.connect(signer).relayDisputeAccepted(arbitrableAddress, arbitrableItemID));
  }

  async function relayDisputeRejected(arbitrableAddress, arbitrableItemID, { signer = governor } = {}) {
    return await submitTransaction(homeProxy.connect(signer).relayDisputeRejected(arbitrableAddress, arbitrableItemID));
  }

  async function payDefendantFee(arbitrationID, amount = arbitrationFee, { signer = defendant } = {}) {
    return await submitTransaction(foreignProxy.connect(signer).payDefendantFee(arbitrationID, { value: amount }));
  }

  async function claimPlaintiffWin(arbitrationID, { signer = governor } = {}) {
    return await submitTransaction(foreignProxy.connect(signer).claimPlaintiffWin(arbitrationID));
  }

  async function giveAppealableRuling(arbitrationID, ruling) {
    const { arbitratorDisputeID } = await foreignProxy.arbitrations(arbitrationID);
    return await submitTransaction(arbitrator.giveRuling(arbitratorDisputeID, ruling));
  }

  async function fundAppeal(
    arbitrationID,
    party,
    amount,
    signer = party === FP.Party.Defendant ? defendant : plaintiff
  ) {
    amount = amount || (await arbitrator.getAppealFee(arbitrationID, party));
    return await submitTransaction(foreignProxy.connect(signer).fundAppeal(arbitrationID, party, { value: amount }));
  }

  async function giveFinalRuling(arbitrationID, ruling) {
    const { arbitratorDisputeID } = await foreignProxy.arbitrations(arbitrationID);
    const appealDisputeID = await arbitrator.getAppealDisputeID(arbitratorDisputeID);
    await submitTransaction(arbitrator.giveRuling(appealDisputeID, ruling));

    await increaseTime(appealTimeout + 1000);

    return await submitTransaction(arbitrator.giveRuling(appealDisputeID, ruling));
  }

  async function batchWithdrawFeesAndRewards(
    arbitrationID,
    beneficiary,
    cursor = 0,
    count = 0,
    { signer = governor } = {}
  ) {
    return await submitTransaction(
      foreignProxy
        .connect(signer)
        .batchWithdrawFeesAndRewards(arbitrationID, await beneficiary.getAddress(), cursor, count)
    );
  }

  async function deactivateArbitrator() {
    return await submitTransaction(arbitrator.deactivate());
  }

  async function submitTransaction(txPromise) {
    try {
      const tx = await txPromise;
      const receipt = await tx.wait();

      return { txPromise, tx, receipt };
    } catch (err) {
      return { txPromise };
    }
  }
});
