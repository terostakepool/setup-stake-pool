#!/bin/bash
set -e

######## START CHANGE VALUES #########

# Create a 24-word length shelley compatible mnemonic with Daedalus or Yoroi on a offline machine preferred.
export MNEMONIC="example example example example example example example example example example example example example example example example example example example example example example example example"

export NETWORK=testnet
export NW_ID=1097911063

export METADATA_URI="https://www.example.com/metadata.json"

export MARGIN=0.020
export MIN_POOL_COST=340000000
export PLEDGE=1000000000

export RELAY_HOST=relaynode1.example.com
export RELAY_PORT=6000

######## END CHANGE VALUES #########

if [ "$NETWORK" != "testnet" ] && [ "$NODE_TYPE" != "mainnet" ]; then
    echo "Invalid: $NETWORK choose testnet or mainnet"$'\n'
fi

if [ "$NETWORK" == "testnet" ]; then
    export MAGIC="--testnet-magic $NW_ID"
else
    export MAGIC="--mainnet"
fi

# for security reasons: Check and Reinstall wallet
echo "4249326fcf5de7dd53340a29217c090ac92ae23268b594c14610371767ebbb89 *packages/cardano-wallet-2021.4.8-linux64.tar.gz" | shasum -a 256 --check
rm -rf $(pwd)/cardano-wallet-2021.4.8/ || true
tar -xvf packages/cardano-wallet-2021.4.8-linux64.tar.gz
export PATH="$(pwd)/cardano-wallet-2021.4.8:$PATH"

export HOT_TRANSFER_PATH=${HOME}/cold-to-hot
export BACKUP_PATH=${HOME}/backup
export HOTKEY_PATH=${HOME}/keystore
export COLDKEY_PATH=${HOME}/cold-keys
export TX_RAW_PATH=${HOME}/transactions
mkdir -p ${BACKUP_PATH}
mkdir -p ${HOTKEY_PATH}
mkdir -p ${TX_RAW_PATH}
# mkdir -p ${COLDKEY_PATH} # It is created at the moment of creating the wallet.

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

fnPackages7z() {
    if ! which 7z >/dev/null; then
        echo "9b115dee8658ec76945e803c3af219100eee05105f7c774d4fd37f3b687457f2 *packages/p7zip_16.02+dfsg-7build1_amd64.deb" | shasum -a 256 --check
        dpkg -i packages/p7zip_16.02+dfsg-7build1_amd64.deb
        
        echo "efc2d2795fe6c707183a4b7f4146477fc410c478131bf451914d534246d06896 *packages/p7zip-full_16.02+dfsg-7build1_amd64.deb" | shasum -a 256 --check
        dpkg -i packages/p7zip-full_16.02+dfsg-7build1_amd64.deb
    fi
}

fnDRP() {
    ########################## Disaster Recovery Plan #####################
    
    fnPackages7z
    
    mkdir -p ${BACKUP_PATH}/DRP
    
    timestamp=$(date +%s)
    
    echo "A BACKUP WILL BE CREATED BELOW PLEASE TAKE NOTE OF FILE NAME [${BACKUP_PATH}/DRP/cold-backup-${timestamp}.7z] AND YOUR PASSWORD."
    
    7z a \
    -t7z -m0=lzma2 -mx=9 -mfb=64 \
    -md=32m -ms=on -mhe=on -p \
    ${BACKUP_PATH}/DRP/cold-backup-${timestamp}.7z ${COLDKEY_PATH} ${HOTKEY_PATH} ${TX_RAW_PATH}
    
    7z t ${BACKUP_PATH}/DRP/cold-backup-${timestamp}.7z
}

fnColdHotTransfer() {
    
    fnPackages7z
    
    mkdir -p ${HOT_TRANSFER_PATH}
    
    name=$1
    timestamp=$(date +%s)
    
    echo "Creating file [${HOT_TRANSFER_PATH}/cold-to-hot-${name}-${timestamp}.7z] to transfer a producer node."$'\n'
    
    7z a \
    -t7z -m0=lzma2 -mx=9 -mfb=64 \
    -md=32m -ms=on -mhe=on -p \
    ${HOT_TRANSFER_PATH}/cold-to-hot-${name}-${timestamp}.7z ${HOTKEY_PATH} ${TX_RAW_PATH}
    
    7z t ${HOT_TRANSFER_PATH}/cold-to-hot-${name}-${timestamp}.7z
}

