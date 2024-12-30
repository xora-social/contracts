# XoraSocial

**XoraSocial** is a simple **SocialFi** (Social Finance) contract. It lets users:

- **Buy allocations** (shares) of any address (“target”).
- **Sell allocations** and receive ETH back.
- **Earn referral fees** when referred users trade.

## Quick Overview

1. **Buy Allocations**

   - Send ETH to get shares in a target.

2. **Sell Allocations**

   - Sell your shares to receive ETH.

3. **Referral System**

   - Add a referrer.
   - The referrer earns a small fee on your trades.

4. **Fees**

   - **Protocol Fee:** Goes to the protocol.
   - **Host Fee:** Goes to the target address.
   - **Referral Fee:** Goes to the referrer.

5. **Pause/Unpause**
   - The owner can lock the contract so no trades can happen.

## How to Use

1. **Deploy** the contract and call `initialize()`.
2. **Set Fees** as needed (using owner-only functions).
3. **Buy** allocations with `acquireAllocations(target, quantity)`.
4. **Sell** allocations with `liquidateAllocations(target, quantity)`.
5. Optionally use `acquireAllocationsWithReferral()` or `liquidateAllocationsWithReferral()` to set a referrer.

Enjoy trading allocations with **XoraSocial**!
