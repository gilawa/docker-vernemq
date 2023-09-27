#!/usr/bin/env bash

# Check istio readiness
istio_health() {
  cmd=$(curl -s http://localhost:15021/healthz/ready > /dev/null)
  status=$?
  return $status
}

NET_INTERFACE=$(route | grep '^default' | grep -o '[^ ]*$')
NET_INTERFACE=${DOCKER_NET_INTERFACE:-${NET_INTERFACE}}
IP_ADDRESS=$(ip -4 addr show ${NET_INTERFACE} | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sed -e "s/^[[:space:]]*//" | head -n 1)
IP_ADDRESS=${DOCKER_IP_ADDRESS:-${IP_ADDRESS}}

VERNEMQ_ETC_DIR="/vernemq/etc"
VERNEMQ_VM_ARGS_FILE="${VERNEMQ_ETC_DIR}/vm.args"
VERNEMQ_CONF_FILE="${VERNEMQ_ETC_DIR}/vernemq.conf"
VERNEMQ_CONF_LOCAL_FILE="${VERNEMQ_ETC_DIR}/vernemq.conf.local"

SECRETS_KUBERNETES_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
CA_CRT_FILE="${SECRETS_KUBERNETES_DIR}/ca.crt"
NAMESPACE_FILE="${SECRETS_KUBERNETES_DIR}/namespace"
TOKEN_FILE="${SECRETS_KUBERNETES_DIR}/token"

# Ensure the Erlang node name is set correctly
if env | grep "DOCKER_VERNEMQ_NODENAME" -q; then
    sed -i.bak -r "s/-name VerneMQ@.+/-name VerneMQ@${DOCKER_VERNEMQ_NODENAME}/" ${VERNEMQ_VM_ARGS_FILE}
else
    if [ -n "$DOCKER_VERNEMQ_SWARM" ]; then
        NODENAME=$(hostname -i)
        sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${NODENAME}/" /etc/vernemq/vm.args
    else
        sed -i.bak -r "s/-name VerneMQ@.+/-name VerneMQ@${IP_ADDRESS}/" ${VERNEMQ_VM_ARGS_FILE}
    fi
fi

if env | grep "DOCKER_VERNEMQ_DISCOVERY_NODE" -q; then
    discovery_node=$DOCKER_VERNEMQ_DISCOVERY_NODE
    if [ -n "$DOCKER_VERNEMQ_SWARM" ]; then
        tmp=''
        while [[ -z "$tmp" ]]; do
            tmp=$(getent hosts tasks.$discovery_node | awk '{print $1}' | head -n 1)
            sleep 1
        done
        discovery_node=$tmp
    fi
    if [ -n "$DOCKER_VERNEMQ_COMPOSE" ]; then
        tmp=''
        while [[ -z "$tmp" ]]; do
            tmp=$(getent hosts $discovery_node | awk '{print $1}' | head -n 1)
            sleep 1
        done
        discovery_node=$tmp
    fi

    sed -i.bak -r "/-eval.+/d" ${VERNEMQ_VM_ARGS_FILE}
    echo "-eval \"vmq_server_cmd:node_join('VerneMQ@$discovery_node')\"" >> ${VERNEMQ_VM_ARGS_FILE}
fi

# If you encounter "SSL certification error (subject name does not match the host name)", you may try to set DOCKER_VERNEMQ_KUBERNETES_INSECURE to "1".
insecure=""
if env | grep "DOCKER_VERNEMQ_KUBERNETES_INSECURE" -q; then
    insecure="--insecure"
fi

if env | grep "DOCKER_VERNEMQ_KUBERNETES_ISTIO_ENABLED" -q; then
    istio_health
    while [ $status != 0 ]; do
        istio_health
        sleep 1
    done
    echo "Istio ready"
fi

if env | grep "DOCKER_VERNEMQ_DISCOVERY_KUBERNETES" -q; then
    DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME=${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME:-cluster.local}
    # Let's get the namespace if it isn't set
    DOCKER_VERNEMQ_KUBERNETES_NAMESPACE=${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE:-$(cat ${NAMESPACE_FILE})}
    # Let's set our nodename correctly
    AUTHORIZATION_HEADER="Authorization: Bearer $(cat ${TOKEN_FILE})"
    NAMESPACE_URL="https://kubernetes.default.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}/api/v1/namespaces/${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}"
    VERNEMQ_KUBERNETES_SUBDOMAIN=${DOCKER_VERNEMQ_KUBERNETES_SUBDOMAIN:-$(curl -sSX GET ${insecure} --cacert ${CA_CRT_FILE} ${NAMESPACE_URL}/pods?labelSelector=${DOCKER_VERNEMQ_KUBERNETES_LABEL_SELECTOR} -H ${AUTHORIZATION_HEADER} \
        | jq '.items[0].spec.subdomain' | sed 's/"//g' | tr '\n' '\0')}
    if [ $VERNEMQ_KUBERNETES_SUBDOMAIN == "null" ]; then
        VERNEMQ_KUBERNETES_HOSTNAME=${MY_POD_NAME}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}
    else
        VERNEMQ_KUBERNETES_HOSTNAME=${MY_POD_NAME}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}
    fi

    sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${VERNEMQ_KUBERNETES_HOSTNAME}/" ${VERNEMQ_VM_ARGS_FILE}
    # Hack into K8S DNS resolution (temporarily)
    kube_pod_names=$(curl -sSX GET $insecure --cacert ${CA_CRT_FILE} ${NAMESPACE_URL}/pods?labelSelector=${DOCKER_VERNEMQ_KUBERNETES_LABEL_SELECTOR} -H ${AUTHORIZATION_HEADER} \
        | jq '.items[].spec.hostname' | sed 's/"//g' | tr '\n' ' ')

    for kube_pod_name in $kube_pod_names; do
        if [ $kube_pod_name == "null" ]; then
            echo "Kubernetes discovery selected, but no pods found. Maybe we're the first?"
            echo "Anyway, we won't attempt to join any cluster."
            break
        fi
        if [ $kube_pod_name != $MY_POD_NAME ]; then
            echo "Will join an existing Kubernetes cluster with discovery node at ${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}"
            echo "-eval \"vmq_server_cmd:node_join('VerneMQ@${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}')\"" >> ${VERNEMQ_VM_ARGS_FILE}
            echo "Did I previously leave the cluster? If so, purging old state."
            curl -fsSL http://${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}:8888/status.json >/dev/null 2>&1 ||
                (echo "Can't download status.json, better to exit now" && exit 1)
            curl -fsSL http://${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}:8888/status.json | grep -q ${VERNEMQ_KUBERNETES_HOSTNAME} ||
                (echo "Cluster doesn't know about me, this means I've left previously. Purging old state..." && rm -rf /vernemq/data/*)
            break
        fi
    done
fi

if [ -f "${VERNEMQ_CONF_LOCAL_FILE}" ]; then
    cp "${VERNEMQ_CONF_LOCAL_FILE}" ${VERNEMQ_CONF_FILE}
    sed -i -r "s/###IPADDRESS###/${IP_ADDRESS}/" ${VERNEMQ_CONF_FILE}
else
    sed -i '/########## Start ##########/,/########## End ##########/d' ${VERNEMQ_CONF_FILE}

    echo "########## Start ##########" >> ${VERNEMQ_CONF_FILE}

    env | grep DOCKER_VERNEMQ | grep -v 'DISCOVERY_NODE\|KUBERNETES\|SWARM\|COMPOSE\|DOCKER_VERNEMQ_USER' | cut -c 16- | awk '{match($0,/^[A-Z0-9_]*/)}{print tolower(substr($0,RSTART,RLENGTH)) substr($0,RLENGTH+1)}' | sed 's/__/./g' >> ${VERNEMQ_CONF_FILE}

    users_are_set=$(env | grep DOCKER_VERNEMQ_USER)
    if [ ! -z "$users_are_set" ]; then
        echo "vmq_passwd.password_file = /vernemq/etc/vmq.passwd" >> ${VERNEMQ_CONF_FILE}
        touch /vernemq/etc/vmq.passwd
    fi

    for vernemq_user in $(env | grep DOCKER_VERNEMQ_USER); do
        username=$(echo $vernemq_user | awk -F '=' '{ print $1 }' | sed 's/DOCKER_VERNEMQ_USER_//g' | tr '[:upper:]' '[:lower:]')
        password=$(echo $vernemq_user | awk -F '=' '{ print $2 }')
        /vernemq/bin/vmq-passwd /vernemq/etc/vmq.passwd $username <<EOF
