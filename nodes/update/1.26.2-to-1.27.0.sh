#!/bin/bash
set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

source ${HOME}/.bashrc
cd ${WORKSPACE}/git
git clone https://github.com/input-output-hk/cardano-node.git cardano-node-1.27.0
cd cardano-node-1.27.0/
cabal update
git fetch --all --recurse-submodules --tags
CARDANO_NODE=$(git describe --tags `git rev-list --tags --max-count=1`)
echo export CARDANO_NODE=${CARDANO_NODE} >> ${HOME}/.bashrc
source ${HOME}/.bashrc
git checkout ${CARDANO_NODE}
${HOME}/.ghcup/bin/cabal configure -O0 --with-ghc=${HOME}/.ghcup/bin/ghc
echo -e "package cardano-crypto-praos\n flags: -external-libsodium-vrf" > cabal.project.local
${HOME}/.ghcup/bin/cabal build cardano-cli cardano-node
$(find ${WORKSPACE}/git/cardano-node-1.27.0/dist-newstyle/build -type f -name "cardano-cli") version
$(find ${WORKSPACE}/git/cardano-node-1.27.0/dist-newstyle/build -type f -name "cardano-node") version
systemctl stop cardano-node
killall -s 2 cardano-node
${HOME}/.ghcup/bin/cabal install --installdir /usr/local/bin cardano-cli cardano-node --overwrite-policy=always
systemctl start cardano-node