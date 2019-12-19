#!/bin/bash
export PROD_DIR="./"

if [[ ! -d ${PROD_DIR}/config/MyConfig ]] ; then
    echo "Custom Values Store Creating...!"
    mkdir ${PROD_DIR}/config/MyConfig
fi

#######################################
## Cloud Provider
function Cloud_Provider() {
    export CLOUD_PROVIDER=""
    until [[ ${CLOUD_PROVIDER} == "AWS" ]] || [[ ${CLOUD_PROVIDER} == "Azure" ]] ; do
        echo "Enter Either AWS or Azure"
        read -r -p "Enter your Cloud Provider :: " CLOUD_PROVIDER </dev/tty
        export CLOUD_PROVIDER=${CLOUD_PROVIDER}
    done
}


#######################################
## Chaincode location finder
function CC_Provider() {
    export CC_LOCATION=""
    until [[ -d ${CC_LOCATION} ]] ; do
        echo "${CC_LOCATION} is not a directory"
        echo -e "Go to Chaincode location in your local system and run : pwd to get the absolute path for your chaincode \n example : assuming that your chaincode is written in node and your code can found under directory called javascript \n Open another terminal and Go to javascript folder and then run pwd, copy the absolute path and run the same command again in order to configure your chaincode"
        read -r -p "Enter your Chaincode location :: " CC_LOCATION </dev/tty
        export CC_LOCATION=${CC_LOCATION}
    done
}


#######################################
## helm and tiller
function Helm_Configure() {
    echo "Configuring Helm in the k8s..!"
    # kubectl create -f helm-rbac.yaml
    # helm init --service-account tiller
    kubectl create serviceaccount --namespace kube-system tiller
    kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
    kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller"}}}}'      
    helm init --service-account tiller --upgrade
    sleep 10
    helm repo add ar-repo https://akhilrajmailbox.github.io/Hyperledger-Fabric/docs
}


#######################################
## configure storageclass
function Storageclass_Configure() {
    Cloud_Provider
    echo "Configuring custom Fast storage class for the deployment...!"
    if [[ ${CLOUD_PROVIDER} == "AWS" ]] ; then 
        echo "Configuring fast storageclass on ${CLOUD_PROVIDER}"
    elif [[ ${CLOUD_PROVIDER} == "Azure" ]] ; then
        echo "Configuring fast storageclass on ${CLOUD_PROVIDER}"
    else
        echo "CLOUD_PROVIDER not found..!, task aborting..!"
        exit 1
    fi
    
    if kubectl get storageclass | grep fast >/dev/null ; then
        echo "fast storageclass already available on your K8s Cluster"
    else
        kubectl apply -f ${PROD_DIR}/extra/Storage/${CLOUD_PROVIDER}-storageclass.yaml
    fi

    if kubectl get storageclass | grep rwmany >/dev/null ; then
        echo "rwmany storageclass already available on your K8s Cluster"
    else
        if [[ ${CLOUD_PROVIDER} == "AWS" ]] ; then
            kubectl apply -f ${PROD_DIR}/extra/Storage/${CLOUD_PROVIDER}-efs-pvc-roles.yaml
            kubectl apply -f ${PROD_DIR}/extra/Storage/${CLOUD_PROVIDER}-efs-provisioner-deployment.yaml

            export EFS_PROVISIONER_STATUS=""
            until [[ ${EFS_PROVISIONER_STATUS} == "Running" ]] ; do
                echo "Waiting for the EFS_PROVISIONER to start...!"
                if [ "${EFS_PROVISIONER_STATUS}" == "Error" ]; then
                    echo "There is an error in the Docker pod. Please check logs."
                    exit 1
                fi
                sleep 2
                export EFS_PROVISIONER_STATUS=$(kubectl get pods -n default -l "app=efs-provisioner" --output=jsonpath={.items..status.phase})
            done
            echo "The EFS_PROVISIONER started and running...!"
            kubectl apply -f ${PROD_DIR}/extra/Storage/${CLOUD_PROVIDER}-RWMany-storageclass.yaml
        elif [[ ${CLOUD_PROVIDER} == "Azure" ]] ; then
            kubectl apply -f ${PROD_DIR}/extra/Storage/${CLOUD_PROVIDER}-file-pvc-roles.yaml
            kubectl apply -f ${PROD_DIR}/extra/Storage/${CLOUD_PROVIDER}-RWMany-storageclass.yaml
        else
            echo "CLOUD_PROVIDER not found..!, task aborting..!"
            exit 1
        fi
    fi
}


#######################################
## NGINX Ingress controller
function Nginx_Configure() {
    echo "Configure Ingress server for the deployment...!"
    Setup_Namespace ingress-controller
    helm install stable/nginx-ingress -n nginx-ingress ${namespace_options}
    Pod_Status_Wait
}


#######################################
## Check pod status
function Pod_Status_Wait() {
    echo "Checking pod status on : ${namespace_options} for the pod : ${1}"
    Pod_Name=$(kubectl ${namespace_options} get pods ${1} | awk '{if(NR>1)print $1}')

    for i in ${Pod_Name} ; do
        Pod_Status=""
        until [[ ${Pod_Status} == "Running" ]] ; do
            echo "Waiting for the pod : ${i} to start...!"
            export Pod_Status=$(kubectl ${namespace_options} get pods ${i} -o jsonpath="{.status.phase}")
        done
        echo "The pod : ${i} started and running...!"
    done
}


#######################################
## Check job status
function Job_Status_Wait() {
    echo "Checking pod status on : ${namespace_options} for the job : ${1}"
    if kubectl ${namespace_options} get jobs | grep ${1} ; then
        if [[ ${2} == "dontkill" ]] ; then
            echo -e "/n break option enabled /n"
        fi

        JOBSTATUS=""
        PODSTATUS=""
        while [ "${JOBSTATUS}" != "1/1" ]; do
            echo "Waiting for ${1} job to be completed"
            sleep 1;
            if [[ ${PODSTATUS} == "Error" ]] && [[ ${2} == "dontkill" ]] ; then
                echo "Job ${1} Failed and loop breaking...!"
                break
            elif [[ ${PODSTATUS} == "Error" ]] ; then
                echo "Job ${1} Failed"
                exit 1
            fi
            JOBSTATUS=$(kubectl ${namespace_options} get jobs | grep ${1} | awk '{print $2}')
            PODSTATUS=$(kubectl ${namespace_options} get pods --sort-by='{.metadata.creationTimestamp}' | grep ${1} | awk '{print $3}' | tail -1)
        done
        echo "job ${1} Completed Successfully"
    else
        echo "no jobs found with name : ${1}"
        exit 1
    fi
}


