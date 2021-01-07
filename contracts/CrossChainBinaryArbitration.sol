// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

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
     * @dev Emitted when an item is registered.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     */
    event MetaEvidenceRegistered(
        ICrossChainArbitrable indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        string _metaEvidence
    );

    /**
     * @dev Emitted when an item is registered.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    event ArbitratorExtraDataRegistered(
        ICrossChainArbitrable indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        bytes _arbitratorExtraData
    );

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
     */
    event DisputeAccepted(ICrossChainArbitrable indexed _arbitrable, uint256 indexed _arbitrableItemID);

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
     * @notice Registers meta evidence at arbitrable item level.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     */
    function registerMetaEvidence(uint256 _arbitrableItemID, string calldata _metaEvidence) external;

    /**
     * @notice Registers arbitrator extra data at arbitrable item level.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function registerArbitratorExtraData(uint256 _arbitrableItemID, bytes calldata _arbitratorExtraData) external;

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
     * @dev Emitted when an arbitrable item meta evidence is received.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     */
    event MetaEvidenceReceived(address indexed _arbitrable, uint256 indexed _arbitrableItemID, string _metaEvidence);

    /**
     * @dev Emitted when the arbitrator extra data related to an arbitrable item is received.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    event ArbitratorExtraDataReceived(
        address indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        bytes _arbitratorExtraData
    );

    /**
     * @dev Emitted when a dispute is requested.
     * @param _arbitrationID The ID of the arbitration.
     * @param _plaintiff The address of the plaintiff.
     */
    event DisputeRequested(uint256 indexed _arbitrationID, address indexed _plaintiff);

    /**
     * @dev Emitted when a dispute is accepted by the arbitrable contract on the Home Chain.
     * @param _arbitrationID The ID of the arbitration.
     */
    event DisputeAccepted(uint256 indexed _arbitrationID);

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
     */
    event DisputeFailed(uint256 indexed _arbitrationID, IArbitrator indexed _arbitrator, bytes _arbitratorExtraData);

    /**
     * @dev Emitted when a dispute is ongoing.
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
     * @notice Receives meta evidence at arbitrable item level.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     */
    function receiveMetaEvidence(
        address _arbitrable,
        uint256 _arbitrableItemID,
        string calldata _metaEvidence
    ) external;

    /**
     * @notice Receives arbitrator extra data at arbitrable item level.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function receiveArbitratorExtraData(
        address _arbitrable,
        uint256 _arbitrableItemID,
        bytes calldata _arbitratorExtraData
    ) external;

    /**
     * @notice Receives from the Home Chain that the dispute has been accepted.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function receiveDisputeAccepted(address _arbitrable, uint256 _arbitrableItemID) external;

    /**
     * @notice Receives from the Home Chain that the dispute has been rejected.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function receiveDisputeRejected(address _arbitrable, uint256 _arbitrableItemID) external;

    /**
     * @notice Allows to submit evidence for a particular question.
     * @param _arbitrationID The ID of the arbitration.
     * @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint256 _arbitrationID, string calldata _evidenceURI) external;
}
