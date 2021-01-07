pragma solidity ^0.7.6;

import {IArbitrator} from "@kleros/erc-792/contracts/IArbitrator.sol";
import {IArbitrable} from "@kleros/erc-792/contracts/IArbitrable.sol";

contract MockAppealableArbitrator is IArbitrator, IArbitrable {
    uint256 public constant NOT_PAYABLE_VALUE = 2**256 - 1;

    address public owner = msg.sender;

    bool public active = true;

    uint256 public arbitrationFee;

    uint256 public appealTimeout;

    IArbitrator public arbitrator;

    struct Dispute {
        DisputeStatus status;
        IArbitrable arbitrated;
        uint256 choices;
        uint256 ruling;
        uint256 paidFee;
    }

    Dispute[] public disputes;

    struct AppealDispute {
        uint256 rulingTime;
        IArbitrator arbitrator;
        uint256 appealDisputeID;
    }

    mapping(uint256 => AppealDispute) public appealDisputes;
    mapping(uint256 => uint256) public appealDisputeIDsToDisputeIDs;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner allowed");
        _;
    }

    modifier onlyIfActive() {
        require(active, "Arbitrator is not active");
        _;
    }

    constructor(uint256 _arbitrationFee, uint256 _appealTimeout) {
        arbitrationFee = _arbitrationFee;
        appealTimeout = _appealTimeout;
    }

    function activate() external onlyOwner {
        active = true;
    }

    function deactivate() external onlyOwner {
        active = false;
    }

    function changeArbitrator(IArbitrator _arbitrator) external onlyOwner {
        arbitrator = _arbitrator;
    }

    function changeAppealTimeout(uint256 _appealTimeout) external onlyOwner {
        appealTimeout = _appealTimeout;
    }

    function createDispute(uint256 _choices, bytes memory _extraData)
        public
        payable
        override
        onlyIfActive
        returns (uint256 disputeID)
    {
        uint256 requiredDeposit = arbitrationCost(_extraData);
        require(msg.value >= requiredDeposit, "Not enough ETH to cover arbitration costs.");

        (uint256 taken, uint256 remainder) = calculateContribution(msg.value, requiredDeposit);

        disputes.push(
            Dispute({
                arbitrated: IArbitrable(msg.sender),
                choices: _choices,
                ruling: uint256(-1),
                status: DisputeStatus.Waiting,
                paidFee: taken
            })
        );
        disputeID = disputes.length - 1;

        if (remainder > 0) {
            msg.sender.send(remainder);
        }

        emit DisputeCreation(disputeID, IArbitrable(msg.sender));
    }

    function appeal(uint256 _disputeID, bytes memory _extraData) public payable override onlyIfActive {
        uint256 requiredDeposit = appealCost(_disputeID, _extraData);
        require(msg.value >= requiredDeposit, "Not enough ETH to cover arbitration costs.");

        (uint256 taken, uint256 remainder) = calculateContribution(msg.value, requiredDeposit);

        AppealDispute storage appealDispute = appealDisputes[_disputeID];

        if (appealDispute.arbitrator != IArbitrator(0)) {
            appealDispute.arbitrator.appeal{value: taken}(appealDispute.appealDisputeID, _extraData);
        } else {
            appealDispute.arbitrator = arbitrator;
            appealDispute.appealDisputeID = arbitrator.createDispute{value: taken}(
                disputes[_disputeID].choices,
                _extraData
            );
            appealDisputeIDsToDisputeIDs[appealDispute.appealDisputeID] = _disputeID;
        }

        if (remainder > 0) {
            msg.sender.send(remainder);
        }

        emit AppealDecision(_disputeID, IArbitrable(msg.sender));
    }

    function giveRuling(uint256 _disputeID, uint256 _ruling) external onlyOwner {
        doGiveRuling(_disputeID, _ruling);
    }

    function doGiveRuling(uint256 _disputeID, uint256 _ruling) internal {
        Dispute storage dispute = disputes[_disputeID];

        require(dispute.status != DisputeStatus.Solved, "Dispute already solved");
        require(_ruling <= dispute.choices, "Ruling out of bounds");

        AppealDispute storage appealDispute = appealDisputes[_disputeID];

        if (appealDispute.arbitrator != IArbitrator(0)) {
            require(
                IArbitrator(msg.sender) == appealDispute.arbitrator,
                "Appealed disputes must be ruled by their back up arbitrator."
            );
            giveFinalRuling(_disputeID, _ruling);
        } else {
            if (dispute.status == DisputeStatus.Appealable) {
                require(block.timestamp > appealDispute.rulingTime + appealTimeout, "Timeout has not passed yet");
                giveFinalRuling(_disputeID, dispute.ruling);
            } else {
                dispute.ruling = _ruling;
                dispute.status = DisputeStatus.Appealable;
                appealDispute.rulingTime = block.timestamp;
                emit AppealPossible(_disputeID, disputes[_disputeID].arbitrated);
            }
        }
    }

    function giveFinalRuling(uint256 _disputeID, uint256 _ruling) internal {
        Dispute storage dispute = disputes[_disputeID];
        require(dispute.status != DisputeStatus.Solved, "Dispute already solved");

        uint256 deposit = dispute.paidFee;

        dispute.paidFee = 0;
        dispute.ruling = _ruling;
        dispute.status = DisputeStatus.Solved;

        msg.sender.send(deposit); // Avoid blocking.
        dispute.arbitrated.rule(_disputeID, _ruling);
    }

    function rule(uint256 _disputeID, uint256 _ruling) external override {
        uint256 originalDisputeID = appealDisputeIDsToDisputeIDs[_disputeID];
        require(
            appealDisputes[originalDisputeID].arbitrator != IArbitrator(address(0)),
            "The dispute must have been appealed"
        );
        doGiveRuling(originalDisputeID, _ruling);
        emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);
    }

    function calculateContribution(uint256 _available, uint256 _requiredAmount)
        internal
        pure
        returns (uint256 taken, uint256 remainder)
    {
        if (_requiredAmount > _available) {
            return (_available, 0);
        }

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }

    function arbitrationCost(bytes memory _extraData) public view override returns (uint256) {
        return arbitrationFee;
    }

    function appealCost(uint256 _disputeID, bytes memory _extraData) public view override returns (uint256) {
        AppealDispute storage appealDispute = appealDisputes[_disputeID];
        if (appealDispute.arbitrator != IArbitrator(0)) {
            return appealDispute.arbitrator.appealCost(appealDispute.appealDisputeID, _extraData);
        }
        Dispute storage dispute = disputes[_disputeID];
        if (dispute.status == DisputeStatus.Appealable) {
            return arbitrator.arbitrationCost(_extraData);
        }
        return NOT_PAYABLE_VALUE;
    }

    function disputeStatus(uint256 _disputeID) public view override returns (DisputeStatus status) {
        AppealDispute storage appealDispute = appealDisputes[_disputeID];
        if (appealDispute.arbitrator != IArbitrator(0)) {
            return appealDispute.arbitrator.disputeStatus(appealDispute.appealDisputeID);
        }
        return disputes[_disputeID].status;
    }

    function currentRuling(uint256 _disputeID) public view override returns (uint256 ruling) {
        AppealDispute storage appealDispute = appealDisputes[_disputeID];
        if (appealDispute.arbitrator != IArbitrator(0)) {
            return appealDispute.arbitrator.currentRuling(appealDispute.appealDisputeID);
        }
        return disputes[_disputeID].ruling;
    }

    function appealPeriod(uint256 _disputeID) public view override returns (uint256 start, uint256 end) {
        AppealDispute storage appealDispute = appealDisputes[_disputeID];
        if (appealDispute.arbitrator != IArbitrator(0)) {
            return appealDispute.arbitrator.appealPeriod(appealDispute.appealDisputeID);
        }

        if (appealDispute.rulingTime == 0) {
            return (0, 0);
        }

        return (appealDispute.rulingTime, appealDispute.rulingTime + appealTimeout);
    }

    function getAppealDisputeID(uint256 _disputeID) external view returns (uint256 disputeID) {
        AppealDispute storage appealDispute = appealDisputes[_disputeID];

        if (appealDispute.arbitrator != IArbitrator(address(0))) {
            try
                MockAppealableArbitrator(address(appealDispute.arbitrator)).getAppealDisputeID(
                    appealDispute.appealDisputeID
                )
            returns (uint256 appealDisputeID) {
                return appealDisputeID;
            } catch {
                return _disputeID;
            }
        }

        return _disputeID;
    }

    function getDisputeCount() external view returns (uint256 count) {
        return disputes.length;
    }
}
