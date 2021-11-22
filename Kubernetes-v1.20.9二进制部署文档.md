 

## 一、部署Etcd集群

Etcd 是一个分布式键值存储系统，Kubernetes使用Etcd进行数据存储，所以先准备一个Etcd数据库，为解决Etcd单点故障，应采用集群方式部署，这里使用3台组建集群，可容忍1台机器故障，当然，你也可以使用5台组建集群，可容忍2台机器故障。

| **节点名称** | **IP**       |
| ------------ | ------------ |
| etcd-1       | 10.115.92.43 |
| etcd-2       | 10.115.92.44 |
| etcd-3       | 10.115.92.45 |

### 1.1 准备cfssl证书生成工具

cfssl是一个开源的证书管理工具，使用json文件生成证书，相比openssl更方便使用。

找任意一台服务器操作，这里用Master节点。

```
wget https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
wget https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
wget https://pkg.cfssl.org/R1.2/cfssl-certinfo_linux-amd64
chmod +x cfssl_linux-amd64 cfssljson_linux-amd64 cfssl-certinfo_linux-amd64
mv cfssl_linux-amd64 /usr/local/bin/cfssl
mv cfssljson_linux-amd64 /usr/local/bin/cfssljson
mv cfssl-certinfo_linux-amd64 /usr/bin/cfssl-certinfo
```

### 1.2 生成Etcd证书

#### 1. 自签证书颁发机构（CA）

创建工作目录：

```
mkdir -p ~/TLS/{etcd,k8s}

cd ~/TLS/etcd
```

自签CA：

```
cat > ca-config.json << EOF
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "www": {
         "expiry": "87600h",
         "usages": [
            "signing",
            "key encipherment",
            "server auth",
            "client auth"
        ]
      }
    }
  }
}
EOF

cat > ca-csr.json << EOF
{
    "CN": "etcd CA",
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "L": "Beijing",
            "ST": "Beijing"
        }
    ]
}
EOF
```

生成证书：

```
cfssl gencert -initca ca-csr.json | cfssljson -bare ca -
```

会生成ca.pem和ca-key.pem文件。

#### 2. 使用自签CA签发Etcd HTTPS证书

创建证书申请文件：

```
cat > server-csr.json << EOF
{
    "CN": "etcd",
    "hosts": [
    "10.115.92.43",
    "10.115.92.44",
    "10.115.92.45"
    ],
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "L": "BeiJing",
            "ST": "BeiJing"
        }
    ]
}
EOF
```

注：上述文件hosts字段中IP为所有etcd节点的集群内部通信IP，一个都不能少！为了方便后期扩容可以多写几个预留的IP。

生成证书：

```
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=www server-csr.json | cfssljson -bare server
```

会生成server.pem和server-key.pem文件。

### 1.3 从Github下载二进制文件

官网：https://etcd.io/

下载地址：

https://github.com/etcd-io/etcd/releases/download/v3.5.0/etcd-v3.5.0-linux-amd64.tar.gz

https://github.com/etcd-io/etcd/releases/download/v3.4.9/etcd-v3.4.9-linux-amd64.tar.gz

### 1.4 部署Etcd集群

以下在节点1上操作，为简化操作，待会将节点1生成的所有文件拷贝到节点2和节点3.

#### 1. 创建工作目录并解压二进制包

```
mkdir /opt/etcd/{bin,cfg,ssl} -p
tar zxvf etcd-v3.4.9-linux-amd64.tar.gz
mv etcd-v3.4.9-linux-amd64/{etcd,etcdctl} /opt/etcd/bin/
```

#### 2. 创建etcd配置文件

```
cat > /opt/etcd/cfg/etcd.conf << EOF
#[Member]
ETCD_NAME="etcd-01"
ETCD_DATA_DIR="/data/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="https://10.115.92.43:2380"
ETCD_LISTEN_CLIENT_URLS="https://10.115.92.43:2379"

#[Clustering]
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://10.115.92.43:2380"
ETCD_ADVERTISE_CLIENT_URLS="https://10.115.92.43:2379"
ETCD_INITIAL_CLUSTER="etcd-1=https://10.115.92.43:2380,etcd-02=https://10.115.92.44:2380,etcd-03=https://10.115.92.45:2380"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF
```

•   ETCD_NAME：节点名称，集群中唯一

•   ETCD_DATA_DIR：数据目录

•   ETCD_LISTEN_PEER_URLS：集群通信监听地址

•   ETCD_LISTEN_CLIENT_URLS：客户端访问监听地址

•   ETCD_INITIAL_ADVERTISE_PEERURLS：集群通告地址

•   ETCD_ADVERTISE_CLIENT_URLS：客户端通告地址

•   ETCD_INITIAL_CLUSTER：集群节点地址

