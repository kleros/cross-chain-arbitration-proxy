// SPDX-License-Identifier: MIT
pragma solidity ^0.7.1;

import "@kleros/erc-792/contracts/IArbitrable.sol";

/**
 * @dev Arbitrable interface for cross-chain arbitration.
 */
interface ICrossChainArbitrable is IArbitrable {
    /**
     * @notice Notifies that a dispute has been requested for an arbitrable item.
     * @param _arbitrableItemID The ID of the arbitrable item.
     * @param _plaintiff The address of the dispute requester.
     */
    function notifyDisputeRequest(uint256 _arbitrableItemID, address _plaintiff) external;

    /**
     * @notice Cancels a dispute previously requested for an arbitrable item.
     * @param _arbitrableItemID The ID of the arbitrable item.
     */
    function cancelDispute(uint256 _arbitrableItemID) external;

    /**
     * @notice Confirms the dispute was created.
     * @param _arbitrableItemID The ID of the arbitrable item.
     * @param _disputeID The ID of the dispute.
     */
    function confirmDispute(uint256 _arbitrableItemID, uint256 _disputeID) external;

    /**
     * @notice Returns whether an arbitrable item is subject to a dispute or not.
     * @param _arbitrableItemID The ID of the arbitrable item.
     * @return The disputability status.
     */
    function isDisputable(uint256 _arbitrableItemID) external view returns (bool);
}

/**
 * @dev Arbitration Proxy on the side chain.
 */
interface IHomeBinaryArbitrationProxy {
    /**
     * @dev Emitted when the MetaEvidence for an arbitrable item is emitted.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _metaEvidence The meta evidence.
     */
    event ArbitrableMetaEvidence(
        ICrossChainArbitrable indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        string _metaEvidence
    );

    /**
     * @dev Emitted when an arbitrable item becomes disputable.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _defendant The address of the defendant in case there is a dispute.
     * @param _deadline The absolute time until which the dispute can be created.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    event ArbitrableDisputable(
        ICrossChainArbitrable indexed _arbitrable,
        uint256 indexed _arbitrableItemID,
        address indexed _defendant,
        uint256 _deadline,
        bytes _arbitratorExtraData
    );

    /**
     * @dev Emitted when a dispute request for an arbitrable item is received.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
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
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    event DisputeAccepted(ICrossChainArbitrable indexed _arbitrable, uint256 indexed _arbitrableItemID);

    /**
     * @dev Emitted when a dispute request for an arbitrable item is rejected.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    event DisputeRejected(ICrossChainArbitrable indexed _arbitrable, uint256 indexed _arbitrableItemID);

    /**
     * @dev Emitted when a dispute was created on the Foreign Chain.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
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
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    event DisputeFailed(ICrossChainArbitrable indexed _arbitrable, uint256 indexed _arbitrableItemID);

    /**
     * @dev Emitted when a dispute creation on the Foreign Chain fails.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _ruling The ruling provided by the arbitrator on the Foreign Chain.
     */
    event DisputeRuled(ICrossChainArbitrable indexed _arbitrable, uint256 indexed _arbitrableItemID, uint256 _ruling);

    /**
     * @notice Registers an arbitrable item.
     * @dev Should be called by the arbitrable contract when the meta evidence is created.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _metaEvidence The meta evidence.
     */
    function register(uint256 _arbitrableItemID, string calldata _metaEvidence) external;

    /**
     * @notice Sets an arbitrable item as disputable.
     * @dev Should be called by the arbitrable contract when the arbitrable item can be disputed.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _defendant The address of the defendant in case there is a dispute.
     * @param _deadline The absolute time until which the dispute can be created.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function setDisputable(
        uint256 _arbitrableItemID,
        address _defendant,
        uint256 _deadline,
        bytes calldata _arbitratorExtraData
    ) external;

    /**
     * @notice Receives a dispute request for an arbitrable item from the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
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
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
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
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function relayDisputeRejected(ICrossChainArbitrable _arbitrable, uint256 _arbitrableItemID) external;

    /**
     * @notice Receives the dispute created on the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _disputeID The dispute ID.
     */
    function receiveDisputeCreated(
        ICrossChainArbitrable _arbitrable,
        uint256 _arbitrableItemID,
        uint256 _disputeID
    ) external;

