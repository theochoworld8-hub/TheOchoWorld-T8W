/**
 *Submitted for verification at BscScan.com on 2025-11-15
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 *  TheOchoWorld (T8W)
 *  - ERC-20 minimal implementation with:
 *    - decimals = 12
 *    - totalSupply = 8,880,000,000 * 10^12 (fixed at constructor)
 *    - transfer / transferFrom with fee distribution
 *    - transferWithDonate: optional extra donation by sender
 *    - adjustable fee BPS by treasury multisig (onlyTreasury), capped total <= 80 BPS (0.8%)
 *    - fee parts: burn, donation, reinvest (treasury), liquidity, buyback
 *
 *  IMPORTANT:
 *  - Set treasuryWallet to a multisig (Gnosis Safe) before making governance changes.
 *  - Test and audit before mainnet deployment.
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract T8W is IERC20 {
    string public constant name = "TheOchoWorld";
    string public constant symbol = "T8W";
    uint8 public constant decimals = 12;

    // Total supply: 8,880,000,000 * 10^12
    uint256 private _totalSupply = 8_880_000_000 * 10**uint256(decimals);

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // Wallets (should be multisig where appropriate)
    address public treasuryWallet;    // reinvest / treasury
    address public donationWallet;    // donations
    address public liquidityWallet;   // liquidity portion (can be used by an automated router/contract)
    address public buybackWallet;     // buyback execution wallet

    // Fee configuration in Basis Points (BPS)
    // Example initial distribution (suma = 8 BPS => 0.08%):
    // burnBPS = 3 (0.03%), donateBPS = 2 (0.02%), reinvestBPS = 1 (0.01%), liquidityBPS = 1 (0.01%), buybackBPS = 1 (0.01%)
    uint256 public feeBasisPoints = 8; // total current fee BPS (sum of the below)
    uint256 public burnBPS = 3;
    uint256 public donateBPS = 2;
    uint256 public reinvestBPS = 1;
    uint256 public liquidityBPS = 1;
    uint256 public buybackBPS = 1;

    // Maximum allowed total fee = 80 BPS (0.8%)
    uint256 public constant MAX_TOTAL_BPS = 80;

    // Events
    event DonationSent(address indexed from, address indexed to, uint256 amount);
    event FeesUpdated(uint256 totalBps, uint256 burnBps, uint256 donateBps, uint256 reinvestBps, uint256 liquidityBps, uint256 buybackBps);
    event WalletsUpdated(address treasury, address donation, address liquidity, address buyback);

    // Modifier: only treasury multisig can change fees or wallets
    modifier onlyTreasury() {
        require(msg.sender == treasuryWallet, "T8W: caller is not treasury");
        _;
    }

    constructor(address _treasuryWallet, address _donationWallet, address _liquidityWallet, address _buybackWallet) {
        require(_treasuryWallet != address(0), "treasury 0x0");
        require(_donationWallet != address(0), "donation 0x0");
        require(_liquidityWallet != address(0), "liquidity 0x0");
        require(_buybackWallet != address(0), "buyback 0x0");

        treasuryWallet = _treasuryWallet;
        donationWallet = _donationWallet;
        liquidityWallet = _liquidityWallet;
        buybackWallet = _buybackWallet;

        // initial supply to deployer
        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    // ---------------- ERC20 Basic ----------------
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferWithFee(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "T8W: allowance too low");
        _allowances[from][msg.sender] = currentAllowance - amount;
        _transferWithFee(from, to, amount);
        return true;
    }

    // ---------------- Fee logic ----------------
    // Internal transfer that applies fee distribution
    function _transferWithFee(address from, address to, uint256 amount) internal {
        require(to != address(0), "T8W: transfer to 0x0");
        require(_balances[from] >= amount, "T8W: insufficient balance");

        // compute fee amounts based on current BPS
        uint256 totalFee = (amount * feeBasisPoints) / 10000; // total fee amount
        uint256 burnAmount = (amount * burnBPS) / 10000;
        uint256 donateAmount = (amount * donateBPS) / 10000;
        uint256 reinvestAmount = (amount * reinvestBPS) / 10000;
        uint256 liquidityAmount = (amount * liquidityBPS) / 10000;
        uint256 buybackAmount = (amount * buybackBPS) / 10000;

        // safety: computed parts should not exceed totalFee (minor rounding may occur)
        // We'll prioritize distributing computed parts; any tiny remainder remains with recipient (sendAmount computed accordingly).
        uint256 partsSum = burnAmount + donateAmount + reinvestAmount + liquidityAmount + buybackAmount;

        // prepare final send amount
        uint256 sendAmount;
        if (partsSum > totalFee) {
            // rounding corner-case: reduce send by totalFee
            sendAmount = amount - totalFee;
        } else {
            sendAmount = amount - partsSum;
        }

        // debit from sender
        _balances[from] -= amount;

        // credit recipient
        _balances[to] += sendAmount;
        emit Transfer(from, to, sendAmount);

        // distribute parts
        if (burnAmount > 0) {
            _totalSupply -= burnAmount;
            emit Transfer(from, address(0), burnAmount);
        }
        if (reinvestAmount > 0) {
            _balances[treasuryWallet] += reinvestAmount;
            emit Transfer(from, treasuryWallet, reinvestAmount);
        }
        if (donateAmount > 0) {
            _balances[donationWallet] += donateAmount;
            emit Transfer(from, donationWallet, donateAmount);
            emit DonationSent(from, donationWallet, donateAmount);
        }
        if (liquidityAmount > 0) {
            _balances[liquidityWallet] += liquidityAmount;
            emit Transfer(from, liquidityWallet, liquidityAmount);
        }
        if (buybackAmount > 0) {
            _balances[buybackWallet] += buybackAmount;
            emit Transfer(from, buybackWallet, buybackAmount);
        }

        // Note: any tiny rounding residue (due to integer division) remains effectively in sendAmount.
    }

    // ---------------- Optional transfer with donation ----------------
    // The sender can optionally donate an extra amount (in T8W) with the transfer.
    // donateExtra is an absolute token amount (not BPS). It must be <= sender balance - amount.
    function transferWithDonate(address to, uint256 amount, uint256 donateExtra) external returns (bool) {
        uint256 totalRequired = amount + donateExtra;
        require(_balances[msg.sender] >= totalRequired, "T8W: insufficient balance for amount + donate");

        // First perform the normal transfer (this consumes the fees as usual)
        _transferWithFee(msg.sender, to, amount);

        // Then process the voluntary donationExtra (sent directly to donationWallet)
        if (donateExtra > 0) {
            _balances[msg.sender] -= donateExtra;
            _balances[donationWallet] += donateExtra;
            emit Transfer(msg.sender, donationWallet, donateExtra);
            emit DonationSent(msg.sender, donationWallet, donateExtra);
        }

        return true;
    }

    // ---------------- Treasury-only functions ----------------
    // Update fee BPS parts. Only treasury multisig can call.
    function setFeeBPS(
        uint256 _burnBps,
        uint256 _donateBps,
        uint256 _reinvestBps,
        uint256 _liquidityBps,
        uint256 _buybackBps
    ) external onlyTreasury {
        uint256 total = _burnBps + _donateBps + _reinvestBps + _liquidityBps + _buybackBps;
        require(total <= MAX_TOTAL_BPS, "T8W: total fee exceeds max allowed (80 BPS)");

        burnBPS = _burnBps;
        donateBPS = _donateBps;
        reinvestBPS = _reinvestBps;
        liquidityBPS = _liquidityBps;
        buybackBPS = _buybackBps;
        feeBasisPoints = total;

        emit FeesUpdated(total, _burnBps, _donateBps, _reinvestBps, _liquidityBps, _buybackBps);
    }

    // Update wallet addresses (only treasury multisig)
    function updateWallets(address _treasury, address _donation, address _liquidity, address _buyback) external onlyTreasury {
        require(_treasury != address(0) && _donation != address(0) && _liquidity != address(0) && _buyback != address(0), "T8W: zero address not allowed");
        treasuryWallet = _treasury;
        donationWallet = _donation;
        liquidityWallet = _liquidity;
        buybackWallet = _buyback;
        emit WalletsUpdated(_treasury, _donation, _liquidity, _buyback);
    }

    // Emergency function: allow treasury to withdraw tokens accidentally sent to contract (optional)
    // Note: this function can be removed if you prefer stricter immutability.
    function rescueERC20(address token, address to, uint256 amount) external onlyTreasury {
        require(token != address(this), "T8W: cannot rescue T8W");
        (bool success, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(success, "T8W: rescue failed");
    }
}
