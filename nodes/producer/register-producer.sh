#!/bin/bash
set -e

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Refresh
source ${HOME}/.bashrc

cd ${CNODE_HOME}

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

# Generate KES
initKES() {
    echo "Generate KES"

    # Determine the number of slots per KES period from the genesis file.
    slotsPerKESPeriod=$(cat $CNODE_HOME/${NETWORK}-shelley-genesis.json | jq -r '.slotsPerKESPeriod')
    echo slotsPerKESPeriod: ${slotsPerKESPeriod}
    slotNo=$(cardano-cli query tip ${MAGIC} | jq -r '.slot')
    echo slotNo: ${slotNo}
    kesPeriod=$((${slotNo} / ${slotsPerKESPeriod}))
    echo kesPeriod: ${kesPeriod}
    startKesPeriod=${kesPeriod}
    echo startKesPeriod: ${startKesPeriod}

    echo ${startKesPeriod} > ${HOTKEY_PATH}/startKesPeriod.out

    confirm

    # Create a backup before changing any important files
    fnDRP

    # Stake pool hot key (kes.skey)
    cardano-cli node key-gen-KES \
    --verification-key-file ${HOTKEY_PATH}/kes.vkey \
    --signing-key-file ${HOTKEY_PATH}/kes.skey

    echo "Encrypt files using 7-Zip for transfer to cold environment"
    echo "Files added: startKesPeriod.out | kes.vkey"
    fnHotColdTransfer kes

    echo "Finished: Generate KES"
}

# Configure keys and cert to start producer mode
startNodeCert() {
    echo "Configure keys and cert to (Start producer mode)"

    # Stake pool cold key (node.cert)
    while true ; do
        read -rsp "Required file: \"${HOTKEY_PATH}/node.cert\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/node.cert" && break
    done

    # Create a backup before changing any important files
    fnDRP

    # Stake pool VRF key (vrf.skey)
    cardano-cli node key-gen-VRF \
    --verification-key-file ${HOTKEY_PATH}/vrf.vkey \
    --signing-key-file ${HOTKEY_PATH}/vrf.skey

    # Update vrf key permissions to read-only.
    chmod 400 ${HOTKEY_PATH}/vrf.skey

    systemctl stop cardano-node

cat > ${CNODE_HOME}/start-${NODE_TYPE}-node.sh << EOF
#!/bin/bash
PORT=${CNODE_PORT}
HOSTADDR=0.0.0.0
TOPOLOGY=${CNODE_HOME}/${NETWORK}-topology.json
DB_PATH=${CNODE_HOME}/db
SOCKET_PATH=${CNODE_HOME}/db/socket
CONFIG=${CNODE_HOME}/${NETWORK}-config.json
KES=${HOTKEY_PATH}/kes.skey
VRF=${HOTKEY_PATH}/vrf.skey
CERT=${HOTKEY_PATH}/node.cert
cardano-node run --topology \${TOPOLOGY} --database-path \${DB_PATH} --socket-path \${SOCKET_PATH} --host-addr \${HOSTADDR} --port \${PORT} --config \${CONFIG} --shelley-kes-key \${KES} --shelley-vrf-key \${VRF} --shelley-operational-certificate \${CERT}
EOF
    sleep 5
    systemctl start cardano-node
    sleep 5
    systemctl status cardano-node

    echo "Finished: Start producer mode"
}

