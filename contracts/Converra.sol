// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Converra is ReentrancyGuard {
    address public constant FEE_RECIPIENT = 0x5Bce25397eEfbc76f6479e6838c00a5115dbEA4c;
    address public constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 public constant FEE_BASIS_POINTS = 100; // 1% = 1/100

    enum PoolStatus {
        Active,
        Successful,
        Failed,
        Cancelled
    }

    struct Pool {
        uint256 id;
        address creator;
        address recipient;
        string title;
        string category;
        string metadataUri;
        uint256 fundingTarget;
        uint256 deadline;
        uint256 minContribution;
        uint256 maxContribution;
        uint256 totalRaised;
        PoolStatus status;
    }

    error InvalidRecipient();
    error InvalidFundingTarget();
    error InvalidDeadline();
    error InvalidContributionLimits();
    error PoolNotActive();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error TargetNotReached();
    error TargetAlreadyReached();
    error AmountTooSmall();
    error AmountTooLarge();
    error NothingToRefund();
    error AlreadyClaimed();
    error NotRecipient();
    error TransferFailed();
    error ZeroAmount();
    error InvalidPoolId();

    event PoolCreated(
        uint256 indexed poolId,
        address indexed creator,
        address indexed recipient,
        uint256 fundingTarget,
        uint256 deadline,
        uint256 fee
    );
    event Contributed(uint256 indexed poolId, address indexed contributor, uint256 amount, uint256 totalRaised);
    event TargetReached(uint256 indexed poolId);
    event FundsClaimed(uint256 indexed poolId, address indexed recipient, uint256 amount);
    event RefundClaimed(uint256 indexed poolId, address indexed contributor, uint256 amount);
    event PoolStatusChanged(uint256 indexed poolId, PoolStatus status);

    uint256 private _nextPoolId = 1;
    mapping(uint256 => Pool) private _pools;
    mapping(uint256 => mapping(address => uint256)) private _contributions;
    mapping(uint256 => bool) public poolClaimed;

    constructor() {}

    function createPool(
        address recipient,
        string calldata title,
        string calldata category,
        string calldata metadataUri,
        uint256 fundingTarget,
        uint256 deadline,
        uint256 minContribution,
        uint256 maxContribution
    ) external {
        if (recipient == address(0)) revert InvalidRecipient();
        if (fundingTarget == 0) revert InvalidFundingTarget();
        if (deadline <= block.timestamp) revert InvalidDeadline();
        if (maxContribution != 0 && maxContribution < minContribution) revert InvalidContributionLimits();

        uint256 fee = _calculateFee(fundingTarget);
        _safeTransferFrom(msg.sender, FEE_RECIPIENT, fee);

        uint256 poolId = _nextPoolId++;

        _pools[poolId] = Pool({
            id: poolId,
            creator: msg.sender,
            recipient: recipient,
            title: title,
            category: category,
            metadataUri: metadataUri,
            fundingTarget: fundingTarget,
            deadline: deadline,
            minContribution: minContribution,
            maxContribution: maxContribution,
            totalRaised: 0,
            status: PoolStatus.Active
        });

        emit PoolCreated(poolId, msg.sender, recipient, fundingTarget, deadline, fee);
    }

    function contribute(uint256 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = _getPool(poolId);

        if (pool.status != PoolStatus.Active) revert PoolNotActive();
        if (block.timestamp > pool.deadline) revert DeadlinePassed();
        if (pool.totalRaised >= pool.fundingTarget) revert TargetAlreadyReached();
        if (amount == 0) revert ZeroAmount();
        if (pool.minContribution > 0 && amount < pool.minContribution) revert AmountTooSmall();

        uint256 newContributorTotal = _contributions[poolId][msg.sender] + amount;
        if (pool.maxContribution > 0 && newContributorTotal > pool.maxContribution) revert AmountTooLarge();

        uint256 newTotalRaised = pool.totalRaised + amount;
        if (newTotalRaised > pool.fundingTarget) revert TargetAlreadyReached();

        _safeTransferFrom(msg.sender, address(this), amount);

        _contributions[poolId][msg.sender] = newContributorTotal;
        pool.totalRaised = newTotalRaised;

        if (newTotalRaised == pool.fundingTarget) {
            pool.status = PoolStatus.Successful;
            emit TargetReached(poolId);
            emit PoolStatusChanged(poolId, PoolStatus.Successful);
        }

        emit Contributed(poolId, msg.sender, amount, newTotalRaised);
    }

    function claimFunds(uint256 poolId) external nonReentrant {
        Pool storage pool = _getPool(poolId);

        if (msg.sender != pool.recipient) revert NotRecipient();
        if (poolClaimed[poolId]) revert AlreadyClaimed();
        if (pool.totalRaised < pool.fundingTarget) revert TargetNotReached();

        if (pool.status != PoolStatus.Successful) {
            pool.status = PoolStatus.Successful;
            emit PoolStatusChanged(poolId, PoolStatus.Successful);
        }

        uint256 amount = pool.totalRaised;
        poolClaimed[poolId] = true;

        _safeTransfer(pool.recipient, amount);

        emit FundsClaimed(poolId, pool.recipient, amount);
    }

    function claimRefund(uint256 poolId) external nonReentrant {
        Pool storage pool = _getPool(poolId);

        if (block.timestamp <= pool.deadline) revert DeadlineNotPassed();
        if (pool.totalRaised >= pool.fundingTarget) revert TargetAlreadyReached();

        if (pool.status != PoolStatus.Failed) {
            pool.status = PoolStatus.Failed;
            emit PoolStatusChanged(poolId, PoolStatus.Failed);
        }

        uint256 refundAmount = _contributions[poolId][msg.sender];
        if (refundAmount == 0) revert NothingToRefund();

        _contributions[poolId][msg.sender] = 0;

        _safeTransfer(msg.sender, refundAmount);

        emit RefundClaimed(poolId, msg.sender, refundAmount);
    }

    function getPool(uint256 poolId) external view returns (Pool memory) {
        return _getPoolView(poolId);
    }

    function getContribution(uint256 poolId, address contributor) external view returns (uint256) {
        _getPoolView(poolId);
        return _contributions[poolId][contributor];
    }

    function getPoolStatus(uint256 poolId) external view returns (PoolStatus) {
        Pool memory pool = _getPoolView(poolId);

        if (
            pool.status == PoolStatus.Active
                && block.timestamp > pool.deadline
                && pool.totalRaised < pool.fundingTarget
        ) {
            return PoolStatus.Failed;
        }

        return pool.status;
    }

    function _calculateFee(uint256 fundingTarget) private pure returns (uint256) {
        uint256 fee = fundingTarget / FEE_BASIS_POINTS;
        if (fee == 0 && fundingTarget > 0) {
            return 1;
        }
        return fee;
    }

    function _safeTransferFrom(address from, address to, uint256 amount) private {
        (bool success, bytes memory data) = USDC.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    function _safeTransfer(address to, uint256 amount) private {
        (bool success, bytes memory data) = USDC.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    function _getPool(uint256 poolId) private view returns (Pool storage) {
        Pool storage pool = _pools[poolId];
        if (pool.creator == address(0)) revert InvalidPoolId();
        return pool;
    }

    function _getPoolView(uint256 poolId) private view returns (Pool memory) {
        Pool memory pool = _pools[poolId];
        if (pool.creator == address(0)) revert InvalidPoolId();
        return pool;
    }
}
