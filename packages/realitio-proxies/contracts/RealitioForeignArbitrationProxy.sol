// SPDX-License-Identifier: MIT
pragma solidity ^0.7.2;

import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/xdai-amb-interface/contracts/IAMB.sol";
import "./ArbitrationProxyInterfaces.sol";

contract RealitioForeignArbitrationProxy is IForeignArbitrationProxy, IArbitrable, IEvidence {
    /// @dev The contract governor. TRUSTED.
    address public governor = msg.sender;

    /// @dev Whether the contract has been properly initialized or not.
    bool public initialized;

    /// @dev The address of the arbitrator. TRUSTED.
    IArbitrator public arbitrator;

    /// @dev The extra data used to raise a dispute in the arbitrator.
    bytes public arbitratorExtraData;

    /// @dev The number of choices for the arbitrator.
    uint256 public constant NUMBER_OF_CHOICES_FOR_ARBITRATOR = (2**256) - 2;

    /// @dev ArbitraryMessageBridge contract address. TRUSTED.
    IAMB public amb;

    /// @dev Address of the counter-party proxy on the Home Chain. TRUSTED.
    address public homeProxy;

    enum Status {None, Requested, Created, Failed}

    struct Arbitration {
        // Status of the arbitration.
        Status status;
        // Address that made the arbitration or paid the remaining fee.
        address requester;
        // The deposit paid by the requester at the time of the arbitration.
        uint256 deposit;
        // The dispute ID after it is created.
        uint256 disputeID;
    }

    /// @dev Tracks arbitration requests for question ID.
    mapping(bytes32 => Arbitration) public arbitrations;

    /// @dev Associates dispute IDs to question IDs.
    mapping(uint256 => bytes32) public disputeIDToQuestionID;

    /**
     * @dev Should be emitted when the arbitration is requested.
     * @param _questionID The ID of the question to be arbitrated.
     * @param _answer The answer provided by the requester.
     * @param _requester The requester.
     */
    event ArbitrationRequested(bytes32 indexed _questionID, bytes32 _answer, address indexed _requester);

    /**
     * @dev Should be emitted when the dispute is created.
     * @param _questionID The ID of the question to be arbitrated.
     * @param _disputeID The ID of the dispute.
     */
    event ArbitrationCreated(bytes32 indexed _questionID, uint256 indexed _disputeID);

    /**
     * @dev Should be emitted when the dispute could not be created.
     * @notice This will happen if there is an increase in the arbitration fees
     * between the time the arbitration is made and the time it is acknowledged.
     * @param _questionID The ID of the question to be arbitrated.
     */
    event ArbitrationFailed(bytes32 indexed _questionID);

    /**
     * @dev Should be emitted when the arbitration arbitration is cancelled by the Home Chain.
     * @param _questionID The ID of the question to be arbitrated.
     */
    event ArbitrationCancelled(bytes32 indexed _questionID);

    modifier onlyArbitrator() {
        require(msg.sender == address(arbitrator), "Only arbitrator allowed");
        _;
    }

    modifier onlyGovernor() {
        require(msg.sender == governor, "Only governor allowed");
        _;
    }

    modifier onlyAmb() {
        require(msg.sender == address(amb), "Only AMB allowed");
        _;
    }

    modifier onlyHomeProxy() {
        require(amb.messageSender() == homeProxy, "Only home proxy allowed");
        _;
    }

    modifier onlyIfInitialized() {
        require(initialized, "Not initialized yet");
        _;
    }

    /**
     * @dev Creates an arbitration proxy on the foreign chain.
     * @notice Contract will still require initialization before being usable.
     * @param _amb ArbitraryMessageBridge contract address.
     * @param _arbitrator Arbitrator contract address.
     * @param _arbitratorExtraData The extra data used to raise a dispute in the arbitrator.
     */
    constructor(
        IAMB _amb,
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData
    ) {
        amb = _amb;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
    }

    /**
     * @dev Initializes the contract so it can start receiving arbitration requests.
     * @notice This function can only be called once, after `homeProxy` has already been set for the first time.
     * Since there is a circular dependency between `RealitioForeignArbitrationProxy` and `RealitioHomeArbitrationProxy`,
     * it is not possible to require the home proxy to be a constructor param.
     * @param _metaEvidence The URI of the meta evidence file.
     */
    function initialize(string calldata _metaEvidence) external onlyGovernor {
        require(!initialized, "Proxy already initialized");
        require(homeProxy != address(0), "Home proxy not set");

        initialized = true;

        emit MetaEvidence(0, _metaEvidence);
    }

    /**
     * @dev Sets the address of a new governor.
     * @param _governor The address of the new governor.
     */
    function setGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    /**
     * @dev Sets the address of the ArbitraryMessageBridge.
     * @param _amb The address of the new ArbitraryMessageBridge.
     */
    function setAmb(IAMB _amb) external onlyGovernor {
        amb = _amb;
    }

    /**
     * @dev Sets the address of the arbitrator.
     * @param _arbitrator The address of the new arbitrator.
     */
    function setArbitrator(IArbitrator _arbitrator) external onlyGovernor {
        arbitrator = _arbitrator;
    }

    /**
     * @dev Sets the address of the arbitration proxy on the Home Chain.
     * @param _homeProxy The address of the proxy.
     */
    function setHomeProxy(address _homeProxy) external onlyGovernor {
        homeProxy = _homeProxy;
    }

    /**
     * @dev Sets the extra data for disputes.
     * @param _arbitratorExtraData The extra data used to raise a dispute in the arbitrator.
     */
    function setArbitratorExtraData(bytes calldata _arbitratorExtraData) external onlyGovernor {
        arbitratorExtraData = _arbitratorExtraData;
    }

    /**
     * @dev Requests arbitration for given question ID.
     * @notice Can be executed only if the contract has been initialized.
     * @param _questionID The ID of the question.
     * @param _requesterAnswer The answer the requester deem to be correct.
     */
    function requestArbitration(bytes32 _questionID, bytes32 _requesterAnswer) external payable onlyIfInitialized {
        Arbitration storage arbitration = arbitrations[_questionID];
        require(arbitration.status == Status.None, "Arbitration already requested");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        require(msg.value >= arbitrationCost, "Deposit value too low");

        arbitration.status = Status.Requested;
        arbitration.requester = msg.sender;
        arbitration.deposit = msg.value;

        bytes4 methodSelector = IHomeArbitrationProxy(0).receiveArbitrationRequest.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, _questionID, _requesterAnswer, msg.sender);
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());

        emit ArbitrationRequested(_questionID, _requesterAnswer, msg.sender);
    }

    /**
     * @dev Requests arbitration for given question ID.
     * @param _questionID The ID of the question.
     */
    function acknowledgeArbitration(bytes32 _questionID) external override onlyAmb onlyHomeProxy {
        Arbitration storage arbitration = arbitrations[_questionID];
        require(arbitration.status == Status.Requested, "Invalid arbitration status");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);

        if (arbitration.deposit < arbitrationCost) {
            arbitration.status = Status.Failed;

            emit ArbitrationFailed(_questionID);
        } else {
            // At this point, arbitration.deposit is guaranteed to be greater than or equal arbitration cost.
            uint256 remainder = arbitration.deposit - arbitrationCost;

            uint256 disputeID = arbitrator.createDispute{value: arbitrationCost}(
                NUMBER_OF_CHOICES_FOR_ARBITRATOR,
                arbitratorExtraData
            );
            disputeIDToQuestionID[disputeID] = _questionID;
            arbitration.status = Status.Created;
            arbitration.disputeID = disputeID;
            arbitration.deposit = 0;

            payable(arbitration.requester).send(remainder);

            emit ArbitrationCreated(_questionID, disputeID);
        }
    }

    /**
     * @dev Cancels the arbitration arbitration.
     * @param _questionID The ID of the question.
     */
    function cancelArbitration(bytes32 _questionID) external override onlyAmb onlyHomeProxy {
        Arbitration storage arbitration = arbitrations[_questionID];
        require(arbitration.status == Status.Requested, "Invalid arbitration status");

        payable(arbitration.requester).send(arbitration.deposit);

        delete arbitrations[_questionID];

        emit ArbitrationCancelled(_questionID);
    }

    /**
     * @dev Cancels the arbitration arbitration in case the dispute could not be created.
     * @param _questionID The ID of the question.
     */
    function handleFailedDisputeCreation(bytes32 _questionID) external onlyIfInitialized {
        Arbitration storage arbitration = arbitrations[_questionID];
        require(arbitration.status == Status.Failed, "Invalid arbitration status");

        bytes4 methodSelector = IHomeArbitrationProxy(0).receiveArbitrationFailure.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, _questionID);
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());

        payable(arbitration.requester).send(arbitration.deposit);

        delete arbitrations[_questionID];

        emit ArbitrationCancelled(_questionID);
    }

    /**
     * @dev Rules a specified dispute.
     * @notice Note that 0 is reserved for "Unable/refused to arbitrate" and we map it to `bytes32(-1)` which has a similar connotation in Realitio.
     * @param _disputeID The ID of the dispute in the ERC792 arbitrator.
     * @param _ruling The ruling given by the arbitrator.
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override onlyArbitrator {
        bytes32 questionID = disputeIDToQuestionID[_disputeID];
        Arbitration storage arbitration = arbitrations[questionID];
        require(arbitration.status == Status.Created, "Invalid arbitration status");

        delete arbitrations[questionID];
        delete disputeIDToQuestionID[_disputeID];

        bytes32 answer = bytes32(_ruling == 0 ? uint256(-1) : _ruling - 1);

        bytes4 methodSelector = IHomeArbitrationProxy(0).receiveArbitrationAnswer.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, questionID, answer);
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());

        emit Ruling(arbitrator, _disputeID, _ruling);
    }
}
