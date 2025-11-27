# Basic L2 EVPN with SONiC using Container Lab

Basic setup of 2 leafs and one spine where one of the leafs is running SONiC, all deployed via container lab.

EVPN L2 running between the SONiC leaf and the other leaf that runs SR Linux and each leaf has one client (Linux CPE) that are all in the same subnet.

The interesting learning curve here is how to create a SONiC container image and how to deploy it and configure it due to the multiple components involved in it, the Linux host and the FRR components of the SONiC device.

![pic1](https://github.com/missoso/basic-clab-sonic-l2-evpn/blob/main/img_and_drawio/setup.png)

# Creating the Container Lab image of SONiC

The starting point are the instructions found here [https://containerlab.dev/manual/kinds/sonic-vs/](https://containerlab.dev/manual/kinds/sonic-vs/) 

1. Go to the pipelines list: https://sonic-build.azurewebsites.net/ui/sonic/pipelines

2. Scroll all the way to the bottom where vs platform is listed

3. Pick a branch name that you want to use (e.g. 202405) and click on the "Build History".

4. On the build history page choose the latest build that has succeeded (check the Result column) and click on the "Artifacts" link

5. In the new window, you will see a list with a single artifact, click on it

6. One more long scroll down until you see target/docker-sonic-vs.gz name (or Ctrl+F for it), click on it to start the download or copy the download link.

The result of the steps above should be : 

```bash
% ls | grep sonic
docker-sonic-vs.gz
```

Gunzip and load it to the docker images local repo

```bash

% gunzip -d docker-sonic-vs.gz 

$ docker load < docker-sonic-vs

$ docker image ls
REPOSITORY                             TAG       IMAGE ID       CREATED         SIZE
docker-sonic-vs                        latest    2d9c647a53df   4 hours ago     797MB 

```

**Caveat #1** : It is not an exact science at all what the image will have, for example when the above was performed the image created had no VXLAN support at the FRR level (meaning all needs to be done at the Linux host level in terms of bridge domains and VXLAN binds) and when it boots the bgpd is set to "no" independently of the contents of the file /etc/frr/daemons

**Caveat #2** : The binds defined in the clab.yaml for the FRR config and daemons setup don't fully work

```bash
    leaf1:
      kind: sonic-vs
      binds:
        - configs/leaf1.cfg:/etc/frr/frr.conf 
        - configs/frr-daemons.conf:/etc/frr/daemons 
      startup-config: configs/leaf1.cfg
      mgmt-ipv4: 172.80.80.11
      group: leaf
```

The files specified in the binds are copied but they are ingored at boot, so after boot the FRR daemons needs to be restarted (so that BGP is enabled) and the configuration needs to be loaded via vtysh

## Deploying the lab

The lab is deployed with the [containerlab](https://containerlab.dev) project, where [`basic-clab-sonic-l2-evpn.clab.yml`](https://github.com/missoso/basic-clab-sonic-l2-evpn/blob/main/basic-clab-sonic-l2-evpn.clab.yml) file declaratively describes the lab topology.

```bash
# change into the cloned directory
# and execute
containerlab deploy --reconfigure
```

To remove the lab:

```bash
containerlab destroy --cleanup
```

## Access the lab

SRL nodes using SSH through their management IP address or their hostname as defined in the topology file.

```bash
# reach a SR Linux leaf or a spine via SSH
ssh admin@leaf2
ssh admin@spine1
```
SONiC and Linux clients cannot be reached via SSH, as it is not enabled, but it is possible to connect to them with a docker exec command.

```bash
# reach a Linux client via Docker
docker exec -it client1 bash
```

# SONiC - Setup required after boot 

After the SONiC container has booted the following actions are required: 

1 - Restart FRR so that bgpd is enabled (see caveat #1)

```bash
$ docker exec -it leaf1 bash
root@leaf1:/# service frr restart
```

2 - Load the configuration (see caveat #2 above)
```bash
$ docker exec -it leaf1 bash
root@leaf1:/# vtysh -f /etc/frr/frr.conf
```

3 - Configure the vxlan and br interfaces
```bash
ip link add vxlan100 type vxlan id 100 dstport 4789 local 10.0.1.1 nolearning
brctl addbr br100
brctl addif br100 vxlan100   
brctl stp br100 off
ip link set up dev br100   
ip link set up dev vxlan100   
ip link set eth1 master br100
ip link set eth1 up
```

10.0.1.1 is the RID of Leaf1 and 100 is the VNI to be used


**Caveat #3** : It is not ideal to have "nolearning" used in the vxlan interface, however, without it the routes were exchanged between leafs but the ping between clients would not work, because there was a MAC learning issue in the br interface at the SONiC box, and the usage of the br interface is mandatory since this is layer 2 EVPN (unclear what was then root cause so just used nolearning), this issue will not exist for layer 3 EVPN.

# Client 1 and 2 MAC addresses 

Of couse every time this setup is deployed the MAC addresses will be different, this is only added here to make the show commands output easier to follow

```bash
$ docker exec -it client1 bash
[*]─[client1]─[/]
└──> ifconfig
eth1      Link encap:Ethernet  HWaddr AA:C1:AB:CF:85:E3  
```

```bash
$ docker exec -it client2 bash
[*]─[client2]─[/]
└──> ifconfig
eth1      Link encap:Ethernet  HWaddr AA:C1:AB:A7:B8:67 
```

# SONiC - check EVPN routes

10.0.1.1 is this leaf, 10.0.1.2 is the other leaf

aa:c1:ab:a7:b8:67 is client 2

```bash
leaf1# show bgp l2vpn evpn
BGP table version is 3, local router ID is 10.0.1.1
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal
Origin codes: i - IGP, e - EGP, ? - incomplete
EVPN type-1 prefix: [1]:[EthTag]:[ESI]:[IPlen]:[VTEP-IP]:[Frag-id]
EVPN type-2 prefix: [2]:[EthTag]:[MAClen]:[MAC]:[IPlen]:[IP]
EVPN type-3 prefix: [3]:[EthTag]:[IPlen]:[OrigIP]
EVPN type-4 prefix: [4]:[ESI]:[IPlen]:[OrigIP]
EVPN type-5 prefix: [5]:[EthTag]:[IPlen]:[IP]

   Network          Next Hop            Metric LocPrf Weight Path
Route Distinguisher: 10.0.1.1:100
 *>  [2]:[0]:[48]:[aa:c1:ab:cf:85:e3]
                    10.0.1.1                           32768 i
                    ET:8 RT:65000:100
 *>  [2]:[0]:[48]:[aa:c1:ab:ee:da:7b]:[128]:[fe80::ac02:5cff:fe50:d11b]
                    10.0.1.1                           32768 i
                    ET:8 RT:65000:100
 *>  [3]:[0]:[32]:[10.0.1.1]
                    10.0.1.1                           32768 i
                    ET:8 RT:65000:100
Route Distinguisher: 10.0.1.2:100
 *>  [2]:[0]:[48]:[aa:c1:ab:a7:b8:67]
                    10.0.1.2                      100      0 100 201 i
                    RT:65000:100 ET:8
 *>  [3]:[0]:[32]:[10.0.1.2]
                    10.0.1.2                      100      0 100 201 i
                    RT:65000:100 ET:8

Displayed 5 out of 5 total prefixes
```

# SR Linux - check EVPN routes

10.0.1.2 is this leaf, 10.0.1.1 is the other leaf

AA:C1:AB:CF:85:E3 is client 1

```bash
--{ running }--[  ]--
A:leaf2# show network-instance vrf-1 bridge-table mac-table all
-----------------------------------------------------------------------------------------------------------------
Mac-table of network instance vrf-1
-----------------------------------------------------------------------------------------------------------------
+------------------+-------------------------+-----------+--------+--------+-------+-------------------------+
|     Address      |       Destination       |   Dest    |  Type  | Active | Aging |       Last Update       |
|                  |                         |   Index   |        |        |       |                         |
+==================+=========================+===========+========+========+=======+=========================+
| AA:C1:AB:A7:B8:6 | ethernet-1/1.0          | 2         | learnt | true   | 255   | 2025-11-                |
| 7                |                         |           |        |        |       | 27T13:35:40.000Z        |
| AA:C1:AB:CF:85:E | vxlan-                  | 182637367 | evpn   | true   | N/A   | 2025-11-                |
| 3                | interface:vxlan1.1      | 184       |        |        |       | 27T13:40:08.000Z        |
|                  | vtep:10.0.1.1 vni:100   |           |        |        |       |                         |
| AA:C1:AB:EE:DA:7 | vxlan-                  | 182637367 | evpn   | true   | N/A   | 2025-11-                |
| B                | interface:vxlan1.1      | 184       |        |        |       | 27T13:40:08.000Z        |
|                  | vtep:10.0.1.1 vni:100   |           |        |        |       |                         |
+------------------+-------------------------+-----------+--------+--------+-------+-------------------------+
Total Irb Macs                 :    0 Total    0 Active
Total Static Macs              :    0 Total    0 Active
Total Duplicate Macs           :    0 Total    0 Active
Total Learnt Macs              :    1 Total    1 Active
Total Evpn Macs                :    2 Total    2 Active
Total Evpn static Macs         :    0 Total    0 Active
Total Irb anycast Macs         :    0 Total    0 Active
Total Proxy Antispoof Macs     :    0 Total    0 Active
Total Reserved Macs            :    0 Total    0 Active
Total Eth-cfm Macs             :    0 Total    0 Active
Total Irb Vrrps                :    0 Total    0 Active
```

# Connectivity between clients

```bash
$ sh pings.sh 
pings from client 1
PING 10.10.10.2 (10.10.10.2) 56(84) bytes of data.
64 bytes from 10.10.10.2: icmp_seq=1 ttl=64 time=1.53 ms
64 bytes from 10.10.10.2: icmp_seq=2 ttl=64 time=1.58 ms

--- 10.10.10.2 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1002ms
rtt min/avg/max/mdev = 1.534/1.555/1.576/0.021 ms
pings from client 2
PING 10.10.10.2 (10.10.10.2) 56(84) bytes of data.
64 bytes from 10.10.10.2: icmp_seq=1 ttl=64 time=0.166 ms
64 bytes from 10.10.10.2: icmp_seq=2 ttl=64 time=0.088 ms

--- 10.10.10.2 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 0.088/0.127/0.166/0.039 ms
```

