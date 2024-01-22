# 1.create a cluster config file
cat <<EOF >./cluster-config.yaml
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
 name: my-cluster
 region: us-east-1
 version: "1.23"
availabilityZones:
- us-east-1a
- us-east-1b
managedNodeGroups:
- name: workers
 instanceType: t2.medium
 desiredCapacity: 2
 volumeSize: 10
 privateNetworking: true
EOF

# 2.apply the cluster config file
eksctl create cluster -f cluster-config.yaml --profile eksctl

# 3.add the OIDC Provider Support to our cluster
eksctl utils associate-iam-oidc-provider \
   --region us-east-1 \
   --cluster my-cluster \
   --approve

# 4. set up the necessary identities and permissions for EBS
POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"

eksctl create iamserviceaccount \
 --name "ebs-csi-controller-sa" \
 --namespace "kube-system" \
 --cluster my-cluster \
 --region us-east-1 \
 --attach-policy-arn $POLICY_ARN \
 --role-only \
 --role-name "ebs-csi-driver-role" \
 --approve

# 5. Export the account id and the role arn
export ACCOUNT_ID=071715510651
export ACCOUNT_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/ebs-csi-driver-role"

# 6. add the EBS driver to the cluster
eksctl create addon \
 --name "aws-ebs-csi-driver" \
 --cluster my-cluster \
 --region=us-east-1 \
 --service-account-role-arn $ACCOUNT_ROLE_ARN \
 --force

# 7. Get status of the driver, and wait until the status is ACTIVE
eksctl get addon \
 --name "aws-ebs-csi-driver" \
 --region us-east-1 \
 --cluster my-cluster

# 8. check the ebs csi driver pods
kubectl get pods \
 --namespace "kube-system" \
 --selector "app.kubernetes.io/name=aws-ebs-csi-driver"

# 9. create the storage class for the EBS CSI driver
cat << EOF > storageclass.yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
 name: ebs-storage-class
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

# 10. apply the storage class
kubectl apply -f storageclass.yaml

# 11. create a PVC to allocate some portion of storage
cat << EOF > pvc.yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
 name: ebs-claim
spec:
 accessModes:
   - ReadWriteOnce
 storageClassName: ebs-storage-class
 resources:
   requests:
     storage: 4Gi
EOF

# 12. apply the pvc 
kubectl apply -f pvc.yaml

# 13. Create the pod config file
cat << EOF > pod.yaml
---
apiVersion: v1
kind: Pod
metadata:
 name: app
spec:
 containers:
 - name: app
   image: centos
   command: ["/bin/sh"]
   args: ["-c", "while true; do echo $(date -u) >> /data/datetime.txt; sleep 5; done"]
   volumeMounts:
   - name: persistent-storage
     mountPath: /data
 volumes:
 - name: persistent-storage
   persistentVolumeClaim:
     claimName: ebs-claim
EOF

# 14. create the pod
kubectl apply -f pod.yaml

# 15. Once the pod is running, verify that is writing data to the volume
kubectl exec -it app -- cat /data/datetime.txt

