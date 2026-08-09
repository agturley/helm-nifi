{{- define "nifi.container.certManager" }}
{{- $vals := .Values.VaultNiFiSecrets }}
{{- $caSecrets := default .Values.certManager.caSecrets .Values.caSecrets }}
      - name: cert-manager
        imagePullPolicy: {{ .Values.images.nifi.pullPolicy | quote }}
        image: "{{ .Values.images.nifi.repository }}:{{ .Values.images.nifi.tag }}"

{{- if .Values.envFrom }}
        envFrom:
{{ toYaml .Values.envFrom | indent 8 }}
{{- end }}

        command:
        - bash
        - -ce
        - |
{{- /* START Wait for vault sidecar HTTP readiness on /ready (tries curl, wget, nc, falls back to port check) */ -}}        
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
{{- /* END Wait for vault sidecar readiness */ -}}
          #END
          trap "exit 0" TERM
          NODENAME=$(hostname)
          mkdir -p "${NIFI_HOME}"/tls/cert-manager
{{ include "nifi.awsSecretsSyncWait" . }}
{{ include "nifi.secretsInit" . }}
          # Note opportunity here to inject additional trusted certs named ca.crt in other
          # subdirectories of /opt/nifi/nifi-current/tls/, using custom secrets and/or configmaps.
          # If any of those trusted certs expire then you will need to restart the pod to pick
          # them up, as the truststore is only created at pod startup and Kubernetes won't
          # update secrets mounted as subPaths anyway.
          # c.f. https://kubernetes.io/docs/concepts/storage/volumes/#secret

          function pullNodeSecretData() {
            rm -f /tmp/secret.json /tmp/secret-data.json
            curl --cacert /run/secrets/kubernetes.io/secret-reader-token/ca.crt \
                 -H "Authorization: Bearer $(cat /run/secrets/kubernetes.io/secret-reader-token/token)" \
                 https://kubernetes.default.svc/api/v1/namespaces/$(cat /run/secrets/kubernetes.io/secret-reader-token/namespace)/secrets/$(hostname) \
                 --output /tmp/secret.json
            jq .data < /tmp/secret.json > /tmp/secret-data.json
            rm -f /tmp/secret.json
          }       
        
          pullNodeSecretData
          jq -r '."ca.crt"' < /tmp/secret-data.json | base64 -d > "${NIFI_HOME}"/tls/cert-manager/ca.crt
          touch /tmp/tls.crt.old
            
          echo "[cert-manager] Building truststore: ${NIFI_HOME}/tls/truststore-new.jks"
          rm -f "${NIFI_HOME}/tls/truststore-new.jks"
          for ca in "${NIFI_HOME}"/tls/*/ca.crt
          do
            ALIAS=$(echo $ca | awk -F "/" '{print $(NF-1) }' -)
            echo "[cert-manager]   + ${ALIAS} (${ca})"
            keytool -import \
                    -noprompt \
                    -trustcacerts \
                    -alias $ALIAS \
                    -storetype JKS \
                    -file $ca \
                    -keystore "${NIFI_HOME}/tls/truststore-new.jks" \
                    -storepass "${NIFI_TLS_TRUSTSTORE_PASSWORD}"
          done
          {{- if $caSecrets }}
          # Import any .crt/.cer/.pem from shared caSecrets mounts
          {{- range $caSecrets }}
          for ca in "${NIFI_HOME}/tls/{{ . }}"/*.crt "${NIFI_HOME}/tls/{{ . }}"/*.cer "${NIFI_HOME}/tls/{{ . }}"/*.pem
          do
            [[ -f "$ca" ]] || continue
            ALIAS="casecret-{{ . }}-$(echo $ca | sed 's|.*/||' | sed 's|\.[^.]*$||')"
            echo "[cert-manager]   + ${ALIAS} (${ca})"
            keytool -import \
                    -noprompt \
                    -trustcacerts \
                    -alias "$ALIAS" \
                    -storetype JKS \
                    -file "$ca" \
                    -keystore "${NIFI_HOME}/tls/truststore-new.jks" \
                    -storepass "${NIFI_TLS_TRUSTSTORE_PASSWORD}" || true
          done
          {{- end }}
          {{- end }}
          {{- if .Values.NiFiSync.s3Sync.enabled}}
          {{- range (include "nifi.syncPaths" . | fromJsonArray) }}
          {{- if and (default true .enabled) (eq .pathType "ca-secret") }}
          _found_ca=0
          for ca in {{ .localPath }}/*.crt {{ .localPath }}/*.cer {{ .localPath }}/*.pem
          do
            [[ -f "$ca" ]] || continue
            _found_ca=1
            ALIAS=$(echo $ca | sed 's|.*/||' | sed 's|\.[^.]*$||')
            echo "[cert-manager]   + s3sync-${ALIAS} (${ca})"
            keytool -import \
                    -noprompt \
                    -trustcacerts \
                    -alias s3sync-$ALIAS \
                    -storetype JKS \
                    -file $ca \
                    -keystore "${NIFI_HOME}/tls/truststore-new.jks" \
                    -storepass "${NIFI_TLS_TRUSTSTORE_PASSWORD}"
          done
          if [[ "$_found_ca" -eq 0 ]]; then
            echo "No .crt/.cer/.pem files found in {{ .localPath }}"
          fi
          unset _found_ca
          {{- end }}
          {{- end }}
          {{- /* if .Values.NiFiSync.s3Sync.enabled */}}{{ end }}
          echo "[cert-manager] Truststore contents:"
          keytool -list -keystore "${NIFI_HOME}/tls/truststore-new.jks" \
                        -storepass "${NIFI_TLS_TRUSTSTORE_PASSWORD}"
          {{- if .Values.certManager.useMergedCACerts }}
          (
          # Build merged cacerts from JVM default + all CAs in truststore-new.jks BEFORE
          # moving it to truststore.jks. Run in background to overlap with other startup work.
          _jvm_cacerts_storepass={{ .Values.certManager.jvmCACertsStorePasswd | default "changeit" | quote }}
          {{- if .Values.certManager.jvmCACertsPath }}
          JVM_CACERTS={{ .Values.certManager.jvmCACertsPath | quote }}
          {{- else }}
          # Auto-detect JVM cacerts: check JAVA_HOME, common JVM paths, then RHEL/UBI9 system path
          JVM_CACERTS=$(find "${JAVA_HOME:-/usr/lib/jvm}" -name "cacerts" -path "*/security/*" 2>/dev/null | head -1)
          if [ -z "$JVM_CACERTS" ] && [ -f "/etc/pki/java/cacerts" ]; then
            JVM_CACERTS="/etc/pki/java/cacerts"
          fi
          {{- end }}
          if [ -n "$JVM_CACERTS" ] && [ -f "$JVM_CACERTS" ]; then
            MERGED_CACERTS="${NIFI_HOME}/tls/cacerts-merged"
            echo "[cert-manager] Building merged cacerts: ${MERGED_CACERTS}"
            echo "[cert-manager]   Base: ${JVM_CACERTS}"
            cp "$JVM_CACERTS" "$MERGED_CACERTS"
            _ts_pass="${NIFI_TLS_TRUSTSTORE_PASSWORD}"
            # Import directly from the ca.crt files (same sources that populated truststore-new.jks)
            _ca_i=0
            for _ca_f in "${NIFI_HOME}"/tls/*/ca.crt; do
              [ -f "$_ca_f" ] || continue
              _ca_i=$((_ca_i + 1))
              echo "[cert-manager]   + merged-ca-${_ca_i} (${_ca_f})"
              keytool -importcert -noprompt -trustcacerts \
                      -alias "merged-ca-${_ca_i}" \
                      -file "$_ca_f" \
                      -keystore "$MERGED_CACERTS" \
                      -storepass "$_jvm_cacerts_storepass" 2>&1 || true
            done
            {{- if $caSecrets }}
            # Also import certs from shared caSecrets mounts
            {{- range $caSecrets }}
            for _ca_f in "${NIFI_HOME}/tls/{{ . }}"/*.crt "${NIFI_HOME}/tls/{{ . }}"/*.cer "${NIFI_HOME}/tls/{{ . }}"/*.pem; do
              [ -f "$_ca_f" ] || continue
              _ca_i=$((_ca_i + 1))
              echo "[cert-manager]   + merged-ca-${_ca_i} (${_ca_f})"
              keytool -importcert -noprompt -trustcacerts \
                      -alias "merged-ca-${_ca_i}" \
                      -file "$_ca_f" \
                      -keystore "$MERGED_CACERTS" \
                      -storepass "$_jvm_cacerts_storepass" 2>&1 || true
            done
            {{- end }}
            {{- end }}
            {{- if .Values.NiFiSync.s3Sync.enabled }}
            {{- range (include "nifi.syncPaths" . | fromJsonArray) }}
            {{- if and (default true .enabled) (eq .pathType "ca-secret") }}
            # Also import S3-synced certs from {{ .localPath }} (ca-secret path)
            for _ca_f in {{ .localPath }}/*.crt {{ .localPath }}/*.cer {{ .localPath }}/*.pem; do
              [ -f "$_ca_f" ] || continue
              _ca_i=$((_ca_i + 1))
              echo "[cert-manager]   + merged-ca-${_ca_i} (${_ca_f})"
              keytool -importcert -noprompt -trustcacerts \
                      -alias "merged-ca-${_ca_i}" \
                      -file "$_ca_f" \
                      -keystore "$MERGED_CACERTS" \
                      -storepass "$_jvm_cacerts_storepass" 2>&1 || true
            done
            {{- end }}
            {{- end }}
            {{- end }}
            # Re-key the merged store from the JVM default password to the configured truststore password
            keytool -storepasswd \
                    -noprompt \
                    -keystore "$MERGED_CACERTS" \
                    -storepass "$_jvm_cacerts_storepass" \
                    -new "$_ts_pass"
            unset _ts_pass _jvm_cacerts_storepass
            echo "[cert-manager] Merged cacerts finalized: ${MERGED_CACERTS} (imported ${_ca_i} CA(s))"
          else
            unset _jvm_cacerts_storepass
            echo "[cert-manager] JVM cacerts not found; skipping merged cacerts build"
          fi
          ) &
          {{- end }}

          mv "${NIFI_HOME}/tls/truststore-new.jks" "${NIFI_HOME}/tls/truststore.jks"
          echo "[cert-manager] Truststore active: ${NIFI_HOME}/tls/truststore.jks"

          while :
          do
            pullNodeSecretData
            jq -r '."tls.crt"' < /tmp/secret-data.json | base64 -d > /tmp/tls.crt
            jq -r '."tls.key"' < /tmp/secret-data.json | base64 -d > /tmp/tls.key
            if ! diff /tmp/tls.crt.old /tmp/tls.crt > /dev/null
            then
              echo "[cert-manager] TLS certificate changed; rebuilding keystore: ${NIFI_HOME}/tls/keystore.jks"
              openssl pkcs12 -export -in      "/tmp/tls.crt" \
                                     -inkey   "/tmp/tls.key" \
                                     -name    "${NODENAME}" \
                                     -out     "/tmp/tls.p12" \
                                     -passout "pass:${NIFI_TLS_KEYSTORE_PASSWORD}"
              rm -f "${NIFI_HOME}/tls/keystore-new.jks"
              keytool -importkeystore \
                      -noprompt \
                      -v \
                      -destkeystore "${NIFI_HOME}/tls/keystore-new.jks" \
                      -srckeystore "/tmp/tls.p12" \
                      -srcstoretype PKCS12 \
                      -deststoretype JKS \
                      -srcstorepass "${NIFI_TLS_KEYSTORE_PASSWORD}" \
                      -deststorepass "${NIFI_TLS_KEYSTORE_PASSWORD}"
              mv  "${NIFI_HOME}/tls/keystore-new.jks" "${NIFI_HOME}/tls/keystore.jks"
              echo "[cert-manager] Keystore active: ${NIFI_HOME}/tls/keystore.jks"
              mv /tmp/tls.crt /tmp/tls.crt.old
            fi

            ls -l "${NIFI_HOME}/tls/keystore.jks"
            echo "[cert-manager] Keystore contents:"
            keytool -list -keystore "${NIFI_HOME}/tls/keystore.jks" \
                          -storepass "${NIFI_TLS_KEYSTORE_PASSWORD}"

            echo Starting to sleep for {{ .Values.certManager.refreshSeconds }} seconds at $(date)
            # Backgrounded + waited-on rather than a plain foreground sleep:
            # bash only lets a trap interrupt the `wait` builtin early on a
            # trapped signal - a plain foreground `sleep N` defers the trap
            # until sleep finishes on its own, so on SIGTERM this container
            # would otherwise sit for up to refreshSeconds before exiting.
            sleep {{ .Values.certManager.refreshSeconds }} &
            wait $!
          done
        volumeMounts:
    {{- if eq (include "nifi.secretSyncEnabled" $) "true" }}
        {{- range (include "nifi.syncPaths" . | fromJsonArray) }}
        {{- if and (default true .enabled) (ne .pathType "fs") (or (ne .pathType "tls-secret") $.Values.ingress.enabled) }}
          - name: {{ include "apache-nifi.fullname" $ }}-{{ .pathName }}
            mountPath: {{ .localPath }}
        {{- end }}
        {{- end }}
    {{- /* if nifi.secretSyncEnabled */}}{{ end }}



    #VaultSecretMounts
          {{- $vals := .Values.VaultNiFiSecrets }}
          {{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSecretOperator") -}}
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
      {{- end }}

    #END VaultSecretMounts

    {{- if or .Values.NiFiSync.s3Sync.enabled .Values.NiFiSync.UserPolicySync.enabled}}
          - mountPath: /opt/nifi/nifi-sync/scripts
            name: nifisync-scripts
    {{- /* if or .Values.NiFiSync.s3Sync.enabled .Values.NiFiSync.UserPolicySync.enabled */}}{{ end }}
          - name: "tls"
            mountPath: /opt/nifi/nifi-current/tls
          - name: secret-reader-token
            mountPath: /run/secrets/kubernetes.io/secret-reader-token
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
          {{ range $secret := $caSecrets }}
          - name: {{ include "apache-nifi.fullname" $ }}-{{ $secret }}
            mountPath: /opt/nifi/nifi-current/tls/{{ $secret }}
            readOnly: true
          {{ end }}
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
          {{- if .Values.extraVolumeMounts }}
{{ toYaml .Values.extraVolumeMounts | indent 10 }}
          {{/* if .Values.extraVolumeMounts */}}{{ end }}
          {{- if .Values.awsSecretsSync.enabled }}
          - name: aws-secrets-path
            mountPath: {{ .Values.awsSecretsSync.outputPath }}
          {{- end }}
          {{- if and .Values.properties.secretsName (ne (include "nifi.effectiveSecretsMode" .) "none") }}
          - name: k8s-secrets
            mountPath: {{ .Values.properties.secretsFilePath }}
            readOnly: true
          {{- end }}
        resources:
{{ toYaml .Values.certManager.resources | indent 10 }}
{{- end }}
