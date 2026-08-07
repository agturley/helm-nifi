{{- define "nifi.container.s3sync" }}
{{- $vals := .Values.VaultNiFiSecrets }}
{{- $caSecrets := .Values.caSecrets }}
{{- $caSecretName := default "" $vals.vaultSidecar.caSecretName }}
{{- if and (eq $caSecretName "") (gt (len $caSecrets) 0) }}
{{- $caSecretName = index $caSecrets 0 }}
{{- end }}
{{- $caBundlePath := "/opt/nifi/nifi-current/tls/ca-bundle/ca-bundle.pem" }}
      - name: s3-sync
        image: {{ default (printf "%s:%s" .Values.images.utility.repository .Values.images.utility.tag) .Values.NiFiSync.s3Sync.sidecar.image }}
        resources:
{{ toYaml .Values.NiFiSync.s3Sync.resources | indent 10 }}             

{{- if .Values.envFrom }}
        envFrom:
{{ toYaml .Values.envFrom | indent 8 }}
{{- end }}

        env:
        - name: S3_BUCKET
          value: {{ .Values.NiFiSync.s3Sync.bucket }}
        - name: S3_ENDPOINT
          value: {{ .Values.NiFiSync.s3Sync.endpoint }}
        - name: instanceName
          value: {{ template "apache-nifi.fullname" $ }}
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: USE_IRSA
          value: {{ .Values.NiFiSync.s3Sync.useIRSA | quote }}
        - name: S3_INSECURE
          value: {{ .Values.NiFiSync.s3Sync.insecure | quote }}
        - name: AWS_DEFAULT_REGION
          value: {{ .Values.NiFiSync.s3Sync.region | quote }}
        {{- if ne $caSecretName "" }}
        - name: REQUESTS_CA_BUNDLE
          value: /merged-ca-bundle/ca-bundle.crt
        - name: SSL_CERT_FILE
          value: /merged-ca-bundle/ca-bundle.crt
        - name: AWS_CA_BUNDLE
          value: /merged-ca-bundle/ca-bundle.crt
        {{- end }}
        command: ["/bin/sh", "-c"]
        args:
        - |
          #!/bin/sh
          # --- Prefix every stdout/stderr line with an ISO-8601 UTC timestamp ---
          # Routes all output (including raw stderr from sub-tools and python)
          # through one timestamper so every log line is machine-parseable.
          if _ts_fifo="$(mktemp -u /tmp/ts.XXXXXX)" && mkfifo "$_ts_fifo" 2>/dev/null; then
            while IFS= read -r _ts_line; do
              printf '%s - %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$_ts_line"
            done < "$_ts_fifo" &
            exec > "$_ts_fifo" 2>&1
            rm -f "$_ts_fifo"
          fi
          # --- end timestamp wrapper ---
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
{{- /* END Wait for vault sidecar readiness */}}
          {{- if and (eq (include "nifi.effectiveSecretsMode" .) "directory") (not .Values.NiFiSync.s3Sync.useIRSA) }}
          # Wait for S3 credential files before loading (file-dir: files may be written by a sidecar).
          # Skipped when useIRSA=true since credentials come from the IAM role, not secret files.
          _creds_sp={{ .Values.properties.secretsFilePath | quote }}
          _creds_timeout=${WAIT_SIDECAR_TIMEOUT:-120}
          _creds_start=$(date +%s)
          for _creds_file in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
            echo "Waiting for $_creds_sp/$_creds_file ..."
            while [ ! -s "$_creds_sp/$_creds_file" ]; do
              if [ $(( $(date +%s) - _creds_start )) -ge "$_creds_timeout" ]; then
                echo "Timed out waiting for $_creds_sp/$_creds_file" >&2
                exit 1
              fi
              sleep 2
            done
            echo "$_creds_file present"
          done
          unset _creds_sp _creds_timeout _creds_start _creds_file
          {{- end }}
{{ include "nifi.awsSecretsSyncWait" . }}
{{ include "nifi.secretsInit" . }}
          # s3sync.py replaces the MinIO `mc` client; credentials resolve via the
          # boto3 default chain (IRSA) or S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY.
          S3SYNC=/scripts/s3sync.py
          export S3_BUCKET S3_ENDPOINT instanceName POD_NAME

          ## Retention settings (consumed by `s3sync.py flow-backup`)
          export RETENTION_ENABLED="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.enabled }}"
          export RETENTION_DRY_RUN="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.dryRun }}"
          export FLOW_KEEP_DAYS="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.flow.keepDays }}"
          export FLOW_MAX_VERSIONS="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.flow.maxVersions }}"
          export ARCHIVE_RETENTION_ENABLED="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.archive.enabled }}"
          export ARCHIVE_KEEP_DAYS="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.archive.keepDays }}"

          # Block until the S3 bucket is reachable (replaces mc alias retry loop)
          python3 "$S3SYNC" wait-ready

          # ---------------- Initial FS Sync Bootstrapping ----------------
          {{- range (include "nifi.syncPaths" . | fromJsonArray) }}
          {{- if eq .pathType "fs" }}
          {{- $root := default "$instanceName" .remoteRoot }}
          echo "Sync File System Paths with S3. LocalPath: {{ .localPath }} RemotePath: $S3_BUCKET/{{ $root }}/{{ .remotePath }}"

          if [ ! -d "{{ .localPath }}" ]; then
            echo "Creating Local Path: {{ .localPath }}"
            mkdir -p {{ .localPath }}
          fi

          {{- if .remoteRoot }}
          # remoteRoot={{ .remoteRoot }}: shared prefix — skip initial mirror-up (read-only)
          if ! python3 "$S3SYNC" prefix-exists --remote "{{ $root }}/{{ .remotePath }}"; then
            echo "Creating Remote Path {{ $root }}/{{ .remotePath }} in S3"
            python3 "$S3SYNC" put-placeholder --remote "{{ $root }}/{{ .remotePath }}"
          fi
          {{- else }}
          if ! python3 "$S3SYNC" prefix-exists --remote "{{ $root }}/{{ .remotePath }}"; then
            echo "Creating Remote Path {{ $root }}/{{ .remotePath }} in S3"
            python3 "$S3SYNC" put-placeholder --remote "{{ $root }}/{{ .remotePath }}"

            if [ "$(ls -A {{ .localPath }})" ]; then
              echo "Syncing local data: {{ .localPath }} to S3: {{ $root }}/{{ .remotePath }}"
              python3 "$S3SYNC" mirror-up --local {{ .localPath }} --remote "{{ $root }}/{{ .remotePath }}" --overwrite || echo "Warning: Initial sync failed for {{ .localPath }}"
            fi
          fi
          {{- end }}
          {{- end }}
          {{- end }}
          # ---------------- End FS Sync Bootstrapping ----------------

          # ---------------- Start Flow Backup Loop ----------------
          {{- if .Values.NiFiSync.s3Sync.flowBackup.enabled }}
          (
            while true; do
              echo "Starting flow backup loop"
              python3 "$S3SYNC" flow-backup || echo "Warning: flow backup failed"
              echo "Flow backup complete. Sleeping for {{ .Values.NiFiSync.s3Sync.flowBackup.interval }}."
              sleep {{ .Values.NiFiSync.s3Sync.flowBackup.interval }}
            done
          ) &
          {{- end }}
          # ---------------- End Flow Backup Loop ----------------

          # ---------------- Start Flow Restore Loop ----------------
          {{- if .Values.NiFiSync.s3Sync.flowRestore.enabled }}
          (
            while true; do
              python3 "$S3SYNC" flow-restore
              _restore_rc=$?
              if [ $_restore_rc -eq 2 ]; then
                echo "Flow restore complete. Deleting pod ${POD_NAME} to trigger restart..."
                _sa_token="$(cat /run/secrets/kubernetes.io/serviceaccount/token)"
                _namespace="$(cat /run/secrets/kubernetes.io/serviceaccount/namespace)"
                curl -sSf \
                  --cacert /run/secrets/kubernetes.io/serviceaccount/ca.crt \
                  -X DELETE \
                  -H "Authorization: Bearer ${_sa_token}" \
                  "https://kubernetes.default.svc/api/v1/namespaces/${_namespace}/pods/${POD_NAME}" \
                  && echo "Pod delete request sent." \
                  || echo "Warning: pod delete request failed (exit $?)"
              fi
              sleep $(( {{ .Values.NiFiSync.s3Sync.flowRestore.intervalMinutes }} * 60 ))
            done
          ) &
          {{- end }}
          # ---------------- End Flow Restore Loop ----------------

          # ---------------- Start FS Sync Loop ----------------
          (
            while true; do
              echo "Starting file system sync loop"
              {{- range (include "nifi.syncPaths" . | fromJsonArray) }}
              {{- if eq .pathType "fs" }}
              {{- $root := default "$instanceName" .remoteRoot }}
              {{- $orphans := "dryrun" }}
              {{- if kindIs "bool" .deleteOrphans }}{{ $orphans = ternary "delete" "off" .deleteOrphans }}{{ else if .deleteOrphans }}{{ $orphans = .deleteOrphans }}{{ end }}
              {{- if not (has $orphans (list "off" "dryrun" "delete")) }}{{ fail (printf "NiFiSync.syncPaths %q: deleteOrphans must be one of off/dryrun/delete (or true/false); got %v" .pathName .deleteOrphans) }}{{ end }}
              echo "Syncing Remote Path {{ $root }}/{{ .remotePath }} to {{ .localPath }}"
              python3 "$S3SYNC" mirror-down --remote "{{ $root }}/{{ .remotePath }}" --local {{ .localPath }} --exclude .placeholder{{- if $.Values.NiFiSync.s3Sync.overwrite }} --overwrite{{- end }} --orphans {{ $orphans }} || echo "Warning: Sync failed for {{ .localPath }}. S3 might be unavailable."
              {{- end }}
              {{- end }}
              echo "File sync completed. Sleeping for {{ .Values.NiFiSync.s3Sync.syncInterval }}."
              sleep {{ .Values.NiFiSync.s3Sync.syncInterval }}
            done
          ) &
          # ---------------- End FS Sync Loop ----------------

          # Wait forever to keep the container alive
          wait
        volumeMounts:
      # VaultSecretMounts
      {{- $vals := .Values.VaultNiFiSecrets }}
      {{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSidecar") }}
        - name: secretfspath
          mountPath: {{ default "/opt/nifi/secrets" $vals.defaultContainerPath }}
      {{- end }}
      # END VaultSecretMounts
        {{- $vaultOwnsSecretsPath := and .Values.VaultNiFiSecrets.enabled (eq (default "" .Values.VaultNiFiSecrets.secretProvider) "vaultSidecar") }}
        {{- if and .Values.properties.secretsName (ne (include "nifi.effectiveSecretsMode" .) "none") (not $vaultOwnsSecretsPath) }}
        - name: k8s-secrets
          mountPath: {{ default "/opt/nifi/secrets" .Values.properties.secretsFilePath }}
          readOnly: true
        {{- end }}
        - mountPath: /opt/nifi/data
          {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.dataStorage.DisallowSubPath) }}
          name: {{ .Values.persistence.subPath.name }}
          subPath: data
          {{- else }}
          name: "data"
          {{- end }}
        - mountPath: /opt/nifi/custom
          {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled (not .Values.persistence.customStorage.DisallowSubPath) }}
          name: {{ .Values.persistence.subPath.name }}
          subPath: custom-data
          {{- else }}
          name: "custom-data"
          {{- end }}
        - mountPath: /scripts
          name: nifisync-scripts
        {{- if ne $caSecretName "" }}
        - name: vault-ca-bundle
          mountPath: /opt/nifi/nifi-current/tls/ca-bundle
          readOnly: true
        - name: merged-ca-bundle
          mountPath: /merged-ca-bundle
          readOnly: true
        {{- end }}
{{- if .Values.awsSecretsSync.enabled }}
        - mountPath: {{ .Values.awsSecretsSync.outputPath }}
          name: aws-secrets-path
{{- end }}
{{- end }}

