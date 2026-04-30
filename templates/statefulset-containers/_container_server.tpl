{{- define "nifi.container.server" }}
{{- $vals := .Values.VaultNiFiSecrets }}
      - name: server
        imagePullPolicy: {{ .Values.image.pullPolicy | quote }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        command:
        - bash
        - -ce
        - |
{{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSidecar") }}   
          wait_for_sidecar_http_ready() {
            local url="${1:-http://127.0.0.1:8080/ready}"
            local timeout=${WAIT_SIDECAR_TIMEOUT:-120}
            local interval=${WAIT_SIDECAR_INTERVAL:-2}
            local start=$(date +%s)

            echo "Waiting for sidecar HTTP readiness at $url (timeout ${timeout}s)..."
            while :; do
              if command -v curl >/dev/null 2>&1; then
                if curl -sSf --connect-timeout 5 "$url" >/dev/null 2>&1; then
                  echo "Sidecar HTTP readiness succeeded via curl"
                  return 0
                fi
              elif command -v wget >/dev/null 2>&1; then
                if wget -qO- --timeout=5 "$url" >/dev/null 2>&1; then
                  echo "Sidecar HTTP readiness succeeded via wget"
                  return 0
                fi
              elif command -v nc >/dev/null 2>&1; then
                if printf "GET /ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" | nc 127.0.0.1 8080 2>/dev/null | grep -q "HTTP/1\.[01] 2[0-9][0-9]"; then
                  echo "Sidecar HTTP readiness succeeded via nc"
                  return 0
                fi
              fi
              local now=$(date +%s)
              if [ $(( now - start )) -ge "$timeout" ]; then
                echo "Timed out waiting for sidecar HTTP readiness at $url" >&2
                return 1
              fi
              sleep "$interval"
            done
          }
          # Block until vault sidecar reports /ready
          if ! wait_for_sidecar_http_ready http://127.0.0.1:8080/ready; then
            echo "Sidecar did not become ready; aborting startup" >&2
            exit 1
          fi 
          
          #END Wait for vault sidecar 

          mkdir -p /tmp/scripts
          cat /etc/scripts/generate-env.sh > /tmp/scripts/generate-env.sh
          chmod +x /tmp/scripts/generate-env.sh
          # Collect all secrets with secretMode=env into a list
          env_payloads=""
          {{- range $i, $s := $vals.secrets }}
          {{- $mode := "" -}}
          {{- if $s.secretMode }}{{- $mode = (lower $s.secretMode) }}{{- end -}}
          {{- if eq $mode "env" }}
          env_payloads="${env_payloads} {{ $s.name }}::{{ printf "%s/%s" (trimSuffix "/" (default $vals.defaultContainerPath $s.containerPath)) $s.name }}"
          {{- end }}
          {{- end }}
          # Call generate-env.sh with the list
          /tmp/scripts/generate-env.sh ${env_payloads}
          # Source the generated env file
          if [ -f /tmp/env.sh ]; then
            echo "Sourcing secrets environment variables"
            . /tmp/env.sh
          else
            echo "No secrets environment file found at /tmp/env.sh"
          fi
          #END
{{- end }}
{{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSidecar") }}
          # Wait until every secret directory has at least one file on disk.
          # The SDK /ready endpoint fires before the first sync cycle writes files.
          _svault_timeout=${WAIT_SIDECAR_TIMEOUT:-120}
          _svault_start=$(date +%s)
          {{- range $s := $vals.secrets }}
          echo "Waiting for secret files in {{ $vals.defaultContainerPath }}/{{ $s.name }} ..."
          while [ -z "$(ls -A '{{ $vals.defaultContainerPath }}/{{ $s.name }}' 2>/dev/null)" ]; do
            if [ $(( $(date +%s) - _svault_start )) -ge "$_svault_timeout" ]; then
              echo "Timed out waiting for secret files in {{ $vals.defaultContainerPath }}/{{ $s.name }}" >&2
              exit 1
            fi
            sleep 2
          done
          echo "Secret files present in {{ $vals.defaultContainerPath }}/{{ $s.name }}"
          {{- end }}
          unset _svault_timeout _svault_start
          # Flatten each vault secret's subdirectory into secretsFilePath so all
          # secret files are accessible from a single directory.
          {{- $sp := .Values.properties.secretsFilePath }}
          mkdir -p "{{ $sp }}"
          {{- range $s := $vals.secrets }}
          {{- $srcDir := printf "%s/%s" $vals.defaultContainerPath $s.name }}
          {{- if ne $srcDir $sp }}
          for _f in "{{ $srcDir }}"/*; do
            [ -f "$_f" ] || continue
            cp "$_f" "{{ $sp }}/$(basename "$_f")"
          done
          {{- end }}
          {{- end }}
{{- end }}
          prop_replace () {
            target_file=${NIFI_HOME}/conf/${3:-nifi.properties}
            echo "updating ${1} in ${target_file}"
            if egrep "^${1}=" ${target_file} &> /dev/null; then
              sed -i -e "s|^$1=.*$|$1=$2|"  ${target_file}
            else
              echo ${1}=${2} >> ${target_file}
            fi
          }
          mkdir -p ${NIFI_HOME}/config-data/conf
{{- if .Values.sts.useHostNetwork }}
          FQDN="0.0.0.0"
{{- else }}
          FQDN=$(hostname -f)
{{- end }}

          # bootstrap.conf is mounted from a ConfigMap; copy to writable path first.
          cp "${NIFI_HOME}/conf/bootstrap.template.conf" "${NIFI_HOME}/conf/bootstrap.conf"

          cat "${NIFI_HOME}/conf/nifi.temp" > "${NIFI_HOME}/conf/nifi.properties"
{{ include "nifi.secretsInit" . }}
{{- if and .Values.certManager.enabled .Values.certManager.useMergedCACerts }}
          # Keep JVM merged-cacerts password in sync with runtime secret value.
          _ts_pass_escaped=$(printf '%s' "${NIFI_TLS_TRUSTSTORE_PASSWORD}" | sed 's/[&/\\]/\\&/g')
          if grep -q '^java.arg.102=' "${NIFI_HOME}/conf/bootstrap.conf"; then
            sed -i -e "s|^java.arg.102=.*$|java.arg.102=-Djavax.net.ssl.trustStorePassword=${_ts_pass_escaped}|" "${NIFI_HOME}/conf/bootstrap.conf"
          else
            echo "java.arg.102=-Djavax.net.ssl.trustStorePassword=${NIFI_TLS_TRUSTSTORE_PASSWORD}" >> "${NIFI_HOME}/conf/bootstrap.conf"
          fi
          unset _ts_pass_escaped
{{- end }}
{{- if .Values.auth.ldap.enabled }}
          cat "${NIFI_HOME}/conf/authorizers.temp" > "${NIFI_HOME}/conf/authorizers.xml"
          cat "${NIFI_HOME}/conf/login-identity-providers-ldap.xml" > "${NIFI_HOME}/conf/login-identity-providers.xml"
          xmlstarlet ed --inplace --update "//authorizers/userGroupProvider/property[@name='TLS - Keystore Password']" -v "${NIFI_TLS_KEYSTORE_PASSWORD}" "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/userGroupProvider/property[@name='TLS - Truststore Password']" -v "${NIFI_TLS_TRUSTSTORE_PASSWORD}" "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/userGroupProvider/property[@name='Manager DN']" -v "${LDAP_MANAGER_DN}" "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/userGroupProvider/property[@name='Manager Password']" -v "${LDAP_MANAGER_PASSWORD}" "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/userGroupProvider/property[@name='Initial User Identity admin']" -v "${INITIAL_ADMIN_IDENTITY}" "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/accessPolicyProvider/property[@name='Initial Admin Identity']" -v "${INITIAL_ADMIN_IDENTITY}" "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//loginIdentityProviders/provider/property[@name='TLS - Keystore Password']" -v "${NIFI_TLS_KEYSTORE_PASSWORD}" "${NIFI_HOME}/conf/login-identity-providers.xml"
          xmlstarlet ed --inplace --update "//loginIdentityProviders/provider/property[@name='TLS - Truststore Password']" -v "${NIFI_TLS_TRUSTSTORE_PASSWORD}" "${NIFI_HOME}/conf/login-identity-providers.xml"
          xmlstarlet ed --inplace --update "//loginIdentityProviders/provider/property[@name='Manager DN']" -v "${LDAP_MANAGER_DN}" "${NIFI_HOME}/conf/login-identity-providers.xml"
          xmlstarlet ed --inplace --update "//loginIdentityProviders/provider/property[@name='Manager Password']" -v "${LDAP_MANAGER_PASSWORD}" "${NIFI_HOME}/conf/login-identity-providers.xml"
          {{- if semverCompare "< 2.0.0-0" .Values.image.tag }}
          xmlstarlet ed --inplace --update "//authorizers/authorizer/property[@name='Initial Admin Identity']" -v "${INITIAL_ADMIN_IDENTITY}" "${NIFI_HOME}/conf/authorizers.xml"
          {{- end }}
          prop_replace nifi.sensitive.props.key "${NIFI_SENSITIVE_PROPS_KEY}"
          prop_replace nifi.security.keystorePasswd "${NIFI_TLS_KEYSTORE_PASSWORD}"
          prop_replace nifi.security.keyPasswd "${NIFI_TLS_KEYSTORE_PASSWORD}"
          prop_replace nifi.security.truststorePasswd "${NIFI_TLS_TRUSTSTORE_PASSWORD}"
{{- else if .Values.auth.oidc.enabled }}
          prop_replace nifi.security.user.login.identity.provider ''
          prop_replace nifi.security.user.authorizer managed-authorizer
          prop_replace nifi.security.user.oidc.discovery.url {{ .Values.auth.oidc.discoveryUrl }}
          prop_replace nifi.security.user.oidc.client.id {{ .Values.auth.oidc.clientId }}
          prop_replace nifi.security.user.oidc.client.secret {{ .Values.auth.oidc.clientSecret }}
          prop_replace nifi.security.user.oidc.claim.identifying.user {{ .Values.auth.oidc.claimIdentifyingUser }}
          xmlstarlet ed --inplace --delete "//authorizers/authorizer[identifier='single-user-authorizer']" "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/userGroupProvider/property[@name='Users File']" -v './auth-conf/users.xml' "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --delete "//authorizers/userGroupProvider/property[@name='Initial User Identity 1']" "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace \
                        --subnode "authorizers/userGroupProvider" --type 'elem' -n 'property' \
                          --value {{ .Values.auth.oidc.admin | quote }} \
                        --insert "authorizers/userGroupProvider/property[not(@name)]" --type attr -n name \
                          --value "Initial User Identity {{ .Values.replicaCount }}" \
                        "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/accessPolicyProvider/property[@name='Initial Admin Identity']" -v {{ .Values.auth.oidc.admin | quote }} "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/accessPolicyProvider/property[@name='Authorizations File']" -v './auth-conf/authorizations.xml' "${NIFI_HOME}/conf/authorizers.xml"
          {{- if .Values.properties.isNode }}
                      xmlstarlet ed --inplace --delete "authorizers/accessPolicyProvider/property[@name='Node Identity 1']" "${NIFI_HOME}/conf/authorizers.xml"
            {{ range untilStep 0 (int .Values.replicaCount) 1 }}
                      xmlstarlet ed --inplace \
                                    --subnode "authorizers/accessPolicyProvider" --type 'elem' -n 'property' \
                                    --value "CN={{ template "apache-nifi.fullname" $ }}-{{ . }}.{{ template "apache-nifi.fullname" $ }}-headless.{{ $.Release.Namespace }}.svc.{{ $.Values.certManager.clusterDomain }}, OU=NIFI" \
                                    --insert "authorizers/accessPolicyProvider/property[not(@name)]" --type attr -n name \
                                    --value "Node Identity {{ . }}" \
                                    "${NIFI_HOME}/conf/authorizers.xml"
                      xmlstarlet ed --inplace \
                                    --subnode "authorizers/userGroupProvider" --type 'elem' -n 'property' \
                                    --value "CN={{ template "apache-nifi.fullname" $ }}-{{ . }}.{{ template "apache-nifi.fullname" $ }}-headless.{{ $.Release.Namespace }}.svc.{{ $.Values.certManager.clusterDomain }}, OU=NIFI" \
                                    --insert "authorizers/userGroupProvider/property[not(@name)]" --type attr -n name \
                                    --value "Initial User Identity {{ . }}" \
                                    "${NIFI_HOME}/conf/authorizers.xml"
            {{/* range untilStep 0 (int .Values.replicaCount ) 1 */}}{{ end }}
          {{- end }}
{{- else if .Values.auth.clientAuth.enabled }}
          cat "${NIFI_HOME}/conf/authorizers.temp" > "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --delete "//authorizers/authorizer[identifier='single-user-authorizer']" "${NIFI_HOME}/conf/authorizers.xml"
{{- else if .Values.auth.singleUser.generateSecret }}
          bin/nifi.sh set-single-user-credentials \
            "$(tr -d '\r\n' < /opt/nifi/single-user-credentials/username)" \
            "$(tr -d '\r\n' < /opt/nifi/single-user-credentials/password)"
{{- else if .Values.auth.singleUser.username }}
          bin/nifi.sh set-single-user-credentials {{ .Values.auth.singleUser.username }} {{ .Values.auth.singleUser.password }}
{{- end }}

          prop_replace nifi.ui.banner.text $(hostname -s)
          prop_replace nifi.remote.input.host ${FQDN}
          prop_replace nifi.cluster.node.address ${FQDN}
          prop_replace nifi.zookeeper.connect.string ${NIFI_ZOOKEEPER_CONNECT_STRING}
          prop_replace nifi.web.http.host ${FQDN}

{{- if .Values.properties.kerberosKrb5Path }}
          prop_replace nifi.kerberos.krb5.file {{ .Values.properties.kerberosKrb5Path }}
{{- end }}

{{- if .Values.properties.webProxyHost }}
          # Update nifi.properties for web ui proxy hostname
          prop_replace nifi.web.proxy.host {{ .Values.properties.webProxyHost }}
{{- else }}
          prop_replace nifi.web.proxy.host {{ template "apache-nifi.fullname" $ }}.{{ .Release.Namespace }}.svc
{{- end }}

{{- if .Values.certManager.enabled }}
          xmlstarlet ed --inplace --delete "authorizers/accessPolicyProvider/property[@name='Node Identity 1']" "${NIFI_HOME}/conf/authorizers.xml"
{{ range untilStep 0 (int .Values.replicaCount) 1 }}
          xmlstarlet ed --inplace \
                        --subnode "authorizers/accessPolicyProvider" --type 'elem' -n 'property' \
                          --value "CN={{ template "apache-nifi.fullname" $ }}-{{ . }}.{{ template "apache-nifi.fullname" $ }}-headless.{{ $.Release.Namespace }}.svc.{{ $.Values.certManager.clusterDomain }}, OU=NIFI" \
                        --insert "authorizers/accessPolicyProvider/property[not(@name)]" --type attr -n name \
                          --value "Node Identity {{ . }}" \
                        "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace \
                        --subnode "authorizers/userGroupProvider" --type 'elem' -n 'property' \
                          --value "CN={{ template "apache-nifi.fullname" $ }}-{{ . }}.{{ template "apache-nifi.fullname" $ }}-headless.{{ $.Release.Namespace }}.svc.{{ $.Values.certManager.clusterDomain }}, OU=NIFI" \
                        --insert "authorizers/userGroupProvider/property[not(@name)]" --type attr -n name \
                          --value "Initial User Identity {{ . }}" \
                        "${NIFI_HOME}/conf/authorizers.xml"
{{/* range untilStep 0 (int .Values.replicaCount ) 1 */}}{{ end }}

          prop_replace nifi.security.keystore "${NIFI_HOME}/tls/keystore.jks"
          prop_replace nifi.security.keystoreType JKS
          prop_replace nifi.security.keystorePasswd "${NIFI_TLS_KEYSTORE_PASSWORD}"
          prop_replace nifi.security.keyPasswd "${NIFI_TLS_KEYSTORE_PASSWORD}"
          prop_replace nifi.security.truststorePasswd "${NIFI_TLS_TRUSTSTORE_PASSWORD}"
          prop_replace nifi.security.truststore "${NIFI_HOME}/tls/truststore.jks"
          prop_replace nifi.security.truststoreType JKS


          prop_replace nifi.web.https.host "$(hostname).{{ template "apache-nifi.fullname" $ }}-headless.{{ $.Release.Namespace }}.svc.{{ $.Values.certManager.clusterDomain }}"
          prop_replace nifi.cluster.node.address "$(hostname).{{ template "apache-nifi.fullname" $ }}-headless.{{ $.Release.Namespace }}.svc.{{ $.Values.certManager.clusterDomain }}"
          prop_replace nifi.web.https.network.interface.default eth0
          prop_replace nifi.web.https.network.interface.lo lo
          prop_replace nifi.web.http.host ""
          prop_replace nifi.web.http.port ""

          prop_replace nifi.security.autoreload.enabled true
          prop_replace nifi.security.autoreload.interval "{{ .Values.certManager.refreshSeconds }} secs"

          while [ ! -r "${NIFI_HOME}/tls/truststore.jks" ]
          do
            echo "${NIFI_HOME}/tls/truststore.jks" is not readable!  Waiting for cert-manager sidecar to populate it.
            sleep 2
          done

          while [ ! -r "${NIFI_HOME}/tls/keystore.jks" ]
          do
            echo "${NIFI_HOME}/tls/keystore.jks" is not readable!  Waiting for cert-manager sidecar to populate it.
            sleep 2
          done

{{- if .Values.certManager.useMergedCACerts }}
          while [ ! -r "${NIFI_HOME}/tls/cacerts-merged" ]
          do
            echo "${NIFI_HOME}/tls/cacerts-merged" is not readable!  Waiting for cert-manager sidecar to populate it.
            sleep 2
          done
{{- end }}

{{- /* if .Values.certManager.enabled */}}{{ else }}

          if [ ! -r "${NIFI_HOME}/conf/nifi-cert.pem" ]
          then
            /opt/nifi/nifi-toolkit-current/bin/tls-toolkit.sh standalone \
              -n '{{.Release.Name}}-nifi-0.{{.Release.Name}}-nifi-headless.{{.Release.Namespace}}.svc.cluster.local' \
              -C '{{.Values.auth.admin}}' \
              -o "${NIFI_HOME}/conf/" \
              -P {{.Values.auth.SSL.truststorePasswd}} \
              -S {{.Values.auth.SSL.keystorePasswd}} \
              --nifiPropertiesFile /opt/nifi/nifi-current/conf/nifi.properties
          fi

{{- /* if .Values.certManager.enabled */}}{{ end }}

{{- if .Values.properties.safetyValve }}
  {{- range $prop, $val := .Values.properties.safetyValve }}
          prop_replace {{ $prop }} "{{ $val }}" nifi.properties
  {{- end }}
{{- end }}

{{- if .Values.properties.sensitiveKeySetFile }}
          if [ ! -r {{ .Values.properties.sensitiveKeySetFile | quote }} ]
          then
{{- if .Values.properties.sensitiveKeyPrior }}
            prop_replace nifi.sensitive.props.key {{ .Values.properties.sensitiveKeyPrior | quote }}
{{- /* if .Values.properties.sensitiveKeyPrior */}}{{ else }}
            prop_replace nifi.sensitive.props.key ""
{{- /* if .Values.properties.sensitiveKeyPrior */}}{{ end }}
            bin/nifi.sh set-sensitive-properties-key "${NIFI_SENSITIVE_PROPS_KEY}"
            touch {{ .Values.properties.sensitiveKeySetFile | quote }}
          fi
{{- /* if .Values.properties.sensitiveKeySetFile */}}{{ end }}

          for f in "${NIFI_HOME}/conf/authorizers.xml" "${NIFI_HOME}/conf/login-identity-providers.xml" ${NIFI_HOME}/conf/nifi.properties
          do
            echo === $f ===
            cat $f
          done
          echo === end of files ===

          function prop () {
            target_file=${NIFI_HOME}/conf/nifi.properties
            egrep "^${1}=" ${target_file} | cut -d'=' -f2
          }

          function offloadNode() {
              FQDN=$(hostname -f)
              echo "disconnecting node '$FQDN'"
              baseUrl=https://${FQDN}:{{ .Values.properties.httpsPort }}

              echo "keystoreType=$(prop nifi.security.keystoreType)" > secure.properties
              echo "keystore=$(prop nifi.security.keystore)" >> secure.properties
              echo "keystorePasswd=$(prop nifi.security.keystorePasswd)" >> secure.properties
              echo "truststoreType=$(prop nifi.security.truststoreType)" >> secure.properties
              echo "truststore=$(prop nifi.security.truststore)" >> secure.properties
              echo "truststorePasswd=$(prop nifi.security.truststorePasswd)" >> secure.properties
              echo "proxiedEntity={{ .Values.auth.admin }}" >> secure.properties
             
              secureArgs="-p secure.properties"

              echo baseUrl ${baseUrl}
              echo "gracefully disconnecting node '$FQDN' from cluster"
              ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi get-nodes -ot json -u ${baseUrl} ${secureArgs} > nodes.json
              nnid=$(jq --arg FQDN "$FQDN" '.cluster.nodes[] | select(.address==$FQDN) | .nodeId' nodes.json)
              echo "disconnecting node ${nnid}"
              ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi disconnect-node -nnid $nnid -u ${baseUrl} ${secureArgs}
              echo ""
              echo "get a connected node"
              connectedNode=$(jq -r 'first(.cluster.nodes|=sort_by(.address)| .cluster.nodes[] | select(.status=="CONNECTED")) | .address' nodes.json)
              baseUrl=https://${connectedNode}:{{ .Values.properties.httpsPort }}
              echo baseUrl ${baseUrl}
              echo ""
              echo "wait until node has state 'DISCONNECTED'"
              while [[ "${node_state}" != "DISCONNECTED" ]]; do
                  sleep 1
                  ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi get-nodes -ot json -u ${baseUrl} ${secureArgs} > nodes.json
                  node_state=$(jq -r --arg FQDN "$FQDN" '.cluster.nodes[] | select(.address==$FQDN) | .status' nodes.json)
                  echo "state is '${node_state}'"
              done
              echo ""
              echo "node '${nnid}' was disconnected"
              echo "offloading node"
              ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi offload-node -nnid $nnid -u ${baseUrl} ${secureArgs}
              echo ""
              echo "wait until node has state 'OFFLOADED'"
              while [[ "${node_state}" != "OFFLOADED" ]]; do
                  sleep 1
                  ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi get-nodes -ot json -u ${baseUrl} ${secureArgs} > nodes.json
                  node_state=$(jq -r --arg FQDN "$FQDN" '.cluster.nodes[] | select(.address==$FQDN) | .status' nodes.json)
                  echo "state is '${node_state}'"
              done
          }

          deleteNode() {
              echo "deleting node"
              ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi delete-node -nnid ${nnid} -u ${baseUrl} ${secureArgs}
              echo "node deleted"
          }

          executeTrap() {
             echo Received trapped signal, beginning shutdown...;
{{- if .Values.properties.isNode }}
             offloadNode;
{{- end }}
             ./bin/nifi.sh stop;
{{- if .Values.properties.isNode }}
             deleteNode;
{{- end }}
             exit 0;
          }

          trap executeTrap TERM HUP INT;
          trap ":" EXIT

          exec bin/nifi.sh run & nifi_pid="$!"
          echo NiFi running with PID ${nifi_pid}.
          wait ${nifi_pid}

        resources:
{{ toYaml .Values.resources | indent 10 }}
        ports:
        - containerPort: {{ .Values.properties.httpsPort }}
{{- if .Values.sts.hostPort }}
          hostPort: {{ .Values.sts.hostPort }}
{{- end }}
          name: https
          protocol: TCP
        - containerPort: {{ .Values.properties.clusterPort }}
          name: cluster
          protocol: TCP
{{- if .Values.containerPorts  }}
{{ toYaml .Values.containerPorts | indent 8 }}
{{- end }}
        env:
        - name: NIFI_ZOOKEEPER_CONNECT_STRING
          value: {{ template "zookeeper.url" . }}
{{- if not (or (.Values.auth.ldap.enabled) (.Values.auth.oidc.enabled)) }}
        - name: NIFI_WEB_HTTPS_HOST
          value: 0.0.0.0
{{- end }}
{{- if .Values.env }}
{{ toYaml .Values.env | indent 8 }}
{{- end }}

#vault envFrom
{{- /* collect Vault secrets with secretMode=env for envFrom */ -}}
{{- $vals := default (dict) .Values.VaultNiFiSecrets -}}
{{- $envSecrets := list -}}
{{- $generatedSecretNames := list -}}

{{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSecretOperator") }}
  {{- range $s := $vals.secrets }}
    {{- $mode := default $vals.defaultSecretMode $s.secretMode }}
    {{- if eq $mode "env" }}
      {{- /* normalize & sanitize */ -}}
      {{- $nameClean := trimPrefix "/" $s.name -}}
      {{- $safeName := include "secret.sanitizeName" $nameClean -}}
      {{- $envSecrets = append $envSecrets (dict "safeName" $safeName "orig" $s) }}
      {{- $generatedSecretNames = append $generatedSecretNames (printf "vault-%s" $safeName) }}
    {{- end }}
  {{- end }}
{{- end }}

{{- /* Start from user-provided envFrom (could be nil or []) and remove any secretRef we auto-generate */ -}}
{{- $rawEnvFrom := default (list) .Values.envFrom -}}
{{- $cleanEnvFrom := list -}}

{{- range $rawEnvFrom }}
  {{- $item := . -}}
  {{- $secretRef := default (dict) (index $item "secretRef") -}}
  {{- $name := default "" (index $secretRef "name") -}}
  {{- if and $name (has $name $generatedSecretNames) }}
    {{- /* skip legacy duplicate like vault-nifi-secrets */ -}}
  {{- else }}
    {{- $cleanEnvFrom = append $cleanEnvFrom $item }}
  {{- end }}
{{- end }}

{{- /* treat envFrom as present only when cleaned list has entries */ -}}
{{- $hasUserEnvFrom := gt (len $cleanEnvFrom) 0 -}}

{{- /* render envFrom if user envFrom (cleaned) has entries OR any Vault env secrets exist */ -}}
{{- if or $hasUserEnvFrom (gt (len $envSecrets) 0) }}
        envFrom:
{{- if $hasUserEnvFrom }}
{{ toYaml $cleanEnvFrom | indent 8 }}
{{- end }}

{{- range $s := $envSecrets }}
        - secretRef:
            name: vault-{{ $s.safeName }}
{{- end }}
{{- end }}
#END vault envFrom


{{- if .Values.postStart }}
        lifecycle:
          postStart:
            exec:
              command: ["/bin/sh", "-c", {{ .Values.postStart | quote }}]
{{- end }}
{{- if .Values.properties.isNode }}
        readinessProbe:
{{- if not .Values.sts.startupProbe.enabled  }}
          initialDelaySeconds: 60
{{- end }}
          periodSeconds: 20
          tcpSocket:
            port: {{ .Values.properties.httpsPort }}
#           exec:
#             command:
#             - bash
#             - -c
#             - |
# {{- if .Values.properties.httpsPort }}
#               curl -kv \
#                 --cert ${NIFI_HOME}/config-data/certs/admin/crt.pem --cert-type PEM \
#                 --key ${NIFI_HOME}/config-data/certs/admin/key.pem --key-type PEM \
#                 https://$(hostname -f):{{ .Values.properties.httpsPort }}/nifi-api/controller/cluster > $NIFI_BASE_DIR/data/cluster.state
# {{- else }}
#               curl -kv \
#                 http://$(hostname -f):{{ .Values.properties.httpPort }}/nifi-api/controller/cluster > $NIFI_BASE_DIR/data/cluster.state
# {{- end }}
#               STATUS=$(jq -r ".cluster.nodes[] | select((.address==\"$(hostname -f)\") or .address==\"localhost\") | .status" $NIFI_BASE_DIR/data/cluster.state)

#               if [[ ! $STATUS = "CONNECTED" ]]; then
#                 echo "Node not found with CONNECTED state. Full cluster state:"
#                 jq . $NIFI_BASE_DIR/data/cluster.state
#                 exit 1
#               fi
{{- end }}
{{- if .Values.sts.startupProbe.enabled }}
        startupProbe:
          failureThreshold: {{ .Values.sts.startupProbe.failureThreshold }}
          periodSeconds: {{ .Values.sts.startupProbe.periodSeconds }}
          tcpSocket:
            port: {{ .Values.properties.httpsPort }}
{{- end }}
        livenessProbe:
{{- if not .Values.sts.startupProbe.enabled }}
          initialDelaySeconds: 90
{{- end }}
          periodSeconds: 60
          tcpSocket:
            port: {{ .Values.properties.httpsPort }}
        volumeMounts:
      # VaultSecretMounts
      {{- $vals := .Values.VaultNiFiSecrets }}
      {{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSecretOperator") -}}
      {{- /* Group secrets by effective containerPath; secrets sharing a path are merged into one projected volume */ -}}
      {{- $pathMap := dict -}}
      {{- range $s := $vals.secrets }}
      {{- $base := trimSuffix "/" (default $vals.defaultContainerPath $s.containerPath) }}
      {{- $pathMap = set $pathMap $base (append (default (list) (index $pathMap $base)) $s) }}
      {{- end }}
      {{- range $path := sortAlpha (keys $pathMap) }}
      {{- $volName := printf "vault-proj-%s" (include "secret.sanitizeName" (trimPrefix "/" $path)) }}
          - name: {{ $volName }}
            mountPath: {{ $path }}
            readOnly: true
      {{- end }}
      {{- end }}
      {{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSidecar") }}
          - name: secretfspath
            mountPath: {{ $vals.defaultContainerPath }}
          - name: secret-env-script
            mountPath: /etc/scripts
      {{- end }}
      # END VaultSecretMounts
      {{- if .Values.awsSecretsSync.enabled }}
          - name: aws-secrets-path
            mountPath: {{ .Values.awsSecretsSync.outputPath }}
      {{- end }}
      {{- if and .Values.properties.secretsName (ne (include "nifi.effectiveSecretsMode" .) "none") (ne (include "nifi.effectiveSecretsMode" .) "env") }}
          - name: k8s-secrets
            mountPath: {{ .Values.properties.secretsFilePath }}
            readOnly: true
      {{- end }}
      {{- if .Values.auth.singleUser.generateSecret }}
          - name: single-user-credentials
            mountPath: /opt/nifi/single-user-credentials
            readOnly: true
      {{- end }}

    {{- if .Values.NiFiSync.s3Sync.enabled}}
        {{- range .Values.NiFiSync.syncPaths }}
        {{- if ne .pathType "fs" }}
          - name: {{ include "apache-nifi.fullname" $ }}-{{ .pathName }}
            mountPath: {{ .localPath }}
        {{- end }}
        {{- end }}
    {{- /* if .Values.NiFiSync.s3Sync.enabled */}}{{ end }}
    {{- if or .Values.NiFiSync.s3Sync.enabled .Values.NiFiSync.UserPolicySync.enabled}}
          - mountPath: /opt/nifi/nifi-sync/scripts
            name: nifisync-scripts
    {{- /* if or .Values.NiFiSync.s3Sync.enabled .Values.NiFiSync.UserPolicySync.enabled */}}{{ end }}    
          - mountPath: /.mc
            name: s3config
          - mountPath: /opt/nifi/nifi-current/logs
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.logStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: logs
            {{- else }}
            name: "logs"
            {{- end }}
          - mountPath: /opt/nifi/data
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.dataStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: data
            {{- else }}
            name: "data"
            {{- end }}
          - mountPath: /opt/nifi/nifi-current/auth-conf/
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.authconfStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: auth-conf
            {{- else }}
            name: "auth-conf"
            {{- end }}
          - mountPath: /opt/nifi/custom
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.customStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: custom-data
            {{- else }}
            name: "custom-data"
            {{- end }}
          - mountPath: /opt/nifi/nifi-current/custom
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.customStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: custom-data
            {{- else }}
            name: "custom-data"
            {{- end }}
          - mountPath: /opt/nifi/nifi-current/config-data
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.configStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: config-data
            {{- else }}
            name: "config-data"
            {{- end }}
          - mountPath: /opt/nifi/status_repository/
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.statusRepoStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: status-repository
            {{- else }}
            name: "status-repository"
            {{- end }}
          - mountPath: /home/nifi/.ssh/
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.sshStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: ssh-data
            {{- else }}
            name: "ssh-data"
            {{- end }}
          - mountPath: /opt/nifi/flowfile_repository
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.flowfileRepoStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: flowfile-repository
            {{- else }}
            name: flowfile-repository
            {{- end }}
          - mountPath: /opt/nifi/content_repository
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.contentRepoStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: content-repository
            {{- else }}
            name: content-repository
            {{- end }}
          - mountPath: /opt/nifi/provenance_repository
            {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.provenanceRepoStorage.DisallowSubPath) }}
            name: {{ .Values.persistence.subPath.name }}
            subPath: provenance-repository
            {{- else }}
            name: provenance-repository
            {{- end }}  
          - name: "bootstrap-conf"
            mountPath: /opt/nifi/nifi-current/conf/bootstrap.template.conf
            subPath: "bootstrap.conf"
          - name: "nifi-properties"
            mountPath: /opt/nifi/nifi-current/conf/nifi.temp
            subPath: "nifi.temp"
          - name: "authorizers-temp"
            mountPath: /opt/nifi/nifi-current/conf/authorizers.temp
            subPath: "authorizers.temp"
          - name: "bootstrap-notification-services-xml"
            mountPath: /opt/nifi/nifi-current/conf/bootstrap-notification-services.xml
            subPath: "bootstrap-notification-services.xml"
          - name: "login-identity-providers-ldap-xml"
            mountPath: /opt/nifi/nifi-current/conf/login-identity-providers-ldap.xml
            subPath: "login-identity-providers-ldap.xml"
          - name: "state-management-xml"
            mountPath: /opt/nifi/nifi-current/conf/state-management.xml
            subPath: "state-management.xml"
          - name: "zookeeper-properties"
            mountPath: /opt/nifi/nifi-current/conf/zookeeper.properties
            subPath: "zookeeper.properties"
          - name: "flow-content"
            mountPath: /opt/nifi/data/flow.xml
            subPath: "flow.xml"
          {{- range $secret := .Values.secrets }}
            {{- if $secret.mountPath }}
              {{- if $secret.keys }}
                {{- range $key := $secret.keys }}
          - name: {{ include "apache-nifi.fullname" $ }}-{{ $secret.name }}
            mountPath: {{ $secret.mountPath }}/{{ $key }}
            subPath: {{ $key }}
            readOnly: true
                {{- end }}
              {{- else }}
          - name: {{ include "apache-nifi.fullname" $ }}-{{ $secret.name }}
            mountPath: {{ $secret.mountPath }}
            readOnly: true
              {{- end }}
            {{- end }}
          {{- end }}
          {{- range $configmap := .Values.configmaps }}
            {{- if $configmap.mountPath }}
              {{- if $configmap.keys }}
                {{- range $key := $configmap.keys }}
          - name: {{ include "apache-nifi.fullname" $ }}-{{ $configmap.name }}
            mountPath: {{ $configmap.mountPath }}/{{ $key }}
            subPath: {{ $key }}
            readOnly: true
                {{- end }}
              {{- else }}
          - name: {{ include "apache-nifi.fullname" $ }}-{{ $configmap.name }}
            mountPath: {{ $configmap.mountPath }}
            readOnly: true
              {{- end }}
            {{- end }}
          {{- end }}
{{- if .Values.certManager.enabled }}
          - name: "tls"
            mountPath: /opt/nifi/nifi-current/tls
            readOnly: true
{{- /* if .Values.certManager.enabled */}}{{ end }}
          {{- if .Values.extraVolumeMounts }}
{{ toYaml .Values.extraVolumeMounts | indent 10 }}
          {{- end }}
{{- end }}

