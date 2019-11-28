#!/bin/bash

####
# 1. Set Initial Variables
####

# For Tor V3 client authentication (optional), user can run standup.sh like: ./standup.sh descriptor:x25519:NWJNEFU487H2BI3JFNKJENFKJWI3
# and it will automatically add the pubkey to the authorized_clients directory, which is great because the user is Tor authenticated before the
# node is even installed.

PUBKEY=$1

# This block defines the variables the user of the script needs to input
# when deploying using this script.

# <UDF name="btctype" label="Installation Type" oneOf="Mainnet,Pruned Mainnet,Testnet,Pruned Testnet,Private Regtest" default="Testnet" example="Bitcoin node type" />
BTCTYPE="Pruned Testnet"
# <UDF name="hostname" label="Short Hostname" example="Example: bitcoincore-testnet-pruned" />
HOSTNAME="bitcoincore-testnet-pruned"
# <UDF name="fqdn" label="Fully Qualified Hostname" example="Example: bitcoincore-testnet-pruned.local or bitcoincore-testnet-pruned.domain.com"/>
FQDN="bitcoincore-testnet-pruned.local"
# <UDF name="userpassword" label="user1 Password" example="Password to for the user1 non-privileged account." />
USERPASSWORD="lul1b13s"
# <UDF name="ssh_key" label="SSH Key" default="" example="Key for automated logins to user1 non-privileged account." optional="true" />
SSH_KEY="standupbitcoin"
# <UDF name="sys_ssh_ip" label="SSH-Allowed IPs" default="" example="Comma separated list of IPs that can use SSH" optional="true" />
SYS_SSH_IP=""


####
# 2. Install latest stable tor
####

# Force check for root
if ! [ "$(id -u)" = 0 ]; then
  echo "You need to be logged in as root!"
  exit 1
fi

# Output stdout and stderr to ~root files
exec > >(tee -a /root/standup.log) 2> >(tee -a /root/standup.log /root/standup.err >&2)

# Download tor

#  To use source lines with https:// in /etc/apt/sources.list the apt-transport-https package is required. Install it with:
sudo apt install apt-transport-https

# We need to set up our package repository before you can fetch Tor. First, you need to figure out the name of your distribution:
DEBIAN_VERSION=$(lsb_release -c | awk '{ print $2 }')

# You need to add the following entries to /etc/apt/sources.list:
cat >> /etc/apt/sources.list << EOF
deb https://deb.torproject.org/torproject.org $DEBIAN_VERSION main
deb-src https://deb.torproject.org/torproject.org $DEBIAN_VERSION main
EOF

# Then add the gpg key used to sign the packages by running:
sudo curl https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc | gpg --import
sudo gpg --export A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89 | apt-key add -

# Update system, install and run tor as a service
sudo apt update
sudo apt install tor deb.torproject.org-keyring

# Setup hidden service
sed -i -e 's/#ControlPort 9051/ControlPort 9051/g' /etc/tor/torrc
sed -i -e 's/#CookieAuthentication 1/CookieAuthentication 1/g' /etc/tor/torrc
sed -i -e 's/## address y:z./## address y:z.\
\
HiddenServiceDir \/var\/lib\/tor\/standup\/\
HiddenServiceVersion 3\
HiddenServicePort 1309 127.0.0.1:18332\
HiddenServicePort 1309 127.0.0.1:18443\
HiddenServicePort 1309 127.0.0.1:8332/g' /etc/tor/torrc
mkdir /var/lib/tor/standup
chown -R debian-tor:debian-tor /var/lib/tor/standup
chmod 700 /var/lib/tor/standup

# start tor and our hidden service
sudo systemctl restart tor

# add V3 authorized_clients public key if one exists

if ! [ $PUBKEY == "" ]; then
  echo $PUBKEY > /var/lib/tor/standup/authorized_clients/fullynoded.auth
else
  echo "No Tor V3 authentication, anyone who gets access to your QR code can have full access to your node,
  ensure you do not store more then you are willing to lose and better yet use the node as a watch-only wallet"
fi

# get uncomplicated firewall
sudo apt-get install ufw
ufw allow ssh
ufw enable

# CURRENT BITCOIN RELEASE:
# Change as necessary

export BITCOIN=bitcoin-core-0.19.0.1

####
# 3. Set Up User
####

# Create "user1" with optional password and give them sudo capability

/usr/sbin/useradd -m -p `perl -e 'printf("%s\n",crypt($ARGV[0],"password"))' "$USERPASSWORD"` -g sudo -s /bin/bash user1
/usr/sbin/adduser user1 sudo

# Add user1 to the tor group so that the tor authentication cookie can be read by bitcoind
sudo usermod -a -G debian-tor user1

echo "$0 - Setup user1 with sudo access."

####
# 5. Bring Debian Up To Date
####

echo "$0 - Starting Debian updates; this will take a while!"

# Make sure all packages are up-to-date

apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y

# Install emacs (a good text editor), haveged (a random number generator

apt-get install emacs -y
apt-get install haveged -y

# Set system to automatically update

echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
apt-get -y install unattended-upgrades

echo "$0 - Updated Debian Packages"

####
# 7. Install Bitcoin
####

# Download Bitcoin

echo "$0 - Downloading Bitcoin; this will also take a while!"

