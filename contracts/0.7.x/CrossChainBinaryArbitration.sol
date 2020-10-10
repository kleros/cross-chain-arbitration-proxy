// SPDX-License-Identifier: MIT
pragma solidity ^0.7.2;

import "@kleros/erc-792/contracts/IArbitrable.sol";

/**
 * @dev Arbitrable interface for cross-chain arbitration.
 */
interface ICrossChainArbitrable is IArbitrable {
    /**
     * @notice Notifies that a dispute has been requested for an arbitrable item.
     * @param _arbitrableItemID The ID of the arbitration item.
     * @param _plaintiff The address of the dispute requester.
     */
    function notifyDisputeRequest(uint256 _arbitrableItemID, address _plaintiff) external;

    /**
     * @notice Cancels a dispute previously requested for an arbitrable item.
     * @param _arbitrableItemID The ID of the arbitration item.
     */
    function cancelDispute(uint256 _arbitrableItemID) external;

    /**
     * @notice Returns whether an arbitrable item is subject to a dispute or not.
     * @param _arbitrableItemID The ID of the arbitration item.
     * @return The disputability status.
     */
    function isDisputable(uint256 _arbitrableItemID) external view returns (bool);

    /**
     * @notice Returns the defendant party for a dispute.
     * @param _arbitrableItemID The ID of the arbitration item.
     * @return The address of the defendant party.
     */
    function getDefendant(uint256 _arbitrableItemID) external view returns (address);

    /**
     * @notice Give a ruling for a dispute. Must be called by the arbitrator.
     * @param _arbitrableItemID The ID of the arbitration item.
     * @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint256 _arbitrableItemID, uint256 _ruling) external override;
}

/**
 * @dev Arbitration Proxy on the side chain.
 */
interface IHomeBinaryArbitrationProxy {
    /**
     * @dev Emitted when an arbitrable contract is registered.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    event ContractRegistered(
        ICrossChainArbitrable indexed _arbitrable,
        string _metaEvidence,
        bytes _arbitratorExtraData
    );

    /**
     * @dev Emitted when an item is registered.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    event ItemRegistered(
        ICrossChainArbitrable indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        string _metaEvidence,
        bytes _arbitratorExtraData
    );

    /**
     * @dev Emitted when an arbitrable item is registered.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    event DisputableItem(ICrossChainArbitrable indexed _arbitrable, uint256 indexed _arbitrableItemID);

    /**
     * @dev Emitted when a dispute request for an arbitrable item is received.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _plaintiff The address of the dispute creator.
     */
    event DisputeRequest(
        ICrossChainArbitrable indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        address indexed _plaintiff
    );

    /**
     * @dev Emitted when a dispute request for an arbitrable item is accepted.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _defendant The address of the defendant in the dispute.
     */
    event DisputeAccepted(
        ICrossChainArbitrable indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        address _defendant
    );

    /**
     * @dev Emitted when a dispute request for an arbitrable item is rejected.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    event DisputeRejected(ICrossChainArbitrable indexed _arbitrable, uint256 indexed _arbitrableItemID);

    /**
     * @dev Emitted when a dispute was created on the Foreign Chain.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _disputeID the ID of the dispute on the Foreign Chain arbitrator.
     */
    event DisputeCreated(
        ICrossChainArbitrable indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        uint256 indexed _disputeID
    );

    /**
     * @dev Emitted when a dispute creation on the Foreign Chain fails.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    event DisputeFailed(ICrossChainArbitrable indexed _arbitrable, uint256 indexed _arbitrableItemID);

    /**
     * @dev Emitted when a dispute creation on the Foreign Chain fails.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _ruling The ruling provided by the arbitrator on the Foreign Chain.
     */
    event DisputeRuled(ICrossChainArbitrable indexed _arbitrable, uint256 indexed _arbitrableItemID, uint256 _ruling);

    /**
     * @notice Registers the dispute params at arbitrable contract level.
     * @dev Should be called only by the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function registerArbitrableContract(string calldata _metaEvidence, bytes calldata _arbitratorExtraData) external;

    /**
     * @notice Registers the dispute params at arbitrable item level.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function registerArbitrableItem(
        uint256 _arbitrableItemID,
        string calldata _metaEvidence,
        bytes calldata _arbitratorExtraData
    ) external;

    /**
     * @notice Sets a given arbitrable item as disputable.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function setDisputableItem(uint256 _arbitrableItemID) external;

    /**
     * @notice Receives a dispute request for an arbitrable item from the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _plaintiff The address of the dispute creator.
     */
    function receiveDisputeRequest(
        ICrossChainArbitrable _arbitrable,
        uint256 _arbitrableItemID,
        address _plaintiff
    ) external;

