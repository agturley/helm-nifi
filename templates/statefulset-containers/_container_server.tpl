{{- define "nifi.container.server" }}
{{- $vals := .Values.VaultNiFiSecrets }}
      - name: server
        imagePullPolicy: {{ .Values.images.nifi.pullPolicy | quote }}
        image: "{{ .Values.images.nifi.repository }}:{{ .Values.images.nifi.tag }}"
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
{{- end }}
{{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSidecar") }}
          # Wait until every secret directory has at least one file on disk.
          # The SDK /ready endpoint fires before the first sync cycle writes files.
          # Only wait for secrets with secretMode: directory
          _svault_timeout=${WAIT_SIDECAR_TIMEOUT:-120}
          _svault_start=$(date +%s)
          {{- range $s := $vals.secrets }}
          {{- $mode := default $vals.defaultSecretMode $s.secretMode }}
          {{- if eq $mode "directory" }}
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
          {{- end }}
          unset _svault_timeout _svault_start
          # Flatten each vault secret's subdirectory into secretsFilePath so all
          # secret files are accessible from a single directory.
          # Only flatten secrets with secretMode: directory
          {{- $sp := .Values.properties.secretsFilePath }}
          mkdir -p "{{ $sp }}"
          {{- range $s := $vals.secrets }}
          {{- $mode := default $vals.defaultSecretMode $s.secretMode }}
          {{- if eq $mode "directory" }}
          {{- $srcDir := printf "%s/%s" $vals.defaultContainerPath $s.name }}
          {{- if ne $srcDir $sp }}
          for _f in "{{ $srcDir }}"/*; do
            [ -f "$_f" ] || continue
            cp "$_f" "{{ $sp }}/$(basename "$_f")"
          done
          {{- end }}
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
{{ include "nifi.awsSecretsSyncWait" . }}
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
          {{- if semverCompare "< 2.0.0-0" .Values.images.nifi.tag }}
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
                          --value "Initial User Identity {{ include "nifi.identityPoolSize" $ }}" \
                        "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/accessPolicyProvider/property[@name='Initial Admin Identity']" -v {{ .Values.auth.oidc.admin | quote }} "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace --update "//authorizers/accessPolicyProvider/property[@name='Authorizations File']" -v './auth-conf/authorizations.xml' "${NIFI_HOME}/conf/authorizers.xml"
          {{- if .Values.properties.isNode }}
                      xmlstarlet ed --inplace --delete "authorizers/accessPolicyProvider/property[@name='Node Identity 1']" "${NIFI_HOME}/conf/authorizers.xml"
            {{- if eq (include "nifi.sharedNodeIdentityMappingEnabled" $) "true" }}
                      xmlstarlet ed --inplace \
                                    --subnode "authorizers/accessPolicyProvider" --type 'elem' -n 'property' \
                                    --value "{{ include "nifi.sharedNodeIdentity" $ }}" \
                                    --insert "authorizers/accessPolicyProvider/property[not(@name)]" --type attr -n name \
                                    --value "Node Identity 0" \
                                    "${NIFI_HOME}/conf/authorizers.xml"
                      xmlstarlet ed --inplace \
                                    --subnode "authorizers/userGroupProvider" --type 'elem' -n 'property' \
                                    --value "{{ include "nifi.sharedNodeIdentity" $ }}" \
                                    --insert "authorizers/userGroupProvider/property[not(@name)]" --type attr -n name \
                                    --value "Initial User Identity 0" \
                                    "${NIFI_HOME}/conf/authorizers.xml"
            {{- else }}
            {{ range untilStep 0 (int (include "nifi.identityPoolSize" $)) 1 }}
                      xmlstarlet ed --inplace \
                                    --subnode "authorizers/accessPolicyProvider" --type 'elem' -n 'property' \
                                    --value "CN={{ include "nifi.nodeCN" (dict "ctx" $ "node" .) }}{{ include "nifi.nodeOU" $ }}" \
                                    --insert "authorizers/accessPolicyProvider/property[not(@name)]" --type attr -n name \
                                    --value "Node Identity {{ . }}" \
                                    "${NIFI_HOME}/conf/authorizers.xml"
                      xmlstarlet ed --inplace \
                                    --subnode "authorizers/userGroupProvider" --type 'elem' -n 'property' \
                                    --value "CN={{ include "nifi.nodeCN" (dict "ctx" $ "node" .) }}{{ include "nifi.nodeOU" $ }}" \
                                    --insert "authorizers/userGroupProvider/property[not(@name)]" --type attr -n name \
                                    --value "Initial User Identity {{ . }}" \
                                    "${NIFI_HOME}/conf/authorizers.xml"
            {{/* range untilStep 0 (int (include "nifi.identityPoolSize" $)) 1 */}}{{ end }}
            {{- end }}
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
{{- if eq (include "nifi.sharedNodeIdentityMappingEnabled" $) "true" }}
          xmlstarlet ed --inplace \
                        --subnode "authorizers/accessPolicyProvider" --type 'elem' -n 'property' \
                          --value "{{ include "nifi.sharedNodeIdentity" $ }}" \
                        --insert "authorizers/accessPolicyProvider/property[not(@name)]" --type attr -n name \
                          --value "Node Identity 0" \
                        "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace \
                        --subnode "authorizers/userGroupProvider" --type 'elem' -n 'property' \
                          --value "{{ include "nifi.sharedNodeIdentity" $ }}" \
                        --insert "authorizers/userGroupProvider/property[not(@name)]" --type attr -n name \
                          --value "Initial User Identity 0" \
                        "${NIFI_HOME}/conf/authorizers.xml"
{{- else }}
{{ range untilStep 0 (int (include "nifi.identityPoolSize" $)) 1 }}
          xmlstarlet ed --inplace \
                        --subnode "authorizers/accessPolicyProvider" --type 'elem' -n 'property' \
                          --value "CN={{ include "nifi.nodeCN" (dict "ctx" $ "node" .) }}{{ include "nifi.nodeOU" $ }}" \
                        --insert "authorizers/accessPolicyProvider/property[not(@name)]" --type attr -n name \
                          --value "Node Identity {{ . }}" \
                        "${NIFI_HOME}/conf/authorizers.xml"
          xmlstarlet ed --inplace \
                        --subnode "authorizers/userGroupProvider" --type 'elem' -n 'property' \
                          --value "CN={{ include "nifi.nodeCN" (dict "ctx" $ "node" .) }}{{ include "nifi.nodeOU" $ }}" \
                        --insert "authorizers/userGroupProvider/property[not(@name)]" --type attr -n name \
                          --value "Initial User Identity {{ . }}" \
                        "${NIFI_HOME}/conf/authorizers.xml"
{{/* range untilStep 0 (int (include "nifi.identityPoolSize" $)) 1 */}}{{ end }}
{{- end }}

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

          # Node disconnect/offload/delete happens in the preStop lifecycle
          # hook (see below), not here. The kubelet execs preStop directly
          # into the container - unlike this TERM trap, which interrupts the
          # 'wait' builtin in the PID1 shell - and live testing showed the
          # trap context makes toolkit CLI calls to peer nodes unreliable in
          # a way preStop's exec context does not.
          executeTrap() {
             echo Received trapped signal, beginning shutdown...;
             printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "trap: SIGTERM received, calling nifi.sh stop (pid $$)" >> /opt/nifi/data/prestop-timeline.log 2>/dev/null || true;
             ./bin/nifi.sh stop;
             printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "trap: nifi.sh stop returned, exiting 0 (pid $$)" >> /opt/nifi/data/prestop-timeline.log 2>/dev/null || true;
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
{{- $vals := .Values.VaultNiFiSecrets }}
{{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSidecar") }}
{{- $hasJsonAwsSecret := false }}
{{- range $s := $vals.secrets }}
{{- $mode := default $vals.defaultSecretMode $s.secretMode }}
{{- if and (eq $mode "aws-credential") (eq (default "" $s.awsCredentialFormat) "json") }}
{{- $hasJsonAwsSecret = true }}
{{- end }}
{{- end }}
{{- if $hasJsonAwsSecret }}
        - name: AWS_CONFIG_FILE
          value: "/opt/nifi/vault-scripts/aws-config"
{{- end }}
{{- end }}
{{- if .Values.env }}
{{ toYaml .Values.env | indent 8 }}
{{- end }}

{{- if .Values.envFrom }}
        envFrom:
{{ toYaml .Values.envFrom | indent 8 }}
{{- end }}


{{- if or .Values.postStart .Values.properties.isNode }}
        lifecycle:
{{- if .Values.postStart }}
          postStart:
            exec:
              command: ["/bin/sh", "-c", {{ .Values.postStart | quote }}]
{{- end }}
{{- if .Values.properties.isNode }}
          preStop:
            exec:
              command:
                - /bin/bash
                - -c
                - |
                  set -o pipefail
                  FQDN=$(hostname -f)
                  cd "${NIFI_HOME}" || exit 0

                  prop() {
                    egrep "^${1}=" "${NIFI_HOME}/conf/nifi.properties" | cut -d'=' -f2
                  }

                  # preStop's own stdout is NOT captured by `kubectl logs` (it's
                  # a separate kubelet exec session, discarded on success and
                  # reduced to a bare "PreStopHook failed" event on failure), so
                  # without this there is no way to see what happened between
                  # cluster removal and the pod actually disappearing. Logging
                  # to the persistent data volume means the timeline survives
                  # even after this pod is gone.
                  LOGFILE=/opt/nifi/data/prestop-timeline.log
                  log() {
                    local msg="$*"
                    echo "${msg}"
                    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "${msg}" >> "${LOGFILE}" 2>/dev/null || true
                  }
                  log "preStop: hook invoked (pid $$)"

                  # Only offload/disconnect/delete when this pod's own ordinal is
                  # actually being removed by a real scale-down, not on a routine
                  # restart/rolling-update (where this same ordinal will just be
                  # recreated). Determined via a live check against the
                  # StatefulSet's current spec.replicas, using a narrowly-scoped
                  # identity (get-only, this one named StatefulSet) that is
                  # completely separate from this pod's own serviceAccountName -
                  # see templates/scaledown-guard-sts-reader.yaml. That identity
                  # only exists when scaleDownGuard.enabled=true; when it's
                  # absent (the default), the safe default is to skip offload
                  # entirely rather than doing unnecessary drain work - and
                  # possibly failing - on every ordinary pod restart.
                  shortName="${FQDN%%.*}"
                  ordinal="${shortName##*-}"
                  stsTokenFile=/run/secrets/kubernetes.io/sts-reader-token/token
                  stsCaFile=/run/secrets/kubernetes.io/sts-reader-token/ca.crt
                  if [[ ! -r "${stsTokenFile}" ]]; then
                      log "preStop: sts-reader credentials not present (scaleDownGuard.enabled=false); skipping offload by default."
                      exit 0
                  fi
                  stsReplicas=$(timeout ${cli_timeout:-10} curl -sS --cacert "${stsCaFile}" \
                      -H "Authorization: Bearer $(cat "${stsTokenFile}")" \
                      "https://kubernetes.default.svc/apis/apps/v1/namespaces/{{ .Release.Namespace }}/statefulsets/{{ include "apache-nifi.fullname" . }}" \
                      2>/dev/null | jq -r '.spec.replicas // empty')
                  if [[ -n "${stsReplicas}" ]] && [[ "${ordinal}" -lt "${stsReplicas}" ]]; then
                      log "preStop: ordinal ${ordinal} is within current desired replica count (${stsReplicas}); this looks like a restart, not a scale-down. Skipping offload."
                      exit 0
                  fi
                  log "preStop: ordinal ${ordinal} is at or beyond current desired replica count (${stsReplicas:-unknown}); proceeding as a scale-down."

                  log "preStop: draining node '$FQDN'"
                  echo "keystoreType=$(prop nifi.security.keystoreType)" > /tmp/preStop-secure.properties
                  echo "keystore=$(prop nifi.security.keystore)" >> /tmp/preStop-secure.properties
                  echo "keystorePasswd=$(prop nifi.security.keystorePasswd)" >> /tmp/preStop-secure.properties
                  echo "truststoreType=$(prop nifi.security.truststoreType)" >> /tmp/preStop-secure.properties
                  echo "truststore=$(prop nifi.security.truststore)" >> /tmp/preStop-secure.properties
                  echo "truststorePasswd=$(prop nifi.security.truststorePasswd)" >> /tmp/preStop-secure.properties
                  echo "proxiedEntity={{ .Values.auth.admin }}" >> /tmp/preStop-secure.properties
                  secureArgs="-p /tmp/preStop-secure.properties"
                  cli_timeout=10
                  max_wait=25
                  drainQueueTimeout={{ .Values.properties.drainQueueTimeoutSeconds }}
                  drainStallLimit={{ .Values.properties.drainQueueStallLimit }}
                  baseUrl=https://${FQDN}:{{ .Values.properties.httpsPort }}

                  if ! timeout ${cli_timeout} ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi get-nodes -ot json -u ${baseUrl} ${secureArgs} > /tmp/preStop-nodes.json; then
                      log "preStop WARNING: get-nodes failed or timed out; skipping drain."
                      exit 0
                  fi
                  nnid=$(jq --arg FQDN "$FQDN" '.cluster.nodes[] | select(.address==$FQDN) | .nodeId' /tmp/preStop-nodes.json)
                  node_state=$(jq -r --arg FQDN "$FQDN" '.cluster.nodes[] | select(.address==$FQDN) | .status' /tmp/preStop-nodes.json)
                  if [[ "${node_state}" == "OFFLOADED" ]] || [[ -z "${node_state}" ]]; then
                      log "preStop: node already terminal or not found (state='${node_state}'); skipping drain."
                      exit 0
                  fi

                  log "preStop: disconnecting node ${nnid}"
                  if ! timeout ${cli_timeout} ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi disconnect-node -nnid $nnid -u ${baseUrl} ${secureArgs}; then
                      log "preStop WARNING: disconnect-node failed or timed out; skipping drain."
                      exit 0
                  fi

                  # Candidate peers to route requests through, rotated whenever
                  # a call fails - guards against picking a peer that is
                  # itself mid-shutdown (e.g. a multi-replica scale-down under
                  # sts.podManagementPolicy: Parallel disconnects several
                  # nodes at once, so "a connected peer" from a stale snapshot
                  # may no longer be reachable).
                  peers=()
                  peer_idx=0

                  refresh_peers() {
                      mapfile -t peers < <(jq -r --arg FQDN "$FQDN" '[.cluster.nodes[] | select(.status=="CONNECTED") | select(.address != $FQDN) | .address] | sort | .[]' /tmp/preStop-nodes.json)
                      if [[ ${#peers[@]} -eq 0 ]]; then
                          mapfile -t peers < <(jq -r --arg FQDN "$FQDN" '[.cluster.nodes[] | select(.address != $FQDN) | .address] | sort | .[]' /tmp/preStop-nodes.json)
                      fi
                  }

                  next_peer() {
                      refresh_peers
                      if [[ ${#peers[@]} -eq 0 ]]; then
                          return 1
                      fi
                      local p="${peers[$((peer_idx % ${#peers[@]}))]}"
                      peer_idx=$((peer_idx + 1))
                      baseUrl="https://${p}:{{ .Values.properties.httpsPort }}"
                      return 0
                  }

                  if ! next_peer; then
                      log "preStop WARNING: no peer available after disconnect; skipping offload."
                      exit 0
                  fi

                  log "preStop: waiting for DISCONNECTED (max ${max_wait}s)"
                  elapsed=0
                  while [[ "${node_state}" != "DISCONNECTED" ]] && [[ $elapsed -lt $max_wait ]]; do
                      sleep 1
                      elapsed=$((elapsed + 1))
                      if ! timeout ${cli_timeout} ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi get-nodes -ot json -u ${baseUrl} ${secureArgs} > /tmp/preStop-nodes.json.tmp; then
                          log "preStop WARNING: get-nodes via ${baseUrl} failed or timed out (${elapsed}s). Trying next peer."
                          next_peer || true
                          continue
                      fi
                      mv /tmp/preStop-nodes.json.tmp /tmp/preStop-nodes.json
                      node_state=$(jq -r --arg FQDN "$FQDN" '.cluster.nodes[] | select(.address==$FQDN) | .status' /tmp/preStop-nodes.json)
                      log "preStop: state is '${node_state}' (${elapsed}s) via ${baseUrl}"
                  done
                  if [[ $elapsed -ge $max_wait ]]; then
                      log "preStop WARNING: timeout waiting for DISCONNECTED; skipping offload."
                      exit 0
                  fi

                  log "preStop: offloading node ${nnid}"
                  offload_attempt=1
                  offload_max_attempts=3
                  while [[ $offload_attempt -le $offload_max_attempts ]]; do
                      if timeout ${cli_timeout} ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi offload-node -nnid $nnid -u ${baseUrl} ${secureArgs}; then
                          break
                      fi
                      log "preStop WARNING: offload-node via ${baseUrl} failed or timed out (attempt ${offload_attempt}/${offload_max_attempts})."
                      next_peer || true
                      offload_attempt=$((offload_attempt + 1))
                  done

                  log "preStop: waiting for OFFLOADED (max ${max_wait}s)"
                  elapsed=0
                  while [[ "${node_state}" != "OFFLOADED" ]] && [[ $elapsed -lt $max_wait ]]; do
                      sleep 1
                      elapsed=$((elapsed + 1))
                      if ! timeout ${cli_timeout} ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi get-nodes -ot json -u ${baseUrl} ${secureArgs} > /tmp/preStop-nodes.json.tmp; then
                          log "preStop WARNING: get-nodes via ${baseUrl} failed or timed out (${elapsed}s). Trying next peer."
                          next_peer || true
                          continue
                      fi
                      mv /tmp/preStop-nodes.json.tmp /tmp/preStop-nodes.json
                      node_state=$(jq -r --arg FQDN "$FQDN" '.cluster.nodes[] | select(.address==$FQDN) | .status' /tmp/preStop-nodes.json)
                      log "preStop: state is '${node_state}' (${elapsed}s) via ${baseUrl}"
                  done

                  # Reaching OFFLOADED does not mean queued content has actually
                  # finished relocating - for connections without Load Balancing
                  # explicitly enabled, that relocation is asynchronous and how
                  # long it takes scales with how much is actually queued, not a
                  # fixed duration. Poll this node's OWN local API (not the
                  # cluster-aggregated view, which can lag behind by a heartbeat
                  # interval or more) and keep waiting AS LONG AS the count is
                  # still going down - only give up if it stalls (no improvement
                  # for drainStallLimit consecutive polls) or the absolute
                  # drainQueueTimeoutSeconds ceiling is hit. The JVM is still up
                  # at this point, so it can still answer about itself even
                  # though it's left the cluster.
                  log "preStop: waiting for locally queued content to drain (max ${drainQueueTimeout}s, giving up after ${drainStallLimit} polls with no progress)"
                  selfUrl=https://${FQDN}:{{ .Values.properties.httpsPort }}
                  self_queued=""
                  last_queued=""
                  stall_count=0
                  drain_poll_interval=10
                  drain_elapsed=0
                  while [[ $drain_elapsed -lt $drainQueueTimeout ]]; do
                      self_queued=""
                      if rootid=$(timeout ${cli_timeout} ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi get-root-id -u ${selfUrl} ${secureArgs} 2>/dev/null); then
                          if timeout ${cli_timeout} ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi pg-status -pgid "${rootid}" -ot json -u ${selfUrl} ${secureArgs} > /tmp/preStop-selfstatus.json 2>/dev/null; then
                              self_queued=$(jq -r '.status.aggregateSnapshot.queuedCount // empty' /tmp/preStop-selfstatus.json 2>/dev/null)
                          fi
                      fi
                      if [[ "${self_queued}" == "0" ]]; then
                          log "preStop: local queue confirmed empty (${drain_elapsed}s)"
                          break
                      fi
                      if [[ -n "${self_queued}" && "${self_queued}" == "${last_queued}" ]]; then
                          stall_count=$((stall_count + 1))
                          log "preStop: still ${self_queued} queued locally, no change (${drain_elapsed}s, stall ${stall_count}/${drainStallLimit})"
                          if [[ $stall_count -ge $drainStallLimit ]]; then
                              log "preStop: no progress for $((drainStallLimit * drain_poll_interval))s; giving up early"
                              break
                          fi
                      else
                          if [[ -n "${self_queued}" && -n "${last_queued}" ]]; then
                              log "preStop: still ${self_queued} queued locally, down from ${last_queued} (${drain_elapsed}s); progress detected, continuing"
                          else
                              log "preStop: still ${self_queued:-unknown} queued locally (${drain_elapsed}s); waiting"
                          fi
                          stall_count=0
                      fi
                      last_queued="${self_queued}"
                      sleep ${drain_poll_interval}
                      drain_elapsed=$((drain_elapsed + drain_poll_interval))
                  done

                  if [[ "${self_queued}" != "0" ]]; then
                      log "preStop WARNING: node still has ${self_queued:-an unknown amount of} FlowFile(s) queued after waiting ${drain_elapsed}s for relocation to finish."
                      log "preStop WARNING: skipping delete-node so this stays visible in the cluster as a DISCONNECTED/OFFLOADED registry entry rather than being silently cleaned up."
                      log "preStop WARNING: this node's local data is safe on its PVC but will be unavailable to the running cluster until this node is restarted (e.g. scale back up to this ordinal)."
                      exit 1
                  fi

                  log "preStop: no queued content remains on this node; safe to remove"
                  log "preStop: deleting node ${nnid}"
                  attempt=1
                  max_attempts=5
                  while [[ $attempt -le $max_attempts ]]; do
                      if timeout ${cli_timeout} ${NIFI_TOOLKIT_HOME}/bin/cli.sh nifi delete-node -nnid ${nnid} -u ${baseUrl} ${secureArgs}; then
                          log "preStop: node deleted"
                          break
                      fi
                      log "preStop WARNING: delete-node via ${baseUrl} failed or timed out (attempt ${attempt}/${max_attempts})."
                      next_peer || true
                      attempt=$((attempt + 1))
                      sleep 1
                  done
                  log "preStop: hook returning, exit 0 (pid $$)"
                  exit 0
{{- end }}
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
            mountPath: {{ default "/opt/nifi/secrets" $vals.defaultContainerPath }}
          - name: vault-scripts
            mountPath: /opt/nifi/vault-scripts
            readOnly: true
      {{- end }}
      # END VaultSecretMounts
      {{- if .Values.awsSecretsSync.enabled }}
          - name: aws-secrets-path
            mountPath: {{ .Values.awsSecretsSync.outputPath }}
      {{- end }}
      {{- if and .Values.properties.secretsName (ne (include "nifi.effectiveSecretsMode" .) "none") }}
          - name: k8s-secrets
            mountPath: {{ .Values.properties.secretsFilePath }}
            readOnly: true
      {{- end }}
      {{- if .Values.auth.singleUser.generateSecret }}
          - name: single-user-credentials
            mountPath: /opt/nifi/single-user-credentials
            readOnly: true
      {{- end }}

    {{- if eq (include "nifi.secretSyncEnabled" $) "true" }}
        {{- range (include "nifi.syncPaths" . | fromJsonArray) }}
        {{- if and (default true .enabled) (ne .pathType "fs") (or (ne .pathType "tls-secret") $.Values.ingress.enabled) }}
          - name: {{ include "apache-nifi.fullname" $ }}-{{ .pathName }}
            mountPath: {{ .localPath }}
        {{- end }}
        {{- end }}
    {{- /* if nifi.secretSyncEnabled */}}{{ end }}
    {{- if or .Values.NiFiSync.s3Sync.enabled .Values.NiFiSync.UserPolicySync.enabled}}
          - mountPath: /opt/nifi/nifi-sync/scripts
            name: nifisync-scripts
    {{- /* if or .Values.NiFiSync.s3Sync.enabled .Values.NiFiSync.UserPolicySync.enabled */}}{{ end }}
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
          - name: "logback-xml"
            mountPath: /opt/nifi/nifi-current/conf/logback.xml
            subPath: "logback.xml"
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
{{- if .Values.scaleDownGuard.enabled }}
          - name: sts-reader-token
            mountPath: /run/secrets/kubernetes.io/sts-reader-token
            readOnly: true
{{- end }}
          {{- if .Values.extraVolumeMounts }}
{{ toYaml .Values.extraVolumeMounts | indent 10 }}
          {{- end }}
{{- end }}