#######################################
## Certificate manager
function Cert_Manager_Configure() {
    echo "CA Mager Configuration...!"
    Setup_Namespace cert-manager

    # kubectl apply -f ${PROD_DIR}/extra/Cert-Manager/CRDs.yaml
    kubectl apply --validate=false -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.12/deploy/manifests/00-crds.yaml
    helm repo add jetstack https://charts.jetstack.io
    sleep 3
    # helm install stable/cert-manager -n cert-manager ${namespace_options}
    helm install jetstack/cert-manager -n cert-manager ${namespace_options}
    Pod_Status_Wait
    kubectl apply -f ${PROD_DIR}/extra/Cert-Manager/certManagerCI_staging.yaml
    kubectl apply -f ${PROD_DIR}/extra/Cert-Manager/certManagerCI_production.yaml
}


#######################################
## Initial setup
function Setup_Namespace() {
    echo "Custom NameSpace Configuration : ${1}"

    if [[ ${1} == "create" ]] ; then
        kubectl create ns cas
        kubectl create ns orderers
        kubectl create ns peers
    elif [[ ${1} == "cas" ]] ; then
        export K8S_NAMESPACE=cas
        namespace_options="--namespace=${K8S_NAMESPACE}"
        echo ${namespace_options}
    elif [[ ${1} == "orderers" ]] ; then
        export K8S_NAMESPACE=orderers
        namespace_options="--namespace=${K8S_NAMESPACE}"
        echo ${namespace_options}
    elif [[ ${1} == "peers" ]] ; then
        export K8S_NAMESPACE=peers
        namespace_options="--namespace=${K8S_NAMESPACE}"
        echo ${namespace_options}
    elif [[ ${1} == "cert-manager" ]] ; then
        export K8S_NAMESPACE=cert-manager
        namespace_options="--namespace=${K8S_NAMESPACE}"
        echo ${namespace_options}
    elif [[ ${1} == "ingress-controller" ]] ; then
        export K8S_NAMESPACE=ingress-controller
        namespace_options="--namespace=${K8S_NAMESPACE}"
        echo ${namespace_options}
    else
        echo "User input for Setup_Namespace is mandatory"
    fi
}


#######################################
## Docker in Docker
function Dind_Configure() {
    echo "Configure Dind server for the deployment...!"
    Setup_Namespace peers
    helm install ar-repo/dind -n dindserver ${namespace_options} -f ${PROD_DIR}/helm_values/dind.yaml
    DIND_POD=$(kubectl ${namespace_options} get pods -l "app=dind" -o jsonpath="{.items[0].metadata.name}")
    Pod_Status_Wait ${DIND_POD}
}


#######################################
## Chaincode storage
function CC_Storage_Configure() {
    if [[ -z ${CLOUD_PROVIDER} ]] ; then
        echo "CLOUD_PROVIDER can't be empty...!"
        Cloud_Provider
    fi

    echo "Configure Chaincode Storage on ${CLOUD_PROVIDER}...!"
    Setup_Namespace peers
    if $(kubectl get storageclass rwmany > /dev/null 2>&1) ; then
        kubectl ${namespace_options} apply -f ${PROD_DIR}/extra/Storage/${CLOUD_PROVIDER}-chaincode-pvc.yaml
    else
        echo "storageclass : rwmany not found....!"
        exit 1
    fi

    kubectl ${namespace_options} apply -f ${PROD_DIR}/extra/Chaincode-Jobs/chaincode_storage.yaml
    CC_STORAGE_POD=$(kubectl ${namespace_options} get pods -l "component=chaincodestorage,role=storage-server" -o jsonpath="{.items[0].metadata.name}")
    Pod_Status_Wait ${CC_STORAGE_POD}
}


#######################################
## Initial setup
function Choose_Env() {
    echo "Choose Env Configuration : ${1}"

    if [[ ${1} == "org_number" ]] ; then
        export ORG_NUM=""
        # until [[ "${ORG_NUM}" =~ ^[0-9]+$ ]] ; do
        until [[ "${ORG_NUM}" == "1" ]] || [[ "${ORG_NUM}" == "2" ]] ; do
        read -r -p "Enter Organisation Num (integers only : 1 or 2) :: " ORG_NUM </dev/tty
        done
        echo "Configuring Organisation with Num :: ${ORG_NUM}"
        export ORG_NUM=${ORG_NUM}
    elif [[ ${1} == "order_number" ]] ; then
        export ORDERER_NUM=""
        # until [[ "${ORDERER_NUM}" =~ ^[0-9]+$ ]] ; do
        until [[ "${ORDERER_NUM}" == "1" ]] || [[ "${ORDERER_NUM}" == "2" ]] || [[ "${ORDERER_NUM}" == "3" ]] || [[ "${ORDERER_NUM}" == "4" ]] || [[ "${ORDERER_NUM}" == "5" ]] ; do
        read -r -p "Enter Orderer ID (integers only : 1 , 2 , 3 , 4 or 5) :: " ORDERER_NUM </dev/tty
        done
        echo "Configuring Orderer with ID :: ${ORDERER_NUM}"
        export ORDERER_NUM="${ORDERER_NUM}"
    elif [[ ${1} == "peer_number" ]] ; then
        export PEER_NUM=""
        # until [[ "${PEER_NUM}" =~ ^[0-9]+$ ]] ; do
        until [[ "${PEER_NUM}" == "1" ]] || [[ "${PEER_NUM}" == "2" ]] || [[ "${PEER_NUM}" == "3" ]] || [[ "${PEER_NUM}" == "4" ]] ; do
        read -r -p "Enter Peer ID (integers only : 1 , 2 , 3 or 4) :: " PEER_NUM </dev/tty
        done
        echo "Configuring Peer with ID :: ${PEER_NUM}"
        export PEER_NUM="${PEER_NUM}"
    elif [[ ${1} == "channel_name" ]] ; then
        export CHANNEL_NAME=""
        until [[ ! -z "${CHANNEL_NAME}" ]] ; do
        read -r -p "Enter Channel name :: " CHANNEL_NAME </dev/tty
        done
        echo "Configuring Channel with name :: ${CHANNEL_NAME}"
        export CHANNEL_NAME="${CHANNEL_NAME}"
    elif [[ ${1} == "channel_opt" ]] ; then
        export CHANNEL_OPT=""
        until [[ "${CHANNEL_OPT}" == "Org1Channel" ]] || [[ "${CHANNEL_OPT}" == "Org2Channel" ]] || [[ "${CHANNEL_OPT}" == "TwoOrgsChannel" ]] ; do
        read -r -p "Enter Channel Option (Org1Channel, Org2Channel or TwoOrgsChannel) :: " CHANNEL_OPT </dev/tty
        done
        echo "Configuring Channel with Option :: ${CHANNEL_OPT}"
        export CHANNEL_OPT="${CHANNEL_OPT}"
    else
        echo "User input for Choose_Env is mandatory"
    fi
}