    /**
     * @notice Relays to the Foreign Chain that a dispute has been accepted.
     * @dev This will likely be called by an external 3rd-party (i.e.: a bot),
     * since currently there cannot be a bi-directional cross-chain message.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function relayDisputeAccepted(ICrossChainArbitrable _arbitrable, uint256 _arbitrableItemID) external;

    /**
     * @notice Relays to the Foreign Chain that a dispute has been rejected.
     * This can happen either because the deadline has passed during the cross-chain
     * message to notify of the dispute request being in course or if the arbitrable
     * contract changed the state for the item and made it non-disputable.
     * @dev This will likely be called by an external 3rd-party (i.e.: a bot),
     * since currently there cannot be a bi-directional cross-chain message.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function relayDisputeRejected(ICrossChainArbitrable _arbitrable, uint256 _arbitrableItemID) external;

    /**
     * @notice Receives the dispute created on the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _arbitrator The address of the arbitrator in the home chain.
     * @param _arbitratorDisputeID The dispute ID.
     */
    function receiveDisputeCreated(
        ICrossChainArbitrable _arbitrable,
        uint256 _arbitrableItemID,
        address _arbitrator,
        uint256 _arbitratorDisputeID
    ) external;

    /**
     * @notice Receives the failed dispute creation on the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function receiveDisputeFailed(ICrossChainArbitrable _arbitrable, uint256 _arbitrableItemID) external;

    /**
     * @notice Receives the ruling for a dispute from the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract on the Home Chain.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _ruling The ruling given by the arbitrator.
     */
    function receiveRuling(
        ICrossChainArbitrable _arbitrable,
        uint256 _arbitrableItemID,
        uint256 _ruling
    ) external;
}

/**
 * @dev Arbitration Proxy on the main chain.
 */
interface IForeignBinaryArbitrationProxy is IArbitrable {
    /**
     * @dev Emitted when an arbitrable contract registration is received.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    event ContractReceived(address indexed _arbitrable, string _metaEvidence, bytes _arbitratorExtraData);

    /**
     * @dev Emitted when an arbitrable item registration is received.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    event ItemReceived(
        address indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        string _metaEvidence,
        bytes _arbitratorExtraData
    );

    /**
     * @dev Emitted when an receiving an arbitrable item marked as disputable.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    event DisputableItemReceived(address indexed _arbitrable, uint256 indexed _arbitrableItemID);

    /**
     * @dev Emitted when a dispute is requested.
     * @param _arbitrationID The ID of the arbitration.
     * @param _plaintiff The address of the plaintiff.
     */
    event DisputeRequested(uint256 indexed _arbitrationID, address indexed _plaintiff);

    /**
     * @dev Emitted when a dispute is accepted by the arbitrable contract on the Home Chain.
     * @param _arbitrationID The ID of the arbitration.
     * @param _defendant The address of the defendant party.
     */
    event DisputeAccepted(uint256 indexed _arbitrationID, address indexed _defendant);

    /**
     * @dev Emitted when a dispute is rejected by the arbitrable contract on the Home Chain.
     * @param _arbitrationID The ID of the arbitration.
     */
    event DisputeRejected(uint256 indexed _arbitrationID);

    /**
     * @dev Emitted when a dispute creation fails.
     * @param _arbitrationID The ID of the arbitration.
     * @param _arbitrator Arbitrator contract address.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     * @param _reason The reason the dispute creation failed.
     */
    event DisputeFailed(
        uint256 indexed _arbitrationID,
        IArbitrator indexed _arbitrator,
        bytes _arbitratorExtraData,
        bytes _reason
    );

    /**
     * @dev Emitted when a dispute creation fails.
     * This event is required to allow detecting the dispute for a given arbitrable was created.
     * The `Dispute` event from `IEvidence` does not have the proper indexes.
     * @param _arbitrationID The ID of the arbitration.
     * @param _arbitrator Arbitrator contract address.
     * @param _arbitratorDisputeID ID of the dispute on the Arbitrator contract.
     */
    event DisputeOngoing(
        uint256 indexed _arbitrationID,
        IArbitrator indexed _arbitrator,
        uint256 indexed _arbitratorDisputeID
    );

    /**
     * @dev Emitted when a dispute is ruled by the arbitrator.
     * This event is required to allow detecting the dispute for a given arbitrable was ruled.
     * The `Ruling` event from `IArbitrable` does not have the proper indexes.
     * @param _arbitrationID The ID of the arbitration.
     * @param _ruling The ruling for the arbitration dispute.
     */
    event DisputeRuled(uint256 indexed _arbitrationID, uint256 _ruling);

    /**
     * @notice Receives the dispute params for an arbitrable contract.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function receiveArbitrableContract(
        address _arbitrable,
        string calldata _metaEvidence,
        bytes calldata _arbitratorExtraData
    ) external;

    /**
     * @notice Receives the dispute params for an arbitrable item.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function receiveArbitrableItem(
        address _arbitrable,
        uint256 _arbitrableItemID,
        string calldata _metaEvidence,
        bytes calldata _arbitratorExtraData
    ) external;

    /**
     * @notice Receives an arbitrable item marked as disputable.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function receiveDisputableItem(address _arbitrable, uint256 _arbitrableItemID) external;

    /**
     * @notice Receives from the Home Chain that the dispute has been accepted.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _defendant The address of the defendant party.
     */
    function receiveDisputeAccepted(
        address _arbitrable,
        uint256 _arbitrableItemID,
        address _defendant
    ) external;

    /**
     * @notice Receives from the Home Chain that the dispute has been rejected.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function receiveDisputeRejected(address _arbitrable, uint256 _arbitrableItemID) external;
}