    /**
     * @notice Receives the failed dispute creation on the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function receiveDisputeFailed(ICrossChainArbitrable _arbitrable, uint256 _arbitrableItemID) external;

    /**
     * @notice Receives the ruling for a dispute from the Foreign Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract on the Home Chain.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
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
     * @dev Emitted when an arbitrable item becomes disputable.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _defendant The address of the defendant in case there is a dispute.
     * @param _deadline The absolute time until which the dispute can be created.
     */
    event DisputePossible(uint256 indexed _arbitrableID, address indexed _defendant, uint256 _deadline);

    /**
     * @dev Emitted when a dispute is requested.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _plaintiff The address of the plaintiff.
     */
    event DisputeRequested(uint256 indexed _arbitrableID, address indexed _plaintiff);

    /**
     * @dev Emitted when a dispute is accepted by the arbitrable contract on the Home Chain.
     * @param _arbitrableID The ID of the arbitrable.
     */
    event DisputeAccepted(uint256 indexed _arbitrableID);

    /**
     * @dev Emitted when a dispute is rejected by the arbitrable contract on the Home Chain.
     * @param _arbitrableID The ID of the arbitrable.
     */
    event DisputeRejected(uint256 indexed _arbitrableID);

    /**
     * @dev Emitted when a dispute creation fails.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _arbitrator Arbitrator contract address.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     * @param _reason The reason the dispute creation failed.
     */
    event DisputeFailed(
        uint256 indexed _arbitrableID,
        IArbitrator indexed _arbitrator,
        bytes _arbitratorExtraData,
        bytes _reason
    );

    /**
     * @dev Emitted when a dispute creation fails.
     * This event is required to allow detecting the dispute for a given arbitrable was created.
     * The `Dispute` event from `IEvidence` does not have the proper indexes.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _arbitrator Arbitrator contract address.
     * @param _arbitratorDisputeID ID of the dispute on the Arbitrator contract.
     */
    event DisputeOngoing(
        uint256 indexed _arbitrableID,
        IArbitrator indexed _arbitrator,
        uint256 indexed _arbitratorDisputeID
    );

    /**
     * @dev Emitted when a dispute is ruled by the arbitrator.
     * This event is required to allow detecting the dispute for a given arbitrable was ruled.
     * The `Ruling` event from `IArbitrable` does not have the proper indexes.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _ruling The ruling for the arbitration dispute.
     */
    event DisputeRuled(uint256 indexed _arbitrableID, uint256 _ruling);

    /**
     * @notice Receives the meta evidence from the Home Chain.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract on the Home Chain.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _metaEvidence The meta evidence.
     */
    function receiveMetaEvidence(
        address _arbitrable,
        uint256 _arbitrableItemID,
        string calldata _metaEvidence
    ) external;

    /**
     * @notice Receives from the Home Chain that an arbitrable item is subject to a dispute.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract on the Home Chain.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _defendant The address of the defendant in case there is a dispute.
     * @param _deadline The absolute time until which the dispute can be created.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function receiveDisputable(
        address _arbitrable,
        uint256 _arbitrableItemID,
        address _defendant,
        uint256 _deadline,
        bytes calldata _arbitratorExtraData
    ) external;

    /**
     * @notice Receives from the Home Chain that the dispute has been accepted.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function receiveDisputeAccepted(address _arbitrable, uint256 _arbitrableItemID) external;

    /**
     * @notice Receives from the Home Chain that the dispute has been rejected.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function receiveDisputeRejected(address _arbitrable, uint256 _arbitrableItemID) external;
}
