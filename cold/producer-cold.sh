#!/bin/bash
set -e

source ./config.sh

fnInternalCreateRenewCertificate() {
    ####################################################
    # Generate operational certificate
    ####################################################

    KESPeriod=$1  # New KEY Period.
    KESKeyVerification=$2 # New KES verification key
    # from cardano-cli node key-gen
    NODEColdSignKey=${COLDKEY_PATH}/cold.skey
    NODEIssueCounter=${COLDKEY_PATH}/node.counter

    cardano-cli node issue-op-cert \
    --kes-verification-key-file ${KESKeyVerification} \
    --cold-signing-key-file ${NODEColdSignKey} \
    --operational-certificate-issue-counter ${NODEIssueCounter} \
    --kes-period ${KESPeriod} \
    --out-file ${HOTKEY_PATH}/node.cert
}

fnRenewCertificate() {
    ######################################################
    # Rotate pool's KES keys
    # Updating the operational cert with a new KES Period
    ######################################################
    echo "Rotate KES keys"

    while true ; do
        read -rsp "Required file: \"${HOTKEY_PATH}/startKesPeriod.out\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/startKesPeriod.out" && break
    done
    
    while true ; do
        read -rsp "Required file: \"${HOTKEY_PATH}/kes.vkey\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/kes.vkey" && break
    done
    
    export START_KES_PERIOD="$(cat ${HOTKEY_PATH}/startKesPeriod.out)"

    echo "Renew operational cert with START_KES_PERIOD: ${START_KES_PERIOD}"
    confirm

    # Create a backup before changing any important files
    fnDRP

    # Generate new certificate with new KES key
    fnInternalCreateRenewCertificate ${START_KES_PERIOD} ${HOTKEY_PATH}/kes.vkey

    echo "Encrypt files using 7-Zip for transfer to producer node"
    echo "File added: node.cert"
    fnColdHotTransfer renew-certificate
    
    echo "Finished: Rotate KES keys"
}

fnGenerateColdKey () {
    echo "Generate stake keys"

    while true ; do
        read -rsp "Required file: \"${HOTKEY_PATH}/startKesPeriod.out\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/startKesPeriod.out" && break
    done

    while true ; do
        read -rsp "Required file: \"${HOTKEY_PATH}/kes.vkey\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/kes.vkey" && break
    done

    export START_KES_PERIOD="$(cat ${HOTKEY_PATH}/startKesPeriod.out)"

    echo "START_KES_PERIOD: ${START_KES_PERIOD}"
    confirm

    # Create a backup before changing any important files
    fnDRP

    # Temporary Wallet: shelley-2020.7.28
    # TODO: update script extractPoolStakingKeys.sh to support newer version of wallet
    echo "f75e5b2b4cc5f373d6b1c1235818bcab696d86232cb2c5905b2d91b4805bae84 *packages/cardano-wallet-shelley-2020.7.28-linux64.tar.gz" | shasum -a 256 --check
    rm -rf $(pwd)/cardano-wallet-shelley-2020.7.28/
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
    --cold-verification-key-file ${COLDKEY_PATH}/cold.vkey \
    --cold-signing-key-file ${COLDKEY_PATH}/cold.skey \
    --operational-certificate-issue-counter ${COLDKEY_PATH}/node.counter
    
    # Create certificate with new KES key
    fnInternalCreateRenewCertificate ${START_KES_PERIOD} ${HOTKEY_PATH}/kes.vkey

    # Create a backup before changing any important files
    fnDRP

    # Create a registration certificate
    cardano-cli stake-address registration-certificate \
    --stake-verification-key-file ${COLDKEY_PATH}/stake.vkey \
    --out-file ${HOTKEY_PATH}/stake.cert
    
    echo "Encrypt files using 7-Zip for transfer to producer node"
    echo "Files added: stake.cert | node.cert"
    fnColdHotTransfer stake-address

    echo "Finished: Generate stake keys"
}

