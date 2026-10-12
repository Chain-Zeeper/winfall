#!/usr/bin/env bash
# Full deployment in one go:
#   1. creates a chainlink vrf subscription owned by the deployer
#   2. reads its real id from the broadcast transaction
#   3. deploys Pool (implementation), PancakeV3Swapper and PoolManager and hands the subscription to the manager
#
# usage:   script/deploy.sh [network] [account]
# example: script/deploy.sh bsc_testnet lottery
#
#   network  an rpc alias from foundry.toml (bsc_testnet, bsc) or an rpc url. default: bsc_testnet
#   account  a keystore name from `cast wallet import`. default: lottery
#
# optional env, same as script/Deploy.s.sol: ADMIN, FEE_TREASURY, VRF_FUND_LINK
# SIGNER_ARGS replaces "--account <account>", e.g. SIGNER_ARGS="--ledger" or, for a local fork only,
# SIGNER_ARGS="--private-key 0x..."
set -euo pipefail

NETWORK="${1:-bsc_testnet}"
ACCOUNT="${2:-lottery}"
SIGNER_ARGS="${SIGNER_ARGS:---account $ACCOUNT}"

cd "$(dirname "$0")/.."

echo "==> 1/2 creating the vrf subscription on $NETWORK"
# shellcheck disable=SC2086
forge script script/CreateVrfSubscription.s.sol --rpc-url "$NETWORK" --broadcast $SIGNER_ARGS

CHAIN_ID="$(cast chain-id --rpc-url "$NETWORK")"
RUN="broadcast/CreateVrfSubscription.s.sol/$CHAIN_ID/run-latest.json"
# the id is the first indexed field of the coordinator's SubscriptionCreated event. the one forge prints during
# the simulation is not the real one, it depends on the block the transaction lands in
SUB_ID="$(python3 -c "
import json, sys
run = json.load(open('$RUN'))
logs = run['receipts'][0]['logs']
if not logs:
    sys.exit('no SubscriptionCreated event in the receipt')
print(int(logs[0]['topics'][1], 16))
")"
echo "==> subscription id: $SUB_ID"

echo "==> 2/2 deploying and handing the subscription to the manager"
# shellcheck disable=SC2086
VRF_SUBSCRIPTION_ID="$SUB_ID" forge script script/Deploy.s.sol --rpc-url "$NETWORK" --broadcast $SIGNER_ARGS

echo
echo "done. vrf subscription id: $SUB_ID"
echo "it is owned by the PoolManager printed above and needs LINK before the first draw."
