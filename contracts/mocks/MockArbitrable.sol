// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "../CrossChainBinaryArbitration.sol";

contract MockArbitrable is ICrossChainArbitrable {
    event ItemCreated(uint256 indexed _arbitrableItemID);
    event ItemDisputeRequest(uint256 indexed _arbitrableItemID, address indexed _plaintiff);
    event ItemDisputeCanceled(uint256 indexed _arbitrableItemID);
    event ItemDisputeRuled(uint256 indexed _arbitrableItemID, uint256 _ruling);

    enum Status {None, Created, DisputeRequested, DisputeOngoing, Settled}

    struct Item {
        Status status;
        uint256 disputableUntil;
        address creator;
        address plaintiff;
        uint256 disputeID;
        uint256 ruling;
        bytes arbitratorExtraData;
        string metaEvidence;
    }

    address public governor = msg.sender;
    IHomeBinaryArbitrationProxy public arbitrator;
    uint256 public disputeTimeout;
    bytes public arbitratorExtraData;
    string public metaEvidence;
    Item[] public items;
    mapping(uint256 => uint256) public disputeIDToItemID;

    modifier onlyGovernor() {
        require(msg.sender == governor, "Only governor allowed");
        _;
    }

    modifier onlyArbitrator() {
        require(msg.sender == address(arbitrator), "Only arbitrator allowed");
        _;
    }

    constructor(
        string memory _metaEvidence,
        IHomeBinaryArbitrationProxy _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _disputeTimeout
    ) {
        metaEvidence = _metaEvidence;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        disputeTimeout = _disputeTimeout;
    }

    function registerForArbitration(uint256 startingID) external onlyGovernor {
        arbitrator.registerMetaEvidence(startingID, metaEvidence);
        arbitrator.registerArbitratorExtraData(startingID, arbitratorExtraData);
    }

    function createItem() external {
        Item storage item = items.push();
        uint256 arbitrableItemID = items.length - 1;
        item.status = Status.Created;
        item.creator = msg.sender;
        item.disputableUntil = block.timestamp + disputeTimeout;

        emit ItemCreated(arbitrableItemID);
    }

    function settleItem(uint256 _arbitrableItemID) external {
        Item storage item = items[_arbitrableItemID];

        if (item.status == Status.Created) {
            require(item.creator == msg.sender, "Only creator allowed");
            item.status = Status.Settled;
        }

        require(item.status == Status.Created, "Invalid status");
        require(block.timestamp > item.disputableUntil, "Dispute still possible");

        item.status = Status.Settled;
    }

    function notifyDisputeRequest(uint256 _arbitrableItemID, address _plaintiff) external override onlyArbitrator {
        Item storage item = items[_arbitrableItemID];
        require(item.status == Status.Created, "Invalid status");
        require(block.timestamp <= item.disputableUntil, "Dispute timeout expired");

        item.status = Status.DisputeRequested;
        // item.disputableUntil = block.timestamp + disputeTimeout;
        item.plaintiff = _plaintiff;

        emit ItemDisputeRequest(_arbitrableItemID, _plaintiff);
    }

    function cancelDispute(uint256 _arbitrableItemID) external override onlyArbitrator {
        Item storage item = items[_arbitrableItemID];
        require(item.status == Status.DisputeRequested, "Invalid status");

        item.status = Status.Settled;

        emit ItemDisputeCanceled(_arbitrableItemID);
    }

    function rule(uint256 _arbitrableItemID, uint256 _ruling) external override onlyArbitrator {
        Item storage item = items[_arbitrableItemID];

        require(item.status >= Status.DisputeRequested, "Invalid dispute status");

        item.status = Status.Settled;

        emit ItemDisputeRuled(_arbitrableItemID, _ruling);
    }
}
