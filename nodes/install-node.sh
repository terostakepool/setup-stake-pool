#!/bin/bash
set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

export LANG=en_US.utf8
export TZ=right/UTC

fnInitSetup() {
    read -p "Enter swap space [4G]: " SWAPFILE
    SWAPFILE=${SWAPFILE:-"4G"}
    echo ${SWAPFILE}
    
    read -p "Enter memory for zram in megabytes [512]: " ZRAM
    ZRAM=${ZRAM:-"512"}
    echo ${ZRAM}
    
    read -p "Default user ssh [ubuntu]: " SYSUSER
    SYSUSER=${SYSUSER:-"ubuntu"}
    echo ${SYSUSER}

    read -p "New user ssh [pepe]: " NEW_SYSUSER
    NEW_SYSUSER=${NEW_SYSUSER:-"pepe"}
    echo ${NEW_SYSUSER}

    read -p "Enter NEW ssh port [22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-"22"}
    echo ${SSH_PORT}

    # Additional security to use 'sudo' with user password
    echo "Enter new password for the user ${SYSUSER}"
    passwd ${SYSUSER}

    echo export TRANSFER_HOME=/home/${NEW_SYSUSER} >> ${HOME}/.bashrc
    
    # Remove lxd prevent privilege escalation
    if which snap >/dev/null; then
        snap remove lxd
    fi
    
    # APT dependencies
    apt-get update && apt-get install -y locales && \
    localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8 && \
    apt-get upgrade -y && \
    apt-get install automake build-essential openssl pkg-config libffi-dev libgmp-dev libgmp10 libssl-dev libtinfo-dev libsystemd-dev systemd zlib1g-dev libncurses-dev libtinfo5 make g++ git jq wget libncursesw5 libtool autoconf bc tcptraceroute rsync htop curl ca-certificates nano dnsutils iproute2 tmux fail2ban chrony p7zip-full -y && \
    apt-get install linux-image-generic linux-modules-extra-aws zram-tools -y && \
    apt-get -y autoremove && \
    apt-get clean autoclean && \
    rm -fr /var/lib/apt/lists/{apt,dpkg,cache,log} /tmp/* /var/tmp/*
    
    # Fix for git
    git config --global http.postBuffer 500M
    git config --global http.maxRequestBuffer 100M

    # Config: fail2ban
    cp files/jail.local /etc/fail2ban/jail.local
    sed -i "s/port = ssh/port = ${SSH_PORT}/" /etc/fail2ban/jail.local

    systemctl enable fail2ban
    systemctl restart fail2ban.service
    # (Problems when running from the bash script): fail2ban-client status
    
    # Config: new user sshd
    adduser ${NEW_SYSUSER}
    usermod -aG sudo ${NEW_SYSUSER}
    mkdir -p /home/${NEW_SYSUSER}/.ssh/
    chmod 700 /home/${NEW_SYSUSER}/.ssh/
    # Copy current authorized_keys to new user
    cp ~/.ssh/authorized_keys /home/${NEW_SYSUSER}/.ssh/authorized_keys
    chmod 600 /home/${NEW_SYSUSER}/.ssh/authorized_keys
    chown -R ${NEW_SYSUSER}:${NEW_SYSUSER} /home/${NEW_SYSUSER}/.ssh/
    # Config: sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config_backup
    cp files/sshd_config /etc/ssh/sshd_config
    sed -i "s/#Port 22/Port ${SSH_PORT}/" /etc/ssh/sshd_config
    echo "AllowUsers ${SYSUSER}" >> /etc/ssh/sshd_config
    sshd -t
    systemctl restart ssh
    
    # Config: Chrony
    cp files/chrony.conf /etc/chrony/chrony.conf
    systemctl enable chrony
    systemctl restart chrony
    
    # Create swap file
    fallocate -l ${SWAPFILE} /swapfile
    ls -lh /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    swapon --show
    
    # TODO: It requires knowing the value to replace. Find a way to get it from /etc/fstab
    # sed -i "s/defaults,discard/noatime,nodelalloc,barrier=0,i_version,commit=30,inode_readahead_blks=64,rw,errors=remount-ro/" /etc/fstab
    
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    # Validate fstab
    mount -a

    # Config: ZRAM
    echo "ALLOCATION=${ZRAM}" >> /etc/default/zramswap
    systemctl enable zramswap.service
    systemctl restart zramswap.service
    
    # Performance
    cp files/limits.conf /etc/security/limits.conf
    
    cp files/sysctl.conf /etc/sysctl.conf
    
    sysctl -p /etc/sysctl.conf
    
    cp files/rc.local /etc/rc.local
    
    read -r -p "Do you want to restart now? [Y/n]" response
    case "$response" in
        [nN])
            true
        ;;
        *)
            reboot
        ;;
    esac
    
}

fnInstallNode() {
    echo "Install node"

    while true ; do
        read -p "Enter NETWORK (testnet|mainnet): " NETWORK
        if [ "$NETWORK" = "testnet" ] || [ "$NETWORK" = "mainnet" ]; then
            break
        else
            echo "Invalid: choose testnet or mainnet"$'\n'
        fi
    done
    echo "NETWORK: $NETWORK"    

    while true ; do
        read -p "Enter node type producer or relay (producer|relay): " NODE_TYPE
        if [ "$NODE_TYPE" = "relay" ] || [ "$NODE_TYPE" = "producer" ]; then
            break
        else
            echo "Invalid: choose producer or relay"$'\n'
        fi
    done
    echo "NODE: $NODE_TYPE"

    read -p "Enter pool ticker [AAAA]: " POOL_NAME
    POOL_NAME=${POOL_NAME:-"AAAA"}
    echo "POOL: $POOL_NAME"
    
    read -p "Enter ssh port [22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-"22"}
    echo ${SSH_PORT}

    read -p "Enter ${NODE_TYPE} port [6000]: " CNODE_PORT
        CNODE_PORT=${CNODE_PORT:-"6000"}
        echo ${CNODE_PORT}
    
    if [ "$NODE_TYPE" = "relay" ]; then
        ufw default deny incoming
        ufw default allow outgoing
        ufw limit proto tcp from any to any port ${SSH_PORT}
        ufw allow ${CNODE_PORT}/tcp
    else
        # TODO: Ask if you want to add another relay
        read -p "Enter relay ip: " RELAY_IP
        RELAY_IP=${RELAY_IP:-"127.0.0.1"}
        echo ${RELAY_IP}

        ufw default deny incoming
        ufw default allow outgoing
        ufw limit proto tcp from any to any port ${SSH_PORT}
        ufw allow from ${RELAY_IP} to any port ${CNODE_PORT} proto tcp
    fi
    ufw enable

    WORKSPACE=/opt/workspace
    CNODE_HOME=/opt/${NODE_TYPE}/${POOL_NAME}
    HOTKEY_PATH=${CNODE_HOME}/keystore
    TX_RAW_PATH=${CNODE_HOME}/transactions
    CNODE_BUILD_NUM=$(curl https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/index.html | grep -e "build" | sed 's/.*build\/\([0-9]*\)\/download.*/\1/g')

    mkdir -p ${WORKSPACE}
    mkdir -p ${CNODE_HOME}
    mkdir -p ${HOTKEY_PATH}
    mkdir -p ${TX_RAW_PATH}

    echo export CNODE_PORT=${CNODE_PORT} >> ${HOME}/.bashrc
    echo export NETWORK=${NETWORK} >> ${HOME}/.bashrc
    echo export NODE_TYPE=${NODE_TYPE} >> ${HOME}/.bashrc
    echo export POOL_NAME=${POOL_NAME} >> ${HOME}/.bashrc
    echo export WORKSPACE=${WORKSPACE} >> ${HOME}/.bashrc
    echo export CNODE_HOME=${CNODE_HOME} >> ${HOME}/.bashrc
    echo export CARDANO_NODE_SOCKET_PATH=${CNODE_HOME}/db/socket >> ${HOME}/.bashrc
    echo export CNODE_BUILD_NUM=${CNODE_BUILD_NUM} >> ${HOME}/.bashrc
    echo export HOTKEY_PATH=${HOTKEY_PATH} >> ${HOME}/.bashrc
    echo export TX_RAW_PATH=${TX_RAW_PATH} >> ${HOME}/.bashrc
    source ${HOME}/.bashrc

    # Install libsodium
    export LIBSODIUM_CHECKOUT=66f017f1
    mkdir -p ${WORKSPACE}/git && \
    cd ${WORKSPACE}/git && \
    git clone https://github.com/input-output-hk/libsodium && \
    cd libsodium && \
    git checkout ${LIBSODIUM_CHECKOUT} && \
    ./autogen.sh && \
    ./configure && \
    make && \
    make install
    
    # Debian OS pool operators: extra lib linking may be required.
    rm /usr/lib/libsodium.so.23 || true
    ln -s /usr/local/lib/libsodium.so.23.3.0 /usr/lib/libsodium.so.23
    
    # Cabal and GHC
    export BOOTSTRAP_HASKELL_VERBOSE=1
    export BOOTSTRAP_HASKELL_NONINTERACTIVE=1
    export BOOTSTRAP_HASKELL_GHC_VERSION=8.10.4
    export BOOTSTRAP_HASKELL_CABAL_VERSION=3.4.0.0

    # ghcup is an installer for the general purpose language Haskell
    # https://www.haskell.org/ghcup/
    cd ${HOME} && \
    curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
    
    source ${HOME}/.bashrc && \
    chmod +x ${HOME}/.ghcup/bin/ghc && \
    chmod +x ${HOME}/.ghcup/bin/cabal && \
    ${HOME}/.ghcup/bin/ghcup upgrade && \
    ${HOME}/.ghcup/bin/ghcup install cabal ${BOOTSTRAP_HASKELL_CABAL_VERSION} && \
    ${HOME}/.ghcup/bin/ghcup set cabal ${BOOTSTRAP_HASKELL_CABAL_VERSION} && \
    ${HOME}/.ghcup/bin/ghcup install ghc ${BOOTSTRAP_HASKELL_GHC_VERSION} && \
    ${HOME}/.ghcup/bin/ghcup set ghc ${BOOTSTRAP_HASKELL_GHC_VERSION}
    
    # Cardano Node - Source
    mkdir -p ${WORKSPACE}/git
    cd ${WORKSPACE}/git
    git clone https://github.com/input-output-hk/cardano-node.git
    cd cardano-node
    git fetch --all --recurse-submodules --tags
    CARDANO_NODE=$(git describe --tags `git rev-list --tags --max-count=1`)
    echo export CARDANO_NODE=${CARDANO_NODE} >> ${HOME}/.bashrc
    source ${HOME}/.bashrc
    git checkout ${CARDANO_NODE}
    
    # Cardano Node - Build
    PATH=${HOME}/.cabal/bin:${HOME}/.ghcup/bin:${PATH}
    LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH}
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}
    echo export PATH=${PATH} >> ${HOME}/.bashrc
    echo export LD_LIBRARY_PATH=${LD_LIBRARY_PATH} >> ${HOME}/.bashrc
    echo export PKG_CONFIG_PATH=${PKG_CONFIG_PATH} >> ${HOME}/.bashrc
    source ${HOME}/.bashrc
    cd ${WORKSPACE}/git/cardano-node
    ${HOME}/.ghcup/bin/cabal configure -O0 --with-ghc=${HOME}/.ghcup/bin/ghc
    echo -e "package cardano-crypto-praos\n flags: -external-libsodium-vrf" > cabal.project.local
    sed -i ${HOME}/.cabal/config -e "s/overwrite-policy:/overwrite-policy: always/g"
    rm -rf ${WORKSPACE}/git/cardano-node/dist-newstyle/build/x86_64-linux/ghc-${BOOTSTRAP_HASKELL_GHC_VERSION}
    ${HOME}/.ghcup/bin/cabal build cardano-cli cardano-node
    
    # Cardano Node - Install
    cd ${WORKSPACE}/git/cardano-node && \
    ${HOME}/.ghcup/bin/cabal install --installdir /usr/local/bin cardano-cli cardano-node && \
    cardano-node version && \
    cardano-cli version
    
    # Configure the nodes
    cd ${CNODE_HOME} && \
    source ${HOME}/.bashrc  && \
    wget -N https://hydra.iohk.io/build/${CNODE_BUILD_NUM}/download/1/${NETWORK}-byron-genesis.json && \
    wget -N https://hydra.iohk.io/build/${CNODE_BUILD_NUM}/download/1/${NETWORK}-topology.json && \
    wget -N https://hydra.iohk.io/build/${CNODE_BUILD_NUM}/download/1/${NETWORK}-shelley-genesis.json && \
    wget -N https://hydra.iohk.io/build/${CNODE_BUILD_NUM}/download/1/${NETWORK}-config.json && \
    sed -i ${CNODE_HOME}/${NETWORK}-config.json -e "s/TraceBlockFetchDecisions\": false/TraceBlockFetchDecisions\": true/g"
    # (Removed for gLiveView to work): sed -i ${CNODE_HOME}/${NETWORK}-config.json -e "s/\"minSeverity\": \"Info\"/\"minSeverity\": \"Error\"/g"

    GEN_FILE=${CNODE_HOME}/${NETWORK}-shelley-genesis.json
    echo export GEN_FILE=${GEN_FILE} >> ${HOME}/.bashrc
    source ${HOME}/.bashrc
    
    NW=$(jq '.networkId' -r "$GEN_FILE")
    NW_ID=$(jq '.networkMagic' -r "$GEN_FILE")
    
    if [ "$NW" == "Testnet" ]; then
        MAGIC="--testnet-magic $NW_ID"
    else
        MAGIC="--mainnet"
    fi
    
    echo export MAGIC="\"${MAGIC}\"" >> ${HOME}/.bashrc
    source ${HOME}/.bashrc
    
    # for relay nodes: It's possible to reduce memory and cpu usage by setting "TraceMempool" to "false" in mainnet-config.json
    if [ "$NODE_TYPE" = "relay" ]; then sed -i ${CNODE_HOME}/${NETWORK}-config.json -e "s/TraceMempool\": true/TraceMempool\": false/g"; fi
    
    # Add start node script