•   ETCD_INITIALCLUSTER_TOKEN：集群Token

•   ETCD_INITIALCLUSTER_STATE：加入集群的当前状态，new是新集群，existing表示加入已有集群

#### 3. systemd管理etcd

```
cat > /usr/lib/systemd/system/etcd.service << EOF
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=/opt/etcd/cfg/etcd.conf
ExecStart=/opt/etcd/bin/etcd \
--cert-file=/opt/etcd/ssl/server.pem \
--key-file=/opt/etcd/ssl/server-key.pem \
--peer-cert-file=/opt/etcd/ssl/server.pem \
--peer-key-file=/opt/etcd/ssl/server-key.pem \
--trusted-ca-file=/opt/etcd/ssl/ca.pem \
--peer-trusted-ca-file=/opt/etcd/ssl/ca.pem \
--logger=zap
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

#### 4. 拷贝刚才生成的证书

把刚才生成的证书拷贝到配置文件中的路径：

```
cp ~/TLS/etcd/ca*pem ~/TLS/etcd/server*pem /opt/etcd/ssl/
```

#### 5. 启动并设置开机启动

```
systemctl daemon-reload
systemctl start etcd
systemctl enable etcd
```

#### 6. 将上面节点1所有生成的文件拷贝到节点2和节点3

```
scp -r /opt/etcd/ root@10.115.92.44:/opt/
scp /usr/lib/systemd/system/etcd.service root@10.115.92.44:/usr/lib/systemd/system/
scp -r /opt/etcd/ root@10.115.92.45:/opt/
scp /usr/lib/systemd/system/etcd.service root@10.115.92.45:/usr/lib/systemd/system/
```

然后在节点2和节点3分别修改etcd.conf配置文件中的节点名称和当前服务器IP：

```
vi /opt/etcd/cfg/etcd.conf
#[Member]
ETCD_NAME="etcd-1"   # 修改此处，节点2改为etcd-2，节点3改为etcd-3
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="https://10.115.92.43:2380"   # 修改此处为当前服务器IP
ETCD_LISTEN_CLIENT_URLS="https://10.115.92.43:2379" # 修改此处为当前服务器IP

#[Clustering]
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://10.115.92.43:2380" # 修改此处为当前服务器IP
ETCD_ADVERTISE_CLIENT_URLS="https://10.115.92.43:2379" # 修改此处为当前服务器IP
ETCD_INITIAL_CLUSTER="etcd-1=https://10.115.92.43:2380,etcd-2=https://10.115.92.44:2380,etcd-3=https://10.115.92.45:2380"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
```

最后启动etcd并设置开机启动，同上。

#### 7. 查看集群状态

```
ETCDCTL_API=3 /opt/etcd/bin/etcdctl --cacert=/opt/etcd/ssl/ca.pem --cert=/opt/etcd/ssl/server.pem --key=/opt/etcd/ssl/server-key.pem --endpoints="https://10.115.92.43:2379,https:// 10.115.92.44:2379,https:// 10.115.92.45:2379" endpoint health --write-out=table

