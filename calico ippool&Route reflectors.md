

# calico ippool&Route reflectors

## 1、calicoctl部署

1、下载安装

```
wget https://github.com/projectcalico/calicoctl/releases/download/v3.18.1/calicoctl
chmod +x calicoctl  && mv calicoctl /usr/bin
```

2、配置calicoctl认证

```text
 cat  > /etc/calico/calicoctl.cfg   << EOF
apiVersion: projectcalico.org/v3
kind: CalicoAPIConfig
metadata:
spec:
  etcdEndpoints: https://10.115.92.43:2379,https://10.115.92.44:2379,https://10.115.92.45:2379
  etcdKeyFile: /opt/calico/ssl/etcd-peer-key.pem 
  etcdCertFile: /opt/calico/ssl/etcd-peer.pem
  etcdCACertFile: /opt/calico/ssl/ca.pem

EOF

[root@node-03 ~]# calicoctl get node  ##验证
NAME        
master-01   
master-03   
node-01     
node-02     
node-03   
```

## 2、k8s集群pod节点CIDR调整

1、删除默认ippool

```
calicoctl get ippool  ##查看当前ippool
NAME                  CIDR            SELECTOR   
default-ipv4-ippool   172.17.0.0/16   all()   

calico delete ippool default-ipv4-ippool  ##删除默认ippool
```

2、设置K8S集群node节点标签

```
kubectl label nodes master-01 rack=43
kubectl label nodes master-03 rack=45
kubectl label nodes node-01 rack=46
kubectl label nodes node-02 rack=47
kubectl label nodes node-03 rack=48
```

3、创建ippool与node节点label关联

```
 cat  > 43-pool.yaml   << EOF
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: rack-43-ippool
spec:
  blockSize: 24
  cidr: 172.17.43.0/24
  ipipMode: Always
  natOutgoing: true
  nodeSelector: rack == "43"
EOF

...分别创建各ippool
```

4、查看验证

```
[root@node-01 pool]# calicoctl get ippool -owide       
NAME             CIDR             NAT    IPIPMODE   VXLANMODE   DISABLED   SELECTOR       
rack-43-ippool   172.17.43.0/24   true   Always     Never       false      rack == "43"   
rack-45-ippool   172.17.45.0/24   true   Always     Never       false      rack == "45"   
rack-46-ippool   172.17.46.0/24   true   Always     Never       false      rack == "46"   
rack-47-ippool   172.17.47.0/24   true   Always     Never       false      rack == "47"   
rack-48-ippool   172.17.48.0/24   true   Always     Never       false      rack == "48"   
```





## 3、calico Route reflectors

默认calico是fill-mesh全互联模式，启用了 BGP 之后，Calico 的默认行为是在每个节点彼此对等的情况下创建完整的内部 BGP（iBGP）连接，这使 Calico 可以在任何 L2 网络（无论是公有云还是私有云）上运行，或者说（如果配了 IPIP）可以在任何不禁止 IPIP 流量的网络上作为 overlay 运行。对于 vxlan overlay，Calico 不使用 BGP。

Full-mesh 模式对于 100 个以内的工作节点或更少节点的中小规模部署非常有用，但是在较大的规模上，Full-mesh 模式效率会降低，较大规模情况下，Calico 官方建议使用 Route reflectors。

1、设置标签，将node-01、node-02作为Route reflectors

```
kubectl label nodes node-01 rr-group-id=rr
kubectl label nodes node-02 rr-group-id=rr
```

2、关闭fill-mesh模式并设置bgp AS号为63113

```
cat > bgp.yaml   << EOF
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  logSeverityScreen: Info
  nodeToNodeMeshEnabled: false
  asNumber: 63113

EOF
```

3、设置node-01/node-02为RR

```YAML
cat > rr-01.yaml   << EOF 
apiVersion: projectcalico.org/v3
kind: Node
metadata:
  creationTimestamp: null
  name: node-01
  labels:
    rr-group-id: "rr"
spec:
  bgp:
    ipv4Address: 10.115.92.46/24
    routeReflectorClusterID: 224.0.0.1
  orchRefs:
  - nodeName: node-01
    orchestrator: k8s
status: {}
EOF
####
 cat > rr-02.yaml  << EOF 
apiVersion: projectcalico.org/v3
kind: Node
metadata:
  creationTimestamp: null
  name: node-02
  labels:
    rr-group-id: "rr"
spec:
  bgp:
    ipv4Address: 10.115.92.47/24
    routeReflectorClusterID: 224.0.0.1
  orchRefs:
  - nodeName: node-02
    orchestrator: k8s
status: {}
EOF
```

4、建立其他节点与RR BGP对等

```
cat > peer-01.yaml << EOF 
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: bgppeer-global-01
spec:
  peerIP: 10.115.92.46
  asNumber: 63113
EOF   
###
cat > peer-02.yaml   << EOF 
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: bgppeer-global-02
spec:
  peerIP: 10.115.92.47
  asNumber: 63113
EOF 

```

4、查看验证

```
[root@node-01 bgp]# calicoctl node status
Calico process is running.

IPv4 BGP status
+--------------+---------------+-------+----------+-------------+
| PEER ADDRESS |   PEER TYPE   | STATE |  SINCE   |    INFO     |
+--------------+---------------+-------+----------+-------------+
| 10.115.5.175 | node specific | up    | 09:48:32 | Established |
| 10.115.92.43 | node specific | up    | 09:48:34 | Established |
| 10.115.92.45 | node specific | up    | 09:48:34 | Established |
| 10.115.92.47 | global        | up    | 09:48:36 | Established |
+--------------+---------------+-------+----------+-------------+

[root@master-01 manifests]# calicoctl node status  ##master-01分别与两个RR建立了BGPPEER
Calico process is running.

IPv4 BGP status
+--------------+-----------+-------+----------+-------------+
| PEER ADDRESS | PEER TYPE | STATE |  SINCE   |    INFO     |
+--------------+-----------+-------+----------+-------------+
| 10.115.92.46 | global    | up    | 09:48:34 | Established |
| 10.115.92.47 | global    | up    | 09:48:36 | Established |
+--------------+-----------+-------+----------+-------------+

[root@master-01 manifests]# ip route sho    ##查看路由
default via 10.115.92.254 dev eth0 
10.115.92.0/24 dev eth0 proto kernel scope link src 10.115.92.43 
blackhole 172.17.43.0/24 proto bird 
172.17.43.1 dev cali3b3d3f40285 scope link 
172.17.43.2 dev calic68db1b4c23 scope link 
172.17.43.3 dev calie0c6040428d scope link 
172.17.43.4 dev califf5b224ff88 scope link 
172.17.45.0/24 via 10.115.92.45 dev tunl0 proto bird onlink 
172.17.46.0/24 via 10.115.92.46 dev tunl0 proto bird onlink 
172.17.47.0/24 via 10.115.92.47 dev tunl0 proto bird onlink 
172.17.48.0/24 via 10.115.5.175 dev tunl0 proto bird onlink 
```

