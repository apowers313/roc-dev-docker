#!/bin/bash

# import .env variables
export $(cat .env | xargs)

ip link show $MACVLAN_LOOPBACK_INTERFACE >/dev/null 2>/dev/null
macvlan_not_setup=$?
if [ $macvlan_not_setup -eq 1 ]; then
    # https://blog.oddbit.com/post/2018-03-12-using-docker-macvlan-networks/
    echo "Setting up loopback network on interface $MACVLAN_LOOPBACK_INTERFACE"
    ip link add $MACVLAN_LOOPBACK_INTERFACE link $NETWORK_INTERFACE type macvlan mode bridge
    ip addr add $NETWORK_AUX_ADDR/32 dev $MACVLAN_LOOPBACK_INTERFACE
    ip link set $MACVLAN_LOOPBACK_INTERFACE up
    ip route add $NETWORK_SUBNET dev $MACVLAN_LOOPBACK_INTERFACE
else
    echo "Loopback network already exists on interface $MACVLAN_LOOPBACK_INTERFACE"
fi