+----------------------------+--------+-------------+-------+
|          ENDPOINT    | HEALTH |    TOOK     | ERROR |
+----------------------------+--------+-------------+-------+
| https://10.115.92.43:2379 |   true | 10.301506ms |    |
| https://10.115.92.45:2379 |   true | 12.87467ms |     |
| https://10.115.92.44:2379 |   true | 13.225954ms |    |
+----------------------------+--------+-------------+-------+
```

如果输出上面信息，就说明集群部署成功。

如果有问题第一步先看日志：/var/log/message 或 journalctl -u etcd

## 二、安装Docker

这里使用Docker作为容器引擎，也可以换成别的，例如containerd

下载地址：https://download.docker.com/linux/static/stable/x86_64/docker-19.03.9.tgz 

以下在所有节点操作。这里采用二进制安装，用yum安装也一样。

### 2.1 解压二进制包

```
tar zxvf docker-19.03.9.tgz
mv docker/* /usr/bin
```

### 2.2 systemd管理docker

```
cat > /usr/lib/systemd/system/docker.service << EOF
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF
```

### 2.3 创建配置文件

```
mkdir /etc/docker
cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": ["https://b9pmyelo.mirror.aliyuncs.com"]
}
EOF
```

•   registry-mirrors 阿里云镜像加速器

### 2.4 启动并设置开机启动

```
systemctl daemon-reload
systemctl start docker
systemctl enable docker
```

## 三、部署Master

### 3.1 生成kube-apiserver证书

#### 1. 自签证书颁发机构（CA）

```
cd ~/TLS/k8s
cat > ca-config.json << EOF
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "kubernetes": {
         "expiry": "87600h",
         "usages": [
            "signing",
            "key encipherment",
            "server auth",
            "client auth"
        ]
      }
    }
  }
}
EOF
cat > ca-csr.json << EOF
{
    "CN": "kubernetes",
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "L": "Beijing",
            "ST": "Beijing",
            "O": "k8s",
            "OU": "System"
        }
    ]
}
EOF
```

生成证书：

```
cfssl gencert -initca ca-csr.json | cfssljson -bare ca -
```

会生成ca.pem和ca-key.pem文件。

#### 2. 使用自签CA签发kube-apiserver HTTPS证书

创建证书申请文件：

```
cat > server-csr.json << EOF
{
    "CN": "kubernetes",
    "hosts": [
      "10.0.0.1",
      "127.0.0.1",
      "10.115.92.43",
      "10.115.92.44",
      "10.115.92.45",
      "192.168.2.74",
      "192.168.2.88",
      "kubernetes",
      "kubernetes.default",
      "kubernetes.default.svc",
      "kubernetes.default.svc.cluster",
      "kubernetes.default.svc.cluster.local"
    ],
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "L": "BeiJing",
            "ST": "BeiJing",
            "O": "k8s",
            "OU": "System"
        }
    ]
}
EOF
```

生成证书：

```
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes server-csr.json | cfssljson -bare server
```

会生成server.pem和server-key.pem文件。

### 3.2 从Github下载二进制文件

官网：https://kubernetes.io/

下载地址： https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.20.md

https://dl.k8s.io/v1.21.0/kubernetes-server-linux-amd64.tar.gz

注：打开链接你会发现里面有很多包，下载一个server包就够了，包含了Master和Worker Node二进制文件。

### 3.3 解压二进制包

```
mkdir -p /opt/kubernetes/{bin,cfg,ssl,logs} 
tar zxvf kubernetes-server-linux-amd64.tar.gz
cd kubernetes/server/bin
cp kube-apiserver kube-scheduler kube-controller-manager /opt/kubernetes/bin
cp kubectl /usr/bin/
```

### 3.4 部署kube-apiserver

#### 1. 创建配置文件

```
cat > /opt/kubernetes/cfg/kube-apiserver.conf << EOF
KUBE_APISERVER_OPTS="--logtostderr=false \\
--v=2 \\
--log-dir=/data/kubernetes/logs/kube-apiserver \\
--etcd-servers=https://10.115.92.43:2379,https://10.115.92.44:2379,https://10.115.92.45:2379 \\
--bind-address=10.115.92.43 \\
--secure-port=6443 \\
--advertise-address=10.115.92.43 \\
--allow-privileged=true \\
--service-cluster-ip-range=192.169.0.0/16 \\
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota,NodeRestriction \\
--authorization-mode=RBAC,Node \\
--enable-bootstrap-token-auth=true \\
--token-auth-file=/opt/kubernetes/cfg/token.csv \\
--service-node-port-range=30000-32767 \\
--kubelet-client-certificate=/opt/kubernetes/ssl/server.pem \\
--kubelet-client-key=/opt/kubernetes/ssl/server-key.pem \\
--tls-cert-file=/opt/kubernetes/ssl/server.pem  \\
--tls-private-key-file=/opt/kubernetes/ssl/server-key.pem \\
--client-ca-file=/opt/kubernetes/ssl/ca.pem \\
--service-account-key-file=/opt/kubernetes/ssl/ca-key.pem \\
--service-account-issuer=api \\
--service-account-signing-key-file=/opt/kubernetes/ssl/server-key.pem \\
--etcd-cafile=/opt/etcd/ssl/ca.pem \\
--etcd-certfile=/opt/etcd/ssl/server.pem \\
--etcd-keyfile=/opt/etcd/ssl/server-key.pem \\
--requestheader-client-ca-file=/opt/kubernetes/ssl/ca.pem \\
--proxy-client-cert-file=/opt/kubernetes/ssl/server.pem \\
--proxy-client-key-file=/opt/kubernetes/ssl/server-key.pem \\
--requestheader-allowed-names=kubernetes \\
--requestheader-extra-headers-prefix=X-Remote-Extra- \\
--requestheader-group-headers=X-Remote-Group \\
--requestheader-username-headers=X-Remote-User \\
--enable-aggregator-routing=true \\
--audit-log-maxage=30 \\
--audit-log-maxbackup=3 \\
--audit-log-maxsize=100 \\
--audit-log-path=/data/kubernetes/logs/kube-apiserver/k8s-audit.log"
EOF
```

注：上面两个\ \ 第一个是转义符，第二个是换行符，使用转义符是为了使用EOF保留换行符。

•   --logtostderr：启用日志

•   ---v：日志等级

•   --log-dir：日志目录

•   --etcd-servers：etcd集群地址

•   --bind-address：监听地址

•   --secure-port：https安全端口

•   --advertise-address：集群通告地址

•   --allow-privileged：启用授权

•   --service-cluster-ip-range：Service虚拟IP地址段

•   --enable-admission-plugins：准入控制模块

•   --authorization-mode：认证授权，启用RBAC授权和节点自管理

•   --enable-bootstrap-token-auth：启用TLS bootstrap机制

•   --token-auth-file：bootstrap token文件

•   --service-node-port-range：Service nodeport类型默认分配端口范围

•   --kubelet-client-xxx：apiserver访问kubelet客户端证书

•   --tls-xxx-file：apiserver https证书

•   1.20版本必须加的参数：--service-account-issuer，--service-account-signing-key-file

•   --etcd-xxxfile：连接Etcd集群证书

•   --audit-log-xxx：审计日志

•   启动聚合层相关配置：--requestheader-client-ca-file，--proxy-client-cert-file，--proxy-client-key-file，--requestheader-allowed-names，--requestheader-extra-headers-prefix，--requestheader-group-headers，--requestheader-username-headers，--enable-aggregator-routing

#### 2. 拷贝刚才生成的证书

把刚才生成的证书拷贝到配置文件中的路径：

```
cp ~/TLS/k8s/ca*pem ~/TLS/k8s/server*pem /opt/kubernetes/ssl/
```

#### 3. 启用 TLS Bootstrapping 机制

TLS Bootstraping：Master apiserver启用TLS认证后，Node节点kubelet和kube-proxy要与kube-apiserver进行通信，必须使用CA签发的有效证书才可以，当Node节点很多时，这种客户端证书颁发需要大量工作，同样也会增加集群扩展复杂度。为了简化流程，Kubernetes引入了TLS bootstraping机制来自动颁发客户端证书，kubelet会以一个低权限用户自动向apiserver申请证书，kubelet的证书由apiserver动态签署。所以强烈建议在Node上使用这种方式，目前主要用于kubelet，kube-proxy还是由我们统一颁发一个证书。

TLS bootstraping 工作流程：



 

创建上述配置文件中token文件：

```
cat > /opt/kubernetes/cfg/token.csv << EOF 
6f40cb05180eff00e5ab514509efd065,kubelet-bootstrap,10001,"system:node-bootstrapper"
EOF
```

格式：token，用户名，UID，用户组

token也可自行生成替换：

```
head -c 16 /dev/urandom | od -An -t x | tr -d ' '
```

#### 4. systemd管理apiserver

```
cat > /usr/lib/systemd/system/kube-apiserver.service << EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
EnvironmentFile=/opt/kubernetes/cfg/kube-apiserver.conf
ExecStart=/opt/kubernetes/bin/kube-apiserver \$KUBE_APISERVER_OPTS
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

#### 5. 启动并设置开机启动

```
systemctl daemon-reload
systemctl start kube-apiserver 
systemctl enable kube-apiserver
```

### 3.5 部署kube-controller-manager

#### 1. 创建配置文件

```
cat > /opt/kubernetes/cfg/kube-controller-manager.conf << EOF
KUBE_CONTROLLER_MANAGER_OPTS="--logtostderr=false \\
--v=2 \\
--log-dir=/data/kubernetes/logs/kube-controller-manager \\
--leader-elect=true \\
--kubeconfig=/opt/kubernetes/cfg/kube-controller-manager.kubeconfig \\
--bind-address=127.0.0.1 \\
--allocate-node-cidrs=true \\
--cluster-cidr=192.169.0.0/16 \\
--service-cluster-ip-range=172.17.0.0/16 \\
--cluster-signing-cert-file=/opt/kubernetes/ssl/ca.pem \\
--cluster-signing-key-file=/opt/kubernetes/ssl/ca-key.pem  \\
--root-ca-file=/opt/kubernetes/ssl/ca.pem \\
--service-account-private-key-file=/opt/kubernetes/ssl/ca-key.pem \\
--cluster-signing-duration=87600h0m0s"
EOF
```

•   --kubeconfig：连接apiserver配置文件

•   --leader-elect：当该组件启动多个时，自动选举（HA）

•   --cluster-signing-cert-file/--cluster-signing-key-file：自动为kubelet颁发证书的CA，与apiserver保持一致

#### 2. 生成kubeconfig文件

生成kube-controller-manager证书：

```
# 切换工作目录
cd ~/TLS/k8s

# 创建证书请求文件
cat > kube-controller-manager-csr.json << EOF
{
  "CN": "system:kube-controller-manager",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "BeiJing", 
      "ST": "BeiJing",
      "O": "system:masters",
      "OU": "System"
    }
  ]
}
EOF

# 生成证书
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager
```

生成kubeconfig文件（以下是shell命令，直接在终端执行）：

```
KUBE_CONFIG="/opt/kubernetes/cfg/kube-controller-manager.kubeconfig"
KUBE_APISERVER="https://10.115.92.43:6443"

kubectl config set-cluster kubernetes \
  --certificate-authority=/opt/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server=${KUBE_APISERVER} \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-credentials kube-controller-manager \
  --client-certificate=/opt/kubernetes/ssl/kube-controller-manager.pem \
  --client-key=/opt/kubernetes/ssl/kube-controller-manager-key.pem \
  --embed-certs=true \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-controller-manager \
  --kubeconfig=${KUBE_CONFIG}
kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
```

#### 3. systemd管理controller-manager

```
cat > /usr/lib/systemd/system/kube-controller-manager.service << EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
EnvironmentFile=/opt/kubernetes/cfg/kube-controller-manager.conf
ExecStart=/opt/kubernetes/bin/kube-controller-manager \$KUBE_CONTROLLER_MANAGER_OPTS
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

#### 4. 启动并设置开机启动

```
systemctl daemon-reload
systemctl start kube-controller-manager
systemctl enable kube-controller-manager
```

### 3.6 部署kube-scheduler

#### 1. 创建配置文件

```
cat > /opt/kubernetes/cfg/kube-scheduler.conf << EOF
KUBE_SCHEDULER_OPTS="--logtostderr=false \\
--v=2 \\
--log-dir= /data/kubernetes/logs/kube-scheduler \\
--leader-elect \\
--kubeconfig=/opt/kubernetes/cfg/kube-scheduler.kubeconfig \\
--bind-address=127.0.0.1"
EOF
```

•   --kubeconfig：连接apiserver配置文件

•   --leader-elect：当该组件启动多个时，自动选举（HA）

#### 2. 生成kubeconfig文件

生成kube-scheduler证书：

```
# 切换工作目录
cd ~/TLS/k8s

# 创建证书请求文件
cat > kube-scheduler-csr.json << EOF
{
  "CN": "system:kube-scheduler",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "BeiJing",
      "ST": "BeiJing",
      "O": "system:masters",
      "OU": "System"
    }
  ]
}
EOF

# 生成证书
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-scheduler-csr.json | cfssljson -bare kube-scheduler
```

生成kubeconfig文件（以下是shell命令，直接在终端执行）：

```
KUBE_CONFIG="/opt/kubernetes/cfg/kube-scheduler.kubeconfig"
KUBE_APISERVER="https://10.115.92.43:6443"

kubectl config set-cluster kubernetes \
  --certificate-authority=/opt/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server=${KUBE_APISERVER} \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-credentials kube-scheduler \
  --client-certificate=/opt/kubernetes/ssl/kube-scheduler.pem \
  --client-key=/opt/kubernetes/ssl/kube-scheduler-key.pem \
  --embed-certs=true \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-scheduler \
  --kubeconfig=${KUBE_CONFIG}
kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
```

#### 3. systemd管理scheduler

```
cat > /usr/lib/systemd/system/kube-scheduler.service << EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
EnvironmentFile=/opt/kubernetes/cfg/kube-scheduler.conf
ExecStart=/opt/kubernetes/bin/kube-scheduler \$KUBE_SCHEDULER_OPTS
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

#### 4. 启动并设置开机启动

```
systemctl daemon-reload
systemctl start kube-scheduler
systemctl enable kube-scheduler
```

#### 5. 查看集群状态

生成kubectl连接集群的证书：

```
cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "BeiJing",
      "ST": "BeiJing",
      "O": "system:masters",
      "OU": "System"
    }
  ]
}
EOF

cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes admin-csr.json | cfssljson -bare admin
```

生成kubeconfig文件：

```
mkdir /root/.kube
KUBE_CONFIG="/root/.kube/config"
KUBE_APISERVER="https://10.115.92.43:6443"

kubectl config set-cluster kubernetes \
  --certificate-authority=/opt/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server=${KUBE_APISERVER} \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-credentials cluster-admin \
  --client-certificate=/opt/kubernetes/ssl/admin.pem \
  --client-key=/opt/kubernetes/ssl/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-context default \
  --cluster=kubernetes \
  --user=cluster-admin \
  --kubeconfig=${KUBE_CONFIG}
kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
```

通过kubectl工具查看当前集群组件状态：

```
kubectl get cs
NAME                STATUS    MESSAGE             ERROR
scheduler             Healthy   ok                  
controller-manager       Healthy   ok                  
etcd-2               Healthy   {"health":"true"}   
etcd-1               Healthy   {"health":"true"}   
etcd-0               Healthy   {"health":"true"}  
```

如上输出说明Master节点组件运行正常。

#### 6. 授权kubelet-bootstrap用户允许请求证书

```
kubectl create clusterrolebinding kubelet-bootstrap \
--clusterrole=system:node-bootstrapper \
--user=kubelet-bootstrap
```

## 四、部署Node

**下面还是在Master Node上操作，即同时作为Worker Node**

### 4.1 创建工作目录并拷贝二进制文件

在所有worker node创建工作目录：

```
mkdir -p /opt/kubernetes/{bin,cfg,ssl,logs} 
```

从master节点拷贝：

```
cd kubernetes/server/bin
cp kubelet kube-proxy /opt/kubernetes/bin   # 本地拷贝
```

### 4.2 部署kubelet

#### 1. 创建配置文件

```
cat > /opt/kubernetes/cfg/kubelet.conf << EOF
KUBELET_OPTS="--logtostderr=false \\
--v=2 \\
--log-dir=/opt/kubernetes/logs \\
--hostname-override=k8s-master1 \\
--network-plugin=cni \\
--kubeconfig=/opt/kubernetes/cfg/kubelet.kubeconfig \\
--bootstrap-kubeconfig=/opt/kubernetes/cfg/bootstrap.kubeconfig \\
--config=/opt/kubernetes/cfg/kubelet-config.yml \\
--cert-dir=/opt/kubernetes/ssl \\
--pod-infra-container-image=harbor.gome.com.cn/k8s-compent/pause-amd64:3.0"
EOF
 
### --cgroup-driver systemd(添加)
 
```

•   --hostname-override：显示名称，集群中唯一

•   --network-plugin：启用CNI

•   --kubeconfig：空路径，会自动生成，后面用于连接apiserver

•   --bootstrap-kubeconfig：首次启动向apiserver申请证书

•   --config：配置参数文件

•   --cert-dir：kubelet证书生成目录

•   --pod-infra-container-image：管理Pod网络容器的镜像

#### 2. 配置参数文件

```
cat > /opt/kubernetes/cfg/kubelet-config.yml << EOF
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
address: 0.0.0.0
port: 10250
readOnlyPort: 10255
cgroupDriver: cgroupfs
clusterDNS:
- 192.169.0.2
clusterDomain: cluster.local 
failSwapOn: false
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 2m0s
    enabled: true
  x509:
    clientCAFile: /opt/kubernetes/ssl/ca.pem 
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
evictionHard:
  imagefs.available: 15%
  memory.available: 100Mi
  nodefs.available: 10%
  nodefs.inodesFree: 5%
maxOpenFiles: 1000000
maxPods: 110
EOF
```

#### 3. 生成kubelet初次加入集群引导kubeconfig文件

```
KUBE_CONFIG="/opt/kubernetes/cfg/bootstrap.kubeconfig"  KUBE_APISERVER="https://10.115.92.43:6443" 
TOKEN="6f40cb05180eff00e5ab514509efd065"
# 生成 kubelet bootstrap kubeconfig 配置文件
kubectl config set-cluster kubernetes \
  --certificate-authority=/opt/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server=${KUBE_APISERVER} \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-credentials "kubelet-bootstrap" \
  --token=${TOKEN} \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-context default \
  --cluster=kubernetes \
  --user="kubelet-bootstrap" \
  --kubeconfig=${KUBE_CONFIG}
kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
```

#### 4. systemd管理kubelet

```
cat > /usr/lib/systemd/system/kubelet.service << EOF
[Unit]
Description=Kubernetes Kubelet
After=docker.service

[Service]
EnvironmentFile=/opt/kubernetes/cfg/kubelet.conf
ExecStart=/opt/kubernetes/bin/kubelet \$KUBELET_OPTS
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

#### 5. 启动并设置开机启动

```
systemctl daemon-reload
systemctl start kubelet
systemctl enable kubelet
systemctl status kubelet
 
## kubelet.kubeconfig 文件启动后自动生成##启动后无10255端口，在master授权加入后会开启该端口
```

### 4.3 批准kubelet证书申请并加入集群

```
# 查看kubelet证书请求
kubectl get csr
NAME                                                   AGE    SIGNERNAME                                    REQUESTOR           CONDITION
node-csr-uCEGPOIiDdlLODKts8J658HrFq9CZ--K6M4G7bjhk8A   6m3s   kubernetes.io/kube-apiserver-client-kubelet   kubelet-bootstrap   Pending

# 批准申请
kubectl certificate approve node-csr-uCEGPOIiDdlLODKts8J658HrFq9CZ--K6M4G7bjhk8A

# 查看节点
kubectl get node
NAME         STATUS     ROLES    AGE   VERSION
k8s-master1   NotReady   <none>   7s    v1.18.3
```

注：由于网络插件还没有部署，节点会没有准备就绪 NotReady ##新增加node节点需删除自动生成证书重启kubelet服务

### 4.4 部署kube-proxy

#### 1. 创建配置文件

```
cat > /opt/kubernetes/cfg/kube-proxy.conf << EOF
KUBE_PROXY_OPTS="--logtostderr=false \\
--v=2 \\
--log-dir=/data/kubernetes/logs/kube-proxy \\
--config=/opt/kubernetes/cfg/kube-proxy-config.yml"
EOF
```

#### 2. 配置参数文件

```
cat > /opt/kubernetes/cfg/kube-proxy-config.yml << EOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
bindAddress: 0.0.0.0
metricsBindAddress: 0.0.0.0:10249
clientConnection:
  kubeconfig: /opt/kubernetes/cfg/kube-proxy.kubeconfig
hostnameOverride: 
clusterCIDR: 172.19.0.0/16
EOF
 
### mode: ipvs  ##调整为ipvs模式
```

#### 3. 生成kube-proxy.kubeconfig文件

```
# 切换工作目录
cd ~/TLS/k8s

# 创建证书请求文件
cat > kube-proxy-csr.json << EOF
{
  "CN": "system:kube-proxy",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "L": "BeiJing",
      "ST": "BeiJing",
      "O": "k8s",
      "OU": "System"
    }
  ]
}
EOF

# 生成证书
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-proxy-csr.json | cfssljson -bare kube-proxy
生成kubeconfig文件：
KUBE_CONFIG="/opt/kubernetes/cfg/kube-proxy.kubeconfig"
KUBE_APISERVER="https://10.115.92.43:6443"

kubectl config set-cluster kubernetes \
  --certificate-authority=/opt/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server=${KUBE_APISERVER} \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-credentials kube-proxy \
  --client-certificate=/opt/kubernetes/ssl/kube-proxy.pem \
  --client-key=/opt/kubernetes/ssl/kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=${KUBE_CONFIG}
kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-proxy \
  --kubeconfig=${KUBE_CONFIG}
kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
```

#### 4. systemd管理kube-proxy

```
cat > /usr/lib/systemd/system/kube-proxy.service << EOF
[Unit]
Description=Kubernetes Proxy
After=network.target

[Service]
EnvironmentFile=/opt/kubernetes/cfg/kube-proxy.conf
ExecStart=/opt/kubernetes/bin/kube-proxy \$KUBE_PROXY_OPTS
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

#### 5. 启动并设置开机启动

```
systemctl daemon-reload
systemctl start kube-proxy
systemctl enable kube-proxy
systemctl status kube-proxy
```

### 4.5 部署网络组件

#### 1、部署calico

https://docs.projectcalico.org/about/about-k8s-networking

[https://github.com/projectcalico/calicoctl/releases/tag/v3.20.](https://github.com/projectcalico/calicoctl/releases/tag/v3.20.1)2 #二进制 

https://github.com/projectcalico/calicoctl/releases/download/v3.20.2/calicoctl 

Calico是一个纯三层的数据中心网络方案，是目前Kubernetes主流的网络方案。

Calico需要连接etcd，因此需要etcd的证书:

```
# cat /opt/etcd/ssl/ca.pem | base64 -w 0
# cat /opt/etcd/ssl/server-key.pem | base64 -w 0        
# cat /opt/etcd/ssl/server.pem | base64 -w 0
```

部署Calico：

```
curl https://docs.projectcalico.org/v3.11/manifests/calico-etcd.yaml -o calico-etcd.yaml
  # Example command for encoding a file contents: cat <file> | base64 -w 0
  etcd-key: #####
  etcd-cert: ####
  etcd-ca: #####
...
kind: ConfigMap
apiVersion: v1
metadata:
  name: calico-config
  namespace: kube-system
data:
  # Configure this with the location of your etcd cluster.
  etcd_endpoints: "https://10.115.92.43:2379,https://10.115.92.44:2379,https://10.115.92.45:2379"
kubectl apply -f calico.yaml
kubectl get pods -n kube-system
```

等Calico Pod都Running，节点也会准备就绪：

```
kubectl get node
NAME         STATUS   ROLES    AGE   VERSION
k8s-master   Ready    <none>   37m   v1.20.9
```

调整calico网络模式：340行value调整位“off” 

```
   333             - name: CLUSTER_TYPE
    334               value: "k8s,bgp"
    335             # Auto-detect the BGP IP address.
    336             - name: IP
    337               value: "autodetect"
    338             # Enable IPIP
    339             - name: CALICO_IPV4POOL_IPIP
    340               value: "off"
    341             - name: FELIX_IPINIPENABLED
    342               value: "false"
```

#### 2、部署calicoctl

```
1、download_install_calicoctl
curl -o calicoctl -O -L  "https://github.com/projectcalico/calicoctl/releases/download/v3.20.2/calicoctl" 
chmod +x calicoctl && mv /usr/bin/

2、config_etc_dcert
mkdir -p /etc/calico/ && cd /etc/calico

cat  > calicoctl.cfg << EOF
apiVersion: projectcalico.org/v3
kind: CalicoAPIConfig
metadata:
spec:
  etcdEndpoints: https://10.115.92.43:2379,https://10.115.92.44:2379,https://10.115.92.45:2379
  etcdKeyFile: /opt/calico/ssl/etcd-peer-key.pem 
  etcdCertFile: /opt/calico/ssl/etcd-peer.pem
  etcdCACertFile: /opt/calico/ssl/ca.pem
EOF

```

### 5.6 授权apiserver访问kubelet

应用场景：例如kubectl logs

```
cat > apiserver-to-kubelet-rbac.yaml << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
      - pods/log
    verbs:
      - "*"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
EOF

kubectl apply -f apiserver-to-kubelet-rbac.yaml
```

### 5.7 新增加Worker Node

#### 1. 拷贝已部署好的Node相关文件到新节点

在Master节点将Worker Node涉及文件拷贝到新节点10.115.92.44/73

```
scp -r /opt/kubernetes root@10.115.92.44:/opt/

scp -r /usr/lib/systemd/system/{kubelet,kube-proxy}.service root@10.115.92.44:/usr/lib/systemd/system

scp /opt/kubernetes/ssl/ca.pem root@10.115.92.44:/opt/kubernetes/ssl
```

#### 2. 删除kubelet证书和kubeconfig文件

```
rm -f /opt/kubernetes/cfg/kubelet.kubeconfig 
rm -f /opt/kubernetes/ssl/kubelet*
```

注：这几个文件是证书申请审批后自动生成的，每个Node不同，必须删除

#### 3. 修改主机名

```
vi /opt/kubernetes/cfg/kubelet.conf
--hostname-override=k8s-node1

vi /opt/kubernetes/cfg/kube-proxy-config.yml
hostnameOverride: k8s-node1
```

#### 4. 启动并设置开机启动

```
systemctl daemon-reload
systemctl start kubelet kube-proxy
systemctl enable kubelet kube-proxy
```

#### 5. 在Master上批准新Node kubelet证书申请

```
# 查看证书请求
kubectl get csr
NAME           AGE   SIGNERNAME                    REQUESTOR           CONDITION
node-csr-4zTjsaVSrhuyhIGqsefxzVoZDCNKei-aE2jyTP81Uro   89s   kubernetes.io/kube-apiserver-client-kubelet   kubelet-bootstrap   Pending

# 授权请求
kubectl certificate approve node-csr-4zTjsaVSrhuyhIGqsefxzVoZDCNKei-aE2jyTP81Uro
```

#### 6. 查看Node状态

```
kubectl get node
NAME       STATUS   ROLES    AGE     VERSION
k8s-master1   Ready    <none>   47m     v1.20.9
k8s-node1    Ready    <none>   6m49s   v1.20.9
```

Node2（10.115.92.45 ）节点同上。记得修改主机名！

## 五、部署Dashboard和CoreDNS

### 6.1 部署Dashboard

https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-rc1/aio/deploy/recommended.yaml

```
kubectl apply -f kubernetes-dashboard.yaml
# 查看部署
kubectl get pods,svc -n kubernetes-dashboard
```

访问地址：https://NodeIP:30001

创建service account并绑定默认cluster-admin管理员集群角色：

```
kubectl create serviceaccount dashboard-admin -n kube-system
kubectl create clusterrolebinding dashboard-admin --clusterrole=cluster-admin --serviceaccount=kube-system:dashboard-admin
kubectl describe secrets -n kube-system $(kubectl -n kube-system get secret | awk '/dashboard-admin/{print $1}')
```

使用输出的token登录Dashboard。

### 6.2 部署CoreDNS

https://github.com/coredns/coredns

https://github.com/coredns/deployment/blob/master/kubernetes/coredns.yaml.sed

https://github.com/kubernetes/kubernetes/blob/master/cluster/addons/dns/coredns/coredns.yaml.base

CoreDNS用于集群内部Service名称解析。

```
kubectl apply -f coredns.yaml 

kubectl get pods -n kube-system  
NAME                          READY   STATUS    RESTARTS   AGE 
coredns-5ffbfd976d-j6shb      1/1     Running   0          32s
```

DNS解析测试：

```
kubectl run -it --rm dns-test --image=busybox:1.28.4 sh 
If you don't see a command prompt, try pressing enter. 

/ # nslookup kubernetes 
Server:    10.0.0.2 
Address 1: 10.0.0.2 kube-dns.kube-system.svc.cluster.local 

Name:      kubernetes 
Address 1: 10.0.0.1 kubernetes.default.svc.cluster.local
```

### 6.3 部署traefik

官网：https://traefik.io/

https://traefik.cn/

http://www.mydlq.club/article/100/



