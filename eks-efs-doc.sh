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

# 4. create an IAM role and policy
curl -o iam-policy-example.json https://raw.githubusercontent.com/kubernetes-sigs/aws-efs-csi-driver/master/docs/iam-policy-example.json
aws iam create-policy \
   --policy-name AmazonEKS_EFS_CSI_Driver_Policy \
   --policy-document file://iam-policy-example.json

# 5. determine your cluster's OIDC provider URL and get its ID
aws eks describe-cluster --name my-cluster --query "cluster.identity.oidc.issuer" --output text

# 6.create the IAM trust policy
cat <<EOF > trust-policy.json
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Effect": "Allow",
     "Principal": {
       "Federated": "arn:aws:iam::YOUR_AWS_ACCOUNT_ID:oidc-provider/oidc.eks.YOUR_AWS_REGION.amazonaws.com/id/<XXXXXXXXXX45D83924220DC4815XXXXX>"
     },
     "Action": "sts:AssumeRoleWithWebIdentity",
     "Condition": {
       "StringEquals": {
         "oidc.eks.YOUR_AWS_REGION.amazonaws.com/id/<XXXXXXXXXX45D83924220DC4815XXXXX>:sub": "system:serviceaccount:kube-system:efs-csi-controller-sa"
       }
     }
   }
 ]
}
EOF

# make sure to change the following attributes with your own values:
# YOUR_AWS_ACCOUNT_ID
# OIDC ID
# YOUR_AWS_REGION

# 7. Create an IAM role, then attach your new IAM policy to the role
aws iam create-role \
 --role-name AmazonEKS_EFS_CSI_DriverRole \
 --assume-role-policy-document file://"trust-policy.json"

aws iam attach-role-policy \
 --policy-arn arn:aws:iam::<AWS_ACCOUNT_ID>:policy/AmazonEKS_EFS_CSI_Driver_Policy \
 --role-name AmazonEKS_EFS_CSI_DriverRole

# 8. Create the Kubernetes service account on your cluster
cat <<EOF > efs-service-account.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
 labels:
   app.kubernetes.io/name: aws-efs-csi-driver
 name: efs-csi-controller-sa
 namespace: kube-system
 annotations:
   eks.amazonaws.com/role-arn: arn:aws:iam::<AWS_ACCOUNT_ID>:role/AmazonEKS_EFS_CSI_DriverRole
EOF

kubectl apply -f efs-service-account.yaml

# 9. Get the driver file
kubectl kustomize "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.5" > public-ecr-driver.yaml

# 10. edit the public-ecr-driver.yaml file to remove the efs-csi-controller-sa section (because we have already deploy it)
nano public-ecr-driver.yaml

# Delete the efs-csi-controller-sa section, your file should begin with the efs-csi-node-sa manifest:
# then apply the manifest
kubectl apply -f public-ecr-driver.yaml

# 11. Clone the aws-efs-csi-driver repository
git clone https://github.com/kubernetes-sigs/aws-efs-csi-driver.git

# 12. Change your working directory to the folder
cd aws-efs-csi-driver/examples/kubernetes/multiple_pods/

# 13. Retrieve your Amazon EFS file system ID
aws efs describe-file-systems --query "FileSystems[*].FileSystemId" --output text

# 14. In the specs/pv.yaml file, replace the spec.csi.volumeHandle value with your Amazon EFS FileSystemId from the previous step
nano specs/pv.yaml

# 15. Create the Kubernetes resources required for testing
kubectl apply -f specs/

# 16. List the pods, wait until become running
kubectl get pods

# 17. Test if the two pods are writing data to the file
kubectl exec -it app1 -- tail /data/out1.txt 
kubectl exec -it app2 -- tail /data/out1.txt 



