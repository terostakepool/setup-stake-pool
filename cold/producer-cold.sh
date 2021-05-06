#!/bin/bash
set -e

source ./config.sh

fnInternalCreateRenewCertificate() {
    cardano-cli node issue-op-cert \
    --kes-verification-key-file $2 \
    --cold-signing-key-file ${COLDKEY_PATH}/node.skey \
    --operational-certificate-issue-counter ${COLDKEY_PATH}/node.counter \
    --kes-period $1 \
    --out-file ${HOTKEY_PATH}/node.cert
}

fnRenewCertificate() {
    #Input: startKesPeriod.out | kes.vkey
    echo "START: renew-certificate"

    while true ; do
        read -rsp "Load file \"${HOTKEY_PATH}/startKesPeriod.out\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/startKesPeriod.out" && break
    done
    
    while true ; do
        read -rsp "Load file \"${HOTKEY_PATH}/kes.vkey\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/kes.vkey" && break
    done
    
    export START_KES_PERIOD="$(cat ${HOTKEY_PATH}/startKesPeriod.out)"

    echo "Renew Certificate with START_KES_PERIOD: ${START_KES_PERIOD}"
    confirm

    fnDRP

    fnInternalCreateRenewCertificate ${START_KES_PERIOD} ${HOTKEY_PATH}/kes.vkey

    fnColdHotTransfer renew-certificate
    
    echo "END: renew-certificate"
    #Output: node.cert
}

fnGenerateColdKey () { 
    #Input: startKesPeriod.out | kes.vkey
    echo "START: generate-cold-key"
    
    while true ; do
        read -rsp "Load file \"${HOTKEY_PATH}/startKesPeriod.out\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/startKesPeriod.out" && break
    done
    
    while true ; do
        read -rsp "Load file \"${HOTKEY_PATH}/kes.vkey\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/kes.vkey" && break
    done
    
    export START_KES_PERIOD="$(cat ${HOTKEY_PATH}/startKesPeriod.out)"
    
    echo "START_KES_PERIOD: ${START_KES_PERIOD}"

    fnDRP

    # Temporal Wallet: shelley-2020.7.28
    # TODO: update script extractPoolStakingKeys.sh to support newer version of wallet
    echo "f75e5b2b4cc5f373d6b1c1235818bcab696d86232cb2c5905b2d91b4805bae84 *packages/cardano-wallet-shelley-2020.7.28-linux64.tar.gz" | shasum -a 256 --check
    rm -rf $(pwd)/cardano-wallet-shelley-2020.7.28/ || true
    tar -xvf packages/cardano-wallet-shelley-2020.7.28-linux64.tar.gz
    export CADDR="$(pwd)/cardano-wallet-shelley-2020.7.28/cardano-address"
    export CCLI="$(pwd)/cardano-wallet-shelley-2020.7.28/cardano-cli"
    export BECH32="$(pwd)/cardano-wallet-shelley-2020.7.28/bech32"
    
    # Create wallet stake-address
    fnMakeFileExtractPoolStakingKeys extractPoolStakingKeys.sh
    chmod +x extractPoolStakingKeys.sh
    ./extractPoolStakingKeys.sh 0 ${COLDKEY_PATH}/ ${MNEMONIC}
    echo ${MNEMONIC} > ${COLDKEY_PATH}/mnemonic-wallet.bak
    unset MNEMONIC
    mv ${COLDKEY_PATH}/base.addr ${COLDKEY_PATH}/payment.addr && \
    cp ${COLDKEY_PATH}/payment.addr ${HOTKEY_PATH}/payment.addr
    
    # Create node certificate
    cardano-cli node key-gen \
    --cold-verification-key-file ${COLDKEY_PATH}/node.vkey \
    --cold-signing-key-file ${COLDKEY_PATH}/node.skey \
    --operational-certificate-issue-counter ${COLDKEY_PATH}/node.counter

    fnInternalCreateRenewCertificate ${START_KES_PERIOD} ${HOTKEY_PATH}/kes.vkey

    fnDRP
    
    history -c && history -w

    cardano-cli stake-address registration-certificate \
    --stake-verification-key-file ${COLDKEY_PATH}/stake.vkey \
    --out-file ${HOTKEY_PATH}/stake.cert
    
    fnColdHotTransfer stake-address

    echo "END: generate-cold-key"
    #Output: stake.cert | node.cert
}

