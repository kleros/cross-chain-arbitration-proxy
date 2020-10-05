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
     * @notice Returns whether an arbitrable item is subject to a dispute or not.
     * @param _arbitrableItemID The ID of the arbitrable item.
     * @return The disputability status.
     */
    function isDisputable(uint256 _arbitrableItemID) external view returns (bool);

    /**
     * @notice Returns the extra data for the arbitrator.
     * @param _arbitrableItemID The ID of the arbitrable item.
     * @return The arbitrator extra data.
     */
    function getArbitratorExtraData(uint256 _arbitrableItemID) external view returns (bytes memory);
}

/**
 * @dev Arbitration Proxy on the side chain.
 */
interface IHomeBinaryArbitrationProxy {
    /**
     * @notice Relays the meta evidence to the Foreign Chain.
     * @dev Should be called by the arbitrable contract when the meta evidence is created.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _metaEvidence The meta evidence.
     */
    function relayMetaEvidence(uint256 _arbitrableItemID, string calldata _metaEvidence) external;

    /**
     * @notice Relays to the Foreign Chain that an arbitrable item is subject to a dispute.
     * @dev Should be called by the arbitrable contract when the arbitrable item can be disputed.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     * @param _defendant The address of the defendant in case there is a dispute.
     * @param _deadline The absolute time until which the dispute can be created.
     */
    function relayDisputable(
        uint256 _arbitrableItemID,
        address _defendant,
        uint256 _deadline
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
     * @param _arbitrator The arbitrator address on the Foreign Chain.
     * @param _arbitratorDisputeID The ID of the dispute in the Foreign Chain arbitrator.
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
        address _arbitrable,
        uint256 _arbitrableItemID,
        uint256 _ruling
    ) external;
}

/**
 * @dev Arbitration Proxy on the main chain.
 */
interface IForeignBinaryArbitrationProxy is IArbitrable {
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
