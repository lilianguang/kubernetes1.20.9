#!/bin/bash
KUBE_CONFIG="/opt/kubernetes/cfg/bootstrap.kubeconfig"  KUBE_APISERVER="https://10.115.92.43:6443" 
TOKEN="6f40cb05180eff00e5ab514509efd065"   ###tokenֵ����ǰ������һ��
# ���� kubelet bootstrap kubeconfig �����ļ�
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