########################## extractPoolStakingKeys.sh ###############################
# Based on: https://gist.github.com/ilap/3fd57e39520c90f084d25b0ef2b96894
fnMakeFileExtractPoolStakingKeys () {
cat > $1 << HERE
#!/bin/bash
set -e

CADDR=\${CADDR:=\$( which cardano-address )}
[[ -z "\$CADDR" ]] && { echo "cardano-address cannot be found, exiting..." >&2 ; exit 127; }

CCLI=\${CCLI:=\$( which cardano-cli )}
[[ -z "\$CCLI" ]] && { echo "cardano-cli cannot be found, exiting..." >&2 ; exit 127; }

BECH32=\${BECH32:=\$( which cardano-cli )}
[[ -z "\$BECH32" ]] && { echo "bech32 cannot be found, exiting..." >&2 ; exit 127; }

# Only 24-word length mnemonic is supported only
[[ "\$#" -ne 26 ]] && {
			 	echo "usage: `basename \$0` <change index e.g. 0/1 external/internal>  <ouptut dir> <24-word length mnemonic>" >&2
			 	exit 127
}

IDX=\$1
shift

OUT_DIR="\$1"
[[ -e "\$OUT_DIR"  ]] && {
			 	echo "The \"\$OUT_DIR\" is already exist delete and run again." >&2
			 	exit 127
} || mkdir -p "\$OUT_DIR" && pushd "\$OUT_DIR" >/dev/null

shift
MNEMONIC="\$*"

# Generate the master key from mnemonics and derive the stake account keys
# as extended private and public keys (xpub, xprv)
echo "\$MNEMONIC" |\
"\$CADDR" key from-recovery-phrase Shelley > root.prv

cat root.prv |\
"\$CADDR" key child 1852H/1815H/0H/2/0 > stake.xprv

cat root.prv |\
"\$CADDR" key child 1852H/1815H/0H/\$IDX/0 > payment.xprv

# XPrv/XPub conversion to normal private and public key, keep in mind the
# keypars are not a valind Ed25519 signing keypairs.

echo "Generating $NETWORK wallet..."
if [ "$NETWORK" == "testnet" ]; then
	NETWORK_ID=0
	MAGIC="--testnet-magic $NW_ID"
	CONV="\$BECH32 | \$BECH32 addr_test"
else
	NETWORK_ID=1
	MAGIC="--mainnet"
	CONV="cat"
fi

cat payment.xprv |\
"\$CADDR" key public | tee payment.xpub |\
"\$CADDR" address payment --network-tag \$NETWORK_ID |\
"\$CADDR" address delegation \$(cat stake.xprv | "\$CADDR" key public | tee stake.xpub) |\
tee base.addr_candidate |\
"\$CADDR" address inspect
echo "Generated from 1852H/1815H/0H/\$IDX/0"
if [  "$NETWORK" == "testnet" ]; then
	cat base.addr_candidate | \$BECH32 | \$BECH32 addr_test > base.addr_candidate_test
	mv base.addr_candidate_test base.addr_candidate
fi
cat base.addr_candidate
echo

SESKEY=\$( cat stake.xprv | \$BECH32 | cut -b -128 )\$( cat stake.xpub | \$BECH32)
PESKEY=\$( cat payment.xprv | \$BECH32 | cut -b -128 )\$( cat payment.xpub | \$BECH32)

cat << EOF > stake.skey
{
		"type": "StakeExtendedSigningKeyShelley_ed25519_bip32",
		"description": "",
		"cborHex": "5880\$SESKEY"
}
EOF

cat << EOF > payment.skey
{
		"type": "PaymentExtendedSigningKeyShelley_ed25519_bip32",
		"description": "Payment Signing Key",
		"cborHex": "5880\$PESKEY"
}
EOF

"\$CCLI" shelley key verification-key --signing-key-file stake.skey --verification-key-file stake.evkey
"\$CCLI" shelley key verification-key --signing-key-file payment.skey --verification-key-file payment.evkey

"\$CCLI" shelley key non-extended-key --extended-verification-key-file payment.evkey --verification-key-file payment.vkey
"\$CCLI" shelley key non-extended-key --extended-verification-key-file stake.evkey --verification-key-file stake.vkey

"\$CCLI" shelley stake-address build --stake-verification-key-file stake.vkey $MAGIC > stake.addr
"\$CCLI" shelley address build --payment-verification-key-file payment.vkey $MAGIC > payment.addr
"\$CCLI" shelley address build \
		--payment-verification-key-file payment.vkey \
		--stake-verification-key-file stake.vkey \
		$MAGIC > base.addr

# Fix: add newline at end of file
sed -e '$a\' base.addr_candidate > base.addr_compare

echo "Important the base.addr and the base.addr_compare must be the same"
diff -s base.addr base.addr_compare
cat base.addr base.addr_compare

popd >/dev/null
HERE
}