fnStakeAddressSign () {
    #Input: tx-payment-stake.raw
    echo "START: stake-address-sign"
    
    while true ; do
        read -rsp "Load file \"${TX_RAW_PATH}/tx-payment-stake.raw\" and press enter to continue..."$'\n'
        test -f "${TX_RAW_PATH}/tx-payment-stake.raw" && break
    done
    
    rm ${TX_RAW_PATH}/tx-payment-stake.signed || true

    # Sign the transaction with both the payment and stake secret keys:
    cardano-cli transaction sign \
    --tx-body-file ${TX_RAW_PATH}/tx-payment-stake.raw \
    --signing-key-file ${COLDKEY_PATH}/payment.skey \
    --signing-key-file ${COLDKEY_PATH}/stake.skey \
    ${MAGIC} \
    --out-file ${TX_RAW_PATH}/tx-payment-stake.signed

    fnColdHotTransfer tx-payment-stake-signed

    echo "END: stake-address-sign"
    #Output: tx-payment-stake.signed
}

fnRegistrationCertificate () {
    echo "START: registration-certificate"
    
    #fnMakeFileMetadata ${HOME}/poolMetaData.json
    cp metadata.json ${HOME}/poolMetaData.json
    
    cat ${HOME}/poolMetaData.json

    confirm

    # Calculate the hash of your metadata file.
    cardano-cli stake-pool metadata-hash \
    --pool-metadata-file ${HOME}/poolMetaData.json > ${HOME}/poolMetaDataHash.txt
    
    cardano-cli stake-pool registration-certificate \
    --cold-verification-key-file ${COLDKEY_PATH}/node.vkey \
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
    --out-file ${HOTKEY_PATH}/pool.cert
    
    cardano-cli stake-address delegation-certificate \
    --stake-verification-key-file ${COLDKEY_PATH}/stake.vkey \
    --cold-verification-key-file ${COLDKEY_PATH}/node.vkey \
    --out-file ${HOTKEY_PATH}/deleg.cert

    fnColdHotTransfer registration-certificate
    echo "END: registration-certificate"
    #Output: pool.cert | deleg.cert
}

fnPoolRegistrationSign () {
    #Input: tx-registration-certificate.raw
    echo "START: pool-registration-sign"
    while true ; do
        read -rsp "Load file \"${TX_RAW_PATH}/tx-registration-certificate.raw\" and press enter to continue..."$'\n'
        test -f "${TX_RAW_PATH}/tx-registration-certificate.raw" && break
    done
    
    rm ${TX_RAW_PATH}/tx-registration-certificate.signed || true

    cardano-cli transaction sign \
    --tx-body-file ${TX_RAW_PATH}/tx-registration-certificate.raw \
    --signing-key-file ${COLDKEY_PATH}/payment.skey \
    --signing-key-file ${COLDKEY_PATH}/node.skey \
    --signing-key-file ${COLDKEY_PATH}/stake.skey \
    ${MAGIC} \
    --out-file ${TX_RAW_PATH}/tx-registration-certificate.signed

    fnColdHotTransfer tx-registration-certificate-signed
    echo "END: pool-registration-sign"
    #Output: tx-registration-certificate.signed
}

fnCheckPoolId () {
    cardano-cli stake-pool id \
    --cold-verification-key-file ${COLDKEY_PATH}/node.vkey \
    --output-format hex > stakepoolid.txt
    cat stakepoolid.txt
    
    #cardano-cli query ledger-state ${MAGIC} | grep publicKey | grep $(cat stakepoolid.txt)
}

PS3="Select the operation: "

select opt in "Install 7z" "Generate stake keys" "Sign skate account" "Register pool certificate" "Sign pool certificate" "Get Pool Id" "Renew KES" "Backup" "EXIT"; do
    case $opt in
        "Install 7z")
        fnPackages7z;;

        "Generate stake keys")
        fnGenerateColdKey;;

        "Sign skate account")
        fnStakeAddressSign;;

        "Register pool certificate")
        fnRegistrationCertificate;;

        "Sign pool certificate")
        fnPoolRegistrationSign;;

        "Get Pool Id")
        fnCheckPoolId;;

        "Renew KES")
        fnRenewCertificate;;

        "Backup")
        fnDRP;;

        "EXIT")
        break;;
        *)
        echo "Invalid option $REPLY";;
    esac
done