export BITCOINPLAIN=`echo $BITCOIN | sed 's/bitcoin-core/bitcoin/'`

sudo -u user1 wget https://bitcoincore.org/bin/$BITCOIN/$BITCOINPLAIN-x86_64-linux-gnu.tar.gz -O ~user1/$BITCOINPLAIN-x86_64-linux-gnu.tar.gz
sudo -u user1 wget https://bitcoincore.org/bin/$BITCOIN/SHA256SUMS.asc -O ~user1/SHA256SUMS.asc
sudo -u user1 wget https://bitcoincore.org/laanwj-releases.asc -O ~user1/laanwj-releases.asc

# Verifying Bitcoin: Signature

echo "$0 - Verifying Bitcoin."

sudo -u user1 /usr/bin/gpg --no-tty --import ~user1/laanwj-releases.asc
export SHASIG=`sudo -u user1 /usr/bin/gpg --no-tty --verify ~user1/SHA256SUMS.asc 2>&1 | grep "Good signature"`
echo "SHASIG is $SHASIG"

if [[ $SHASIG ]]; then
    echo "VERIFICATION SUCCESS / SIG: $SHASIG"
else
    (>&2 echo "VERIFICATION ERROR: Signature for Bitcoin did not verify!")
fi

# Verify Bitcoin: SHA

export TARSHA256=`/usr/bin/sha256sum ~user1/$BITCOINPLAIN-x86_64-linux-gnu.tar.gz | awk '{print $1}'`
export EXPECTEDSHA256=`cat ~user1/SHA256SUMS.asc | grep $BITCOINPLAIN-x86_64-linux-gnu.tar.gz | awk '{print $1}'`

if [ "$TARSHA256" == "$EXPECTEDSHA256" ]; then
   echo "VERIFICATION SUCCESS / SHA: $TARSHA256"
else
    (>&2 echo "VERIFICATION ERROR: SHA for Bitcoin did not match!")
fi

# Install Bitcoin

echo "$0 - Installinging Bitcoin."

sudo -u user1 /bin/tar xzf ~user1/$BITCOINPLAIN-x86_64-linux-gnu.tar.gz -C ~user1
/usr/bin/install -m 0755 -o root -g root -t /usr/local/bin ~user1/$BITCOINPLAIN/bin/*
/bin/rm -rf ~user1/$BITCOINPLAIN/

# Start Up Bitcoin

echo "$0 - Starting Bitcoin."

sudo -u user1 /bin/mkdir ~user1/.bitcoin

# The only variation between Mainnet and Testnet is that Testnet has the "testnet=1" variable
# The only variation between Regular and Pruned is that Pruned has the "prune=550" variable, which is the smallest possible prune

RPCPASSWORD=$(xxd -l 16 -p /dev/urandom)

cat >> ~user1/.bitcoin/bitcoin.conf << EOF
server=1
dbcache=1536
par=1
maxuploadtarget=137
maxconnections=16
rpcuser=StandUp
rpcpassword=$RPCPASSWORD
rpcallowip=127.0.0.1
debug=tor
[test]
rpcbind=127.0.0.1
rpcport=18332
[main]
rpcbind=127.0.0.1
rpcport=8332
[regtest]
rpcbind=127.0.0.1
rpcport=18443
EOF

if [ "$BTCTYPE" == "Mainnet" ]; then

cat >> ~user1/.bitcoin/bitcoin.conf << EOF
txindex=1
EOF

elif [ "$BTCTYPE" == "Pruned Mainnet" ]; then

cat >> ~user1/.bitcoin/bitcoin.conf << EOF
prune=550
EOF

elif [ "$BTCTYPE" == "Testnet" ]; then

cat >> ~user1/.bitcoin/bitcoin.conf << EOF
txindex=1
testnet=1
EOF

elif [ "$BTCTYPE" == "Pruned Testnet" ]; then

cat >> ~user1/.bitcoin/bitcoin.conf << EOF
prune=550
testnet=1
EOF

elif [ "$BTCTYPE" == "Private Regtest" ]; then

  (>&2 echo "$0 - ERROR: Private Regtest is not setup yet.")

else

  (>&2 echo "$0 - ERROR: Somehow you managed to select no Bitcoin Installation Type, so Bitcoin hasn't been properly setup. Whoops!")

fi

/bin/chown user1 ~user1/.bitcoin/bitcoin.conf
/bin/chmod 600 ~user1/.bitcoin/bitcoin.conf

sudo -u user1 /usr/local/bin/bitcoind -daemon

# Add Bitcoin Startup to Crontab for user1

sudo -u user1 sh -c '( /usr/bin/crontab -l -u user1 2>/dev/null; echo "@reboot /usr/local/bin/bitcoind -daemon" ) | /usr/bin/crontab -u user1 -'

# Show the user the QuickConnect QR
sudo -u user1 touch ~user1/BITCOIN-IS-READY
HS_HOSTNAME=$(sudo cat /var/lib/tor/standup/hostname)
QR="btcstandup://StandUp:$RPCPASSWORD@$HS_HOSTNAME:1309/?label=StandUp.sh"
echo "Ready to display the QuickConnect QR, first we need to install qrencode and fim"
sudo apt-get install qrencode
sudo apt-get install fim
qrencode -m 10 -o qrcode.png "$QR"
fim -a qrcode.png
