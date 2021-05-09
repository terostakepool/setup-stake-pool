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

# TODO: DUPLICATE FUNCTION
confirm() {
    # call with a prompt string or use a default
    read -r -p "${1:-Are you sure? [y/N]} " response
    case "$response" in
        [yY][eE][sS]|[yY])
            true
        ;;
        *)
            exit 1
        ;;
    esac
}

# TODO: DUPLICATE FUNCTION
fnDRP() {
    ########################## Disaster Recovery Plan #####################
    HOTKEY_BACKUP_PATH=${HOME}/backup-hot-keys

    mkdir -p ${HOTKEY_BACKUP_PATH}/DRP
    
    timestamp=$(date +%s)

    read -rsp "A BACKUP WILL BE CREATED BELOW PLEASE TAKE NOTE OF FILE NAME [${HOTKEY_BACKUP_PATH}/DRP/drp-hot-keys-${timestamp}.7z] AND YOUR PASSWORD."$'\n'
    
    7z a \
    -t7z -m0=lzma2 -mx=9 -mfb=64 \
    -md=32m -ms=on -mhe=on -p \
    ${HOTKEY_BACKUP_PATH}/DRP/drp-hot-keys-${timestamp}.7z ${HOTKEY_PATH}
    
    7z t ${HOTKEY_BACKUP_PATH}/DRP/drp-hot-keys-${timestamp}.7z
}

fnHotColdTransfer() {
    HOT_TRANSFER_PATH=${TRANSFER_HOME}/hot-to-cold

    mkdir -p ${HOT_TRANSFER_PATH}

    name=$1
    timestamp=$(date +%s)
    
    echo "Creating file [${HOT_TRANSFER_PATH}/hot-to-cold-${name}-${timestamp}.7z] for transfer to cold environment."$'\n'
    
    7z a \
    -t7z -m0=lzma2 -mx=9 -mfb=64 \
    -md=32m -ms=on -mhe=on -p \
    ${HOT_TRANSFER_PATH}/hot-to-cold-${name}-${timestamp}.7z ${HOTKEY_PATH} ${TX_RAW_PATH}
    
   7z t ${HOT_TRANSFER_PATH}/hot-to-cold-${name}-${timestamp}.7z
}

fnTxUpdateCert() {
    read -p "Enter ID CERT: " ID_CERT
    echo ${ID_CERT}

    while true ; do
        read -rsp "Load file \"${HOTKEY_PATH}/pool-${ID_CERT}.cert\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/pool-${ID_CERT}.cert" && break
    done
        
    while true ; do
        read -rsp "Load file \"${HOTKEY_PATH}/deleg-${ID_CERT}.cert\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/deleg-${ID_CERT}.cert" && break
    done

    cardano-cli query protocol-parameters \
        ${MAGIC} \
        --out-file ${CNODE_HOME}/params.json
        
    fnDRP

    currentSlot=$(cardano-cli query tip ${MAGIC} | jq -r '.slot')
    echo Current Slot: $currentSlot
        
    cardano-cli query utxo \
    --address $(cat ${HOTKEY_PATH}/payment.addr) \
    ${MAGIC} > fullUtxo.out

    tail -n +3 fullUtxo.out | sort -k3 -nr > balance-update-stakepool.out

    cat balance-update-stakepool.out
        
    tx_in=""
    total_balance=0
    while read -r utxo; do
        in_addr=$(awk '{ print $1 }' <<< "${utxo}")
        idx=$(awk '{ print $2 }' <<< "${utxo}")
        utxo_balance=$(awk '{ print $3 }' <<< "${utxo}")
        total_balance=$((${total_balance}+${utxo_balance}))
        echo "TxHash: ${in_addr}#${idx}"
        echo ADA: ${utxo_balance}
        tx_in="${tx_in} --tx-in ${in_addr}#${idx}"
    done < balance-update-stakepool.out
    txcnt=$(cat balance-update-stakepool.out | wc -l)
    echo Total ADA balance: ${total_balance}
    echo Number of UTXOs: ${txcnt}
        
    # Not need: stakePoolDeposit
    rm ${TX_RAW_PATH}/tx-update-certificate.tmp || true 
    cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${HOTKEY_PATH}/payment.addr)+${total_balance} \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee 0 \
    --certificate-file ${HOTKEY_PATH}/pool-${ID_CERT}.cert \
    --certificate-file ${HOTKEY_PATH}/deleg-${ID_CERT}.cert \
    --out-file ${TX_RAW_PATH}/tx-update-certificate.tmp
        
    fee=$(cardano-cli transaction calculate-min-fee \
        --tx-body-file ${TX_RAW_PATH}/tx-update-certificate.tmp \
        --tx-in-count ${txcnt} \
        --tx-out-count 1 \
        ${MAGIC} \
        --witness-count 3 \
        --byron-witness-count 0 \
    --protocol-params-file ${CNODE_HOME}/params.json | awk '{ print $1 }')
    echo fee: $fee

    txOut=$((${total_balance}-${fee}))
    echo txOut: ${txOut}

    confirm

    cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${HOTKEY_PATH}/payment.addr)+${txOut} \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee ${fee} \
    --certificate-file ${HOTKEY_PATH}/pool-${ID_CERT}.cert \
    --certificate-file ${HOTKEY_PATH}/deleg-${ID_CERT}.cert \
    --out-file ${TX_RAW_PATH}/tx-update-certificate-${ID_CERT}.raw

    echo "Securing file (tx-update-certificate-${ID_CERT}.raw) for transfer to cold environment"
    fnHotColdTransfer update-certificate-${ID_CERT}
}

fnSendUpdateCert() {
    read -p "Enter ID CERT: " ID_CERT
    echo ${ID_CERT}

    confirm

    while true ; do
        read -rsp "Load file \"${TX_RAW_PATH}/tx-update-certificate-${ID_CERT}.signed\" and press enter to continue..."$'\n'
        test -f "${TX_RAW_PATH}/tx-update-certificate-${ID_CERT}.signed" && break
    done

    cardano-cli transaction submit \
    --tx-file ${TX_RAW_PATH}/tx-update-certificate-${ID_CERT}.signed \
    ${MAGIC}
}

PS3="Select the operation: "

select opt in "Update Cert" "Submit cert" quit; do
    case $opt in
        "Update cert")
        fnTxUpdateCert;;

        "Submit cert")
        fnSendUpdateCert;;

        quit)
        break;;
        *)
        echo "Invalid option $REPLY";;
    esac
done