$password
$password
EOF
    done

    if [ -z "$DOCKER_VERNEMQ_ERLANG__DISTRIBUTION__PORT_RANGE__MINIMUM" ]; then
        echo "erlang.distribution.port_range.minimum = 9100" >> ${VERNEMQ_CONF_FILE}
    fi

    if [ -z "$DOCKER_VERNEMQ_ERLANG__DISTRIBUTION__PORT_RANGE__MAXIMUM" ]; then
        echo "erlang.distribution.port_range.maximum = 9109" >> ${VERNEMQ_CONF_FILE}
    fi

    if [ -z "$DOCKER_VERNEMQ_LISTENER__TCP__DEFAULT" ]; then
        echo "listener.tcp.default = ${IP_ADDRESS}:1883" >> ${VERNEMQ_CONF_FILE}
    fi

    if [ -z "$DOCKER_VERNEMQ_LISTENER__WS__DEFAULT" ]; then
        echo "listener.ws.default = ${IP_ADDRESS}:8080" >> ${VERNEMQ_CONF_FILE}
    fi

    if [ -z "$DOCKER_VERNEMQ_LISTENER__VMQ__CLUSTERING" ]; then
        echo "listener.vmq.clustering = ${IP_ADDRESS}:44053" >> ${VERNEMQ_CONF_FILE}
    fi

    if [ -z "$DOCKER_VERNEMQ_LISTENER__HTTP__METRICS" ]; then
        echo "listener.http.metrics = ${IP_ADDRESS}:8888" >> ${VERNEMQ_CONF_FILE}
    fi

    echo "########## End ##########" >> ${VERNEMQ_CONF_FILE}