#######################################
## Fabric CA
function Fabric_CA_Configure() {
    echo "Fabric CA Deployment...!"
    ## configuring namespace for fabric ca
    Setup_Namespace cas

    helm install ar-repo/hlf-ca -n ca ${namespace_options} -f ${PROD_DIR}/helm_values/ca.yaml
    export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")

    until kubectl logs ${namespace_options} ${CA_POD} | grep "Listening on" > /dev/null 2>&1 ; do
        sleep 2
        echo "waiting for CA to be up and running..!"
    done
    Pod_Status_Wait ${CA_POD}

    ## Check that we don't have a certificate
    if $(kubectl exec ${namespace_options} ${CA_POD} -- cat /var/hyperledger/fabric-ca/msp/signcerts/cert.pem > /dev/null 2>&1) ; then
        echo "Certificates are already available...!"
    else
        kubectl exec ${namespace_options} ${CA_POD} -- bash -c 'fabric-ca-client enroll -d -u http://${CA_ADMIN}:${CA_PASSWORD}@${SERVICE_DNS}:7054'
    fi

    ## Check that ingress works correctly
    Get_CA_Info
    curl https://${CA_INGRESS}/cainfo
}


#######################################
## getting CA_INGRESS
function Get_CA_Info() {
    echo "Fabric CA Info...!"
    Setup_Namespace cas
    export CA_INGRESS=$(kubectl get ingress ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].spec.rules[0].host}")
    export CA_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ca,release=ca" -o jsonpath="{.items[0].metadata.name}")
}


