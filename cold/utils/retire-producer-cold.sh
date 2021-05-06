#!/bin/bash
set -e

echo "IN DEVELOPMENT PHASE"
exit 0


source ./../config.sh

read -p "Enter retirementEpoch: " retirementEpoch

cardano-cli stake-pool deregistration-certificate \
--cold-verification-key-file ${COLDKEY_PATH}/node.vkey \
--epoch ${retirementEpoch} \
--out-file ${HOTKEY_PATH}/pool.dereg

while true ; do
   read -rsp "Load file \"${TX_RAW_PATH}/tx-retire-stake-pool.raw\" and press enter to continue..."$'\n'
   test -f "${TX_RAW_PATH}/tx-retire-stake-pool.raw" && break
done

cardano-cli transaction sign \
    --tx-body-file ${TX_RAW_PATH}/tx-retire-stake-pool.raw \
    --signing-key-file ${COLDKEY_PATH}/payment.skey \
    --signing-key-file ${COLDKEY_PATH}/node.skey \
    ${MAGIC} \
    --out-file ${TX_RAW_PATH}/tx-retire-stake-pool.signed