fi

# Check configuration file
/vernemq/bin/vernemq config generate 2>&1 > /dev/null | tee /tmp/config.out | grep error

if [ $? -ne 1 ]; then
    echo "configuration error, exit"
    echo "$(cat /tmp/config.out)"
    exit $?
fi

pid=0

# SIGUSR1-handler
siguser1_handler() {
    echo "stopped"
}

# SIGTERM-handler
sigterm_handler() {
    if [ $pid -ne 0 ]; then
        if [ -d "${SECRETS_KUBERNETES_DIR}" -a -f "${TOKEN_FILE}" ] ; then
            # this will stop the VerneMQ process, but first drain the node from all existing client sessions (-k)
            if [ -n "$VERNEMQ_KUBERNETES_HOSTNAME" ]; then
                terminating_node_name=VerneMQ@$VERNEMQ_KUBERNETES_HOSTNAME
            elif [ -n "$DOCKER_VERNEMQ_SWARM" ]; then
                terminating_node_name=VerneMQ@$(hostname -i)
            else
                terminating_node_name=VerneMQ@$IP_ADDRESS
            fi
            AUTHORIZATION_HEADER="Authorization: Bearer $(cat ${TOKEN_FILE})"
            NAMESPACE_URL="https://kubernetes.default.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}/api/v1/namespaces/${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}"
            kube_pod_names=$(curl -sSX GET ${insecure} --cacert ${CA_CRT_FILE} -H ${AUTHORIZATION_HEADER} ${NAMESPACE_URL}/pods?labelSelector=${DOCKER_VERNEMQ_KUBERNETES_LABEL_SELECTOR} \
                | jq '.items[].spec.hostname' | sed 's/"//g' | tr '\n' ' ')
            if [ $kube_pod_names == $MY_POD_NAME ]; then
                echo "I'm the only pod remaining, not performing leave and state purge."
                /vernemq/bin/vmq-admin node stop >/dev/null
            else
                # Lookup the NAMESPACE from the file again (maybe this should be changed into the DOCKER_VERNEMQ_KUBERNETES_NAMESPACE variable?)
                NAMESPACE=$(cat ${NAMESPACE_FILE})
                NAMESPACE_URL="https://kubernetes.default.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}/api/v1/namespaces/${NAMESPACE}"
                statefulset=$(curl -sSX GET --cacert ${CA_CRT_FILE} -H ${AUTHORIZATION_HEADER} \
                    ${NAMESPACE_URL}/pods/$(hostname) | jq -r '.metadata.ownerReferences[0].name')

                reschedule=$(curl -sSX GET --cacert ${CA_CRT_FILE} -H ${AUTHORIZATION_HEADER} \
                    ${NAMESPACE_URL}/statefulsets/${statefulset} | jq '.status.replicas == .status.currentReplicas')

                if [[ ${reschedule} == "true" ]]; then
                    echo "Reschedule is true, not leaving the cluster"
                    /vernemq/bin/vmq-admin node stop >/dev/null
                else
                    echo "Reschedule is false, leaving the cluster"
                    /vernemq/bin/vmq-admin cluster leave node=${terminating_node_name} -k && rm -rf /vernemq/data/*
                fi
            fi
        else
            # In non-k8s mode: Stop the vernemq node gracefully
            /vernemq/bin/vmq-admin node stop >/dev/null
        fi
        kill -s TERM ${pid}
        WAITFOR_PID=${pid}
        pid=0
        wait ${WAITFOR_PID}
    fi
    exit 143; # 128 + 15 -- SIGTERM
}

# Setup OS signal handlers
trap 'siguser1_handler' SIGUSR1
trap 'sigterm_handler' SIGTERM

# Start VerneMQ
/vernemq/bin/vernemq console -noshell -noinput $@ &
pid=$!
sleep 30 && echo "Adding API_KEY..." && /vernemq/bin/vmq-admin api-key add key=${API_KEY}
wait $pid
