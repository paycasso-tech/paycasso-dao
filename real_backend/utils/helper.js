const { ethers } = require("ethers");

/**
 * Converts human-readable USDC (e.g. 10.5) to blockchain format (integer with 6 decimals)
 */
const toUSDC = (amount) => ethers.parseUnits(amount.toString(), 6);

/**
 * Converts blockchain USDC (BigInt) to human-readable string (e.g. "10.5")
 */
const fromUSDC = (amount) => ethers.formatUnits(amount, 6);

/**
 * Standardizes the 0-100 percentage splits used in your contracts
 */
const formatPercent = (percent) =>
  Math.min(Math.max(parseInt(percent), 0), 100);

module.exports = { toUSDC, fromUSDC, formatPercent };
