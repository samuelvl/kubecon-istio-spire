#!/bin/sh
set -o nounset

deploy_hello_world_and_sleep_apps() {
  contexts=("$@")

  # Define the HelloWorld service YAML
  helloworld_service_yaml=$(cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: helloworld
  namespace: sample
spec:
  ports:
  - name: http
    port: 5000
  selector:
    app: helloworld
EOF
  )

  # Deploy HelloWorld v1 and its service in the first cluster
  kubectl create --context="${contexts[0]}" namespace sample
  kubectl label --context="${contexts[0]}" namespace sample istio-injection=enabled
  echo "$helloworld_service_yaml" | kubectl apply --context="${contexts[0]}" -f -
  kubectl apply --context="${contexts[0]}" -n sample -f \
    https://raw.githubusercontent.com/istio/istio/release-1.20/samples/helloworld/helloworld.yaml \
    -l app=helloworld -l version=v1

  # Deploy HelloWorld v2 and its service in the second cluster
  if [ "${#contexts[@]}" -gt 1 ]; then
    kubectl create --context="${contexts[1]}" namespace sample
    kubectl label --context="${contexts[1]}" namespace sample istio-injection=enabled
    echo "$helloworld_service_yaml" | kubectl apply --context="${contexts[1]}" -f -
    kubectl apply --context="${contexts[1]}" -n sample -f \
      https://raw.githubusercontent.com/istio/istio/release-1.20/samples/helloworld/helloworld.yaml \
      -l app=helloworld -l version=v2
  fi

  # Deploy Sleep in both clusters
  for context in "${contexts[@]}"; do
    kubectl apply --context="${context}" -n sample -f \
      https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml
  done
}

}

