// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import '@openzeppelin/contracts/access/Ownable.sol';
import './ISwanGovernance.sol';

/**
 * @title Swan Governance contract
 * @dev Main point of interaction with Swan protocol's governance
 * - Create a Proposal
 * - Cancel a Proposal
 * - Queue a Proposal
 * - Execute a Proposal
 * - Submit Vote to a Proposal
 *
 * @author Swan
 */
contract SwanGovernance is Ownable, ISwanGovernance {
    /// @notice The name of this contract
    string public constant name = 'Swan Governance';
    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
            'EIP712Domain(string name,uint256 chainId,address verifyingContract)'
        );

    /// @notice The EIP-712 typehash for the ballot struct used by the contract
    bytes32 public constant BALLOT_TYPEHASH =
        keccak256('Ballot(uint256 proposalId,bool support)');

    /// @notice The address of the Swan Protocol Timelock
    TimelockInterface public timelock;

    /// @notice The address of the Swan governance token
    SwanInterface public swan;

    /// @notice The address of the Governor Guardian
    address private _guardian;
    modifier onlyGuardian() {
        require(msg.sender == _guardian, 'ONLY_BY_GUARDIAN');
        _;
    }

    uint256 private _quorumVotes;
    uint256 private _proposalThreshold;
    uint256 private _maxProposalOperations = 10;
    uint256 private _votingDelay;

    constructor(
        address timelock_,
        uint256 quorumVotes_,
        uint256 proposalThreshold_,
        address swan_,
        uint256 votingDelay_,
        address guardian_
    ) {
        timelock = TimelockInterface(timelock_);
        _quorumVotes = quorumVotes_;
        _proposalThreshold = proposalThreshold_;
        swan = SwanInterface(swan_);
        _setVotingDelay(votingDelay_);
        _guardian = guardian_;
    }

    /// @notice The total number of proposals
    uint256 private _proposalsCount;

    /// @notice The official record of all proposals ever proposed
    mapping(uint256 => Proposal) public _proposals;

    /// @notice The latest proposal for each proposer
    mapping(address => uint256) public latestProposalIds;

    /// @notice the official record of all authorized executors
    mapping(address => bool) private _authorizedExecutors;

    function propose(
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        require(
            swan.getPriorVotes(msg.sender, sub256(block.number, 1)) >
                _proposalThreshold,
            'PROPOSAL_BELOW_THRESHOLD'
        );
        require(
            targets.length == values.length &&
                targets.length == signatures.length &&
                targets.length == calldatas.length,
            'INCONSISTENT_PARAMS_LENGTH'
        );
        require(targets.length != 0, 'INVALID_EMPTY_TARGETS');
        require(
            targets.length <= _maxProposalOperations,
            'INVALID_TOO_MANY_ACTIONS'
        );

        uint256 latestProposalId = latestProposalIds[msg.sender];
        if (latestProposalId != 0) {
            ProposalState proposersLatestProposalState = getProposalState(
                latestProposalId
            );
            require(
                proposersLatestProposalState != ProposalState.Active,
                'One live proposal per proposer, found an already active proposal'
            );
            require(
                proposersLatestProposalState != ProposalState.Pending,
                'One live proposal per proposer, found an already pending proposal'
            );
        }

        uint256 startBlock = add256(block.number, _votingDelay);
        uint256 endBlock = add256(startBlock, votingPeriod());

        _proposalsCount++;

        Proposal storage _newProposal = _proposals[_proposalsCount];
        _newProposal.id = _proposalsCount;
        _newProposal.proposer = msg.sender;
        _newProposal.eta = 0;
        _newProposal.targets = targets;
        _newProposal.values = values;
        _newProposal.signatures = signatures;
        _newProposal.calldatas = calldatas;
        _newProposal.startBlock = startBlock;
        _newProposal.endBlock = endBlock;
        _newProposal.forVotes = 0;
        _newProposal.againstVotes = 0;
        _newProposal.canceled = false;
        _newProposal.executed = false;

        latestProposalIds[_newProposal.proposer] = _newProposal.id;

        emit ProposalCreated(
            _newProposal.id,
            msg.sender,
            targets,
            values,
            signatures,
            calldatas,
            startBlock,
            endBlock,
            description
        );
        return _newProposal.id;
    }

    /**
     * @notice Queue the proposal (If Proposal Succeeded)
     * @param proposalId id of the proposal to queue
     **/
    function queue(uint256 proposalId) external override {
        require(
            getProposalState(proposalId) == ProposalState.Succeeded,
            'INVALID_STATE_FOR_QUEUE'
        );
        Proposal storage proposal = _proposals[proposalId];
        uint256 eta = add256(block.timestamp, timelock.delay());
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            _queueOrRevert(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                eta
            );
        }
        proposal.eta = eta;
        emit ProposalQueued(proposalId, eta);
    }

    function _queueOrRevert(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) internal {
        require(
            !timelock.queuedTransactions(
                keccak256(abi.encode(target, value, signature, data, eta))
            ),
            'PROPOSAL_ACTION_ALREADY_QUEUED_AT_ETA'
        );
        timelock.queueTransaction(target, value, signature, data, eta);
    }

    /**
     * @notice Execute the proposal (If Proposal Queued)
     * @param proposalId id of the proposal to execute
     **/
    function execute(uint256 proposalId) external payable override {
        require(
            getProposalState(proposalId) == ProposalState.Queued,
            'ONLY_QUEUED_PROPOSALS'
        );
        Proposal storage proposal = _proposals[proposalId];
        proposal.executed = true;
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            timelock.executeTransaction{value: proposal.values[i]}(
                proposal.targets[i],
                proposal.values[i],
                proposal.signatures[i],
                proposal.calldatas[i],
                proposal.eta
            );
        }
        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancels a Proposal, either at anytime by guardian
     * or when proposal is Pending/Active and threshold no longer reached
     * @param proposalId id of the proposal
     **/
    function cancel(uint256 proposalId) external override {
        ProposalState state = getProposalState(proposalId);

        require(
            state != ProposalState.Executed &&
                state != ProposalState.Canceled &&
                state != ProposalState.Expired,
            'ONLY_BEFORE_EXECUTED'
        );

        Proposal storage _proposal = _proposals[proposalId];
        require(
            msg.sender == _guardian ||
                swan.getPriorVotes(
                    _proposal.proposer,
                    sub256(block.number, 1)
                ) <
                _proposalThreshold,
            'PROPOSER_ABOVE_THRESHOLD'
        );
        _proposal.canceled = true;

        for (uint256 i = 0; i < _proposal.targets.length; i++) {
            timelock.cancelTransaction(
                _proposal.targets[i],
                _proposal.values[i],
                _proposal.signatures[i],
                _proposal.calldatas[i],
                _proposal.eta
            );
        }

        emit ProposalCanceled(proposalId);
    }

    /**
     * @dev Function allowing msg.sender to vote for/against a proposal
     * @param proposalId id of the proposal
     * @param support boolean, true = vote for, false = vote against
     **/
    function castVote(uint256 proposalId, bool support) external override {
        return _castVote(msg.sender, proposalId, support);
    }

    /**
     * @dev Function to register the vote of user that has voted offchain via signature
     * @param proposalId id of the proposal
     * @param support boolean, true = vote for, false = vote against
     * @param v v part of the voter signature
     * @param r r part of the voter signature
     * @param s s part of the voter signature
     **/
    function castVoteBySignature(
        uint256 proposalId,
        bool support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                getChainId(),
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(BALLOT_TYPEHASH, proposalId, support)
        );
        bytes32 digest = keccak256(
            abi.encodePacked('\x19\x01', domainSeparator, structHash)
        );
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), 'INVALID_SIGNATURE');
        return _castVote(signer, proposalId, support);
    }

    function _castVote(
        address voter,
        uint256 proposalId,
        bool support
    ) internal {
        require(
            getProposalState(proposalId) == ProposalState.Active,
            'VOTING_CLOSED'
        );
        Proposal storage proposal = _proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];

        require(receipt.hasVoted == false, 'VOTE_ALREADY_CASTED');

        uint256 votingPower = swan.getPriorVotes(voter, proposal.startBlock);

        if (support) {
            proposal.forVotes = add256(proposal.forVotes, votingPower);
        } else {
            proposal.againstVotes = add256(proposal.againstVotes, votingPower);
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votingPower;

        emit VoteCast(voter, proposalId, support, votingPower);
    }

    /**
     * @dev Set new Voting Delay (delay before a newly created proposal can be voted on)
     * Note: owner should be a timelocked executor, so needs to make a proposal
     * @param votingDelay_ new voting delay in terms of blocks
     **/
    function setVotingDelay(uint256 votingDelay_) external override onlyOwner {
        _setVotingDelay(votingDelay_);
    }

    function _setVotingDelay(uint256 votingDelay_) internal {
        _votingDelay = votingDelay_;

        emit VotingDelayChanged(votingDelay_, msg.sender);
    }

    /// @notice The delay before voting on a proposal may take place, once proposed
    function getVotingDelay() external view override returns (uint256) {
        return _votingDelay;
    }

    /**
     * @dev Add new addresses to the list of authorized executors
     * @param executors list of new addresses to be authorized executors
     **/
    function authorizeExecutors(address[] memory executors)
        public
        override
        onlyOwner
    {
        for (uint256 i = 0; i < executors.length; i++) {
            _authorizeExecutor(executors[i]);
        }
    }

    function _authorizeExecutor(address executor) internal {
        _authorizedExecutors[executor] = true;
        emit ExecutorAuthorized(executor);
    }

    /**
     * @dev Remove addresses to the list of authorized executors
     * @param executors list of addresses to be removed as authorized executors
     **/
    function unauthorizeExecutors(address[] memory executors)
        public
        override
        onlyOwner
    {
        for (uint256 i = 0; i < executors.length; i++) {
            _unauthorizeExecutor(executors[i]);
        }
    }

    function _unauthorizeExecutor(address executor) internal {
        _authorizedExecutors[executor] = false;
        emit ExecutorUnauthorized(executor);
    }

    /**
     * @dev Returns whether an address is an authorized executor
     * @param executor address to evaluate as authorized executor
     * @return true if authorized
     **/
    function isExecutorAuthorized(address executor)
        public
        view
        override
        returns (bool)
    {
        return _authorizedExecutors[executor];
    }

    /**
     * @dev Let the guardian abdicate from its priviledged rights
     **/
    function __abdicate() external override onlyGuardian {
        _guardian = address(0);
    }

    /// @dev The number of votes in support of a proposal required in order for a quorum to be reached and for a vote to succeed
    function getQuorumVotes() external view override returns (uint256) {
        return _quorumVotes;
    }

    /// @notice The number of votes required in order for a voter to become a proposer
    function proposalThreshold() external view override returns (uint256) {
        return _proposalThreshold; // x% of Swan
    }

    /// @notice The maximum number of actions that can be included in a proposal
    function proposalMaxOperations() external view override returns (uint256) {
        return _maxProposalOperations; // 10 actions
    }

    /**
     * @dev Getter the address of the guardian, that can mainly cancel proposals
     * @return The address of the guardian
     **/
    function getGuardian() external view override returns (address) {
        return _guardian;
    }

    /**
     * @dev Getter of the proposal count (the current number of proposals ever created)
     * @return the proposal count
     **/
    function getProposalsCount() external view override returns (uint256) {
        return _proposalsCount;
    }

    /**
     * @dev Getter of a proposal by id
     * @param proposalId id of the proposal to get
     * @return the proposal as ProposalWithoutReceipts memory object
     **/
    function getProposalById(uint256 proposalId)
        external
        view
        override
        returns (ProposalWithoutReceipts memory)
    {
        Proposal storage proposal = _proposals[proposalId];
        ProposalWithoutReceipts
            memory proposalWithoutReceipts = ProposalWithoutReceipts({
                id: proposal.id,
                proposer: proposal.proposer,
                eta: proposal.eta,
                targets: proposal.targets,
                values: proposal.values,
                signatures: proposal.signatures,
                calldatas: proposal.calldatas,
                startBlock: proposal.startBlock,
                endBlock: proposal.endBlock,
                forVotes: proposal.forVotes,
                againstVotes: proposal.againstVotes,
                canceled: proposal.canceled,
                executed: proposal.executed
            });

        return proposalWithoutReceipts;
    }

    /**
     * @dev Getter of the Receipt of a voter about a proposal
     * Note: Receipt is a struct: ({bool hasVoted, bool support, uint256 votes})
     * @param proposalId id of the proposal
     * @param voter address of the voter
     * @return The associated Receipt memory object
     **/
    function getReceiptOnProposal(uint256 proposalId, address voter)
        external
        view
        override
        returns (Receipt memory)
    {
        return _proposals[proposalId].receipts[voter];
    }

    /**
     * @dev Get the current state of a proposal
     * @param proposalId id of the proposal
     * @return The current state if the proposal
     **/
    function getProposalState(uint256 proposalId)
        public
        view
        override
        returns (ProposalState)
    {
        require(
            _proposalsCount >= proposalId && proposalId > 0,
            'INVALID_PROPOSAL_ID'
        );

        Proposal storage proposal = _proposals[proposalId];
        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        } else if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        } else if (
            proposal.forVotes <= proposal.againstVotes ||
            proposal.forVotes < _quorumVotes
        ) {
            return ProposalState.Defeated;
        } else if (proposal.eta == 0) {
            return ProposalState.Succeeded;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (
            block.timestamp >= add256(proposal.eta, timelock.GRACE_PERIOD())
        ) {
            return ProposalState.Expired;
        } else {
            return ProposalState.Queued;
        }
    }

    /// @notice The duration of voting on a proposal, in blocks
    function votingPeriod() public pure returns (uint256) {
        return 17280;
    } // ~3 days in blocks (assuming 15s blocks)

    function add256(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, 'addition overflow');
        return c;
    }

    function sub256(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, 'subtraction underflow');
        return a - b;
    }

    function getChainId() internal view returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }

    function __acceptAdmin() public onlyGuardian {
        timelock.acceptAdmin();
    }

    function __queueSetTimelockPendingAdmin(
        address newPendingAdmin,
        uint256 eta
    ) public onlyGuardian {
        timelock.queueTransaction(
            address(timelock),
            0,
            'setPendingAdmin(address)',
            abi.encode(newPendingAdmin),
            eta
        );
    }

    function __executeSetTimelockPendingAdmin(
        address newPendingAdmin,
        uint256 eta
    ) public onlyGuardian {
        timelock.executeTransaction(
            address(timelock),
            0,
            'setPendingAdmin(address)',
            abi.encode(newPendingAdmin),
            eta
        );
    }
}

interface TimelockInterface {
    function delay() external view returns (uint256);

    function GRACE_PERIOD() external view returns (uint256);

    function acceptAdmin() external;

    function queuedTransactions(bytes32 hash) external view returns (bool);

    function queueTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external returns (bytes32);

    function cancelTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external;

    function executeTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        uint256 eta
    ) external payable returns (bytes memory);
}

interface SwanInterface {
    function getPriorVotes(address account, uint256 blockNumber)
        external
        view
        returns (uint256);
}