# Register stake address
registerStakeAddress () {
    echo "Register stake address"

    while true ; do
        read -rsp "Required file: \"${HOTKEY_PATH}/payment.addr\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/payment.addr" && break
    done
    
    while true ; do
        read -rsp "Required file: \"${HOTKEY_PATH}/stake.cert\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/stake.cert" && break
    done

    # Create a backup before changing any important files
    fnDRP

    cardano-cli query protocol-parameters ${MAGIC} --out-file ${CNODE_HOME}/params.json
    cardano-cli query utxo --address $(cat ${HOTKEY_PATH}/payment.addr) ${MAGIC}
    
    currentSlot=$(cardano-cli query tip ${MAGIC} | jq -r '.slot')
    echo Current Slot: $currentSlot
    
    cardano-cli query utxo \
    --address $(cat ${HOTKEY_PATH}/payment.addr) \
    ${MAGIC} > fullUtxo.out
    
    tail -n +3 fullUtxo.out | sort -k3 -nr > balance-register-stakeaddress.out
    cat balance-register-stakeaddress.out
    
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
    done < balance-register-stakeaddress.out
    
    txcnt=$(cat balance-register-stakeaddress.out | wc -l)
    echo Total ADA balance: ${total_balance}
    echo Number of UTXOs: ${txcnt}
    
    stakeAddressDeposit=$(cat ${CNODE_HOME}/params.json | jq -r '.stakeAddressDeposit')
    # Deposit to start delegation - 2 ADA
    echo stakeAddressDeposit: $stakeAddressDeposit
    # TODO: Will it be necessary to check if you have already paid the deposit to delegate?

    # Run the build-raw transaction to calculate fee
    cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${HOTKEY_PATH}/payment.addr)+0 \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee 0 \
    --out-file ${TX_RAW_PATH}/tx-payment-stake.tmp \
    --certificate-file ${HOTKEY_PATH}/stake.cert
    
    # Calculate the current minimum fee
    fee=$(cardano-cli transaction calculate-min-fee \
        --tx-body-file ${TX_RAW_PATH}/tx-payment-stake.tmp \
        --tx-in-count ${txcnt} \
        --tx-out-count 1 \
        ${MAGIC} \
        --witness-count 2 \
        --byron-witness-count 0 \
    --protocol-params-file ${CNODE_HOME}/params.json | awk '{ print $1 }')
    echo fee: $fee
    
    # Calculate your change output:
    txOut=$((${total_balance}-${stakeAddressDeposit}-${fee}))
    echo Change Output: ${txOut}
    # TODO: Format numbers as currency: X.XXXXXX ADA

    confirm

    # Build your transaction which will register your stake address
    # Certificate file: stake.cert
    cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${HOTKEY_PATH}/payment.addr)+${txOut} \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee ${fee} \
    --certificate-file ${HOTKEY_PATH}/stake.cert \
    --out-file ${TX_RAW_PATH}/tx-payment-stake.raw

    echo "Encrypt files using 7-Zip for transfer to cold environment"
    echo "Files added: tx-payment-stake.raw"
    fnHotColdTransfer payment-stake

    echo "Finished: Register stake address"
}

submitStakeAddress() {
    echo "Submit the transaction to record your stake address"
    echo "${TX_RAW_PATH}/tx-payment-stake.signed"
    confirm

    while true ; do
        read -rsp "Required file: \"${TX_RAW_PATH}/tx-payment-stake.signed\" and press enter to continue..."$'\n'
        test -f "${TX_RAW_PATH}/tx-payment-stake.signed" && break
    done

    cardano-cli transaction submit \
    --tx-file ${TX_RAW_PATH}/tx-payment-stake.signed \
    ${MAGIC}
}

