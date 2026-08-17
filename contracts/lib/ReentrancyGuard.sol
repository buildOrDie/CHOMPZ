// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private status = NOT_ENTERED;

    error ReentrantCall();

    modifier nonReentrant() {
        if (status == ENTERED) revert ReentrantCall();
        status = ENTERED;
        _;
        status = NOT_ENTERED;
    }
}
