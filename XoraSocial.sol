// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract XoraSocial is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    function initialize() public initializer {
        aggregatorRecipient = owner();
        hostTariff = 7 ether / 100;
        aggregatorTariff = 2 ether / 100;
        referralTariff = 1 ether / 100;
        baseQuote = 1 ether / 250;
        locked = 1;

        __Ownable_init();
        __ReentrancyGuard_init();
    }

    // New constants
    uint256 constant RATE_A = 80 ether / 100;
    uint256 constant RATE_B = 50 ether / 100;
    uint256 constant RATE_C = 2;

    // State variables
    address public aggregatorRecipient;     // was protocolFeeDestination
    uint256 public aggregatorTariff;       // was protocolFeePercent
    uint256 public hostTariff;             // was subjectFeePercent
    uint256 public referralTariff;         // was referralFeePercent
    uint256 public baseQuote;              // was initialPrice

    // Pausing mechanism
    uint256 public locked;                 // was paused

    mapping(address => mapping(address => uint256)) public userAllocations;       // was sharesBalance
    mapping(address => uint256) public allocationsInCirculation;                  // was sharesSupply
    mapping(address => address) public referralAssignments;                       // was userToReferrer
    mapping(address => uint256) private lockedFunds;                              // was tvl

    event TransactionRecord(
        address indexed sender,
        address indexed target,
        bool isAcquisition,
        uint256 quantity,
        uint256 rawValue,
        uint256 aggregatorPortion,
        uint256 hostPortion,
        uint256 referralPortion,
        uint256 totalCirculation,
        uint256 postQuote,
        uint256 senderBalance
    );
    event ReferralAssignment(address indexed account, address indexed assignedReferrer);

    receive() external payable {}

    function toggleLock(bool halt) external onlyOwner {
        if (halt) {
            locked = 1;
        } else {
            locked = 0;
        }
    }

    function defineProtocolDestination(address newDestination) external {
        require(msg.sender == aggregatorRecipient, "Unauthorized");
        aggregatorRecipient = newDestination;
    }

    function assignReferralTariff(uint256 newTariff) public onlyOwner {
        uint256 maximum = 2 ether / 100;
        require(newTariff < maximum, "Invalid fee setting");
        referralTariff = newTariff;
    }

    function assignProtocolTariff(uint256 newTariff) public onlyOwner {
        uint256 maximum = 4 ether / 100;
        require(newTariff < maximum, "Invalid fee setting");
        aggregatorTariff = newTariff;
    }

    function assignHostTariff(uint256 newTariff) public onlyOwner {
        uint256 maximum = 8 ether / 100;
        require(newTariff < maximum, "Invalid fee setting");
        hostTariff = newTariff;
    }

    function refreshReferral(address user, address referrer) external onlyOwner {
        referralAssignments[user] = referrer;
        emit ReferralAssignment(user, referrer);
    }

    function refreshReferrals(address[] calldata users, address[] calldata referrers) external onlyOwner {
        require(users.length == referrers.length, "Invalid input");
        for (uint256 i = 0; i < users.length; i++) {
            referralAssignments[users[i]] = referrers[i];
            emit ReferralAssignment(users[i], referrers[i]);
        }
    }

    function assignLocalReferrer(address user, address referrer) internal {
        if (referralAssignments[user] == address(0) && user != referrer) {
            referralAssignments[user] = referrer;
            emit ReferralAssignment(user, referrer);
        }
    }

    function evaluatePrice(address target, uint256 supply, uint256 quantity) public view returns (uint256) {
        uint256 adjustedSupply = supply + RATE_C;
        if (adjustedSupply == 0) {
            return baseQuote;
        }
        uint256 sum1 = (adjustedSupply - 1) * (adjustedSupply) * (2 * (adjustedSupply - 1) + 1) / 6;
        uint256 sum2 = (adjustedSupply - 1 + quantity) * (adjustedSupply + quantity) * (2 * (adjustedSupply - 1 + quantity) + 1) / 6;
        uint256 resultSum = RATE_A * (sum2 - sum1);
        uint256 quote = RATE_B * resultSum * baseQuote / 1 ether / 1 ether;
        if (quote < baseQuote) {
            return baseQuote;
        }
        return quote;
    }

    function myAllocations(address target) public view returns (uint256) {
        return userAllocations[target][msg.sender];
    }

    function totalAllocations(address target) public view returns (uint256) {
        return allocationsInCirculation[target];
    }

    function evaluateAcquisitionPrice(address target, uint256 quantity) public view returns (uint256) {
        return evaluatePrice(target, allocationsInCirculation[target], quantity);
    }

    function evaluateLiquidationPrice(address target, uint256 quantity) public view returns (uint256) {
        if (allocationsInCirculation[target] == 0 || quantity == 0 || allocationsInCirculation[target] < quantity) {
            return 0;
        }
        return evaluatePrice(target, allocationsInCirculation[target] - quantity, quantity);
    }

    function evaluateAcquisitionPriceWithCharge(address target, uint256 quantity) public view returns (uint256) {
        uint256 base = evaluateAcquisitionPrice(target, quantity);
        uint256 aggregatorCut = base * aggregatorTariff / 1 ether;
        uint256 hostCut = base * hostTariff / 1 ether;
        uint256 referCut = base * referralTariff / 1 ether;
        return base + aggregatorCut + hostCut + referCut;
    }

    function evaluateLiquidationPriceWithCharge(address target, uint256 quantity) public view returns (uint256) {
        uint256 base = evaluateLiquidationPrice(target, quantity);
        uint256 aggregatorCut = base * aggregatorTariff / 1 ether;
        uint256 hostCut = base * hostTariff / 1 ether;
        uint256 referCut = base * referralTariff / 1 ether;
        return base - aggregatorCut - hostCut - referCut;
    }

    // --- Acquisitions & Liquidations (with optional referrer) ---

    function acquireAllocationsWithReferral(address target, uint256 quantity, address referrer) public payable {
        if (referrer != address(0)) {
            assignLocalReferrer(msg.sender, referrer);
        }
        acquireAllocations(target, quantity);
    }

    function liquidateAllocationsWithReferral(address target, uint256 quantity, address referrer) public payable {
        if (referrer != address(0)) {
            assignLocalReferrer(msg.sender, referrer);
        }
        liquidateAllocations(target, quantity);
    }

    function acquireAllocations(address target, uint256 quantity) public payable nonReentrant {
        require(locked == 0, "Contract is locked");
        require(quantity > 0, "Quantity must be > 0");

        uint256 supply = allocationsInCirculation[target];
        uint256 cost = evaluatePrice(target, supply, quantity);

        lockedFunds[target] += cost;

        uint256 aggregatorCut = cost * aggregatorTariff / 1 ether;
        uint256 hostCut = cost * hostTariff / 1 ether;
        uint256 referCut = cost * referralTariff / 1 ether;

        require(msg.value >= cost + aggregatorCut + hostCut + referCut, "Insufficient funds");

        userAllocations[target][msg.sender] += quantity;
        allocationsInCirculation[target] = supply + quantity;

        uint256 nextQuote = evaluateAcquisitionPrice(target, 1);
        uint256 myBalance = userAllocations[target][msg.sender];
        uint256 newSupply = supply + quantity;

        dispatchProtocolFunds(aggregatorCut);
        dispatchHostFunds(target, hostCut);

        uint256 refund = msg.value - (cost + aggregatorCut + hostCut + referCut);
        if (refund > 0) {
            dispatchHostFunds(msg.sender, refund);
        }
        if (referCut > 0) {
            dispatchReferralFunds(msg.sender, referCut);
        }

        emit TransactionRecord(
            msg.sender,
            target,
            true,
            quantity,
            cost,
            aggregatorCut,
            hostCut,
            referCut,
            newSupply,
            nextQuote,
            myBalance
        );
    }

    function liquidateAllocations(address target, uint256 quantity) public payable nonReentrant {
        require(locked == 0, "Contract is locked");
        require(quantity > 0, "Quantity must be > 0");

        uint256 supply = allocationsInCirculation[target];
        require(userAllocations[target][msg.sender] >= quantity, "Insufficient holdings");

        uint256 proceeds = evaluatePrice(target, supply - quantity, quantity);
        lockedFunds[target] -= proceeds;

        uint256 aggregatorCut = proceeds * aggregatorTariff / 1 ether;
        uint256 hostCut = proceeds * hostTariff / 1 ether;
        uint256 referCut = proceeds * referralTariff / 1 ether;

        userAllocations[target][msg.sender] -= quantity;
        allocationsInCirculation[target] = supply - quantity;

        uint256 nextQuote = evaluateAcquisitionPrice(target, 1);
        uint256 myBalance = userAllocations[target][msg.sender];
        uint256 newSupply = supply - quantity;

        dispatchHostFunds(msg.sender, proceeds - aggregatorCut - hostCut - referCut);
        dispatchProtocolFunds(aggregatorCut);
        dispatchHostFunds(target, hostCut);

        if (referCut > 0) {
            dispatchReferralFunds(msg.sender, referCut);
        }

        emit TransactionRecord(
            msg.sender,
            target,
            false,
            quantity,
            proceeds,
            aggregatorCut,
            hostCut,
            referCut,
            newSupply,
            nextQuote,
            myBalance
        );
    }

    function dispatchHostFunds(address target, uint256 amount) internal {
        (bool success, ) = target.call{value: amount}("");
        require(success, "Fund dispatch failed");
    }

    function dispatchProtocolFunds(uint256 amount) internal {
        (bool success, ) = aggregatorRecipient.call{value: amount}("");
        require(success, "Fund dispatch failed");
    }

    function dispatchReferralFunds(address sender, uint256 amount) internal {
        address ref = referralAssignments[sender];
        if (ref != address(0) && ref != sender) {
            (bool success, ) = ref.call{value: amount, gas: 30_000}("");
            if (!success) {
                dispatchProtocolFunds(amount);
            }
        } else {
            dispatchProtocolFunds(amount);
        }
    }

    function reclaimFunds() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "No balance to withdraw");
        (bool success, ) = owner().call{value: bal}("");
        require(success, "Withdraw failed");
    }
}