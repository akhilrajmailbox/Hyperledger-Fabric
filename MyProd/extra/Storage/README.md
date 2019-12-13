## AWS-EFS
### https://medium.com/@while1eq1/using-amazon-efs-in-a-multiaz-kubernetes-setup-57922e032776
### https://github.com/kubernetes-incubator/external-storage/tree/master/aws/efs

* create efs : https://console.aws.amazon.com/efs/
* Edit the efs-provisioner deployment (Modify `efs-provisioner-deployment.yml` In the configmap section change the `file.system.id:` and `aws.region:` to match the details of the EFS you created. Change `dns.name` if you want to mount by your own DNS name and not by AWS's *file-system-id*.efs.*aws-region*.amazonaws.com, `server:` entry also need to be update.

* Configure the rbac
```
kubectl apply -f AWS-efs-pvc-roles.yaml
```

* Deploy efs-provisioner on default namesapce
```
kubectl apply -f efs-provisioner-deployment.yml
```

* Create a StorageClass called `rwmany`
```
kubectl create -f AWS-RWMany-storageclass.yaml
```

* Create pvc with `rwmany` and start your journey with EFS