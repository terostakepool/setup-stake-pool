# setup-stake-pool

Help scripts to build a Cardano Stake Pool.

> This script is under development to use at your own risk.  
> We always recommend trying it first on the testnet

#### - Install nodes

In your block producer and relay nodes you should run the installer
`./instal-node.sh`

 This install script was tested on Ubuntu 20.04.  
 There may be differences in the initial configuration of your Ubuntu distribution, depending on your server provider.

#### - Prepare relay

`./nodes/relay/relay-topology.sh`

Select the menu option "Topology Update".  
This will create a registry in crontab, every hour the information for the registry of your topology will be sent. Look at log in ${CNODE_HOME}/logs  
You must wait 4 hours before you can continue to the next menu option. "Relay topology pull"  

#### - Register pool stake

A table is shown with the operations that you must perform in your block producer node and your air-gapped offline machine

|  | Block Producer  | air-gapped offline machine |
|---|---|---|
| *main script* | `./nodes/producer/producer.sh` | `./cold/producer-cold.sh`  |
| *choose menu*    | Generate KES  |   |
| *transfer*    | `hot-to-cold-kes-{timestamp}.7z` | *Extract file here*  |
| *edit file*   |   | `config.sh`  |
| *choose menu*    |   | Install 7z  |
| *choose menu*    |   | Generate stake keys  |
| *transfer*    | *Extract file here* | `cold-to-hot-stake-address-{timestamp}.7z`  |
| *choose menu* | Start producer mode | |
| *choose menu* | Register stake address | |
| *transfer*    | `hot-to-cold-tx-payment-stake-{timestamp}.7z` | *Extract file here*  |
| *choose menu*    |   | Sign stake account  |
| *transfer*    | *Extract file here* | `cold-to-hot-tx-payment-stake-signed-{timestamp}.7z`  |
| *choose menu*    | Submit stake address  |   |
| *choose menu*    |   | Register pool certificate |
| *transfer*    | *Extract file here* | `cold-to-hot-registration-certificate-{timestamp}.7z`  |
| *choose menu*    | Register stake pool  |   |
| *transfer*    | `hot-to-cold-tx-registration-certificate-{timestamp}.7z` | *Extract file here*  |
| *choose menu*    |   | Sign pool certificate |
| *transfer*    | *Extract file here* | `cold-to-hot-tx-registration-certificate-signed-{timestamp}.7z`  |
| *choose menu*    | Submit stake pool |   |
| *choose menu*    | Topology Updater |   |
| *choose menu*    |   | Get Pool Id |
| *choose menu*    |   | Create backup |
| *choose menu*    | Create backup  |  |

### Support

To report bugs and issues please open a [GitHub Issue](https://github.com/terostakepool/setup-stake-pool/issues).  
Feature requests are best opened as a [discussion thread](https://github.com/terostakepool/setup-stake-pool/discussions).

### Collaboration

If you want to support me please feel free to send some ADA to:  
<span style="font-size:12px;">*addr1qy906qf9lqsxj2nquwy6uzwwha7av60kude42hk2tasm3hmzmhrpy6cpu4p0rvyrnc56yyrjclzyd2fc2accmvwwqm8qlfc5el*</span>

or delegate your stake to my stake pool [TERO](https://adapools.org/pool/07175f6efa70645146007138a4fdd00b9e8db2a73baecdd704ebccfd) — thanks!
