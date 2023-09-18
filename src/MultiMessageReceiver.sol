// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.8.9;

/// external modules
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// interfaces
import "./interfaces/IMessageReceiverAdapter.sol";
import "./interfaces/IMultiMessageReceiver.sol";
import "./interfaces/EIP5164/ExecutorAware.sol";
import "./interfaces/IGovernanceTimelock.sol";

/// libraries
import "./libraries/Error.sol";
import "./libraries/Message.sol";

/// @title Multi-bridge message receiver.
/// @notice This contract is deployed on each destination chain, and receives messages sent by the MultiMessageSender
/// contract on the source chain, through multiple bridge adapters. A message is considered valid and can be executed
/// if it has been delivered by enough trusted bridge receiver adapters (i.e. has achieved a quorum threshold),
/// before the message's expiration. If a message is successfully validated in time, it is queued for execution on the
/// governance timelock contract.
/// @dev The contract only accepts messages from trusted bridge receiver adapters, each of which implements the
/// IMessageReceiverAdapter interface.
contract MultiMessageReceiver is IMultiMessageReceiver, ExecutorAware, Initializable {
    /*/////////////////////////////////////////////////////////////////
                            STATE VARIABLES
    ////////////////////////////////////////////////////////////////*/

    /// @notice the id of the source chain that this contract can receive messages from
    uint256 public srcChainId;

    /// @notice minimum number of bridges that must deliver a message for it to be considered valid
    uint64 public quorum;

    /// @notice the address of governance timelock contract on the same chain, that a message will be forwarded to for execution
    address public governanceTimelock;

    /// @notice maintains which bridge adapters have delivered each message
    mapping(bytes32 msgId => mapping(address receiverAdapter => bool delivered)) public msgDeliveries;

    /// @notice count of bridge adapters that have delivered each message
    mapping(bytes32 msgId => uint256 deliveryCount) public msgDeliveryCount;

    /// @notice the data required for executing a message
    mapping(bytes32 msgId => ExecutionData execData) public msgExecData;

    /// @notice whether a message has been validated and sent to the governance timelock for execution
    mapping(bytes32 msgId => bool executed) public isExecuted;

    /*/////////////////////////////////////////////////////////////////
                                MODIFIERS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Checks whether the caller is a trusted bridge receiver adapter
    modifier onlyReceiverAdapter() {
        if (!isTrustedExecutor(msg.sender)) {
            revert Error.INVALID_RECEIVER_ADAPTER();
        }
        _;
    }

    /// @notice A modifier used for restricting the caller to just the governance timelock contract
    modifier onlyGovernanceTimelock() {
        if (msg.sender != governanceTimelock) {
            revert Error.CALLER_NOT_GOVERNANCE_TIMELOCK();
        }
        _;
    }

    /*/////////////////////////////////////////////////////////////////
                                INITIALIZER
    ////////////////////////////////////////////////////////////////*/

    /// @notice sets the initial parameters
    function initialize(
        uint256 _srcChainId,
        address[] calldata _receiverAdapters,
        bool[] calldata _operations,
        uint64 _quorum,
        address _governanceTimelock
    ) external initializer {
        if (_governanceTimelock == address(0)) {
            revert Error.ZERO_GOVERNANCE_TIMELOCK();
        }
        governanceTimelock = _governanceTimelock;

        /// @dev adds the new receiver adapters  before setting quorum and validations to account for duplicates
        _updateReceiverAdapters(_receiverAdapters, _operations);

        if (_quorum > trustedExecutorsCount() || _quorum == 0) {
            revert Error.INVALID_QUORUM_THRESHOLD();
        }
        quorum = _quorum;

        srcChainId = _srcChainId;
    }

    /*/////////////////////////////////////////////////////////////////
                                EXTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /// @notice receive messages from allowed bridge receiver adapters
    /// @param _message is the crosschain message sent by the mma sender
    /// @param _bridgeName is the name of the bridge that relays the message
    function receiveMessage(MessageLibrary.Message calldata _message, string memory _bridgeName)
        external
        override
        onlyReceiverAdapter
    {
        if (_message.dstChainId != block.chainid) {
            revert Error.INVALID_DST_CHAIN();
        }

        if (_message.target == address(0)) {
            revert Error.INVALID_TARGET();
        }

        if (_message.srcChainId != srcChainId) {
            revert Error.INVALID_SENDER_CHAIN_ID();
        }

        /// this msgId is totally different with each adapters' internal msgId(which is their internal nonce essentially)
        /// although each adapters' internal msgId is attached at the end of calldata, it's not useful to MultiMessageReceiver.
        bytes32 msgId = MessageLibrary.computeMsgId(_message);

        if (msgDeliveries[msgId][msg.sender]) {
            revert Error.DUPLICATE_MESSAGE_DELIVERY_BY_ADAPTER();
        }

        if (isExecuted[msgId]) {
            revert Error.MSG_ID_ALREADY_EXECUTED();
        }

        msgDeliveries[msgId][msg.sender] = true;

        /// increment quorum
        ++msgDeliveryCount[msgId];

        /// stores the execution data required
        ExecutionData memory prevStored = msgExecData[msgId];

        /// stores the message if the amb is the first one delivering the message
        if (prevStored.target == address(0)) {
            msgExecData[msgId] = ExecutionData(
                _message.target, _message.callData, _message.nativeValue, _message.nonce, _message.expiration
            );
        }

        emit SingleBridgeMsgReceived(msgId, _bridgeName, _message.nonce, msg.sender);
    }

    /// @notice Execute the message (invoke external call according to the message content) if the message
    /// @dev has reached the power threshold (the same message has been delivered by enough multiple bridges).
    /// Param values can be found in the MultiMessageSent event from the source chain MultiMessageSender contract.
    function executeMessage(bytes32 msgId) external {
        ExecutionData memory _execData = msgExecData[msgId];

        /// @dev validates if msg execution is not beyond expiration
        if (block.timestamp > _execData.expiration) {
            revert Error.MSG_EXECUTION_PASSED_DEADLINE();
        }

        /// @dev validates if msgId is already executed
        if (isExecuted[msgId]) {
            revert Error.MSG_ID_ALREADY_EXECUTED();
        }

        isExecuted[msgId] = true;

        /// @dev validates message quorum
        if (msgDeliveryCount[msgId] < quorum) {
            revert Error.QUORUM_NOT_ACHIEVED();
        }

        /// @dev queues the action on timelock for execution
        IGovernanceTimelock(governanceTimelock).scheduleTransaction(
            _execData.target, _execData.value, _execData.callData
        );

        emit MessageExecuted(msgId, _execData.target, _execData.value, _execData.nonce, _execData.callData);
    }

    /// @notice Update bridge receiver adapters.
    /// @dev called by admin to update receiver bridge adapters on all other chains
    function updateReceiverAdapters(address[] calldata _receiverAdapters, bool[] calldata _operations)
        external
        onlyGovernanceTimelock
    {
        _updateReceiverAdapters(_receiverAdapters, _operations);
    }

    /// @notice Update bridge receiver adapters after quorum update
    /// @dev called by admin to update receiver bridge adapters on all other chains
    function updateQuorumAndReceiverAdapter(
        uint64 _newQuorum,
        address[] calldata _receiverAdapters,
        bool[] calldata _operations
    ) external onlyGovernanceTimelock {
        /// @dev updates quorum here
        _updateQuorum(_newQuorum);

        /// @dev updates receiver adapter here
        _updateReceiverAdapters(_receiverAdapters, _operations);
    }

    /// @notice Update power quorum threshold of message execution.
    function updateQuorum(uint64 _quorum) external onlyGovernanceTimelock {
        _updateQuorum(_quorum);
    }

    /*/////////////////////////////////////////////////////////////////
                            VIEW/READ-ONLY FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /// @notice view message info, return (executed, msgPower, delivered adapters)
    function getMessageInfo(bytes32 msgId) public view returns (bool, uint256, string[] memory) {
        uint256 msgCurrentVotes = msgDeliveryCount[msgId];
        string[] memory successfulBridge = new string[](msgCurrentVotes);

        if (msgCurrentVotes != 0) {
            uint256 currIndex;
            address[] memory executors = getTrustedExecutors();
            for (uint256 i; i < executors.length;) {
                if (msgDeliveries[msgId][executors[i]]) {
                    successfulBridge[currIndex] = IMessageReceiverAdapter(executors[i]).name();
                    ++currIndex;
                }

                unchecked {
                    ++i;
                }
            }
        }

        return (isExecuted[msgId], msgCurrentVotes, successfulBridge);
    }

    /*/////////////////////////////////////////////////////////////////
                            PRIVATE/INTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _updateQuorum(uint64 _quorum) internal {
        if (_quorum > trustedExecutorsCount() || _quorum == 0) {
            revert Error.INVALID_QUORUM_THRESHOLD();
        }

        uint64 oldValue = quorum;

        quorum = _quorum;
        emit QuorumUpdated(oldValue, _quorum);
    }

    function _updateReceiverAdapters(address[] memory _receiverAdapters, bool[] memory _operations) internal {
        uint256 len = _receiverAdapters.length;

        if (len == 0) {
            revert Error.ZERO_RECEIVER_ADAPTER();
        }

        if (len != _operations.length) {
            revert Error.ARRAY_LENGTH_MISMATCHED();
        }

        for (uint256 i; i < len;) {
            if (_receiverAdapters[i] == address(0)) {
                revert Error.ZERO_ADDRESS_INPUT();
            }

            _updateReceiverAdapter(_receiverAdapters[i], _operations[i]);

            unchecked {
                ++i;
            }
        }
    }

    function _updateReceiverAdapter(address _receiverAdapter, bool _add) private {
        if (_add) {
            _addTrustedExecutor(_receiverAdapter);
        } else {
            _removeTrustedExecutor(_receiverAdapter);

            if (quorum > trustedExecutorsCount()) {
                revert Error.INVALID_QUORUM_THRESHOLD();
            }
        }
        emit ReceiverAdapterUpdated(_receiverAdapter, _add);
    }
}