cat > ${CNODE_HOME}/start-${NODE_TYPE}-node.sh << EOF
#!/bin/bash
PORT=${CNODE_PORT}
HOSTADDR=0.0.0.0
TOPOLOGY=${CNODE_HOME}/${NETWORK}-topology.json
DB_PATH=${CNODE_HOME}/db
SOCKET_PATH=${CNODE_HOME}/db/socket
CONFIG=${CNODE_HOME}/${NETWORK}-config.json
cardano-node run --topology \${TOPOLOGY} --database-path \${DB_PATH} --socket-path \${SOCKET_PATH} --host-addr \${HOSTADDR} --port \${PORT} --config \${CONFIG}
EOF
    
    chmod +x ${CNODE_HOME}/start-${NODE_TYPE}-node.sh
    
    # Systemd: cardano-node
cat > /etc/systemd/system/cardano-node.service << EOF
# The Cardano node service (part of systemd)
# file: /etc/systemd/system/cardano-node.service

[Unit]
Description     = Cardano node service
Wants           = network-online.target
After           = network-online.target

[Service]
User             = ${USER}
Type             = simple
WorkingDirectory = ${CNODE_HOME}
Environment      = "LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH}"
ExecStart        = /bin/bash -c '${CNODE_HOME}/start-${NODE_TYPE}-node.sh'
KillSignal=SIGINT
RestartKillSignal=SIGINT
TimeoutStopSec=2
LimitNOFILE=32768
Restart=always
RestartSec=5
SyslogIdentifier=cardano-node

