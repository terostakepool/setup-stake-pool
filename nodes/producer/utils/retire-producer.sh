#!/bin/bash
set -e

echo "IN DEVELOPMENT PHASE"
exit 0


if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Refresh
source ${HOME}/.bashrc

cd ${CNODE_HOME}

cardano-cli query protocol-parameters \
    ${MAGIC} \
    --out-file ${CNODE_HOME}/params.json

# Calculate the current epoch.
startTimeGenesis=$(cat ${CNODE_HOME}/${NETWORK}-shelley-genesis.json | jq -r .systemStart)
startTimeSec=$(date --date=${startTimeGenesis} +%s)
currentTimeSec=$(date -u +%s)
epochLength=$(cat ${CNODE_HOME}/${NETWORK}-shelley-genesis.json | jq -r .epochLength)
epoch=$(( (${currentTimeSec}-${startTimeSec}) / ${epochLength} ))
echo current epoch: ${epoch}

# Find the earliest and latest retirement epoch that your pool can retire.
poolRetireMaxEpoch=$(cat ${CNODE_HOME}/params.json | jq -r '.poolRetireMaxEpoch')
echo poolRetireMaxEpoch: ${poolRetireMaxEpoch}

minRetirementEpoch=$(( ${epoch} + 1 ))
maxRetirementEpoch=$(( ${epoch} + ${poolRetireMaxEpoch} ))

echo "Take notes:"
echo earliest epoch for retirement is: ${minRetirementEpoch}
echo latest epoch for retirement is: ${maxRetirementEpoch}

read -rsp $'Press enter to continue...\n'

while true ; do
   read -rsp "Load file \"${HOTKEY_PATH}/pool.dereg\" and press enter to continue..."$'\n'
   test -f "${HOTKEY_PATH}/pool.dereg" && break
done

cardano-cli query utxo \
    --address $(cat ${HOTKEY_PATH}/payment.addr) \
    ${MAGIC} > fullUtxo.out

tail -n +3 fullUtxo.out | sort -k3 -nr > balance-retire-producer.out

cat balance-retire-producer.out

tx_in=""
total_balance=0
while read -r utxo; do
    in_addr=$(awk '{ print $1 }' <<< "${utxo}")
    idx=$(awk '{ print $2 }' <<< "${utxo}")
    utxo_balance=$(awk '{ print $3 }' <<< "${utxo}")
    total_balance=$((${total_balance}+${utxo_balance}))
    echo TxHash: "${in_addr}#${idx}"
    echo ADA: ${utxo_balance}
    tx_in="${tx_in} --tx-in ${in_addr}#${idx}"
done < balance-retire-producer.out
txcnt=$(cat balance-retire-producer.out | wc -l)
echo Total ADA balance: ${total_balance}
echo Number of UTXOs: ${txcnt}

currentSlot=$(cardano-cli query tip ${MAGIC} | jq -r '.slot')
echo Current Slot: $currentSlot

cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${HOTKEY_PATH}/payment.addr)+${total_balance} \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee 0 \
    --certificate-file ${HOTKEY_PATH}/pool.dereg \
    --out-file ${TX_RAW_PATH}/tx-retire-stake-pool.tmp

fee=$(cardano-cli transaction calculate-min-fee \
    --tx-body-file ${TX_RAW_PATH}/tx-retire-stake-pool.tmp \
    --tx-in-count ${txcnt} \
    --tx-out-count 1 \
    ${MAGIC} \
    --witness-count 2 \
    --byron-witness-count 0 \
    --protocol-params-file ${CNODE_HOME}/params.json | awk '{ print $1 }')
echo fee: $fee

txOut=$((${total_balance}-${fee}))
echo txOut: ${txOut}

cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${HOTKEY_PATH}/payment.addr)+${txOut} \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee ${fee} \
    --certificate-file ${HOTKEY_PATH}/pool.dereg \
    --out-file ${TX_RAW_PATH}/tx-retire-stake-pool.raw

while true ; do
   read -rsp "Load file \"${TX_RAW_PATH}/tx-retire-stake-pool.signed\" and press enter to continue..."$'\n'
   test -f "${TX_RAW_PATH}/tx-retire-stake-pool.signed" && break
done

cardano-cli transaction submit \
    --tx-file ${TX_RAW_PATH}/tx-retire-stake-pool.signed \
    ${MAGIC}

#cardano-cli query ledger-state ${MAGIC} > ledger-state.json
#jq -r '.esLState._delegationState._pstate._pParams."'"$(cat stakepoolid.txt)"'"  // empty' ledger-state.json