# Register your stake pool
registerStakePool() {

    echo "Register stake pool"

    while true ; do
        read -rsp "Required file: \"${HOTKEY_PATH}/pool.cert\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/pool.cert" && break
    done
    
    while true ; do
        read -rsp "Required file: \"${HOTKEY_PATH}/deleg.cert\" and press enter to continue..."$'\n'
        test -f "${HOTKEY_PATH}/deleg.cert" && break
    done
    
    # Create a backup before changing any important files
    fnDRP

    currentSlot=$(cardano-cli query tip ${MAGIC} | jq -r '.slot')
    echo Current Slot: $currentSlot
    
    cardano-cli query utxo \
    --address $(cat ${HOTKEY_PATH}/payment.addr) \
    ${MAGIC} > fullUtxo.out
    
    tail -n +3 fullUtxo.out | sort -k3 -nr > balance-register-stakepool.out
    
    cat balance-register-stakepool.out
    
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
    done < balance-register-stakepool.out
    txcnt=$(cat balance-register-stakepool.out | wc -l)
    echo Total ADA balance: ${total_balance}
    echo Number of UTXOs: ${txcnt}
    
    stakePoolDeposit=$(cat ${CNODE_HOME}/params.json | jq -r '.stakePoolDeposit')
    # Deposit to register pool - 500 ADA
    echo stakePoolDeposit: $stakePoolDeposit
    # TODO: Will it be possible to verify if it has already been paid?

    # Run the build-raw transaction to calculate fee
    cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${HOTKEY_PATH}/payment.addr)+$(( ${total_balance} - ${stakePoolDeposit}))  \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee 0 \
    --certificate-file ${HOTKEY_PATH}/pool.cert \
    --certificate-file ${HOTKEY_PATH}/deleg.cert \
    --out-file ${TX_RAW_PATH}/tx-registration-certificate.tmp

    # Calculate the current minimum fee
    fee=$(cardano-cli transaction calculate-min-fee \
        --tx-body-file ${TX_RAW_PATH}/tx-registration-certificate.tmp \
        --tx-in-count ${txcnt} \
        --tx-out-count 1 \
        ${MAGIC} \
        --witness-count 3 \
        --byron-witness-count 0 \
    --protocol-params-file ${CNODE_HOME}/params.json | awk '{ print $1 }')
    echo fee: $fee

    txOut=$((${total_balance}-${stakePoolDeposit}-${fee}))
    echo txOut: ${txOut}

    confirm

    # Build your transaction which will register your stake pool:
    # Certificate files: pool.cert and deleg.cert
    cardano-cli transaction build-raw \
    ${tx_in} \
    --tx-out $(cat ${HOTKEY_PATH}/payment.addr)+${txOut} \
    --invalid-hereafter $(( ${currentSlot} + 10000)) \
    --fee ${fee} \
    --certificate-file ${HOTKEY_PATH}/pool.cert \
    --certificate-file ${HOTKEY_PATH}/deleg.cert \
    --out-file ${TX_RAW_PATH}/tx-registration-certificate.raw

    echo "Encrypt files using 7-Zip for transfer to cold environment"
    echo "Files added: tx-registration-certificate.raw"
    fnHotColdTransfer registration-certificate

    echo "Finished: Register stake pool"
}

submitStakePool () {
    echo "Submit the transaction to record your stake pool"
    echo "${TX_RAW_PATH}/tx-registration-certificate.signed"
    confirm

    while true ; do
        read -rsp "Required file: \"${TX_RAW_PATH}/tx-registration-certificate.signed\" and press enter to continue..."$'\n'
        test -f "${TX_RAW_PATH}/tx-registration-certificate.signed" && break
    done
    
    cardano-cli transaction submit \
    --tx-file ${TX_RAW_PATH}/tx-registration-certificate.signed \
    ${MAGIC}
}

updateTopology() {
    # TODO: Ask if you want to add another relay
    read -p "Enter relay ip: " RELAY_IP
    RELAY_IP=${RELAY_IP:-"127.0.0.1"}
    echo ${RELAY_IP}

    read -p "Enter ${NODE_TYPE} port [6000]: " CNODE_PORT
    CNODE_PORT=${CNODE_PORT:-"6000"}
    echo ${CNODE_PORT}

cat > ${CNODE_HOME}/${NETWORK}-topology.json << EOF 
{
    "Producers": [
        {
        "addr": "${RELAY_IP}",
        "port": ${CNODE_PORT},
        "valency": 1
        }
    ]
}
EOF

    cat ${CNODE_HOME}/${NETWORK}-topology.json

    echo "Rebooting..."
    systemctl stop cardano-node
    sleep 5
    systemctl start cardano-node
    sleep 5
    systemctl status cardano-node
}

PS3="Select the operation: "

select opt in "Generate KES" "Start producer mode" "Register stake address" "Submit stake address" "Register stake pool" "Submit stake pool" "Topology Updater" "EXIT"; do
    case $opt in
        "Generate KES")
        initKES;;

        "Start producer mode")
        startNodeCert;;

        "Register stake address")
        registerStakeAddress;;

        "Submit stake address")
        submitStakeAddress;;

        "Register stake pool")
        registerStakePool;;

        "Submit stake pool")
        submitStakePool;;

        "Topology Updater")
        updateTopology;;

        "EXIT")
        break;;
        *)
        echo "Invalid option $REPLY";;
    esac
done