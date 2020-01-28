#!/bin/bash
export JSON_TEMPLATE=ccp-template.json
export YAML_TEMPLATE=ccp-template.yaml
# export PROD_DIR="../../"
export PPORT=7051
export ORGS=(
        "1"
        "2")


if [[ -f ${JSON_TEMPLATE} ]] && [[ -f ${YAML_TEMPLATE} ]] ; then
    echo "both template files found...!"

    if [[ ! -d ${PROD_DIR}/config/MyConfig/ConnectionConfig ]] ; then
        echo "Custom Values Store Creating for Connection Config...!"
        mkdir ${PROD_DIR}/config/MyConfig/ConnectionConfig
    fi


function one_line_pem {
    # awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' $1
    echo "`awk 'NF {sub(/\\n/, ""); printf "%s\\\\\\\n",$0;}' $1`"
}

function json_ccp {
    local PP=$(one_line_pem $4)
    local CP=$(one_line_pem $5)
    local OP=$(one_line_pem $6)
    sed -e "s/\${ORG}/$1/" \
        -e "s/\${PPORT}/$2/" \
        -e "s/\${CA_INGRESS}/$3/" \
        -e "s#\${PEERPEM}#$PP#" \
        -e "s#\${CAPEM}#$CP#" \
        -e "s#\${ORDPEM}#$OP#" \
        -e "s/\${CA_NAME}/$7/" \
        ${JSON_TEMPLATE} 
}

function yaml_ccp {
    local PP=$(one_line_pem $4)
    local CP=$(one_line_pem $5)
    local OP=$(one_line_pem $6)
    sed -e "s/\${ORG}/$1/" \
        -e "s/\${PPORT}/$2/" \
        -e "s/\${CA_INGRESS}/$3/" \
        -e "s#\${PEERPEM}#$PP#" \
        -e "s#\${CAPEM}#$CP#" \
        -e "s#\${ORDPEM}#$OP#" \
        -e "s/\${CA_NAME}/$7/" \
        ${YAML_TEMPLATE} | sed -e $'s/\\\\n/\\\n        /g'
}


for ORG in ${ORGS[@]} ; do
    echo -e "\ncreating Configfile for Organisation ${ORG}\n"
    export PEERPEM=$(ls ${PROD_DIR}/config/Org${ORG}MSP/cacerts/*.pem)
    export CAPEM=$(ls ${PROD_DIR}/config/Org${ORG}MSP/cacerts/*.pem)
    export ORDPEM=$(ls ${PROD_DIR}/config/Org${ORG}MSP/cacerts/*.pem)

    echo "$(json_ccp ${ORG} ${PPORT} ${CA_INGRESS} ${PEERPEM} ${CAPEM} ${ORDPEM} ${CA_NAME})" > ${PROD_DIR}/config/MyConfig/ConnectionConfig/connection-org${ORG}.json
    echo "$(yaml_ccp ${ORG} ${PPORT} ${CA_INGRESS} ${PEERPEM} ${CAPEM} ${ORDPEM} ${CA_NAME})" > ${PROD_DIR}/config/MyConfig/ConnectionConfig/connection-org${ORG}.yaml
done


else
    echo -e "\n${JSON_TEMPLATE} and/or ${YAML_TEMPLATE} not found...!\ntask aborting.....!"
    exit 1
fi