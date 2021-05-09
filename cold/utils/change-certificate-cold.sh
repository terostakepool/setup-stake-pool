#!/bin/bash
set -e

echo "IN DEVELOPMENT"
exit 0


# Change pool operation certificate (pledge, fee, margin)
source ./../config.sh

fnUpdateCert() {
    ID_CERT=$(date +%s)
    
    export METADATA_URI="https://www.example.com/metadata.json"
    export MARGIN=0.020
    export MIN_POOL_COST=340000000
    export PLEDGE=1000000000
    export RELAY_HOST=relaynode1.example.com
    export RELAY_PORT=6000
    
    rm ${HOME}/poolMetaData.json || true
    cp ./../metadata.json ${HOME}/poolMetaData.json
    
    cardano-cli stake-pool metadata-hash \
    --pool-metadata-file ${HOME}/poolMetaData.json > ${HOME}/poolMetaDataHash.txt
    
    cardano-cli stake-pool registration-certificate \
    --cold-verification-key-file ${COLDKEY_PATH}/cold.vkey \
    --vrf-verification-key-file ${HOTKEY_PATH}/vrf.vkey \
    --pool-pledge ${PLEDGE} \
    --pool-cost ${MIN_POOL_COST} \
    --pool-margin ${MARGIN} \
    --pool-reward-account-verification-key-file ${COLDKEY_PATH}/stake.vkey \
    --pool-owner-stake-verification-key-file ${COLDKEY_PATH}/stake.vkey \
    ${MAGIC} \
    --single-host-pool-relay ${RELAY_HOST} \
    --pool-relay-port ${RELAY_PORT} \
    --metadata-url ${METADATA_URI} \
    --metadata-hash $(cat ${HOME}/poolMetaDataHash.txt) \
    --out-file ${HOTKEY_PATH}/pool-${ID_CERT}.cert
    
    cardano-cli stake-address delegation-certificate \
    --stake-verification-key-file ${COLDKEY_PATH}/stake.vkey \
    --cold-verification-key-file ${COLDKEY_PATH}/cold.vkey \
    --out-file ${HOTKEY_PATH}/deleg-${ID_CERT}.cert
    
    fnColdHotTransfer change-certificate
}

fnUpdateCertSign() {

    read -p "Enter New ID CERT: " ID_CERT
    echo ${ID_CERT}
    
    while true ; do
        read -rsp "Load file \"${TX_RAW_PATH}/tx-update-certificate-${ID_CERT}.raw\" and press enter to continue..."$'\n'
        test -f "${TX_RAW_PATH}/tx-update-certificate-${ID_CERT}.raw" && break
    done
    
    rm ${TX_RAW_PATH}/tx-update-certificate-${ID_CERT}.signed || true

    cardano-cli transaction sign \
    --tx-body-file ${TX_RAW_PATH}/tx-update-certificate-${ID_CERT}.raw \
    --signing-key-file ${COLDKEY_PATH}/payment.skey \
    --signing-key-file ${COLDKEY_PATH}/cold.skey \
    --signing-key-file ${COLDKEY_PATH}/stake.skey \
    ${MAGIC} \
    --out-file ${TX_RAW_PATH}/tx-update-certificate-${ID_CERT}.signed
    
    fnColdHotTransfer tx-update-certificate-${ID_CERT}-signed
}

# TODO: add menu