fnStakeAddressSign () {
    echo "Sign skate account"
    
    while true ; do
        read -rsp "Required file: \"${TX_RAW_PATH}/tx-payment-stake.raw\" and press enter to continue..."$'\n'
        test -f "${TX_RAW_PATH}/tx-payment-stake.raw" && break
    done
    
    rm -f ${TX_RAW_PATH}/tx-payment-stake.signed

    # Sign the transaction with both the payment and stake secret keys
    cardano-cli transaction sign \
    --tx-body-file ${TX_RAW_PATH}/tx-payment-stake.raw \
    --signing-key-file ${COLDKEY_PATH}/payment.skey \
    --signing-key-file ${COLDKEY_PATH}/stake.skey \
    ${MAGIC} \
    --out-file ${TX_RAW_PATH}/tx-payment-stake.signed

    echo "Encrypt files using 7-Zip for transfer to producer node"
    echo "Files added: tx-payment-stake.signed"
    fnColdHotTransfer tx-payment-stake-signed

    echo "Finished: Sign skate account"
}

fnRegistrationCertificate () {
    echo "Register pool certificate"
    
    #fnMakeFileMetadata ${HOME}/poolMetaData.json
    cp metadata.json ${HOME}/poolMetaData.json
    
    cat ${HOME}/poolMetaData.json

    confirm

    # Calculate the hash of your metadata file.
    cardano-cli stake-pool metadata-hash \
    --pool-metadata-file ${HOME}/poolMetaData.json > ${HOME}/poolMetaDataHash.txt
    
    # Generate Stake pool registration certificate
    # TODO: Support register with multiple relays with --single-host-pool-relay
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
    --out-file ${HOTKEY_PATH}/pool.cert

    # Creates a delegation certificate which delegates funds from all stake addresses 
    # associated with key (stake.vkey) to the pool belonging to cold key (cold.vkey)
    cardano-cli stake-address delegation-certificate \
    --stake-verification-key-file ${COLDKEY_PATH}/stake.vkey \
    --cold-verification-key-file ${COLDKEY_PATH}/cold.vkey \
    --out-file ${HOTKEY_PATH}/deleg.cert

    echo "Encrypt files using 7-Zip for transfer to producer node"
    echo "Files added: pool.cert | deleg.cert"
    fnColdHotTransfer registration-certificate

    echo "Finished: Register pool certificate"
}

fnPoolRegistrationSign () {
    echo "Sign pool certificate"

    while true ; do
        read -rsp "Required file: \"${TX_RAW_PATH}/tx-registration-certificate.raw\" and press enter to continue..."$'\n'
        test -f "${TX_RAW_PATH}/tx-registration-certificate.raw" && break
    done
    
    rm -f ${TX_RAW_PATH}/tx-registration-certificate.signed

    # Sign the transaction (Register pool certificate)
    cardano-cli transaction sign \
    --tx-body-file ${TX_RAW_PATH}/tx-registration-certificate.raw \
    --signing-key-file ${COLDKEY_PATH}/payment.skey \
    --signing-key-file ${COLDKEY_PATH}/cold.skey \
    --signing-key-file ${COLDKEY_PATH}/stake.skey \
    ${MAGIC} \
    --out-file ${TX_RAW_PATH}/tx-registration-certificate.signed

    echo "Encrypt files using 7-Zip for transfer to producer node"
    echo "Files added: tx-registration-certificate.signed"
    fnColdHotTransfer tx-registration-certificate-signed

    echo "Finished: Sign pool certificate"
}

fnCheckPoolId () {

    # Get Pool ID
    cardano-cli stake-pool id \
    --cold-verification-key-file ${COLDKEY_PATH}/cold.vkey \
    --output-format hex > stakepoolid.txt
    cat stakepoolid.txt

    # (on producer) Check for the presence of your poolID in the network ledger state
    # PoolID=07175f6efa70645146007138a4fdd00b9e8db2a73baecdd704ebccfd # Change for your Pool Id
    # cardano-cli query ledger-state ${MAGIC} | grep publicKey | grep ${PoolID}
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

        "Create backup")
        fnDRP;;

        "EXIT")
        break;;
        *)
        echo "Invalid option $REPLY";;
    esac
done