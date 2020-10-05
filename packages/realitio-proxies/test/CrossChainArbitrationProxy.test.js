const {ethers} = require("@nomiclabs/buidler");
const {solidity} = require("ethereum-waffle");
const {use, expect} = require("chai");

use(solidity);

const {BigNumber} = ethers;
const {hexZeroPad} = ethers.utils;

const ZERO_HASH = hexZeroPad(0, 32);
const ZERO_ADDRESS = hexZeroPad(0, 20);

let arbitrator;
let homeProxy;
let foreignProxy;
let amb;
let realitio;

let governor;
let asker;
let answerer;
let requester;

const arbitrationFee = BigNumber.from(BigInt(1e18));
const arbitratorExtraData = "0x00";
const metaEvidence = "ipfs/X";

let questionId;
const question = "Whats the answer for everything in the universe?";
const currentAnswer = hexZeroPad(0, 32);
const requesterAnswer = hexZeroPad(1, 32);

describe("Cross-Chain Arbitration", () => {
  beforeEach("Setup contracts", async () => {
    [governor, asker, answerer, requester] = await ethers.getSigners();

    const Arbitrator = await ethers.getContractFactory("MockArbitrator", governor);
    arbitrator = await Arbitrator.deploy(String(arbitrationFee));

    const AMB = await ethers.getContractFactory("MockAMB", governor);
    amb = await AMB.deploy();

    const ForeignProxy = await ethers.getContractFactory("RealitioForeignArbitrationProxy", governor);
    foreignProxy = await ForeignProxy.deploy(amb.address, arbitrator.address, arbitratorExtraData);

    const Realitio = await ethers.getContractFactory("MockRealitio", governor);
    realitio = await Realitio.deploy();

    const HomeProxy = await ethers.getContractFactory("RealitioHomeArbitrationProxy", governor);
    homeProxy = await HomeProxy.deploy(amb.address, realitio.address);

    const setArbitratorTx = await realitio.setArbitrator(homeProxy.address);
    await setArbitratorTx.wait();

    const setForeignProxyTx = await homeProxy.setForeignProxy(foreignProxy.address);
    await setForeignProxyTx.wait();

    const setHomeProxyTx = await foreignProxy.setHomeProxy(homeProxy.address);
    await setHomeProxyTx.wait();
    const initializeTx = await foreignProxy.initialize(metaEvidence);
    await initializeTx.wait();
  });

  describe("Request Arbitration", () => {
    beforeEach("Create question and submit answer", async () => {
      const askTx = await realitio.connect(asker).askQuestion(question);
      const askTxReceipt = await askTx.wait();
      questionId = getEventArgs("LogNewQuestion", askTxReceipt)._questionId;

      await submitAnswer(questionId, currentAnswer);
    });

    describe("When requester answer is different from the current answer", () => {
      it("should immediately notify Realitio of the arbitration request when the requester answer is different from the current one", async () => {
        const {txPromise} = await requestArbitration(questionId, requesterAnswer);

        await expect(txPromise)
          .to.emit(homeProxy, "RequestNotified")
          .withArgs(questionId, requesterAnswer, await requester.getAddress());
        await expect(txPromise)
          .to.emit(realitio, "LogNotifyOfArbitrationRequest")
          .withArgs(questionId, await requester.getAddress());
      });

      it("should pass the message to create the dispute after notifying Realitio of the arbitration request", async () => {
        await requestArbitration(questionId, requesterAnswer);

        const {txPromise} = await handleRequestNotification(questionId);

        await expect(txPromise).to.emit(foreignProxy, "ArbitrationCreated");
        await expect(txPromise).to.emit(arbitrator, "DisputeCreation");
      });
    });

    describe("When requester answer is the same as the current answer during arbitration request", () => {
      it("should wait before notifying Realitio of the arbitration request", async () => {
        await submitAnswer(questionId, requesterAnswer);

        const {txPromise} = await requestArbitration(questionId, requesterAnswer);

        await expect(txPromise)
          .to.emit(homeProxy, "RequestPending")
          .withArgs(questionId, requesterAnswer, await requester.getAddress());
        await expect(txPromise).not.to.emit(realitio, "LogNotifyOfArbitrationRequest");
      });

      it("should notify Realitio of the arbitration request and pass the message to create the dispute when current answer becomes different from the requester one", async () => {
        await submitAnswer(questionId, requesterAnswer);
        await requestArbitration(questionId, requesterAnswer);
        await submitAnswer(questionId, currentAnswer);

        const txPromise = homeProxy.handleAnswerChanged(questionId);

        await expect(txPromise)
          .to.emit(realitio, "LogNotifyOfArbitrationRequest")
          .withArgs(questionId, await requester.getAddress());
        await expect(txPromise).to.emit(foreignProxy, "ArbitrationCreated");
        await expect(txPromise).to.emit(arbitrator, "DisputeCreation");
      });

      it("should pass the message to cancel the dispute when the current answer becomes final", async () => {
        await submitAnswer(questionId, requesterAnswer);
        await requestArbitration(questionId, requesterAnswer);
        await submitAnswer(questionId, currentAnswer);
        await finalizeQuestion(questionId);

        const {txPromise} = await handleQuestionFinalized(questionId);

        await expect(txPromise).to.emit(foreignProxy, "ArbitrationCancelled");
        await expect(txPromise).not.to.emit(realitio, "LogNotifyOfArbitrationRequest");
        await expect(txPromise).not.to.emit(arbitrator, "DisputeCreation");
      });

      it("should reimbuser the requester when the current answer becomes final before the dispute is created", async () => {
        await submitAnswer(questionId, requesterAnswer);
        await requestArbitration(questionId, requesterAnswer);
        await submitAnswer(questionId, currentAnswer);
        await finalizeQuestion(questionId);

        const balanceBefore = await requester.getBalance();
        await handleQuestionFinalized(questionId);
        const balanceAfter = await requester.getBalance();

        const expectedBalance = balanceBefore.add(arbitrationFee);
        expect(balanceAfter).to.equal(expectedBalance, "Requeter was not properly reimbursed");
      });
    });

    describe("When arbitration cost changes between the arbitration request and acknowledgement", () => {
      beforeEach("Request arbitration", async () => {
        await requestArbitration(questionId, requesterAnswer);
      });

      it("Should create the dispute when arbitration cost decreases", async () => {
        const newArbitrationFee = arbitrationFee.div(2);
        await setArbitrationCost(newArbitrationFee);

        const {txPromise} = await handleRequestNotification(questionId);

        await expect(txPromise).to.emit(foreignProxy, "ArbitrationCreated");
        await expect(txPromise).to.emit(arbitrator, "DisputeCreation");
      });

      it("Should send the remainig arbitration fee to the requester when arbitration cost decreases", async () => {
        const newArbitrationFee = arbitrationFee.div(2);
        await setArbitrationCost(newArbitrationFee);

        const balanceBefore = await requester.getBalance();
        await handleRequestNotification(questionId);
        const balanceAfter = await requester.getBalance();

        const expectedBalance = balanceBefore.add(newArbitrationFee);
        expect(balanceAfter).to.equal(expectedBalance, "Requeter was not properly reimbursed");
      });

      it("Should cancel the dispute creation when arbitration cost increases", async () => {
        const newArbitrationFee = arbitrationFee.mul(2);
        await setArbitrationCost(newArbitrationFee);

        const {txPromise} = await handleRequestNotification(questionId);

        await expect(txPromise).to.emit(foreignProxy, "ArbitrationFailed").withArgs(questionId);
        await expect(txPromise).not.to.emit(arbitrator, "DisputeCreation");
      });

      it("Should pass the message informing the dispute creation failed due to an increase in arbitration cost", async () => {
        const newArbitrationFee = arbitrationFee.mul(2);
        await setArbitrationCost(newArbitrationFee);
        await handleRequestNotification(questionId);

        const {txPromise} = await handleFailedDisputeCreation(questionId);

        await expect(txPromise).to.emit(homeProxy, "ArbitrationFailed").withArgs(questionId);
        await expect(txPromise).to.emit(realitio, "LogCancelArbitrationRequest").withArgs(questionId);
      });

      it("Should reimburse the requester when the dispute creation failed due to an increase in arbitration cost", async () => {
        const newArbitrationFee = arbitrationFee.mul(2);
        await setArbitrationCost(newArbitrationFee);
        await handleRequestNotification(questionId);

        const balanceBefore = await requester.getBalance();
        await handleFailedDisputeCreation(questionId);
        const balanceAfter = await requester.getBalance();

        const expectedBalance = balanceBefore.add(arbitrationFee);
        expect(balanceAfter).to.equal(expectedBalance, "Requeter was not properly reimbursed");
      });
    });
  });

  describe("Arbitrator provide ruling", () => {
    beforeEach("Create question, submit answer and requet arbitration", async () => {
      const askTx = await realitio.connect(asker).askQuestion(question);
      const askTxReceipt = await askTx.wait();
      questionId = getEventArgs("LogNewQuestion", askTxReceipt)._questionId;

      await submitAnswer(questionId, currentAnswer);
      await requestArbitration(questionId, requesterAnswer);
      await handleRequestNotification(questionId);
    });

    it("Should pass the message with the ruling when the arbitrator rules", async () => {
      const ruling = 2; // rules in favor of the requester
      const {txPromise} = await rule(questionId, ruling);

      await expect(txPromise).to.emit(homeProxy, "ArbitratorAnswered").withArgs(questionId, requesterAnswer);
    });

    it("Should notify Realitio of the answer given by the arbitrator when the home proxy reports the answer", async () => {
      const ruling = 1; // rules in favor of the original answer
      await rule(questionId, ruling);

      const {txPromise} = await reportAnswer(questionId);
      await expect(txPromise).to.emit(realitio, "LogFinalize").withArgs(questionId, currentAnswer);
    });
  });

  async function submitAnswer(questionId, answer, signer = answerer) {
    const txPromise = realitio.connect(signer).submitAnswer(questionId, answer, 0);
    const tx = await txPromise;
    const receipt = await tx.wait();

    return {txPromise, tx, receipt};
  }

  async function requestArbitration(questionId, requesterAnswer, signer = requester) {
    const txPromise = foreignProxy
      .connect(signer)
      .requestArbitration(questionId, requesterAnswer, {value: arbitrationFee});
    const tx = await txPromise;
    const receipt = await tx.wait();

    return {txPromise, tx, receipt};
  }

  async function setArbitrationCost(cost, signer = governor) {
    const txPromise = arbitrator.connect(signer).setArbitrationCost(cost);
    const tx = await txPromise;
    const receipt = await tx.wait();

    return {txPromise, tx, receipt};
  }

  async function finalizeQuestion(questionId, signer = governor) {
    const txPromise = realitio.connect(signer).finalizeQuestion(questionId);
    const tx = await txPromise;
    const receipt = await tx.wait();

    return {txPromise, tx, receipt};
  }

  async function handleQuestionFinalized(questionId, signer = governor) {
    const txPromise = homeProxy.connect(signer).handleQuestionFinalized(questionId);
    const tx = await txPromise;
    const receipt = await tx.wait();

    return {txPromise, tx, receipt};
  }

  async function handleRequestNotification(questionId, signer = governor) {
    const txPromise = homeProxy.connect(signer).handleRequestNotification(questionId);
    const tx = await txPromise;
    const receipt = await tx.wait();

    return {txPromise, tx, receipt};
  }

  async function handleFailedDisputeCreation(questionId, signer = governor) {
    const txPromise = foreignProxy.connect(signer).handleFailedDisputeCreation(questionId);
    const tx = await txPromise;
    const receipt = await tx.wait();

    return {txPromise, tx, receipt};
  }

  async function rule(questionId, ruling, signer = governor) {
    const question = await foreignProxy.arbitrations(questionId);

    const txPromise = arbitrator.connect(signer).rule(question.disputeID, ruling);
    const tx = await txPromise;
    const receipt = await tx.wait();

    return {txPromise, tx, receipt};
  }

  async function reportAnswer(questionId, signer = governor) {
    const txPromise = homeProxy.connect(signer).reportAnswer(questionId, ZERO_HASH, ZERO_HASH, ZERO_ADDRESS);
    const tx = await txPromise;
    const receipt = await tx.wait();

    return {txPromise, tx, receipt};
  }

  function getEventArgs(eventName, receipt) {
    const event = receipt.events.find(({event}) => event === eventName);
    if (!event) {
      throw new Error(`Event ${eventName} not emiited in transaction`);
    }

    const omitIntegerKeysReducer = (acc, [key, value]) =>
      Number.isNaN(parseInt(key, 10)) ? Object.assign(acc, {[key]: value}) : acc;

    return Object.entries(event.args).reduce(omitIntegerKeysReducer, {});
  }
});
