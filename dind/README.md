# Hyperledger Fabric Orderer

DinD Deployment on K8s

## TL;DR;

```bash
$ helm repo add ar-repo https://akhilrajmailbox.github.io/Hyperledger-Fabric/docs
$ helm install ar-repo/dind
```

## Installing the Chart

To install the chart with the release name `dindserver`:

```bash
$ helm install ar-repo/dind --name dindserver
```

The command deploys the dind on the Kubernetes cluster in the default configuration. The [Configuration](#configuration) section lists the parameters that can be configured during installation.

### Custom parameters

Specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example:

```bash
$ helm install ar-repo/dind --name dindserver --set service.port=2375
```


Alternatively, a YAML file can be provided while installing the chart. This file specifies values to override those provided in the default values.yaml. For example,

```bash
$ helm install ar-repo/dind --name dindserver -f my-values.yaml
```

## Updating the chart

To update the chart run:

```bash
$ helm upgrade dindserver ar-repo/dind -f my-values.yaml
```

## Uninstalling the Chart

To uninstall/delete the `dindserver` deployment:

```bash
$ helm delete dindserver
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

## Configuration

The following table lists the configurable parameters of the Hyperledger Fabric Orderer chart and default values.

| Parameter                          | Description                                       | Default                                                   |
| ---------------------------------- | ------------------------------------------------ | ---------------------------------------------------------- |
| `image.repository`                 | `dind` image repository                          | `docker`                                                   |
| `image.tag`                        | `dind` image tag                                 | `stable-dind`                                              |
| `image.pullPolicy`                 | Image pull policy                                | `IfNotPresent`                                             |
| `service.port`                     | TCP port                                         | `2375`                                                     |
| `service.type`                     | K8S service type exposing ports, e.g. `ClusterIP`| `ClusterIP`                                                |
| `tls.enabled`                      | Disable / Enable DOCKER_TLS_CERTDIR variable     | `false`                                                    |
| `persistence.accessMode`           | Use volume as ReadOnly or ReadWrite              | `ReadWriteOnce`                                            |
| `persistence.annotations`          | Persistent Volume annotations                    | `{}`                                                       |
| `persistence.size`                 | Size of data volume (adjust for production!)     | `100Gi`                                                    |
| `persistence.storageClass`         | Storage class of backing PVC                     | `default`                                                  |
| `resources`                        | CPU/Memory resource requests/limits              | `{}`                                                       |
| `nodeSelector`                     | Node labels for pod assignment                   | `{}`                                                       |
| `tolerations`                      | Toleration labels for pod assignment             | `[]`                                                       |
| `affinity`                         | Affinity settings for pod assignment             | `{}`                                                       |