[Install]
WantedBy	= multi-user.target
EOF

    chmod 644 /etc/systemd/system/cardano-node.service

    systemctl daemon-reload
    systemctl enable cardano-node
    systemctl start cardano-node
    
    # Credits to the Guild Operators for creating gLiveView: https://github.com/cardano-community/guild-operators/blob/master/docs/Scripts/gliveview.md
    cd ${CNODE_HOME} && \
    cp files/gLiveView.sh ${CNODE_HOME}/gLiveView.sh  && \
    cp files/env ${CNODE_HOME}/env  && \
    chmod 755 gLiveView.sh && \
    sed -i env \
    -e "s/\#CONFIG=\"\${CNODE_HOME}\/files\/config.json\"/CONFIG=\"\${CNODE_HOME}\/\${NETWORK}-config.json\"/g" \
    -e "s/\#SOCKET=\"\${CNODE_HOME}\/sockets\/node0.socket\"/SOCKET=\"\${CNODE_HOME}\/db\/socket\"/g" \
    -e "s/\#TOPOLOGY=\"\${CNODE_HOME}\/files\/topology.json\"/TOPOLOGY=\"\${CNODE_HOME}\/\${NETWORK}-topology.json\"/g" \
    -e "s/\CNODE_PORT=\"6000\"/CNODE_PORT=\"\${CNODE_PORT}\"/g"
    
    echo "BEFORE CONTINUING YOU MUST WAIT TO SYNCONIZE YOUR NODE THIS MAY TAKE UP TO 10 HOURS"

    # Clear temp
    rm -fr /var/lib/apt/lists/{apt,dpkg,cache,log} /tmp/* /var/tmp/*

    echo "Finished: Install node"
}

PS3="Select the operation: "

select opt in "Prepare requirements" "Install node" "EXIT"; do
    case $opt in
        "Prepare requirements")
        fnInitSetup;;
        "Install node")
        fnInstallNode;;
        "EXIT")
        break;;
        *)
        echo "Invalid option $REPLY";;
    esac
done