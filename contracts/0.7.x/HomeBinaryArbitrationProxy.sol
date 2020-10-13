/**
 * @authors: [@hbarcelos]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 *
 * SPDX-License-Identifier: MIT
 */
pragma solidity ^0.7.2;

import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "./dependencies/IAMB.sol";
import "./CrossChainBinaryArbitration.sol";

contract HomeBinaryArbitrationProxy is IHomeBinaryArbitrationProxy {
    /**
     * State chart for AribtrableItem status.
     * (I) Means the initial state.
     * (F) Means a final state.
     * [condition] Means a guard condition.
     *
     *      Receive Request     +----------+
     *    +-------------------->+ Rejected |
     *    |   [Rejected]        +-----+----+
     *    |                           |
     *    |                           |
     *    |                           | Relay Rejected
     * +-(I)--+                       |
     * | None +<----------------------+
     * +--+---+                       |
     *    |                           |
     *    |                           | Receive Dispute Failed
     *    |                           |
     *    | Receive Request     +-----+----+                     +--(F)--+
     *    +-------------------->+ Accepted +-------------------->+ Ruled |
     *       [Accepted]         +----------+   Receive Ruling    +-------+
     */
    enum Status {None, Rejected, Accepted, Ruled}

    struct ArbitrableItem {
        Status status;
        address arbitrator;
        uint256 arbitratorDisputeID;
        uint256 ruling;
    }

    event Initialized();

    /// @dev Maps an arbitrable contract and and arbitrable item ID to a status
    mapping(ICrossChainArbitrable => mapping(uint256 => ArbitrableItem)) public arbitrableItems;

    /// @dev The contract governor. TRUSTED.
    address public governor = msg.sender;

    /// @dev Whether the contract has been properly initialized or not.
    bool public initialized;

    /// @dev ArbitraryMessageBridge contract address. TRUSTED.
    IAMB public amb;

    /// @dev Address of the counter-party proxy on the Foreign Chain. TRUSTED.
    address public foreignProxy;

    modifier onlyGovernor() {
        require(msg.sender == governor, "Only governor allowed");
        _;
    }

    modifier onlyAmb() {
        require(msg.sender == address(amb), "Only AMB allowed");
        _;
    }

    modifier onlyForeignProxy() {
        require(amb.messageSender() == foreignProxy, "Only foreign proxy allowed");
        _;
    }

    modifier onlyIfInitialized() {
        require(initialized, "Not initialized yet");
        _;
    }

    /**
     * @notice Creates an arbitration proxy on the foreign chain.  @dev The contract will still require initialization before being usable.  @param _amb ArbitraryMessageBridge contract address.
     */
    constructor(IAMB _amb) {
        amb = _amb;
    }

    /**
     * @dev Initializes the contract so it can start receiving arbitration requests.
     * @notice This function can only be called once, after `foreignProxy` has already been set for the first time.
     * Since there is a circular dependency between `ForeignBinaryArbitrationProxy` and `HomeBinaryArbitrationProxy`,
     * it is not possible to require the home proxy to be a constructor param.
     */
    function initialize() external onlyGovernor {
        require(!initialized, "Proxy already initialized");
        require(foreignProxy != address(0), "Foreign proxy not set");

        initialized = true;

        emit Initialized();
    }

    /**
     * @notice Sets the address of a new governor.
     * @param _governor The address of the new governor.
     */
    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    /**
     * @notice Sets the address of the ArbitraryMessageBridge.
     * @param _amb The address of the new ArbitraryMessageBridge.
     */
    function changeAmb(IAMB _amb) external onlyGovernor {
        amb = _amb;
    }

    /**
     * @notice Sets the address of the arbitration proxy on the Foreign Chain.
     * @param _foreignProxy The address of the proxy.
     */
    function changeForeignProxy(address _foreignProxy) external onlyGovernor {
        foreignProxy = _foreignProxy;
    }

    /**
     * @notice Registers the meta evidence at the arbitrable item level.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     */
    function registerItemMetaEvidence(uint256 _arbitrableItemID, string calldata _metaEvidence)
        external
        override
        onlyIfInitialized
    {
        emit ItemMetaEvidenceRegistered(ICrossChainArbitrable(msg.sender), _arbitrableItemID, _metaEvidence);

        bytes4 methodSelector = IForeignBinaryArbitrationProxy(0).receiveItemMetaEvidence.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, msg.sender, _arbitrableItemID, _metaEvidence);
        amb.requireToPassMessage(foreignProxy, data, amb.maxGasPerTx());
    }

    /**
     * @notice Registers the arbitrator extra data at the arbitrable item level.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function registerItemArbitratorExtraData(uint256 _arbitrableItemID, bytes calldata _arbitratorExtraData)
        external
        override
        onlyIfInitialized
    {
        emit ItemArbitratorExtraDataRegistered(
            ICrossChainArbitrable(msg.sender),
            _arbitrableItemID,
            _arbitratorExtraData
        );

        bytes4 methodSelector = IForeignBinaryArbitrationProxy(0).receiveItemArbitratorExtraData.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, msg.sender, _arbitrableItemID, _arbitratorExtraData);
        amb.requireToPassMessage(foreignProxy, data, amb.maxGasPerTx());
    }

    /**
     * @notice Sets a given arbitrable item as disputable.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function setDisputableItem(uint256 _arbitrableItemID) external override onlyIfInitialized {
        emit DisputableItem(ICrossChainArbitrable(msg.sender), _arbitrableItemID);

        bytes4 methodSelector = IForeignBinaryArbitrationProxy(0).receiveDisputableItem.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, msg.sender, _arbitrableItemID);
        amb.requireToPassMessage(foreignProxy, data, amb.maxGasPerTx());
    }

    /**
     * @notice Receives a dispute request for an arbitrable item from the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract. UNTRUSTED.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _plaintiff The address of the dispute creator.
     */
    function receiveDisputeRequest(
        ICrossChainArbitrable _arbitrable,
        uint256 _arbitrableItemID,
        address _plaintiff
    ) external override onlyAmb onlyForeignProxy {
        ArbitrableItem storage arbitrableItem = arbitrableItems[_arbitrable][_arbitrableItemID];

        require(arbitrableItem.status == Status.None, "Dispute request already exists");

        if (_arbitrable.isDisputable(_arbitrableItemID)) {
            arbitrableItem.status = Status.Accepted;
            _arbitrable.notifyDisputeRequest(_arbitrableItemID, _plaintiff);
        } else {
            arbitrableItem.status = Status.Rejected;
        }

        emit DisputeRequest(_arbitrable, _arbitrableItemID, _plaintiff);
    }

    /**
     * @notice Relays to the Foreign Chain that a dispute has been accepted.
     * @dev This will likely be called by an external 3rd-party (i.e.: a bot),
     * since currently there cannot be a bi-directional cross-chain message.
     * @param _arbitrable The address of the arbitrable contract. UNTRUSTED.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function relayDisputeAccepted(ICrossChainArbitrable _arbitrable, uint256 _arbitrableItemID) external override {
        ArbitrableItem storage arbitrableItem = arbitrableItems[_arbitrable][_arbitrableItemID];

        require(arbitrableItem.status == Status.Accepted, "Dispute is not accepted");

        address defendant = _arbitrable.getDefendant(_arbitrableItemID);

        emit DisputeAccepted(_arbitrable, _arbitrableItemID, defendant);

        bytes4 methodSelector = IForeignBinaryArbitrationProxy(0).receiveDisputeAccepted.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, address(_arbitrable), _arbitrableItemID, defendant);
        amb.requireToPassMessage(foreignProxy, data, amb.maxGasPerTx());
    }

    /**
     * @notice Relays to the Foreign Chain that a dispute has been rejected.
     * This can happen either because the deadline has passed during the cross-chain
     * message to notify of the dispute request being in course or if the arbitrable
     * contract changed the state for the item and made it non-disputable.
     * @dev This will likely be called by an external 3rd-party (i.e.: a bot),
     * since currently there cannot be a bi-directional cross-chain message.
     * @param _arbitrable The address of the arbitrable contract. UNTRUSTED.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function relayDisputeRejected(ICrossChainArbitrable _arbitrable, uint256 _arbitrableItemID) external override {
        ArbitrableItem storage arbitrableItem = arbitrableItems[_arbitrable][_arbitrableItemID];

        require(arbitrableItem.status == Status.Rejected, "Dispute is not rejected");

        delete arbitrableItems[_arbitrable][_arbitrableItemID];

        emit DisputeRejected(_arbitrable, _arbitrableItemID);

        bytes4 methodSelector = IForeignBinaryArbitrationProxy(0).receiveDisputeRejected.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, address(_arbitrable), _arbitrableItemID);
        amb.requireToPassMessage(foreignProxy, data, amb.maxGasPerTx());
    }

    /**
     * @notice Receives the dispute created on the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract. UNTRUSTED.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _arbitrator The address of the arbitrator in the home chain.
     * @param _arbitratorDisputeID The dispute ID.
     */
    function receiveDisputeCreated(
        ICrossChainArbitrable _arbitrable,
        uint256 _arbitrableItemID,
        address _arbitrator,
        uint256 _arbitratorDisputeID
    ) external override onlyAmb onlyForeignProxy {
        ArbitrableItem storage arbitrableItem = arbitrableItems[_arbitrable][_arbitrableItemID];

        require(arbitrableItem.status == Status.Accepted, "Dispute is not accepted");

        arbitrableItem.arbitrator = _arbitrator;
        arbitrableItem.arbitratorDisputeID = _arbitratorDisputeID;

        emit DisputeCreated(_arbitrable, _arbitrableItemID, _arbitratorDisputeID);
    }

    /**
     * @notice Receives the failed dispute creation on the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract. UNTRUSTED.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function receiveDisputeFailed(ICrossChainArbitrable _arbitrable, uint256 _arbitrableItemID)
        external
        override
        onlyAmb
        onlyForeignProxy
    {
        ArbitrableItem storage arbitrableItem = arbitrableItems[_arbitrable][_arbitrableItemID];

        require(arbitrableItem.status == Status.Accepted, "Dispute is not accepted");

        delete arbitrableItems[_arbitrable][_arbitrableItemID];
        _arbitrable.cancelDispute(_arbitrableItemID);

        emit DisputeFailed(_arbitrable, _arbitrableItemID);
    }

    /**
     * @notice Receives the ruling for a dispute from the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract. UNTRUSTED.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _ruling The ruling given by the arbitrator.
     */
    function receiveRuling(
        ICrossChainArbitrable _arbitrable,
        uint256 _arbitrableItemID,
        uint256 _ruling
    ) external override onlyAmb onlyForeignProxy {
        ArbitrableItem storage arbitrableItem = arbitrableItems[_arbitrable][_arbitrableItemID];

        // Allow receiving ruling if the dispute was accepted but not created.
        // This can happen if the defendant fails to fund her side in time.
        require(arbitrableItem.status == Status.Accepted, "Dispute cannot be ruled");

        arbitrableItem.status = Status.Ruled;
        arbitrableItem.ruling = _ruling;

        _arbitrable.rule(_arbitrableItemID, _ruling);

        emit DisputeRuled(_arbitrable, _arbitrableItemID, _ruling);
    }
}
