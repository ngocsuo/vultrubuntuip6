#!/bin/sh

USER=n2l
PASS=N2l123

FIRST_PORT=10000
LAST_PORT=10350

WORKDIR="/home/3proxy"
WORKDATA="${WORKDIR}/data.txt"

random() {
	tr </dev/urandom -dc A-Za-z0-9 | head -c5
	echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
	ip64() {
		echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
	}
	echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_3proxy() {
    echo "installing 3proxy"
    mkdir -p /tmp/3proxy
    cd /tmp/3proxy
    wget -qO- "https://github.com/z3APA3A/3proxy/archive/0.9.3.tar.gz" | tar -xvz
    cd 3proxy-0.9.3
    make -f Makefile.Linux

    cp bin/3proxy $WORKDIR
}

optimize_system() {
    if cat /etc/sysctl.conf | grep -q '#PROXY_CUSTOM'; then
        return
    fi

    # systemctl enable 3proxy
    echo "session required pam_limits.so" >> /etc/pam.d/common-session

cat <<EOF >> /etc/security/limits.conf
#PROXY_CUSTOM
* hard nproc 65535
* soft nproc 65535
* hard nofile 65535
* soft nofile 65535
root hard nproc 65535
root soft nproc 65535
root hard nofile 65535
root soft nofile 65535
EOF

cat <<EOF >> /etc/sysctl.conf
#PROXY_CUSTOM
fs.file-max=65535

vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2

net.ipv4.tcp_synack_retries = 2
net.ipv4.ip_local_port_range = 2000 65535
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.core.rmem_default = 31457280
net.core.rmem_max = 12582912
net.core.wmem_default = 31457280
net.core.wmem_max = 12582912
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.optmem_max = 25165824
net.ipv4.tcp_mem = 65535 131072 262144
net.ipv4.udp_mem = 65535 131072 262144
net.ipv4.tcp_rmem = 8192 87380 16777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.tcp_wmem = 8192 65535 16777216
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_reuse = 1

net.ipv6.conf.enp1s0.proxy_ndp=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.enp1s0.accept_ra=2
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
net.ipv6.ip_nonlocal_bind=1
EOF
    sysctl -p
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 20000
nserver 8.8.8.8
nserver 8.8.4.4
nserver 1.1.1.1
nserver 2606:4700:4700::64
nserver 2606:4700:4700::6400
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6000
flush
auth strong
users ${USER}:CL:${PASS}
allow ${USER}
$(awk -F "/" '{print "proxy -6 -n -a -p" $4 " -i" $3 " -e"$5""}' ${WORKDATA})
flush
EOF
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "${USER}/${PASS}/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_iptables() {
    cat <<EOF
    $(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}) 
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig enp1s0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}


# START SCRIPTS
if [ -d "$WORKDIR" ]; then
  # Take action if $DIR exists. #
  echo "Proxy installed!!! Exit!"
  exit
fi

echo "Installing proxy to folder: ${WORKDIR}"
mkdir $WORKDIR && cd $_

echo "installing complier..."
#apt update --fix-missing
apt -y install net-tools gcc make

INETWORK=$(ip route get 8.8.8.8 | sed -nr 's/.*dev ([^\ ]+).*/\1/p')

echo "installing 3proxy..."
install_3proxy

echo "optimize system..."
optimize_system

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal ip = ${IP4}. Exteranl sub for ip6 = ${IP6}. NETWORK INTERFACE: ${INETWORK}"

gen_data >$WORKDIR/data.txt
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x $WORKDIR/boot_*.sh

gen_3proxy >$WORKDIR/3proxy.cfg

cat >>/etc/rc.local <<EOF
#!/bin/sh
ulimit -n 600000
ulimit -u 600000
ulimit -i 20000
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh

ps -ef | grep '3proxy' | grep -v grep | awk '{print $2}' | xargs kill -9
${WORKDIR}/3proxy ${WORKDIR}/3proxy.cfg &
EOF

if free | awk '/^Swap:/ {exit !$2}'; then
    echo 'Swap exist!'
else
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

chmod +x /etc/rc.local
bash /etc/rc.local

echo "Finished!"
echo "Proxy created on: ${WORKDIR}/data.txt"

cat "${WORKDIR}/data.txt"
