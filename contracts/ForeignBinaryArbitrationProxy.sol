/**
 * @authors: [@hbarcelos]
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 *
 * SPDX-License-Identifier: MIT
 */
pragma solidity ^0.7.6;

import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";
import "./dependencies/IAMB.sol";
import "./CrossChainBinaryArbitration.sol";

contract ForeignBinaryArbitrationProxy is IForeignBinaryArbitrationProxy, IEvidence {
    using CappedMath for uint256;

    /**
     * State chart for Arbitration status.
     * (I) Means the initial state.
     * (F) Means a final state.
     * [condition] Means a guard condition.
     *
     *                                                                                [Defendant did not pay]
     *                                                                                       |
     * +-(I)--+   Request Dispute   +-----------+                  +----------------+        |        +--(F)--+
     * | None +-------------------->+ Requested +----------------->+ DepositPending +---------------->+ Ruled |
     * +------+    [Registered]     +-----+-----+    [Accepted]    +-------+--------+                 +---+---+
     *     A                              |                                |                              ^
     *     |                              |                                |                              |
     *     |                              | [Rejected]                     | [Defendant Paid]             |
     *     |                              |                                |                              | Rule
     *     |                              |                                |                              |
     *     |                              |                                |          +---------+         |
     *     +------------------------------+--------------------------------+--------->+ Ongoing +---------+
     *                                                               |           |    +---------+
     *                                                               |           |
     *                                            [Create Dispute Failed]      [Create Dispute Created]
     */
    enum Status {None, Requested, DepositPending, Ongoing, Ruled}

    enum Party {None, Defendant, Plaintiff}

    struct Arbitration {
        Status status; // Status of the request.
        Party ruling; // The ruling of the dispute.
        uint240 acceptedAt; // The time when the dispute creation was accepted.
        address payable plaintiff; // The address of the plaintiff.
        address payable defendant; // The address of the defendant.
        uint256 sumDeposit; // The sum of deposits from the defendant and the plaintiff
        address arbitrable; // The address of the arbitrable contract.
        uint256 arbitrableItemID; // The ID of the arbitration item in the contract.
        IArbitrator arbitrator; // The address of the arbitrator contract.
        uint256 arbitratorDisputeID; // The ID of the dispute in the arbitrator.
        Round[] rounds; // Rounds of the dispute
    }

    struct Round {
        uint256[3] paidFees; // Tracks the fees paid by each side in this round.
        bool[3] fullyPaid; // True when the side has fully paid its fee. False otherwise.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side.
    }

    struct MetaEvidenceChanges {
        string[] values;
        uint256[] arbitrableItemIDs;
    }

    struct ArbitratorExtraDataChanges {
        bytes[] values;
        uint256[] arbitrableItemIDs;
    }

    struct DisputeParamChanges {
        MetaEvidenceChanges metaEvidence;
        ArbitratorExtraDataChanges arbitratorExtraData;
    }

    /// @dev A value depositor won't be able to pay.
    uint256 private constant NON_PAYABLE_VALUE = (2**256 - 2) / 2;

    /// @dev The number of choices for the arbitrator.
    uint256 public constant NUMBER_OF_CHOICES = 2;

    /// @dev Divisor parameter for multipliers.
    uint256 public constant MULTIPLIER_DIVISOR = 10000;

    /// @dev The contract governor. TRUSTED.
    address public governor = msg.sender;

    /// @dev The amount of time the defendant side have to deposit the arbitration fee.
    uint240 public feeDepositTimeout;

    /// @dev The address of the arbitrator. TRUSTED.
    IArbitrator public arbitrator;

    /// @dev ArbitraryMessageBridge contract address. TRUSTED.
    IAMB public amb;

    /// @dev Address of the counter-party proxy on the Home Chain. TRUSTED.
    address public homeProxy;

    /// @dev The chain ID where the home proxy is deployed.
    uint256 public homeChainId;

    /// @dev Multiplier for calculating the appeal fee that must be paid by submitter in the case where there isn't a winner and loser (e.g. when the arbitrator ruled "refuse to arbitrate").
    uint256 public sharedStakeMultiplier;

    /// @dev Multiplier for calculating the appeal fee of the party that won the previous round.
    uint256 public winnerStakeMultiplier;

    /// @dev  Multiplier for calculating the appeal fee of the party that lost the previous round.
    uint256 public loserStakeMultiplier;

    /// @dev The arbitrations by arbitrationID.
    mapping(uint256 => Arbitration) public arbitrations;

    /// @dev Maps the disputeIDs to arbitrationIDs.
    mapping(uint256 => uint256) public disputeIDToArbitrationID;

    /// @dev Stores disputeParamChanges for dispute creation for contracts and items.
    mapping(address => DisputeParamChanges) private disputeParamChanges;

    /**
     * @dev Emitted when someone contributes to a dispute or appeal.
     * @param _arbitrationID The ID of the arbitration.
     * @param _party The party which received the contribution.
     * @param _contributor The address of the contributor.
     * @param _amount The amount contributed.
     * @param _roundNumber The round from which to withdraw.
     */
    event FeeContribution(
        uint256 indexed _arbitrationID,
        Party _party,
        address indexed _contributor,
        uint256 _amount,
        uint256 indexed _roundNumber
    );

    /**
     * @dev Emitted when someone pays for the full dispute or appeal fee.
     * @param _arbitrationID The ID of the arbitration.
     * @param _party The party which received the contribution.
     * @param _roundNumber The round from which to withdraw.
     */
    event FeePaid(uint256 indexed _arbitrationID, Party indexed _party, uint256 indexed _roundNumber);

    modifier onlyGovernor() {
        require(msg.sender == governor, "Only governor allowed");
        _;
    }

    modifier onlyHomeProxy() {
        require(msg.sender == address(amb), "Only AMB allowed");
        require(amb.messageSourceChainId() == bytes32(homeChainId), "Only home chain allowed");
        require(amb.messageSender() == homeProxy, "Only home proxy allowed");
        _;
    }

    modifier onlyIfInitialized() {
        require(homeProxy != address(0), "Not initialized yet");
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
        uint240 _feeDepositTimeout,
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
     * @notice Sets the address of the arbitrator.
     * @param _arbitrator The address of the new arbitrator.
     */
    function changeArbitrator(IArbitrator _arbitrator) external onlyGovernor {
        arbitrator = _arbitrator;
    }

    /**
     * @notice Sets the address of the ArbitraryMessageBridge.
     * @param _amb The address of the new ArbitraryMessageBridge.
     */
    function changeAmb(IAMB _amb) external onlyGovernor {
        amb = _amb;
    }

    /**
     * @notice Sets the address of the arbitration proxy on the Home Chain.
     * @param _homeProxy The address of the proxy.
     * @param _homeChainId The chain ID where the home proxy is deployed.
     */
    function setHomeProxy(address _homeProxy, uint256 _homeChainId) external onlyGovernor {
        require(homeProxy == address(0), "Home proxy already set");

        homeProxy = _homeProxy;
        homeChainId = _homeChainId;
    }

    /**
     * @notice Sets the amount of time the defendant has to deposit the arbitration fee.
     * @param _feeDepositTimeout The amount of time (seconds) to deposit.
     */
    function changeFeeDepositTimeout(uint240 _feeDepositTimeout) external onlyGovernor {
        feeDepositTimeout = _feeDepositTimeout;
    }

    /**
     * @notice Changes the percentage of arbitration fees that must be paid by parties as a fee stake if there was no winner and loser in the previous round.
     * @param _sharedStakeMultiplier A new value of the multiplier of the appeal cost in case when there is no winner/loser in previous round. In basis point.
     */
    function changeSharedStakeMultiplier(uint256 _sharedStakeMultiplier) external onlyGovernor {
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /**
     * @notice Changes the percentage of arbitration fees that must be paid as a fee stake by the party that won the previous round.
     * @param _winnerStakeMultiplier A new value of the multiplier of the appeal cost that the winner of the previous round has to pay. In basis points.
     */
    function changeWinnerStakeMultiplier(uint256 _winnerStakeMultiplier) external onlyGovernor {
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /**
     * @notice Changes the percentage of arbitration fees that must be paid as a fee stake by the party that lost the previous round.
     * @param _loserStakeMultiplier A new value of the multiplier of the appeal cost that the party that lost the previous round has to pay. In basis points.
     */
    function changeLoserStakeMultiplier(uint256 _loserStakeMultiplier) external onlyGovernor {
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /**
     * @notice Receives meta evidence at arbitrable item level.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _metaEvidence The MetaEvicence related to the arbitrable item.
     */
    function receiveMetaEvidence(
        address _arbitrable,
        uint256 _arbitrableItemID,
        string calldata _metaEvidence
    ) external override {
        MetaEvidenceChanges storage metaEvidenceChanges = disputeParamChanges[_arbitrable].metaEvidence;

        uint256 listSize = metaEvidenceChanges.arbitrableItemIDs.length;

        if (listSize > 0) {
            require(
                _arbitrableItemID > metaEvidenceChanges.arbitrableItemIDs[listSize - 1],
                "Item ID value lower than latest"
            );
            require(
                keccak256(abi.encodePacked(metaEvidenceChanges.values[listSize - 1])) !=
                    keccak256(abi.encodePacked(_metaEvidence)),
                "MetaEvidence should be different"
            );
        }

        metaEvidenceChanges.values.push(_metaEvidence);
        metaEvidenceChanges.arbitrableItemIDs.push(_arbitrableItemID);

        emit MetaEvidenceReceived(_arbitrable, _arbitrableItemID, _metaEvidence);
    }

    /**
     * @notice Receives arbitrator extra data at arbitrable item level.
     * @dev Should be called only by the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     */
    function receiveArbitratorExtraData(
        address _arbitrable,
        uint256 _arbitrableItemID,
        bytes calldata _arbitratorExtraData
    ) external override onlyHomeProxy {
        ArbitratorExtraDataChanges storage arbitratorExtraDataChanges =
            disputeParamChanges[_arbitrable].arbitratorExtraData;

        uint256 listSize = arbitratorExtraDataChanges.arbitrableItemIDs.length;
        if (listSize > 0) {
            require(
                _arbitrableItemID > arbitratorExtraDataChanges.arbitrableItemIDs[listSize - 1],
                "Item ID value lower than latest"
            );
            require(
                keccak256(abi.encodePacked(arbitratorExtraDataChanges.values[listSize - 1])) !=
                    keccak256(abi.encodePacked(_arbitratorExtraData)),
                "Extra data should be different"
            );
        }

        arbitratorExtraDataChanges.values.push(_arbitratorExtraData);
        arbitratorExtraDataChanges.arbitrableItemIDs.push(_arbitrableItemID);

        emit ArbitratorExtraDataReceived(_arbitrable, _arbitrableItemID, _arbitratorExtraData);
    }

    /**
     * @notice Requests the creation of a dispute for an arbitrable item.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function requestDispute(address _arbitrable, uint256 _arbitrableItemID) external payable onlyIfInitialized {
        uint256 arbitrationID = getArbitrationID(_arbitrable, _arbitrableItemID);
        Arbitration storage arbitration = arbitrations[arbitrationID];
        (bytes storage arbitratorExtraData, ) = getDisputeParamsStorage(_arbitrable, _arbitrableItemID);
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);

        require(arbitration.status == Status.None, "Dispute already requested");
        require(msg.value >= arbitrationCost, "Deposit value too low");

        (, uint256 remainder) = calculateContribution(msg.value, arbitrationCost);

        arbitration.arbitrable = _arbitrable;
        arbitration.arbitrableItemID = _arbitrableItemID;
        arbitration.status = Status.Requested;
        arbitration.plaintiff = msg.sender;
        arbitration.sumDeposit = arbitrationCost;

        if (remainder > 0) {
            msg.sender.send(remainder);
        }

        emit DisputeRequested(arbitrationID, msg.sender);

        bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveDisputeRequest.selector;
        bytes memory data =
            abi.encodeWithSelector(methodSelector, arbitration.arbitrable, arbitration.arbitrableItemID, msg.sender);
        amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());
    }

    /**
     * @notice Receives from the Home Chain that the dispute has been accepted.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function receiveDisputeAccepted(address _arbitrable, uint256 _arbitrableItemID) external override onlyHomeProxy {
        uint256 arbitrationID = getArbitrationID(_arbitrable, _arbitrableItemID);
        Arbitration storage arbitration = arbitrations[arbitrationID];

        require(arbitration.status == Status.Requested, "Invalid arbitration status");

        arbitration.status = Status.DepositPending;
        arbitration.acceptedAt = uint240(block.timestamp);

        emit DisputeAccepted(arbitrationID);
    }

    /**
     * @notice Receives from the Home Chain that the dispute has been rejected.
     * @dev Should only be called by the xDAI/ETH bridge.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitration item on the arbitrable contract.
     */
    function receiveDisputeRejected(address _arbitrable, uint256 _arbitrableItemID) external override onlyHomeProxy {
        uint256 arbitrationID = getArbitrationID(_arbitrable, _arbitrableItemID);
        Arbitration storage arbitration = arbitrations[arbitrationID];

        require(arbitration.status == Status.Requested, "Invalid arbitration status");
        address payable plaintiff = arbitration.plaintiff;
        // At this point, only the plantiff have contributed.
        uint256 deposit = arbitration.sumDeposit;

        delete arbitrations[arbitrationID];

        plaintiff.send(deposit); // It is the user responsibility to accept ETH.

        emit DisputeRejected(arbitrationID);
    }

    /**
     * @notice Funds the defendant side of the dispute after it has been accepted.
     * @dev We require both sides to pay the full arbitration cost, so the winner can be refunded after.
     * The plaintiff already paid it when the dispute was requested.
     * @param _arbitrationID The ID of the arbitration.
     */
    function payDefendantFee(uint256 _arbitrationID) external payable {
        Arbitration storage arbitration = arbitrations[_arbitrationID];
        (bytes storage arbitratorExtraData, string storage metaEvidence) =
            getDisputeParamsStorage(arbitration.arbitrable, arbitration.arbitrableItemID);

        require(arbitration.status == Status.DepositPending, "Invalid arbitration status");
        require(block.timestamp <= arbitration.acceptedAt + feeDepositTimeout, "Deadline for deposit has expired");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        require(msg.value >= arbitrationCost, "Deposit value too low");

        (, uint256 remainder) = calculateContribution(msg.value, arbitrationCost);
        arbitration.sumDeposit = arbitration.sumDeposit.addCap(arbitrationCost);
        arbitration.defendant = msg.sender;

        if (createDispute(_arbitrationID, arbitrationCost, arbitratorExtraData)) {
            emit MetaEvidence(_arbitrationID, metaEvidence);

            if (remainder > 0) {
                // Reimburse the contributor with the remaining value.
                msg.sender.send(remainder);
            }

            bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveDisputeCreated.selector;
            bytes memory data =
                abi.encodeWithSelector(
                    methodSelector,
                    arbitration.arbitrable,
                    arbitration.arbitrableItemID,
                    arbitration.arbitrator,
                    arbitration.arbitratorDisputeID
                );
            amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());
        } else {
            address arbitrable = arbitration.arbitrable;
            uint256 arbitrableItemID = arbitration.arbitrableItemID;
            address payable plaintiff = arbitration.plaintiff;
            uint256 plaintiffDeposit = arbitration.sumDeposit.subCap(arbitrationCost);

            delete arbitrations[_arbitrationID];

            // If the dispute creation fails, fully reimburse the defendant and the plaintiff
            msg.sender.send(msg.value); // It is the user responsibility to accept ETH.
            plaintiff.send(plaintiffDeposit); // It is the user responsibility to accept ETH.

            bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveDisputeFailed.selector;
            bytes memory data = abi.encodeWithSelector(methodSelector, arbitrable, arbitrableItemID);
            amb.requireToPassMessage(homeProxy, data, amb.maxGasPerTx());
        }
    }

    /**
     * @notice Creates a dispute in the arbitrator.
     * @param _arbitrationID The already calculated arbitrable ID to save up some gas.
     * @param _arbitrationCost The cost of arbitration.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     * @return Whether the dispute creation succeeded or not.
     */
    function createDispute(
        uint256 _arbitrationID,
        uint256 _arbitrationCost,
        bytes storage _arbitratorExtraData
    ) internal returns (bool) {
        Arbitration storage arbitration = arbitrations[_arbitrationID];

        try arbitrator.createDispute{value: _arbitrationCost}(NUMBER_OF_CHOICES, _arbitratorExtraData) returns (
            uint256 arbitratorDisputeID
        ) {
            uint256 disputeID = getDisputeID(arbitrator, arbitratorDisputeID);

            arbitration.status = Status.Ongoing;
            arbitration.arbitrator = arbitrator;
            arbitration.arbitratorDisputeID = arbitratorDisputeID;
            arbitration.sumDeposit = arbitration.sumDeposit.subCap(_arbitrationCost);
            // Create a new round for a possible appeal.
            arbitration.rounds.push();

            disputeIDToArbitrationID[disputeID] = _arbitrationID;

            emit Dispute(arbitrator, arbitratorDisputeID, _arbitrationID, _arbitrationID);
            emit DisputeOngoing(_arbitrationID, arbitrator, arbitratorDisputeID);

            return true;
        } catch {
            emit DisputeFailed(_arbitrationID, arbitrator, _arbitratorExtraData);

            return false;
        }
    }

    /**
     * @notice Reimburses the rest.
     * @dev Takes up to the total amount required to fund a side of an appeal.
     * If users send more than required, they will be reimbursed of the remaining.
     * Creates an appeal if both sides are fully funded.
     * @param _arbitrationID The ID of the arbitration.
     * @param _party The party that pays the appeal fee.
     */
    function fundAppeal(uint256 _arbitrationID, Party _party) external payable {
        require(msg.value > 0, "Must pay non-zero value");

        Arbitration storage arbitration = arbitrations[_arbitrationID];
        (bytes storage arbitratorExtraData, ) =
            getDisputeParamsStorage(arbitration.arbitrable, arbitration.arbitrableItemID);

        require(_party == Party.Defendant || _party == Party.Plaintiff, "Invalid side");
        require(arbitration.status == Status.Ongoing, "Invalid arbitration status");

        Round storage round = arbitration.rounds[arbitration.rounds.length - 1];
        require(!round.fullyPaid[uint256(_party)], "Appeal fee already paid");

        (uint256 appealCost, uint256 totalCost) = getAppealFeeComponents(arbitration, _party, arbitratorExtraData);

        (uint256 remainder, ) = contribute(_arbitrationID, _party, msg.sender, msg.value, totalCost);

        if (round.fullyPaid[uint256(Party.Defendant)] && round.fullyPaid[uint256(Party.Plaintiff)]) {
            round.feeRewards = round.feeRewards.subCap(appealCost);
            arbitration.rounds.push();

            // The appeal must happen on the same arbitrator the original dispute was created.
            arbitration.arbitrator.appeal{value: appealCost}(arbitration.arbitratorDisputeID, arbitratorExtraData);
        }

        msg.sender.send(remainder);
    }

    /**
     * @notice Allows to submit evidence for a particular arbitration.
     * @param _arbitrationID The ID of the arbitration.
     * @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint256 _arbitrationID, string calldata _evidenceURI) external override {
        Arbitration storage arbitration = arbitrations[_arbitrationID];
        require(arbitration.status < Status.Ruled, "Invalid status");

        if (bytes(_evidenceURI).length > 0) {
            emit Evidence(arbitrator, _arbitrationID, msg.sender, _evidenceURI);
        }
    }

    /**
     * @notice Give a ruling for a dispute. Must be called by the arbitrator.
     * The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     * @param _arbitratorDisputeID ID of the dispute in the Arbitrator contract.
     * @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint256 _arbitratorDisputeID, uint256 _ruling) external override {
        uint256 disputeID = getDisputeID(IArbitrator(msg.sender), _arbitratorDisputeID);
        uint256 arbitrationID = disputeIDToArbitrationID[disputeID];
        Arbitration storage arbitration = arbitrations[arbitrationID];

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
            arbitration.ruling = Party.Defendant;
        } else if (round.fullyPaid[uint256(Party.Plaintiff)] == true) {
            arbitration.ruling = Party.Plaintiff;
        } else {
            arbitration.ruling = Party(_ruling);
        }

        if (arbitration.ruling == Party.None) {
            uint256 amount = arbitration.sumDeposit / 2;
            arbitration.plaintiff.send(amount);
            arbitration.defendant.send(amount);
        } else if (arbitration.ruling == Party.Defendant) {
            arbitration.defendant.send(arbitration.sumDeposit);
        } else {
            arbitration.plaintiff.send(arbitration.sumDeposit);
        }
        arbitration.sumDeposit = 0;

        emit Ruling(arbitration.arbitrator, _arbitratorDisputeID, uint256(arbitration.ruling));
        emit DisputeRuled(arbitrationID, uint256(arbitration.ruling));

        bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveRuling.selector;
        bytes memory data =
            abi.encodeWithSelector(
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
     * @param _arbitrationID The ID of the arbitration.
     */
    function claimPlaintiffWin(uint256 _arbitrationID) external {
        Arbitration storage arbitration = arbitrations[_arbitrationID];

        require(arbitration.status == Status.DepositPending, "Invalid arbitration status");
        require(block.timestamp > arbitration.acceptedAt + feeDepositTimeout, "Defendant deposit still possible");

        uint256 deposit = arbitration.sumDeposit;

        arbitration.status = Status.Ruled;
        arbitration.ruling = Party.Plaintiff;
        arbitration.sumDeposit = 0;

        arbitration.plaintiff.send(deposit); // It is the user responsibility to accept ETH.

        emit DisputeRuled(_arbitrationID, uint256(arbitration.ruling));

        bytes4 methodSelector = IHomeBinaryArbitrationProxy(0).receiveRuling.selector;
        bytes memory data =
            abi.encodeWithSelector(
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
     * @param _arbitrationID The ID of the arbitration.
     * @param _cursor The round from where to start withdrawing.
     * @param _count The number of rounds to iterate. If set to 0 or a value larger than the number of rounds, iterates until the last round.
     */
    function batchWithdrawFeesAndRewards(
        uint256 _arbitrationID,
        address payable _beneficiary,
        uint256 _cursor,
        uint256 _count
    ) external {
        Arbitration storage arbitration = arbitrations[_arbitrationID];

        require(
            arbitration.status == Status.Ruled,
            "The arbitration is not settled"
        );

        uint256 amount;
        for (uint256 i = _cursor; i < arbitration.rounds.length && (_count == 0 || i < _cursor + _count); i++) {
            amount += registerWithdrawal(arbitration, _beneficiary, i);
        }

        _beneficiary.send(amount); // It is the user responsibility to accept ETH.
    }

    /**
     * @dev Withdraws contributions of a specific appeal round.
     * @notice Reimburses contributions if no appeals were raised; otherwise sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute.
     * @param _arbitrationID The ID of the arbitration.
     * @param _beneficiary The address that made contributions.
     * @param _roundNumber The round from which to withdraw.
     * @return amount The withdrawn amount.
     */
    function withdrawFeesAndRewards(
        uint256 _arbitrationID,
        address payable _beneficiary,
        uint256 _roundNumber
    ) external returns (uint256 amount) {
        Arbitration storage arbitration = arbitrations[_arbitrationID];

        require(
            arbitration.status == Status.Ruled,
            "The arbitration is not settled"
        );
        require(arbitration.rounds.length > 0, "No appeal rounds");

        amount = registerWithdrawal(arbitration, _beneficiary, _roundNumber);

        _beneficiary.send(amount); // It is the user responsibility to accept ETH.
    }

    /**
     * @notice Returns the arbitration cost for a given arbitrable item.
     * @param _arbitrationID The ID of the arbitration.
     * @return The dispute fee.
     */
    function getDisputeFee(uint256 _arbitrationID) external view returns (uint256) {
        Arbitration storage arbitration = arbitrations[_arbitrationID];
        (bytes storage arbitratorExtraData, ) =
            getDisputeParamsStorage(arbitration.arbitrable, arbitration.arbitrableItemID);
        if (arbitration.status <= Status.DepositPending) {
            return arbitrator.arbitrationCost(arbitratorExtraData);
        } else {
            return NON_PAYABLE_VALUE;
        }
    }

    /**
     * @notice Returns the appeal cost for a given arbitrable item.
     * @param _arbitrationID The ID of the arbitration.
     * @param _party The party to get the appeal fee for.
     * @return The appeal fee.
     */
    function getAppealFee(uint256 _arbitrationID, Party _party) external view returns (uint256) {
        Arbitration storage arbitration = arbitrations[_arbitrationID];
        (bytes storage arbitratorExtraData, ) =
            getDisputeParamsStorage(arbitration.arbitrable, arbitration.arbitrableItemID);

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) =
            arbitration.arbitrator.appealPeriod(arbitration.arbitratorDisputeID);

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

        uint256 appealCost = arbitration.arbitrator.appealCost(arbitration.arbitratorDisputeID, arbitratorExtraData);

        return appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);
    }

    /**
     * @dev Gets the number of rounds of arbitration.
     * @param _arbitrationID The ID of the arbitration.
     * @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _arbitrationID) external view returns (uint256) {
        Arbitration storage arbitration = arbitrations[_arbitrationID];

        return arbitration.rounds.length;
    }

    /**
     * @notice Gets the information of a round of an arbitration.
     * @param _arbitrationID The ID of the arbitration.
     * @return paidFees The amount of fees paid by each side.
     * @return fullyPaid Whether each side has paid all the required appeal fees or not.
     * @return feeRewards The total amount of appeal fees to be used as crowdfunding rewards.
     */
    function getRoundInfo(uint256 _arbitrationID, uint256 _roundNumber)
        external
        view
        returns (
            uint256[3] memory paidFees,
            bool[3] memory fullyPaid,
            uint256 feeRewards
        )
    {
        Arbitration storage arbitration = arbitrations[_arbitrationID];
        Round storage round = arbitration.rounds[_roundNumber];

        return (round.paidFees, round.fullyPaid, round.feeRewards);
    }

    /**
     * @dev Gets the contributions made by a party for a given round of task appeal.
     * @param _arbitrationID The ID of the arbitration.
     * @param _contributor The address of the contributor.
     * @param _roundNumber The position of the round.
     * @return The contributions.
     */
    function getContributions(
        uint256 _arbitrationID,
        address _contributor,
        uint256 _roundNumber
    ) external view returns (uint256[3] memory) {
        Arbitration storage arbitration = arbitrations[_arbitrationID];

        return arbitration.rounds[_roundNumber].contributions[_contributor];
    }

    /**
     * @notice Returns the sum of withdrawable wei from appeal rounds. This function is O(n), where n is the number of rounds of the task. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     * @param _arbitrationID The ID of the arbitration.
     * @param _beneficiary The contributor for which to query.
     * @return total The total amount of wei available to withdraw.
     */
    function getTotalWithdrawableAmount(uint256 _arbitrationID, address _beneficiary)
        external
        view
        returns (uint256 total)
    {
        Arbitration storage arbitration = arbitrations[_arbitrationID];

        // Only Ruled arbitrations or those one which failed and where reset are withdrawable.
        if (arbitration.status != Status.Ruled) {
            return 0;
        }

        for (uint256 i = 0; i < arbitration.rounds.length; i++) {
            total += getWithdrawableAmount(arbitration, _beneficiary, i);
        }

        return total;
    }

    /**
     * @notice Makes a fee contribution to the current round.
     * @param _arbitrationID The ID of the arbitration.
     * @param _party The party which to contribute.
     * @param _contributor The address of the contributor.
     * @param _availableAmount The amount the contributor has sent.
     * @param _totalRequired The total amount required for the party.
     * @return remainder The remainder to send back to the contributor.
     * @return fullyPaid Whether or not the contribution is enough to cover the total required.
     */
    function contribute(
        uint256 _arbitrationID,
        Party _party,
        address _contributor,
        uint256 _availableAmount,
        uint256 _totalRequired
    ) internal returns (uint256 remainder, bool fullyPaid) {
        Arbitration storage arbitration = arbitrations[_arbitrationID];
        uint256 roundNumber = arbitration.rounds.length - 1;
        Round storage round = arbitration.rounds[roundNumber];

        uint256 contribution;
        (contribution, remainder) = calculateContribution(
            _availableAmount,
            _totalRequired.subCap(round.paidFees[uint256(_party)])
        );

        round.feeRewards += contribution;
        round.paidFees[uint256(_party)] += contribution;
        round.contributions[_contributor][uint256(_party)] += contribution;

        emit FeeContribution(_arbitrationID, _party, _contributor, contribution, roundNumber);

        if (round.paidFees[uint256(_party)] >= _totalRequired) {
            round.fullyPaid[uint256(_party)] = true;

            emit FeePaid(_arbitrationID, _party, roundNumber);
        }

        return (remainder, round.fullyPaid[uint256(_party)]);
    }

    /**
     * @notice Gets the dispute params for a given arbitrable item.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item.
     * @return arbitratorExtraData The extra data for the arbitrator.
     * @return metaEvidence The meta evidence for the item.
     */
    function getDisputeParams(address _arbitrable, uint256 _arbitrableItemID)
        external
        view
        returns (bytes memory arbitratorExtraData, string memory metaEvidence)
    {
        return getDisputeParamsStorage(_arbitrable, _arbitrableItemID);
    }

    /**
     * @notice Gets the storage pointer for the dispute params for a given arbitrable item.
     * @param _arbitrable The address of the arbitrable contract.
     * @param _arbitrableItemID The ID of the arbitrable item.
     * @return arbitratorExtraData The extra data for the arbitrator.
     * @return metaEvidence The meta evidence for the item.
     */
    function getDisputeParamsStorage(address _arbitrable, uint256 _arbitrableItemID)
        internal
        view
        returns (bytes storage arbitratorExtraData, string storage metaEvidence)
    {
        ArbitratorExtraDataChanges storage arbitratorExtraDataChanges =
            disputeParamChanges[_arbitrable].arbitratorExtraData;
        MetaEvidenceChanges storage metaEvidenceChanges = disputeParamChanges[_arbitrable].metaEvidence;

        require(
            arbitratorExtraDataChanges.arbitrableItemIDs.length > 0 &&
                arbitratorExtraDataChanges.arbitrableItemIDs[0] <= _arbitrableItemID,
            "ArbitratorExtraData not found"
        );
        require(
            metaEvidenceChanges.arbitrableItemIDs.length > 0 &&
                metaEvidenceChanges.arbitrableItemIDs[0] <= _arbitrableItemID,
            "MetaEvidence not found"
        );

        arbitratorExtraData = arbitratorExtraDataChanges.values[
            findBestIndex(arbitratorExtraDataChanges.arbitrableItemIDs, _arbitrableItemID)
        ];

        metaEvidence = metaEvidenceChanges.values[
            findBestIndex(metaEvidenceChanges.arbitrableItemIDs, _arbitrableItemID)
        ];
    }

    /**
     * @notice Finds the best index for a value in a sorted list. O(log n) in worst case.
     * @dev Finds the index `n` such _list[0], _list[1], ... list[n] <= _value < _list[n + 1] ...
     * @param _list The sorted list.
     * @param _value The value to search.
     * @return The index for the value.
     */
    function findBestIndex(uint256[] storage _list, uint256 _value) internal view returns (uint256) {
        uint256 left = 0;
        uint256 right = _list.length;

        // Optimizaiton for a common access pattern
        if (_value > _list[right - 1]) {
            return right - 1;
        }

        while (left < right) {
            uint256 pivot = (left + right / 2);
            if (_list[pivot] <= _value) {
                left = pivot + 1;
            } else {
                right = pivot;
            }
        }

        return right - 1;
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
     * @notice Calculates the appeal fee and total cost for an arbitration.
     * @dev This function was extracted from `fundAppeal` because of the stack depth problem.
     * @param _arbitration The arbitration object.
     * @param _party The party appealing.
     * @param _arbitratorExtraData The extra data for the arbitrator.
     * @return appealCost The actual appeal cost.  @return totalCost The total cost for the appeal. */
    function getAppealFeeComponents(
        Arbitration storage _arbitration,
        Party _party,
        bytes storage _arbitratorExtraData
    ) internal view returns (uint256 appealCost, uint256 totalCost) {
        (uint256 appealPeriodStart, uint256 appealPeriodEnd) =
            _arbitration.arbitrator.appealPeriod(_arbitration.arbitratorDisputeID);
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

        appealCost = _arbitration.arbitrator.appealCost(_arbitration.arbitratorDisputeID, _arbitratorExtraData);
        totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);
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
        } else if (_arbitration.ruling == Party.None) {
            uint256 rewardDefendant =
                round.paidFees[uint256(Party.Defendant)] > 0
                    ? (round.contributions[_beneficiary][uint256(Party.Defendant)] * round.feeRewards) /
                        (round.paidFees[uint256(Party.Defendant)] + round.paidFees[uint256(Party.Plaintiff)])
                    : 0;
            uint256 rewardPlaintiff =
                round.paidFees[uint256(Party.Plaintiff)] > 0
                    ? (round.contributions[_beneficiary][uint256(Party.Plaintiff)] * round.feeRewards) /
                        (round.paidFees[uint256(Party.Defendant)] + round.paidFees[uint256(Party.Plaintiff)])
                    : 0;

            return rewardDefendant + rewardPlaintiff;
        } else {
            return
                round.paidFees[uint256(_arbitration.ruling)] > 0
                    ? (round.contributions[_beneficiary][uint256(_arbitration.ruling)] * round.feeRewards) /
                        round.paidFees[uint256(_arbitration.ruling)]
                    : 0;
        }
    }

    /**
     * @dev Turns the address of the arbitrable contract and the ID of the arbitrable item into an identifier.
     * @param _arbitrable The arbitrable contract address.
     * @param _arbitrableItemID The ID of the arbitration item.
     */
    function getArbitrationID(address _arbitrable, uint256 _arbitrableItemID) public pure returns (uint256) {
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
