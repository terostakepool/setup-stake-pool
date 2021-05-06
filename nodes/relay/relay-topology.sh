#!/bin/bash
set -e

source ${HOME}/.profile

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

fnTopologyUpdater() {

cat > ${CNODE_HOME}/topologyUpdater.sh << EOF
#!/bin/bash
# shellcheck disable=SC2086,SC2034

USERNAME=$(whoami)
CNODE_PORT=${CNODE_PORT} # must match your relay node port as set in the startup command
CNODE_HOSTNAME="CHANGE ME"  # optional. must resolve to the IP you are requesting from
CNODE_BIN="/usr/local/bin"
CNODE_LOG_DIR="${CNODE_HOME}/logs"
GENESIS_JSON="${CNODE_HOME}/${NETWORK}-shelley-genesis.json"
NETWORKID=\$(jq -r .networkId \$GENESIS_JSON)
CNODE_VALENCY=1   # optional for multi-IP hostnames
NWMAGIC=\$(jq -r .networkMagic < \$GENESIS_JSON)

if [ "\${NETWORKID}" == "Testnet" ]; then
    NETWORK_IDENTIFIER="--testnet-magic \${NWMAGIC}"
else
    NETWORK_IDENTIFIER="--mainnet"
fi

export PATH="\${CNODE_BIN}:\${PATH}"
export CARDANO_NODE_SOCKET_PATH="${CNODE_HOME}/db/socket"

blockNo=\$(/usr/local/bin/cardano-cli query tip \${NETWORK_IDENTIFIER} | jq -r .block )

# Note:
# if you run your node in IPv4/IPv6 dual stack network configuration and want announced the
# IPv4 address only please add the --ipv4 parameter to the curl command below  (curl --ipv4 -s ...)
if [ "\${CNODE_HOSTNAME}" != "CHANGE ME" ]; then
  T_HOSTNAME="&hostname=\${CNODE_HOSTNAME}"
else
  T_HOSTNAME=''
fi

if [ ! -d \${CNODE_LOG_DIR} ]; then
  mkdir -p \${CNODE_LOG_DIR};
fi

curl --ipv4 -s "https://api.clio.one/htopology/v1/?port=\${CNODE_PORT}&blockNo=\${blockNo}&valency=\${CNODE_VALENCY}&magic=\${NWMAGIC}\${T_HOSTNAME}" | tee -a \$CNODE_LOG_DIR/topologyUpdater_lastresult.json
EOF
    
    chmod +x ${CNODE_HOME}/topologyUpdater.sh
    ${CNODE_HOME}/topologyUpdater.sh
    
cat > ${CNODE_HOME}/crontab-fragment.txt << EOF
24 * * * * ${CNODE_HOME}/topologyUpdater.sh
EOF
    crontab -l | cat - ${CNODE_HOME}/crontab-fragment.txt > ${CNODE_HOME}/crontab.txt && crontab ${CNODE_HOME}/crontab.txt
    rm ${CNODE_HOME}/crontab-fragment.txt

    systemctl restart cron
}

fnRelayTopologyPull() {
    
    read -p "Enter producer ip: " BLOCKPRODUCING_IP
    BLOCKPRODUCING_IP=${BLOCKPRODUCING_IP:-"not-set"}
    echo ${BLOCKPRODUCING_IP}

    read -p "Enter producer port [6000]: " BLOCKPRODUCING_PORT
    BLOCKPRODUCING_PORT=${BLOCKPRODUCING_PORT:-"6000"}
    echo ${BLOCKPRODUCING_PORT}
    
    confirm

cat > ${CNODE_HOME}/relayTopologyPull.sh << EOF
#!/bin/bash
GENESIS_JSON="${CNODE_HOME}/${NETWORK}-shelley-genesis.json"
NETWORKID=\$(jq -r .networkId \$GENESIS_JSON)
NWMAGIC=\$(jq -r .networkMagic < \$GENESIS_JSON)
BLOCKPRODUCING_IP=${BLOCKPRODUCING_IP}
BLOCKPRODUCING_PORT=${BLOCKPRODUCING_PORT}

if [ "\${NETWORKID}" == "Testnet" ]; then
    curl --ipv4 -s -o ${CNODE_HOME}/${NETWORK}-topology.json "https://api.clio.one/htopology/v1/fetch/?max=20&magic=${NWMAGIC}&ipv=4&customPeers=\${BLOCKPRODUCING_IP}:\${BLOCKPRODUCING_PORT}:1|relays-new.cardano-testnet.iohkdev.io:3001:2"
else
    curl --ipv4 -s -o ${CNODE_HOME}/${NETWORK}-topology.json "https://api.clio.one/htopology/v1/fetch/?max=20&magic=${NWMAGIC}&ipv=4&customPeers=\${BLOCKPRODUCING_IP}:\${BLOCKPRODUCING_PORT}:1|relays-new.cardano-mainnet.iohk.io:3001:2"
fi

EOF
    
    chmod +x ${CNODE_HOME}/relayTopologyPull.sh
    ${CNODE_HOME}/relayTopologyPull.sh
    cat ${CNODE_HOME}/${NETWORK}-topology.json

    systemctl restart cardano-node
}

PS3="Select the operation: "

select opt in topology-updater relay-topology-pull quit; do
    case $opt in
        topology-updater)
        fnTopologyUpdater;;
        relay-topology-pull)
        fnRelayTopologyPull;;
        quit)
        break;;
        *)
        echo "Invalid option $REPLY";;
    esac
done