#######################################
## Org Orderer Organisation Identities
function Orgadmin_Orderer_Configure() {

    if [[ -d ${PROD_DIR}/config/OrdererMSP ]] ; then
        echo "Orderer Admin already configured...!"
        echo "Please move/rename the folder ${PROD_DIR}/config/OrdererMSP, then try to run this command again...!"
        echo ""
        echo -e "Delete the secrets also. \n kubectl -n orderers delete secrets hlf--ord-admincert hlf--ord-adminkey hlf--ord-ca-cert"
        echo ""

        Get_CA_Info
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id ord-admin > /dev/null 2>&1) ; then
            echo "identity of ord-admin already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : ord-admin from CA Server, then run the same command again to create it"
            echo -e "\n kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove ord-admin \n"
        else
            echo "No identity Registered on CA"
        fi
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        Get_CA_Info
        echo "Configuring Org Orderer Admin...!"
        export ORDERER_ADMIN_PASS=$(base64 <<< ${K8S_NAMESPACE}-ord-admin)
        export Admin_Conf=Orderer
        ## Get identity of ord-admin (this should not exist at first)
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id ord-admin > /dev/null 2>&1) ; then
            echo "identity of ord-admin already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : ord-admin from CA Server, then run the same command again to create it"
            echo "kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove ord-admin"
            echo ""
            echo "Warning :: I sure hope you know what you're doing...!"
            echo ""
            exit 1
        else
            ## Register Orderer Admin if the previous command did not work
            kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name ord-admin --id.secret ${ORDERER_ADMIN_PASS} --id.attrs 'admin=true:ecert'

            ## Enroll the Organisation Admin identity
            FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -u https://ord-admin:${ORDERER_ADMIN_PASS}@${CA_INGRESS} -M OrdererMSP
            mkdir -p ${PROD_DIR}/config/OrdererMSP/admincerts
            cp ${PROD_DIR}/config/OrdererMSP/signcerts/* ${PROD_DIR}/config/OrdererMSP/admincerts
            Save_Admin_Crypto
        fi
    fi
}


#######################################
## Org Peer Organisation Identities
function Orgadmin_Peer_Configure() {
    
    Choose_Env org_number
    if [[ -d ${PROD_DIR}/config/Org${ORG_NUM}MSP ]] ; then
        echo "Peer Admin already configured...!"
        echo "Please move/rename the folder ${PROD_DIR}/config/Org${ORG_NUM}MSP, then try to run this command again...!"
        echo ""
        echo -e "Delete the secrets also. \n kubectl -n peers delete secrets hlf--peer-org${ORG_NUM}-admincert hlf--peer-org${ORG_NUM}-adminkey hlf--peer-org${ORG_NUM}-ca-cert"
        echo ""
        Get_CA_Info
        echo -e "\n Checking the identity on CA...! \n"
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id peer-org${ORG_NUM}-admin > /dev/null 2>&1) ; then
            echo "identity of peer-org${ORG_NUM}-admin already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : peer-org${ORG_NUM}-admin from CA Server, then run the same command again to create it"
            echo -e "\n kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove peer-org${ORG_NUM}-admin \n"
            echo ""
        else
            echo "No identity Registered on CA"
        fi
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        Get_CA_Info
        echo "Configuring Org Peer Admin...!"
        export PEER_ADMIN_PASS=$(base64 <<< ${K8S_NAMESPACE}-peer-org${ORG_NUM}-admin)
        export Admin_Conf=Peer

        ## Get identity of peer-org${ORG_NUM}-admin (this should not exist at first)
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id peer-org${ORG_NUM}-admin > /dev/null 2>&1) ; then
            echo "identity of peer-org${ORG_NUM}-admin already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : peer-org${ORG_NUM}-admin from CA Server, then run the same command again to create it"
            echo "kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove peer-org${ORG_NUM}-admin"
            echo ""
            echo "Warning :: I sure hope you know what you're doing...!"
            echo ""
            exit 1
        else
            ## Register Peer Admin if the previous command did not work
            kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name peer-org${ORG_NUM}-admin --id.secret ${PEER_ADMIN_PASS} --id.attrs 'admin=true:ecert'

            ## Enroll the Organisation Admin identity
            FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -u https://peer-org${ORG_NUM}-admin:${PEER_ADMIN_PASS}@${CA_INGRESS} -M Org${ORG_NUM}MSP
            mkdir -p ${PROD_DIR}/config/Org${ORG_NUM}MSP/admincerts
            cp ${PROD_DIR}/config/Org${ORG_NUM}MSP/signcerts/* ${PROD_DIR}/config/Org${ORG_NUM}MSP/admincerts
            Save_Admin_Crypto
        fi
    fi
}


#######################################
## Save Crypto Material
function Save_Admin_Crypto() {

    if [[ ${Admin_Conf} == Orderer ]] ; then
        echo "Saving Orderer Crypto to K8s"
        ## Orderer Organisation
        Setup_Namespace orderers
        echo "Saving Crypto Material for ${Admin_Conf} with namespace_options : ${namespace_options}"

        ## Create a secret to hold the admin certificate:
        export ORG_CERT=$(ls ${PROD_DIR}/config/OrdererMSP/admincerts/cert.pem)
        kubectl create secret generic ${namespace_options} hlf--ord-admincert --from-file=cert.pem=${ORG_CERT}

        ## Create a secret to hold the admin key:
        export ORG_KEY=$(ls ${PROD_DIR}/config/OrdererMSP/keystore/*_sk)
        kubectl create secret generic ${namespace_options} hlf--ord-adminkey --from-file=key.pem=${ORG_KEY}

        ## Create a secret to hold the admin key CA certificate:
        export CA_CERT=$(ls ${PROD_DIR}/config/OrdererMSP/cacerts/*.pem)
        kubectl create secret generic ${namespace_options} hlf--ord-ca-cert --from-file=cacert.pem=${CA_CERT}

    elif [[ ${Admin_Conf} == Peer ]] ; then
        echo "Saving Peer Crypto to K8s"
        ## Peer Organisation
        Setup_Namespace peers
        echo "Saving Crypto Material for ${Admin_Conf} with namespace_options : ${namespace_options}"

        ## Create a secret to hold the admincert:
        export ORG_CERT=$(ls ${PROD_DIR}/config/Org${ORG_NUM}MSP/admincerts/cert.pem)
        kubectl create secret generic ${namespace_options} hlf--peer-org${ORG_NUM}-admincert --from-file=cert.pem=${ORG_CERT}

        ## Create a secret to hold the admin key:
        export ORG_KEY=$(ls ${PROD_DIR}/config/Org${ORG_NUM}MSP/keystore/*_sk)
        kubectl create secret generic ${namespace_options} hlf--peer-org${ORG_NUM}-adminkey --from-file=key.pem=${ORG_KEY}

        ## Create a secret to hold the CA certificate:
        export CA_CERT=$(ls ${PROD_DIR}/config/Org${ORG_NUM}MSP/cacerts/*.pem)
        kubectl create secret generic ${namespace_options} hlf--peer-org${ORG_NUM}-ca-cert --from-file=cacert.pem=${CA_CERT}

    else
        echo "Admin_Conf can't be empty...!"
    fi
}


#######################################
## Genesis and channel
function Genesis_Create() {

    Setup_Namespace orderers
    if [[ -f ${PROD_DIR}/config/genesis.block ]] ; then
        echo "genesis block already created...!"
        echo -e "Please move the file ${PROD_DIR}/config/genesis.block. \n Delete the secrets from orderer namespace : kubectl ${namespace_options} delete secrets hlf--genesis. \n then try to run this command again...!"
        echo ""
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        echo "Create Genesis Block...!"
        export P_W_D=${PWD} ; cd ${PROD_DIR}/config
        ## Create Genesis block
        configtxgen -profile OrdererGenesis -channelID systemchannel -outputBlock ./genesis.block
        ## Save them as secrets
        kubectl create secret generic ${namespace_options} hlf--genesis --from-file=genesis.block
        cd ${P_W_D}
    fi
}


#######################################
## Genesis and channel
function Channel_Create() {
    
    Setup_Namespace peers
    Choose_Env channel_name
    Choose_Env channel_opt
    if [[ -f ${PROD_DIR}/config/${CHANNEL_NAME}.tx ]] ; then
        echo "Channel block already created...!"
        echo -e "Please move the file ${PROD_DIR}/config/${CHANNEL_NAME}.tx. \n Delete the secrets from orderer namespace : kubectl ${namespace_options} delete secrets hlf--channel. \n then try to run this command again...!"
        echo ""
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        echo "Create Channel Block...!"

        export P_W_D=${PWD} ; cd ${PROD_DIR}/config
        ## Create Channel
        configtxgen -profile ${CHANNEL_OPT} -channelID ${CHANNEL_NAME} -outputCreateChannelTx ./${CHANNEL_NAME}.tx
        ## Save them as secrets
        kubectl create secret generic ${namespace_options} hlf--channel --from-file=${CHANNEL_NAME}.tx
        cd ${P_W_D}
    fi
}


#######################################
## Fabric Orderer nodes Creation
function Orderer_Conf() {

    Choose_Env order_number
    if [[ -d ${PROD_DIR}/config/ord${ORDERER_NUM}_MSP ]] ; then
        echo "ord${ORDERER_NUM} already configured...!"
        echo "Please move/rename the folder ${PROD_DIR}/config/ord${ORDERER_NUM}_MSP, then try to run this command again...!"
        echo ""
        echo -e "Delete the secrets also. \n kubectl -n orderers delete secrets hlf--ord${ORDERER_NUM}-idcert hlf--ord${ORDERER_NUM}-idkey"
        echo ""
        Get_CA_Info
        echo -e "\n Checking the identity on CA...! \n"
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id ord${ORDERER_NUM} > /dev/null 2>&1) ; then
            echo "identity of ord${ORDERER_NUM} already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : ord${ORDERER_NUM} from CA Server, then run the same command again to create it"
            echo -e "\n kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove ord${ORDERER_NUM} \n"
            echo ""
        else
            echo "No identity Registered on CA"
        fi
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        Get_CA_Info
        echo "Create and Add Orderer node...!"
        export ORDERER_NODE_PASS=$(base64 <<< ${K8S_NAMESPACE}-ord-${ORDERER_NUM})

        ## Get identity of ord${ORDERER_NUM} (this should not exist at first)
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id ord${ORDERER_NUM} > /dev/null 2>&1) ; then
            echo "identity of ord${ORDERER_NUM} already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : ord${ORDERER_NUM} from CA Server, then run the same command again to create it"
            echo "kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove ord${ORDERER_NUM}"
            echo ""
            echo "Warning :: I sure hope you know what you're doing...!"
            echo ""
            exit 1
        else
            kubectl exec ${namespace_options} $CA_POD -- fabric-ca-client register --id.name ord${ORDERER_NUM} --id.secret ${ORDERER_NODE_PASS} --id.type orderer
            FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -d -u https://ord${ORDERER_NUM}:${ORDERER_NODE_PASS}@${CA_INGRESS} -M ord${ORDERER_NUM}_MSP

            ## Save the Orderer certificate in a secret
            Setup_Namespace orderers
            export NODE_CERT=$(ls ${PROD_DIR}/config/ord${ORDERER_NUM}_MSP/signcerts/*.pem)
            kubectl create secret generic ${namespace_options} hlf--ord${ORDERER_NUM}-idcert --from-file=cert.pem=${NODE_CERT}

            ## Save the Orderer private key in another secret
            export NODE_KEY=$(ls ${PROD_DIR}/config/ord${ORDERER_NUM}_MSP/keystore/*_sk)
            kubectl create secret generic ${namespace_options} hlf--ord${ORDERER_NUM}-idkey --from-file=key.pem=${NODE_KEY}

            ## Install orderers using helm
            envsubst < ${PROD_DIR}/helm_values/ord.yaml > ${PROD_DIR}/config/MyConfig/ord${ORDERER_NUM}.yaml
            helm install ar-repo/hlf-ord -n ord${ORDERER_NUM} ${namespace_options} -f ${PROD_DIR}/config/MyConfig/ord${ORDERER_NUM}.yaml

            ## Get logs from orderer to check it's actually started
            export ORD_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-ord,release=ord${ORDERER_NUM}" -o jsonpath="{.items[0].metadata.name}")

            until kubectl logs ${namespace_options} ${ORD_POD} | grep 'completeInitialization' > /dev/null 2>&1 ; do
                echo "checking for completeInitialization ; waiting for ${ORD_POD} to start...!"
                sleep 2
            done
            Pod_Status_Wait ${ORD_POD}
            echo "Orderer nodes ord${ORDERER_NUM} started...! : ${ORD_POD}"
        fi
    fi
}


#######################################
## Fabric Peer nodes Creation
function Peer_Conf() {
    Choose_Env org_number
    Choose_Env peer_number
    if [[ -d ${PROD_DIR}/config/peer${PEER_NUM}-org${ORG_NUM}_MSP ]] ; then
        echo "peer${PEER_NUM}-org${ORG_NUM} already configured...!"
        echo "Please move/rename the folder ${PROD_DIR}/config/peer${PEER_NUM}-org${ORG_NUM}_MSP, then try to run this command again...!"
        echo ""
        echo -e "Delete the secrets also. \n kubectl -n peers delete secrets hlf--peer${PEER_NUM}-org${ORG_NUM}-idcert hlf--peer${PEER_NUM}-org${ORG_NUM}-idkey"
        echo ""
        Get_CA_Info
        echo -e "\n Checking the identity on CA...! \n"
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id peer${PEER_NUM}-org${ORG_NUM} > /dev/null 2>&1) ; then
            echo "identity of peer${PEER_NUM}-org${ORG_NUM} already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : peer${PEER_NUM}-org${ORG_NUM} from CA Server, then run the same command again to create it"
            echo -e "\n kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove peer${PEER_NUM}-org${ORG_NUM} \n"
            echo ""
        else
            echo "No identity Registered on CA"
        fi
        echo "Warning :: I sure hope you know what you're doing...!"
        echo ""
        exit 1
    else
        echo "Create and Add Peer node...!"
        export PEER_NODE_PASS=$(base64 <<< ${K8S_NAMESPACE}-peer${PEER_NUM}-org${ORG_NUM})

        ## Install CouchDB chart
        Setup_Namespace peers
        envsubst < ${PROD_DIR}/helm_values/cdb-peer.yaml > ${PROD_DIR}/config/MyConfig/cdb-peer${PEER_NUM}-org${ORG_NUM}.yaml
        helm install ar-repo/hlf-couchdb -n cdb-peer${PEER_NUM}-org${ORG_NUM} ${namespace_options} -f ${PROD_DIR}/config/MyConfig/cdb-peer${PEER_NUM}-org${ORG_NUM}.yaml

        ## Check that CouchDB is running
        export CDB_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-couchdb,release=cdb-peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[*].metadata.name}")

        until kubectl logs ${namespace_options} $CDB_POD | grep 'Apache CouchDB has started on' > /dev/null 2>&1 ; do
            echo "waiting for ${CDB_POD} to start...!"
            sleep 2
        done
        Pod_Status_Wait ${CDB_POD}
        echo "CouchDB started...! : ${CDB_POD}"

        Get_CA_Info
        ## Get identity of peer${PEER_NUM}-org${ORG_NUM} (this should not exist at first)
        if $(kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity list --id peer${PEER_NUM}-org${ORG_NUM} > /dev/null 2>&1) ; then
            echo "identity of peer${PEER_NUM}-org${ORG_NUM} already there...!"
            echo "If you really want to recreate the identity , the run the following command to remove the identiry : peer${PEER_NUM}-org${ORG_NUM} from CA Server, then run the same command again to create it"
            echo "kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client identity remove peer${PEER_NUM}-org${ORG_NUM}"
            echo ""
            echo "Warning :: I sure hope you know what you're doing...!"
            echo ""
            exit 1
        else
            kubectl exec ${namespace_options} ${CA_POD} -- fabric-ca-client register --id.name peer${PEER_NUM}-org${ORG_NUM} --id.secret ${PEER_NODE_PASS} --id.type peer
            FABRIC_CA_CLIENT_HOME=${PROD_DIR}/config fabric-ca-client enroll -d -u https://peer${PEER_NUM}-org${ORG_NUM}:${PEER_NODE_PASS}@${CA_INGRESS} -M peer${PEER_NUM}-org${ORG_NUM}_MSP


            ## Save the Peer certificate in a secret
            Setup_Namespace peers
            export NODE_CERT=$(ls ${PROD_DIR}/config/peer${PEER_NUM}-org${ORG_NUM}_MSP/signcerts/*.pem)
            kubectl create secret generic ${namespace_options} hlf--peer${PEER_NUM}-org${ORG_NUM}-idcert --from-file=cert.pem=${NODE_CERT}

            ## Save the Peer private key in another secret
            export NODE_KEY=$(ls ${PROD_DIR}/config/peer${PEER_NUM}-org${ORG_NUM}_MSP/keystore/*_sk)
            kubectl create secret generic ${namespace_options} hlf--peer${PEER_NUM}-org${ORG_NUM}-idkey --from-file=key.pem=${NODE_KEY}

            ## Install Peer using helm
            envsubst < ${PROD_DIR}/helm_values/peer.yaml > ${PROD_DIR}/config/MyConfig/peer${PEER_NUM}-org${ORG_NUM}.yaml
            helm install ar-repo/hlf-peer -n peer${PEER_NUM}-org${ORG_NUM} ${namespace_options} -f ${PROD_DIR}/config/MyConfig/peer${PEER_NUM}-org${ORG_NUM}.yaml

            ## check that Peer is running
            export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")

            until kubectl logs ${namespace_options} $PEER_POD | grep 'Starting peer' > /dev/null 2>&1 ; do
                echo "waiting for ${PEER_POD} to start...!"
                sleep 2
            done
            Pod_Status_Wait ${PEER_POD}
            echo "Peer node peer${PEER_NUM}-org${ORG_NUM} started...! : ${PEER_POD}"
        fi
    fi
}



#######################################
## Create channel
function Create_Channel_On_Peer() {

    Choose_Env channel_name
    if [[ -f ${PROD_DIR}/config/${CHANNEL_NAME}.tx ]] ; then
        echo "Create channel : ${CHANNEL_NAME} in peer node : Peer1"
        Setup_Namespace peers
        ## Create channel (do this only once in Peer 1)
        export PEER_NUM="1"
        Choose_Env org_number

        echo "Configuring Channel with name :: $CHANNEL_NAME on peer : peer${PEER_NUM}-org${ORG_NUM}"
        export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")
        Pod_Status_Wait ${PEER_POD}
        kubectl ${namespace_options} cp ${PROD_DIR}/config/${CHANNEL_NAME}.tx ${PEER_POD}:/${CHANNEL_NAME}.tx
        echo "kubectl exec ${namespace_options} ${PEER_POD} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer channel create -o ord1-hlf-ord.orderers.svc.cluster.local:7050 -c ${CHANNEL_NAME} -f /${CHANNEL_NAME}.tx'" | bash
    else
        echo "Channel ${CHANNEL_NAME}.block for channel ${CHANNEL_NAME} not created yet...!"
        echo "Please run channel-block for create your channel..!"
        exit 1
    fi

}


# CORE_PEER_LOCALMSPID=Org1MSP
# CORE_PEER_MSPCONFIGPATH=/var/hyperledger/admin_msp/
# peer channel create -o ord1-hlf-ord.orderers.svc.cluster.local:7050 -c kogxchannel -f /kogxchannel.tx

#######################################
## Join and Fetch channel
function Join_Channel() {
    Setup_Namespace peers
    Choose_Env org_number
    Choose_Env peer_number
    Choose_Env channel_name

    echo "Join Channel in peer : peer${PEER_NUM}-org${ORG_NUM}"
    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")
    Pod_Status_Wait ${PEER_POD}
    echo "Connecting with Peer : peer${PEER_NUM}-org${ORG_NUM}on pod : ${PEER_POD}"
    echo "Fetching and joining Channel with name :: $CHANNEL_NAME on peer : peer${PEER_NUM}-org${ORG_NUM} wich has name : ${PEER_POD}"

    ## Fetch and join channel
    kubectl exec ${namespace_options} ${PEER_POD} -- rm -rf /var/hyperledger/${CHANNEL_NAME}.block
    kubectl exec ${namespace_options} ${PEER_POD} -- peer channel fetch config /var/hyperledger/${CHANNEL_NAME}.block -c ${CHANNEL_NAME} -o ord1-hlf-ord.orderers.svc.cluster.local:7050
    echo "kubectl exec ${namespace_options} ${PEER_POD} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer channel join -b /var/hyperledger/${CHANNEL_NAME}.block'" | bash
    echo "I'm Waiting for the peer to join to my channel...." ; sleep 5
    if [[ $(kubectl exec ${PEER_POD} ${namespace_options} -- peer channel list | grep ${CHANNEL_NAME}) ]] ; then
        echo "peer peer${PEER_NUM}-org${ORG_NUM} successfully joined to channel : ${CHANNEL_NAME}"
    else
        echo "Channel : ${CHANNEL_NAME} not found..!, please check it manually or debug the issue..!"
        echo "Use this command to confirm : kubectl exec ${PEER_POD} ${namespace_options} -- peer channel list | grep ${CHANNEL_NAME}"
        exit 1
    fi
}


#######################################
## Chaincode versioning
function CC_Version() {
    CC_Provider
    Setup_Namespace peers
    export CC_LOCATION_BASENAME=$(basename ${CC_LOCATION})
    export PEER_NUM=1
    export ORG_NUM=1

    kubectl ${namespace_options} apply -f ${PROD_DIR}/extra/Chaincode-Jobs/chaincode-ConfigMap.yaml
    CHAINCODE_NAME=$(kubectl ${namespace_options} get configmap chaincode-cm -o yaml | grep "CHAINCODE_NAME:" | awk '{print $2}')

    if [[ -z ${CHAINCODE_NAME} ]] ; then
        export CHAINCODE_NAME=mycc
    fi
    echo "Choosing CHAINCODE_NAME : ${CHAINCODE_NAME}"

    ## Peer pod : org1 peer1
    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")
    Pod_Status_Wait ${PEER_POD}

    if echo "kubectl exec ${namespace_options} ${PEER_POD} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer chaincode list --installed'" | bash | grep "${CHAINCODE_NAME}" ; then
        echo -e "chaincode with name : ${CHAINCODE_NAME} installed...\n checking the version"
        export CHAINCODE_OLD_VER=$(echo "kubectl exec ${namespace_options} ${PEER_POD} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer chaincode list --installed'" | bash | grep "${CHAINCODE_NAME}" | tail -1 | grep "Version:" | awk '{print $4}' | cut -f1 -d",")
        if [[ -z ${CHAINCODE_OLD_VER} ]] ; then
            export CHAINCODE_VER_SET=false
            echo "some issue while fetching the chaincode version"
            exit 1
        else
            export CHAINCODE_VER_SET=update
            echo "chaincode : ${CHAINCODE_NAME} with version : ${CHAINCODE_OLD_VER} found..!"
        fi
    else
        export CHAINCODE_VER_SET=initial
        echo -e "chaincode not found with name : ${CHAINCODE_NAME} one peer : ${PEER_POD} \n assuming that we are installing the chaincode at very first time...!"
    fi

    if [[ ${CHAINCODE_VER_SET} == "update" ]] ; then
        ## DinD server
        export DIND_POD=$(kubectl ${namespace_options} get pods -l "app=dind" -o jsonpath="{.items[0].metadata.name}")
        Pod_Status_Wait ${DIND_POD}

        echo "kubectl exec ${namespace_options} ${DIND_POD} -- sh -c 'rm -rf /tmp/VERSION && echo ${CHAINCODE_OLD_VER} > /tmp/VERSION'" | bash
        CHAINCODE_NEW_VER=$(kubectl exec ${namespace_options} ${DIND_POD} -- sh -c 'docker run --rm -v /tmp/:/app akhilrajmailbox/bump PATCH &> /dev/null && cat /tmp/VERSION')
        echo "Chaincode updating from verison : ${CHAINCODE_OLD_VER} to verison : ${CHAINCODE_NEW_VER}"
        export CHAINCODE_VERSION=${CHAINCODE_NEW_VER}
        ## envsubt

    elif [[ ${CHAINCODE_VER_SET} == "initial" ]] ; then
        echo "Installing chaincode with version 1.0.0"
        export CHAINCODE_VERSION=1.0.0
    else
        echo "Chaincode version won't update manually...!" 
    fi

    if [[ ! -z ${CHAINCODE_VERSION} ]] ; then
        echo "configuring configmap for the chaincode ver : ${CHAINCODE_VERSION}"
        envsubst < ${PROD_DIR}/extra/Chaincode-Jobs/chaincode-ConfigMap.yaml
        envsubst < ${PROD_DIR}/extra/Chaincode-Jobs/chaincode-ConfigMap.yaml > ${PROD_DIR}/config/MyConfig/chaincode-ConfigMap-${CHAINCODE_VERSION}.yaml
        kubectl ${namespace_options} apply -f ${PROD_DIR}/config/MyConfig/chaincode-ConfigMap-${CHAINCODE_VERSION}.yaml
    else
        echo "CHAINCODE_VERSION can't be empty...!"
        exit 1
    fi
}


#######################################
## Chaincode install
function CC_Install() {
    Setup_Namespace peers

    ## Configuring Shared storage server for chaincode
    CC_STORAGE_POD=$(kubectl ${namespace_options} get pods -l "component=chaincodestorage,role=storage-server" -o jsonpath="{.items[0].metadata.name}")
    Pod_Status_Wait ${CC_STORAGE_POD}

    ## checking DinD server
    export DIND_POD=$(kubectl ${namespace_options} get pods -l "app=dind" -o jsonpath="{.items[0].metadata.name}")
    Pod_Status_Wait ${DIND_POD}

    if kubectl exec ${namespace_options} ${CC_STORAGE_POD} -- ls /shared/${CC_LOCATION_BASENAME} ; then
        echo "${CC_LOCATION_BASENAME} already available in the network, backing up in remote system...!"
        kubectl exec ${namespace_options} ${CC_STORAGE_POD} -- mv /shared/${CC_LOCATION_BASENAME} /shared/${CC_LOCATION_BASENAME}-${CHAINCODE_NAME}-${CHAINCODE_OLD_VER}
    fi
    echo -e "\nCopying chaincode from local to remote system"
    kubectl cp ${namespace_options} ${CC_LOCATION} ${CC_STORAGE_POD}:/shared/

    echo -e "\nCreating installchaincode job"
    if kubectl exec ${namespace_options} ${CC_STORAGE_POD} -- ls /shared/${CC_LOCATION_BASENAME} ; then
        if kubectl ${namespace_options} get jobs | grep chaincodeinstall > /dev/null 2>&1 ; then
            kubectl ${namespace_options} delete jobs chaincodeinstall
        fi
        kubectl ${namespace_options} apply -f ${PROD_DIR}/extra/Chaincode-Jobs/chaincode_install.yaml
        Job_Status_Wait chaincodeinstall
    else
        echo -e "task aborthing \n Location : /shared/${CC_LOCATION_BASENAME} not found"
        exit 1
    fi
}


#######################################
## Chaincode instantiate / upgrade
function CC_Deploy() {
    Setup_Namespace peers
    if [[ ${CHAINCODE_VER_SET} == "initial" ]] ; then
        echo -e "\nCreating chaincodeinstantiate job"
        if kubectl ${namespace_options} get jobs | grep chaincodeinstantiate > /dev/null 2>&1 ; then
            kubectl ${namespace_options} delete jobs chaincodeinstantiate
        fi
        kubectl ${namespace_options} apply -f ${PROD_DIR}/extra/Chaincode-Jobs/chaincode_instantiate.yaml
        Job_Status_Wait chaincodeinstantiate dontkill
        echo -e "\n rollback initiated...! \n"
        CC_Delete
    elif [[ ${CHAINCODE_VER_SET} == "update" ]] ; then
        echo -e "\nCreating chaincodeupgrade job"
        if kubectl ${namespace_options} get jobs | grep chaincodeupgrade > /dev/null 2>&1 ; then
            kubectl ${namespace_options} delete jobs chaincodeupgrade
        fi
        kubectl ${namespace_options} apply -f ${PROD_DIR}/extra/Chaincode-Jobs/chaincode_upgrade.yaml
        Job_Status_Wait chaincodeupgrade dontkill
        echo -e "\n rollback initiated...! \n"
        CC_Delete
    else
        echo "CHAINCODE_VER_SET is empty...!"
        exit 1
    fi
}


#######################################
## Chaincode delete
function CC_Delete() {
    Setup_Namespace peers

    ## checking DinD server
    export DIND_POD=$(kubectl ${namespace_options} get pods -l "app=dind" -o jsonpath="{.items[0].metadata.name}")
    Pod_Status_Wait ${DIND_POD}

    ## Configuring Shared storage server for chaincode
    CC_STORAGE_POD=$(kubectl ${namespace_options} get pods -l "component=chaincodestorage,role=storage-server" -o jsonpath="{.items[0].metadata.name}")
    Pod_Status_Wait ${CC_STORAGE_POD}
    echo "kubectl exec ${namespace_options} ${CC_STORAGE_POD} -- rm -rf /shared/${CC_LOCATION_BASENAME}" | bash

    PEERS_PODS=$(kubectl ${namespace_options} get pods  | grep "^peer" | awk '{print $1}')
    CHAINCODE_NAME=$(kubectl ${namespace_options} get configmap chaincode-cm -o jsonpath="{.data.CHAINCODE_NAME}")
    CHAINCODE_VERSION=$(kubectl ${namespace_options} get configmap chaincode-cm -o jsonpath="{.data.CHAINCODE_VERSION}")

    for peer_pods in ${PEERS_PODS} ; do
        echo "executing chaincode delete function on peer : ${peer_pods}"
        if echo "kubectl exec ${namespace_options} ${peer_pods} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer chaincode list --installed'" | bash | grep ${CHAINCODE_NAME} | grep ${CHAINCODE_VERSION} ; then
            echo "chaincode ${CHAINCODE_NAME} with version : ${CHAINCODE_VERSION} found...!"
            echo "kubectl ${namespace_options} exec ${peer_pods} -- bash -c 'rm -rf /var/hyperledger/production/chaincodes/${CHAINCODE_NAME}.${CHAINCODE_VERSION}'" | bash
            if echo "kubectl exec ${namespace_options} ${peer_pods} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer chaincode list --installed'" | bash | grep ${CHAINCODE_NAME} | grep ${CHAINCODE_VERSION} ; then
                echo "tried to delete, but failed..!" ;
                exit 1 ;
            fi
        else
            echo "chaincode : ${CHAINCODE_NAME} not installed on peer ${peer_pods} with version : ${CHAINCODE_VERSION}"
        fi
    done




    # echo -e "\nCreating deletechaincode job"
    # if kubectl ${namespace_options} get jobs | grep chaincodedelete > /dev/null 2>&1 ; then
    #     kubectl ${namespace_options} delete jobs chaincodedelete
    # fi
    # kubectl ${namespace_options} apply -f ${PROD_DIR}/extra/Chaincode-Jobs/chaincode_delete.yaml
    # Job_Status_Wait chaincodedelete
}


#######################################
## List channel
function List_Channel() {
    Setup_Namespace peers
    Choose_Env org_number
    Choose_Env peer_number

    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")
    echo "List Channels which peer : peer${PEER_NUM}-org${ORG_NUM} has joined...!"
    kubectl exec ${PEER_POD} ${namespace_options} -- peer channel list
}


#######################################
## List Chaincode Install
function List_Chaincode_Install() {
    Setup_Namespace peers
    Choose_Env org_number
    Choose_Env peer_number
    
    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")
    echo "List chaincode which installed on peer : peer${PEER_NUM}-org${ORG_NUM}"
    echo "kubectl exec ${namespace_options} ${PEER_POD} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer chaincode list --installed'" | bash
}


#######################################
## List Chaincode Instantiate
function List_Chaincode_Instantiate() {
    Setup_Namespace peers
    Choose_Env org_number
    Choose_Env peer_number
    Choose_Env channel_name

    export PEER_POD=$(kubectl get pods ${namespace_options} -l "app=hlf-peer,release=peer${PEER_NUM}-org${ORG_NUM}" -o jsonpath="{.items[0].metadata.name}")
    if kubectl exec ${PEER_POD} ${namespace_options} -- peer channel list | grep ${CHANNEL_NAME} ; then
        echo "List chaincode which instantiated on peer : peer${PEER_NUM}-org${ORG_NUM} per on channel : ${CHANNEL_NAME}...!"
        echo "kubectl exec ${namespace_options} ${PEER_POD} -- bash -c 'CORE_PEER_MSPCONFIGPATH=\$ADMIN_MSP_PATH peer chaincode list --instantiated -C ${CHANNEL_NAME}'" | bash
    else
        echo -e "channel : ${CHANNEL_NAME} not found on peer : ${PEER_POD} \n Please check the channel name or run channel-ls to list the channel...!"
        exit 1
    fi
}











export Command_Usage="Usage: ./hgf.sh -o [OPTION...]"

while getopts ":o:" opt
   do
     case $opt in
        o ) option=$OPTARG;;
     esac
done



if [[ $option = initial ]]; then
    Helm_Configure
    echo "sleeping for 2 sec" ; sleep 2
    Storageclass_Configure
    Nginx_Configure
    Setup_Namespace create
    Dind_Configure
    CC_Storage_Configure
elif [[ $option = cert-manager ]]; then
    Cert_Manager_Configure
elif [[ $option = fabric-ca ]]; then
    echo "Configure CA Domain Name in file /helm_values/ca.yaml"
    Fabric_CA_Configure
elif [[ $option = org-orderer-admin ]]; then
    Orgadmin_Orderer_Configure
elif [[ $option = org-peer-admin ]]; then
    Orgadmin_Peer_Configure
elif [[ $option = genesis-block ]]; then
    Genesis_Create
elif [[ $option = channel-block ]]; then
    Channel_Create
elif [[ $option = orderer-create ]]; then
    Orderer_Conf
elif [[ $option = peer-create ]]; then
    Peer_Conf
elif [[ $option = channel-create ]]; then
    Create_Channel_On_Peer
elif [[ $option = channel-join ]]; then
    Join_Channel
elif [[ $option = cc-deploy ]]; then
    CC_Version
    CC_Install
    CC_Deploy
elif [[ $option = cc-delete ]]; then
    CC_Delete
elif [[ $option = channel-ls ]]; then
    List_Channel
elif [[ $option = cc-install-ls ]]; then
    List_Chaincode_Install
elif [[ $option = cc-instantiate-ls ]]; then
    List_Chaincode_Instantiate
else
	echo "$Command_Usage"
cat << EOF
_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_

Main modes of operation:

initial             :   Initialisation for the HLF Cluster, It will create fast storageclass, nginx ingress and namespaces
cert-manager        :   CA Mager Configuration
fabric-ca           :   Deploy Fabric CA on namespace ca 
org-orderer-admin   :   Orderer Admin certs creation and store it in the K8s secrets on namespace orderers
org-peer-admin      :   Peer Admin certs creation and store it in the K8s secrets on namespace peers
genesis-block       :   Genesis block creation
channel-block       :   Creating the Channel
orderer-create      :   Create the Orderers certs and configure it in the K8s secrets, Deploying the Orderers nodes on namespace orderers
peer-create         :   Create the Orderers certs and configure it in the K8s secrets, Deploying the Peers nodes on namespace peers
channel-create      :   One time configuraiton on first peer (peer-org1-1 / peer-org2-1) on each organisation ; Creating the channel in one peer
channel-join        :   Join to the channel which we created before
cc-deploy           :   Install / Instantiate / Upgrade chaincode
cc-delete           :   Delete the latest version of installed chaincode
channel-ls          :   List all channels which a particular peer has joined
cc-install-ls       :   List chaincode which installed on a particular peer
cc-instantiate-ls   :   List chaincode which instantiated on a particular peer per channel

_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
EOF
fi
