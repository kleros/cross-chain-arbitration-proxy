/**
 * @authors: [@hbarcelos]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 *
 * SPDX-License-Identifier: MIT
 */
pragma solidity ^0.7.1;

import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";
import "./dependencies/IAMB.sol";
import "./CrossChainArbitration.sol";

contract ForeignBinaryArbitrationProxy is IForeignBinaryArbitrationProxy, IEvidence {
    using CappedMath for uint256;

    enum Status {None, Possible, Requested, DepositPending, Ongoing, Ruled, Failed}

    enum Party {None, Defendant, Plaintiff}

    struct Arbitration {
        Status status; // Status of the request.
        uint40 possibleUntil; // The deadline for creating a dispute.
        uint40 acceptedAt; // The time when the dispute creation was accepted.
        address payable plaintiff; // The address of the plaintiff.
        // All the above fit into a single word (:
        address arbitrable; // The address of the arbitrable contract.
        uint256 arbitrableItemID; // The ID of the arbitrable item in the contract.
        bytes arbitratorExtraData; // Extra data for the arbitrator.
        IArbitrator arbitrator; // The address of the arbitrator contract.
        uint256 arbitratorDisputeID; // The ID of the dispute in the arbitrator.
        uint256 ruling; // The ruling of the dispute.
        Round[] rounds; // Rounds of the dispute
    }

    struct Round {
        uint256[3] paidFees; // Tracks the fees paid by each side in this round.
        bool[3] fullyPaid; // True when the side has fully paid its fee. False otherwise.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side.
    }

    /// @dev A value depositor won't be able to pay.
    uint256 private constant NON_PAYABLE_VALUE = (2**256 - 2) / 2;

    /// @dev The number of choices for the arbitrator.
    uint256 public constant NUMBER_OF_CHOICES = 2;

    /// @dev Divisor parameter for multipliers.
    uint256 public constant MULTIPLIER_DIVISOR = 10000;

    /// @dev The contract governor. TRUSTED.
    address public governor = msg.sender;

    /// @dev The address of the arbitrator. TRUSTED.
    IArbitrator public arbitrator;

    /// @dev ArbitraryMessageBridge contract address. TRUSTED.
    IAMB public amb;

    /// @dev Address of the counter-party proxy on the Home Chain. TRUSTED.
    address public homeProxy;

    /// @dev The amount of time the defendant side have to deposit the arbitration fee.
    uint40 public feeDepositTimeout;

    /// @dev Multiplier for calculating the appeal fee that must be paid by submitter in the case where there isn't a winner and loser (e.g. when the arbitrator ruled "refuse to arbitrate").
    uint256 public sharedStakeMultiplier;

    /// @dev Multiplier for calculating the appeal fee of the party that won the previous round.
    uint256 public winnerStakeMultiplier;

    /// @dev  Multiplier for calculating the appeal fee of the party that lost the previous round.
    uint256 public loserStakeMultiplier;

    /// @dev The arbitrations by arbitrableID.
    mapping(uint256 => Arbitration) public arbitrations;

    /// @dev Maps the disputeIDs to arbitrableIDs.
    mapping(uint256 => uint256) public disputeIDToArbitrableID;

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
     * @dev Emitted when someone contributes to a dispute or appeal.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _party The party which received the contribution.
     * @param _contributor The address of the contributor.
     * @param _amount The amount contributed.
     */
    event FeeContribution(uint256 indexed _arbitrableID, Party _party, address indexed _contributor, uint256 _amount);

    /**
     * @dev Emitted when someone pays for the full dispute or appeal fee.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _party The party which received the contribution.
     */
    event FeePaid(uint256 indexed _arbitrableID, Party _party);

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

    /**
     * @notice Creates an arbitration proxy on the foreign chain.
     * @param _amb ArbitraryMessageBridge contract address.
     * @param _arbitrator Arbitrator contract address.
     * @param _feeDepositTimeout The amount of time (seconds) within the defendant side must deposit the arbitration
     * fee, otherwise she will automatically loose the dispute.
     */
    constructor(
        IAMB _amb,
        IArbitrator _arbitrator,
        uint40 _feeDepositTimeout,
        uint256 _sharedStakeMultiplier,
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier
    ) {
        amb = _amb;
        arbitrator = _arbitrator;
        feeDepositTimeout = _feeDepositTimeout;
        sharedStakeMultiplier = _sharedStakeMultiplier;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
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
     * @notice Sets the address of the arbitrator.
     * @param _arbitrator The address of the new arbitrator.
     */
    function changeArbitrator(IArbitrator _arbitrator) external onlyGovernor {
        arbitrator = _arbitrator;
    }

    /**
     * @notice Sets the address of the arbitration proxy on the Home Chain.
     * @param _homeProxy The address of the proxy.
     */
    function changeHomeProxy(address _homeProxy) external onlyGovernor {
        homeProxy = _homeProxy;
    }

    /**
     * @notice Sets the amount of time the defendant has to deposit the arbitration fee.
     * @param _feeDepositTimeout The amount of time (seconds) to deposit.
     */
    function changeFeeDepositTimeout(uint40 _feeDepositTimeout) external onlyGovernor {
        feeDepositTimeout = _feeDepositTimeout;
    }

    /**
     * @notice Changes the percentage of arbitration fees that must be paid by parties as a fee stake if there was no winner and loser in the previous round.
     * @param _sharedStakeMultiplier A new value of the multiplier of the appeal cost in case when there is no winner/loser in previous round. In basis point.
     */
    function changeSharedStakeMultiplier(uint256 _sharedStakeMultiplier) public onlyGovernor {
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /**
     * @notice Changes the percentage of arbitration fees that must be paid as a fee stake by the party that won the previous round.
     * @param _winnerStakeMultiplier A new value of the multiplier of the appeal cost that the winner of the previous round has to pay. In basis points.
     */
    function changeWinnerStakeMultiplier(uint256 _winnerStakeMultiplier) public onlyGovernor {
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /**
     * @notice Changes the percentage of arbitration fees that must be paid as a fee stake by the party that lost the previous round.
     * @param _loserStakeMultiplier A new value of the multiplier of the appeal cost that the party that lost the previous round has to pay. In basis points.
     */
    function changeLoserStakeMultiplier(uint256 _loserStakeMultiplier) public onlyGovernor {
        loserStakeMultiplier = _loserStakeMultiplier;
    }

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
    ) external override onlyAmb onlyHomeProxy {
        uint256 arbitrableID = getArbitrableID(_arbitrable, _arbitrableItemID);
        emit MetaEvidence(arbitrableID, _metaEvidence);
    }

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
    ) external override onlyAmb onlyHomeProxy {
        uint256 arbitrableID = getArbitrableID(_arbitrable, _arbitrableItemID);
        Arbitration storage arbitration = arbitrations[arbitrableID];

        arbitration.status = Status.Possible;
        arbitration.possibleUntil = uint40(_deadline);
        arbitration.arbitrable = _arbitrable;
        arbitration.arbitrableItemID = _arbitrableItemID;
        arbitration.arbitratorExtraData = _arbitratorExtraData;

        emit DisputePossible(arbitrableID, _defendant, _deadline);
    }

    /**
     * @notice Requests the creation of a dispute for an arbitrable item.
     * @dev Can be called by any 3rd-party.
     * @param _arbitrableID The ID of the arbitrable.
     */
    function requestDispute(uint256 _arbitrableID) external payable {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        require(arbitration.status == Status.Possible, "Invalid arbitration status");
        require(arbitration.possibleUntil >= block.timestamp, "Deadline for request has expired");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitration.arbitratorExtraData);

        require(msg.value >= arbitrationCost, "Deposit value too low");

        arbitration.status = Status.Requested;
        arbitration.plaintiff = msg.sender;
        arbitration.rounds.push();

        (uint256 remainder, ) = contribute(_arbitrableID, Party.Plaintiff, msg.sender, msg.value, arbitrationCost);

        msg.sender.send(remainder);

        emit DisputeRequested(_arbitrableID, msg.sender);

        bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveDisputeRequest.selector;
        bytes memory data = abi.encodeWithSelector(
            methodSelector,
            arbitration.arbitrable,
            arbitration.arbitrableItemID,
            msg.sender
        );
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());
    }

    /**
     * @notice Receives from the Home Chain that the dispute has been accepted.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function receiveDisputeAccepted(address _arbitrable, uint256 _arbitrableItemID)
        external
        override
        onlyAmb
        onlyHomeProxy
    {
        uint256 arbitrableID = getArbitrableID(_arbitrable, _arbitrableItemID);
        Arbitration storage arbitration = arbitrations[arbitrableID];

        require(arbitration.status == Status.Requested, "Invalid arbitration status");

        arbitration.status = Status.DepositPending;
        arbitration.acceptedAt = uint40(block.timestamp);

        emit DisputeAccepted(arbitrableID);
    }

    /**
     * @notice Receives from the Home Chain that the dispute has been rejected.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item on the arbitrable contract.
     */
    function receiveDisputeRejected(address _arbitrable, uint256 _arbitrableItemID)
        external
        override
        onlyAmb
        onlyHomeProxy
    {
        uint256 arbitrableID = getArbitrableID(_arbitrable, _arbitrableItemID);
        Arbitration storage arbitration = arbitrations[arbitrableID];

        require(arbitration.status == Status.Requested, "Invalid arbitration status");

        arbitration.status = Status.Failed;

        // Reimburses the plaintiff.
        uint256 amount = registerWithdrawal(arbitration, arbitration.plaintiff, 0);
        arbitration.plaintiff.send(amount); // It is the user responsibility to accept ETH.

        emit DisputeRejected(arbitrableID);
    }

    /**
     * @notice Funds the defendant side of the dispute after it has been accepted.
     * @dev We require both sides to pay the full arbitration cost, so the winner can be refunded after.
     * The plaintiff already paid for their part when requested the dispute.
     * @param _arbitrableID The ID of the arbitrable.
     */
    function fundDisputeDefendant(uint256 _arbitrableID) external payable {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        require(arbitration.status == Status.DepositPending, "Invalid arbitration status");
        require(block.timestamp <= arbitration.acceptedAt + feeDepositTimeout, "Deadline for deposit has expired");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitration.arbitratorExtraData);

        (uint256 remainder, bool fullyPaid) = contribute(
            _arbitrableID,
            Party.Defendant,
            msg.sender,
            msg.value,
            arbitrationCost
        );

        // Notice that if the fee is not fully paid, it means there is no remainder value.
        if (fullyPaid) {
            if (createDispute(_arbitrableID, arbitrationCost)) {
                // Reimburse the contributor with the remaining value.
                msg.sender.send(remainder);

                bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveDisputeCreated.selector;
                bytes memory data = abi.encodeWithSelector(
                    methodSelector,
                    arbitration.arbitrable,
                    arbitration.arbitrableItemID,
                    arbitrator,
                    arbitration.arbitratorDisputeID
                );
                amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());
            } else {
                uint256 amount = registerWithdrawal(arbitration, msg.sender, 0);
                msg.sender.send(amount); // It is the user responsibility to accept ETH.

                bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveDisputeFailed.selector;
                bytes memory data = abi.encodeWithSelector(
                    methodSelector,
                    arbitration.arbitrable,
                    arbitration.arbitrableItemID
                );
                amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());
            }
        }
    }

    /**
     * @notice Reimburses the rest.
     * @dev Takes up to the total amount required to fund a side of an appeal.
     * If users send more than required, they will be reimbursed of the remaining.
     * Creates an appeal if both sides are fully funded.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _party The party that pays the appeal fee.
     */
    function fundAppeal(uint256 _arbitrableID, Party _party) external payable {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        require(_party == Party.Defendant || _party == Party.Plaintiff, "Invalid side");
        require(arbitration.status == Status.Ongoing, "Invalid arbitration status");

        Round storage round = arbitration.rounds[arbitration.rounds.length - 1];
        require(!round.fullyPaid[uint256(_party)], "Appeal fee already paid");

        (uint256 appealCost, uint256 totalCost) = getAppealFeeComponents(arbitration, _party);

        (uint256 remainder, ) = contribute(
            _arbitrableID,
            _party,
            msg.sender,
            msg.value,
            totalCost.subCap(round.paidFees[uint256(_party)])
        );

        if (round.fullyPaid[uint256(Party.Defendant)] && round.fullyPaid[uint256(Party.Plaintiff)]) {
            round.feeRewards = round.feeRewards.subCap(appealCost);
            arbitration.rounds.push();

            // The appeal must happen on the same arbitrator the original dispute was created.
            arbitration.arbitrator.appeal{value: appealCost}(
                arbitration.arbitratorDisputeID,
                arbitration.arbitratorExtraData
            );
        }

        msg.sender.send(remainder);
    }

    /**
     * @notice Calculates the appeal fee and total cost for an arbitration.
     * @dev This function was extracted from `fundAppeal` because of the stack depth problem.
     * @param _arbitration The arbitration object.
     * @param _party The party appealing.
     * @return appealCost The actual appeal cost.
     * @return totalCost The total cost for the appeal
     */
    function getAppealFeeComponents(Arbitration storage _arbitration, Party _party)
        internal
        view
        returns (uint256 appealCost, uint256 totalCost)
    {
        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = _arbitration.arbitrator.appealPeriod(
            _arbitration.arbitratorDisputeID
        );
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Appeal period is over");

        uint256 winner = _arbitration.arbitrator.currentRuling(_arbitration.arbitratorDisputeID);
        uint256 multiplier;
        if (winner == 0) {
            multiplier = sharedStakeMultiplier;
        } else if (winner == uint256(_party)) {
            multiplier = winnerStakeMultiplier;
        } else {
            require(
                block.timestamp - appealPeriodStart < (appealPeriodEnd - appealPeriodStart) / 2,
                "Loser party deadline is over"
            );
            multiplier = loserStakeMultiplier;
        }

        uint256 appealCost = _arbitration.arbitrator.appealCost(
            _arbitration.arbitratorDisputeID,
            _arbitration.arbitratorExtraData
        );
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        return (appealCost, totalCost);
    }

    /**
     * @notice Give a ruling for a dispute. Must be called by the arbitrator.
     * The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     * @param _arbitratorDisputeID ID of the dispute in the Arbitrator contract.
     * @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint256 _arbitratorDisputeID, uint256 _ruling) external override {
        uint256 disputeID = getDisputeID(IArbitrator(msg.sender), _arbitratorDisputeID);
        uint256 arbitrableID = disputeIDToArbitrableID[disputeID];
        Arbitration storage arbitration = arbitrations[arbitrableID];

        require(address(arbitration.arbitrator) == msg.sender, "Only dispute arbitrator allowed");
        require(arbitration.status == Status.Ongoing, "Invalid arbitration status");

        arbitration.status = Status.Ruled;
        Round storage round = arbitration.rounds[arbitration.rounds.length - 1];

        /**
         * @notice If only one side paid its fees, we assume the ruling to be in its favor.
         * It is not possible for a round to have both sides paying the full fees AND
         * being the latest round at the same time.
         * When the last party pays its fees, a new round is automatically created.
         */
        if (round.fullyPaid[uint256(Party.Defendant)] == true) {
            arbitration.ruling = uint256(Party.Defendant);
        } else if (round.fullyPaid[uint256(Party.Plaintiff)] == true) {
            arbitration.ruling = uint256(Party.Plaintiff);
        } else {
            arbitration.ruling = _ruling;
        }

        emit Ruling(arbitration.arbitrator, _arbitratorDisputeID, arbitration.ruling);
        emit DisputeRuled(arbitrableID, arbitration.ruling);

        bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveRuling.selector;
        bytes memory data = abi.encodeWithSelector(
            methodSelector,
            arbitration.arbitrable,
            arbitration.arbitrableItemID,
            arbitration.ruling
        );
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());
    }

    /**
     * @notice Claims the win in favor of the plaintiff when the defendant side fails to fund her side of the dispute.
     * @dev We require both sides to pay the full arbitration cost, so the winner can be refunded after.
     * The plaintiff already paid for their part when requested the dispute.
     * @param _arbitrableID The ID of the arbitrable.
     */
    function claimPlaintiffWin(uint256 _arbitrableID) external {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        require(arbitration.status == Status.DepositPending, "Invalid arbitration status");
        require(block.timestamp > arbitration.acceptedAt + feeDepositTimeout, "Defendant deposit still possible");

        arbitration.status = Status.Ruled;
        arbitration.ruling = uint256(Party.Plaintiff);

        uint256 amount = registerWithdrawal(arbitration, arbitration.plaintiff, 0);
        arbitration.plaintiff.send(amount); // It is the user responsibility to accept ETH.

        emit DisputeRuled(_arbitrableID, arbitration.ruling);

        bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveRuling.selector;
        bytes memory data = abi.encodeWithSelector(
            methodSelector,
            arbitration.arbitrable,
            arbitration.arbitrableItemID,
            arbitration.ruling
        );
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());
    }

    /**
     * @dev Withdraws contributions of multiple appeal rounds at once.
     * @notice This function is O(n) where n is the number of rounds. This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _cursor The round from where to start withdrawing.
     * @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
    function batchWithdrawFeesAndRewards(
        uint256 _arbitrableID,
        address payable _beneficiary,
        uint256 _cursor,
        uint256 _count
    ) external {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        require(arbitration.status >= Status.Ruled, "The arbitration is not settled.");

        uint256 amount;
        for (uint256 i = _cursor; i < arbitration.rounds.length && (_count == 0 || i < _cursor + _count); i++) {
            amount += registerWithdrawal(arbitration, _beneficiary, i);
        }

        _beneficiary.send(amount); // It is the user responsibility to accept ETH.
    }

    /**
     * @dev Withdraws contributions of a specific appeal round.
     * @notice Reimburses contributions if no appeals were raised; otherwise sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _beneficiary The address that made contributions.
     * @param _roundNumber The round from which to withdraw.
     * @return amount The withdrawn amount.
     */
    function withdrawFeesAndRewards(
        uint256 _arbitrableID,
        address payable _beneficiary,
        uint256 _roundNumber
    ) external returns (uint256 amount) {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        require(arbitration.status >= Status.Ruled, "The arbitration is not settled.");

        amount = registerWithdrawal(arbitration, _beneficiary, _roundNumber);

        _beneficiary.send(amount); // It is the user responsibility to accept ETH.
    }

    /**
     * @notice Returns the arbitration cost for a given arbitrable item.
     * @param _arbitrableID The ID of the arbitrable.
     * @return The dispute fee.
     */
    function getDisputeFee(uint256 _arbitrableID) external view returns (uint256) {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        if (arbitration.status >= Status.Possible && arbitration.status <= Status.DepositPending) {
            return arbitrator.arbitrationCost(arbitration.arbitratorExtraData);
        } else {
            return NON_PAYABLE_VALUE;
        }
    }

    /**
     * @notice Returns the appeal cost for a given arbitrable item.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _party The party to get the appeal fee for.
     * @return The appeal fee.
     */
    function getAppealFee(uint256 _arbitrableID, Party _party) external view returns (uint256) {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitration.arbitrator.appealPeriod(
            arbitration.arbitratorDisputeID
        );

        if (!(block.timestamp >= appealPeriodStart && block.timestamp <= appealPeriodEnd)) {
            return NON_PAYABLE_VALUE;
        }

        uint256 winner = arbitration.arbitrator.currentRuling(arbitration.arbitratorDisputeID);
        uint256 multiplier;

        if (winner == 0) {
            multiplier = sharedStakeMultiplier;
        } else if (winner == uint256(_party)) {
            multiplier = winnerStakeMultiplier;
        } else {
            multiplier = loserStakeMultiplier;
        }

        uint256 appealCost = arbitration.arbitrator.appealCost(
            arbitration.arbitratorDisputeID,
            arbitration.arbitratorExtraData
        );

        return appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);
    }

    /**
     * @dev Gets the number of rounds of arbitration.
     * @param _arbitrableID The ID of the arbitrable.
     * @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _arbitrableID) external view returns (uint256) {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        return arbitration.rounds.length;
    }

    /**
     * @notice Gets the information of a round of an arbitration.
     * @param _arbitrableID The ID of the arbitrable.
     * @return paidFees The amount of fees paid by each side.
     * @return fullyPaid Whether each side has paid all the required appeal fees or not.
     * @return feeRewards The total amount of appeal fees to be used as crowdfunding rewards.
     */
    function getRoundInfo(uint256 _arbitrableID, uint256 _roundNumber)
        external
        view
        returns (
            uint256[3] memory paidFees,
            bool[3] memory fullyPaid,
            uint256 feeRewards
        )
    {
        Arbitration storage arbitration = arbitrations[_arbitrableID];
        Round storage round = arbitration.rounds[_roundNumber];

        return (round.paidFees, round.fullyPaid, round.feeRewards);
    }

    /**
     * @dev Gets the contributions made by a party for a given round of task appeal.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _contributor The address of the contributor.
     * @param _roundNumber The position of the round.
     * @return The contributions.
     */
    function getContributions(
        uint256 _arbitrableID,
        address _contributor,
        uint256 _roundNumber
    ) external view returns (uint256[3] memory) {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        return arbitration.rounds[_roundNumber].contributions[_contributor];
    }

    /**
     * @notice Returns the sum of withdrawable wei from appeal rounds. This function is O(n), where n is the number of rounds of the task. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _beneficiary The contributor for which to query.
     * @return total The total amount of wei available to withdraw.
     */
    function getTotalWithdrawableAmount(uint256 _arbitrableID, address _beneficiary)
        external
        view
        returns (uint256 total)
    {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        // Only Ruled and Failed arbitrations are withdrawable.
        if (arbitration.status < Status.Ruled) {
            return total;
        }

        for (uint256 i = 0; i < arbitration.rounds.length; i++) {
            total += getWithdrawableAmount(arbitration, _beneficiary, i);
        }

        return total;
    }

    /**
     * @notice Creates a dispute in the arbitrator.
     * @param _arbitrableID The already calculated arbitrable ID to save up some gas.
     * @param _arbitrationCost The cost of arbitration.
     * @return Whether the dispute creation succeeded or not.
     */
    function createDispute(uint256 _arbitrableID, uint256 _arbitrationCost) internal returns (bool) {
        Arbitration storage arbitration = arbitrations[_arbitrableID];

        try
            arbitrator.createDispute{value: _arbitrationCost}(NUMBER_OF_CHOICES, arbitration.arbitratorExtraData)
        returns (uint256 arbitratorDisputeID) {
            uint256 disputeID = getDisputeID(arbitrator, arbitratorDisputeID);

            arbitration.status = Status.Ongoing;
            arbitration.arbitrator = arbitrator;
            arbitration.arbitratorDisputeID = arbitratorDisputeID;
            // Create a new round for a possible appeal.
            arbitration.rounds.push();

            disputeIDToArbitrableID[disputeID] = _arbitrableID;

            emit Dispute(arbitrator, arbitratorDisputeID, _arbitrableID, _arbitrableID);
            emit DisputeOngoing(_arbitrableID, arbitrator, arbitratorDisputeID);

            return true;
        } catch (bytes memory reason) {
            arbitration.status = Status.Failed;

            emit DisputeFailed(_arbitrableID, arbitrator, arbitration.arbitratorExtraData, reason);

            return false;
        }
    }

    /**
     * @notice Makes a fee contribution to the current round.
     * @param _arbitrableID The ID of the arbitrable.
     * @param _party The party which to contribute.
     * @param _contributor The address of the contributor.
     * @param _availableAmount The amount the contributor has sent.
     * @param _totalRequired The total amount required for the party.
     * @return remainder The remainder to send back to the contributor.
     * @return fullyPaid Whether or not the contribution is enough to cover the total required.
     */
    function contribute(
        uint256 _arbitrableID,
        Party _party,
        address _contributor,
        uint256 _availableAmount,
        uint256 _totalRequired
    ) internal returns (uint256 remainder, bool fullyPaid) {
        Arbitration storage arbitration = arbitrations[_arbitrableID];
        Round storage round = arbitration.rounds[arbitration.rounds.length - 1];

        (uint256 contribution, uint256 remainder) = calculateContribution(
            _availableAmount,
            _totalRequired.subCap(round.paidFees[uint256(_party)])
        );

        round.feeRewards += contribution;
        round.paidFees[uint256(_party)] += contribution;
        round.contributions[_contributor][uint256(_party)] += contribution;

        emit FeeContribution(_arbitrableID, _party, _contributor, contribution);

        if (round.paidFees[uint256(_party)] >= _totalRequired) {
            round.fullyPaid[uint256(_party)] = true;

            emit FeePaid(_arbitrableID, _party);
        }

        return (remainder, round.fullyPaid[uint256(_party)]);
    }

    /**
     * @dev Returns the contribution value and remainder from available ETH and required amount.
     * @param _available The amount of ETH available for the contribution.
     * @param _requiredAmount The amount of ETH required for the contribution.
     * @return taken The amount of ETH taken.
     * @return remainder The amount of ETH left from the contribution.
     */
    function calculateContribution(uint256 _available, uint256 _requiredAmount)
        internal
        pure
        returns (uint256 taken, uint256 remainder)
    {
        if (_requiredAmount > _available) {
            // Take whatever is available, return 0 as leftover ETH.
            return (_available, 0);
        }

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }

    /**
     * @notice Registers the withdrawal of fees and rewards for a given party in a given round.
     * @dev This function is private because no checks are made on the arbitration state. Caller functions MUST do the check before calling this function.
     * @param _arbitration The arbitration object.
     * @param _beneficiary The address that made contributions.
     * @param _roundNumber The round from which to withdraw.
     * @return The withdrawn amount.
     */
    function registerWithdrawal(
        Arbitration storage _arbitration,
        address _beneficiary,
        uint256 _roundNumber
    ) internal returns (uint256) {
        uint256 amount = getWithdrawableAmount(_arbitration, _beneficiary, _roundNumber);

        uint256[3] storage addressContributions = _arbitration.rounds[_roundNumber].contributions[_beneficiary];
        addressContributions[uint256(Party.Defendant)] = 0;
        addressContributions[uint256(Party.Plaintiff)] = 0;

        return amount;
    }

    /**
     * @notice Returns the sum of withdrawable wei from a specific appeal round.
     * @dev This function is internal because no checks are made on the task state. Caller functions MUST do the check before calling this function.
     * @param _arbitration The arbitration object.
     * @param _beneficiary The contributor for which to query.
     * @param _roundNumber The number of the round.
     * @return The amount of wei available to withdraw from the round.
     */
    function getWithdrawableAmount(
        Arbitration storage _arbitration,
        address _beneficiary,
        uint256 _roundNumber
    ) internal view returns (uint256) {
        Round storage round = _arbitration.rounds[_roundNumber];

        if (!round.fullyPaid[uint256(Party.Defendant)] || !round.fullyPaid[uint256(Party.Plaintiff)]) {
            // If the round is not fully funded, reimburse according to the contributions.
            return
                round.contributions[_beneficiary][uint256(Party.Defendant)] +
                round.contributions[_beneficiary][uint256(Party.Plaintiff)];
        } else if (_arbitration.ruling == uint256(Party.None)) {
            uint256 rewardTranslator = round.paidFees[uint256(Party.Defendant)] > 0
                ? (round.contributions[_beneficiary][uint256(Party.Defendant)] * round.feeRewards) /
                    (round.paidFees[uint256(Party.Defendant)] + round.paidFees[uint256(Party.Plaintiff)])
                : 0;
            uint256 rewardChallenger = round.paidFees[uint256(Party.Plaintiff)] > 0
                ? (round.contributions[_beneficiary][uint256(Party.Plaintiff)] * round.feeRewards) /
                    (round.paidFees[uint256(Party.Defendant)] + round.paidFees[uint256(Party.Plaintiff)])
                : 0;

            return rewardTranslator + rewardChallenger;
        } else {
            return
                round.paidFees[_arbitration.ruling] > 0
                    ? (round.contributions[_beneficiary][_arbitration.ruling] * round.feeRewards) /
                        round.paidFees[_arbitration.ruling]
                    : 0;
        }
    }

    /**
     * @dev Turns the address of the arbitrable contract and the ID of the arbitrable item into an identifier.
     * @param _arbitrable The arbitrable contract address.
     * @param _arbitrableItemID The ID of the arbitrable item.
     */
    function getArbitrableID(address _arbitrable, uint256 _arbitrableItemID) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_arbitrable, _arbitrableItemID)));
    }

    /**
     * @dev Turns the address of the arbitrator contract and the ID of the dispute in that contract into an identifier.
     * @param _arbitrator The arbitrable contract address.
     * @param _arbitratorDisputeID The ID of the dispute in the arbitrator.
     */
    function getDisputeID(IArbitrator _arbitrator, uint256 _arbitratorDisputeID) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_arbitrator, _arbitratorDisputeID)));
    }
}
