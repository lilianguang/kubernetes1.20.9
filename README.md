部署说明：
1、部署流程请参照 Kuberneter-v1.20.9-Binary.docx 文档。
2、system-config目录下是部署前期系统优化及证书工具准备工作。
3、etcd/certs目录下是etcd所使用生产ca证书及etcd证书以及生产证书脚本；etcd/cetcd-config目录下是etcd主配置文件及systemd启动文件直接copy到各对应目录即可（注意：不同节点标识需要更改）
4、kubernetes/certs目录下是etcd所使用生产ca证书及k8s证书以及生产证书脚本；kubernetes/kubernetes-config目录下是k8s主配置文件及systemd启动文件直接copy到各对应目录即可（注意：不同节点标识需要更改）
5、yaml目录下是以yaml方式交付到k8s集群组件各yaml配置。.
