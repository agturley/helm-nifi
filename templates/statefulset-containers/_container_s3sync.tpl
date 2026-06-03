{{- define "nifi.container.s3sync" }}
{{- $vals := .Values.VaultNiFiSecrets }}
      - name: s3-sync
        image: {{ .Values.NiFiSync.s3Sync.sidecar.image }}
        resources:
{{ toYaml .Values.NiFiSync.s3Sync.resources | indent 10 }}             

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
        command: ["/bin/sh", "-c"]
        args:
        - |
          #!/bin/sh
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
{{- /* END Wait for vault sidecar readiness */}}
          {{- if eq (include "nifi.effectiveSecretsMode" .) "file-dir" }}
          # Wait for S3 credential files before loading (file-dir: files may be written by a sidecar)
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
          {{- range .Values.NiFiSync.syncPaths }}
          {{- if eq .pathType "fs" }}
          echo "$(date) - Sync File System Paths with S3. LocalPath: {{ .localPath }} RemotePath: $S3_BUCKET/$instanceName/{{ .remotePath }}"

          if [ ! -d "{{ .localPath }}" ]; then
            echo "$(date) - Creating Local Path: {{ .localPath }}"
            mkdir -p {{ .localPath }}
          fi

          if ! python3 "$S3SYNC" prefix-exists --remote "$instanceName/{{ .remotePath }}"; then
            echo "$(date) - Creating Remote Path $instanceName/{{ .remotePath }} in S3"
            python3 "$S3SYNC" put-placeholder --remote "$instanceName/{{ .remotePath }}"

            if [ "$(ls -A {{ .localPath }})" ]; then
              echo "$(date) - Syncing local data: {{ .localPath }} to S3: $instanceName/{{ .remotePath }}"
              python3 "$S3SYNC" mirror-up --local {{ .localPath }} --remote "$instanceName/{{ .remotePath }}" --overwrite || echo "$(date) - Warning: Initial sync failed for {{ .localPath }}"
            fi
          fi
          {{- end }}
          {{- end }}
          # ---------------- End FS Sync Bootstrapping ----------------

          # ---------------- Start Flow Backup Loop ----------------
          {{- if .Values.NiFiSync.s3Sync.flowBackup.enabled }}
          (
            while true; do
              echo "$(date) - Starting flow backup loop"
              python3 "$S3SYNC" flow-backup || echo "$(date) - Warning: flow backup failed"
              echo "$(date) - Flow backup complete. Sleeping for {{ .Values.NiFiSync.s3Sync.flowBackup.interval }}."
              sleep {{ .Values.NiFiSync.s3Sync.flowBackup.interval }}
            done
          ) &
          {{- end }}
          # ---------------- End Flow Backup Loop ----------------

          # ---------------- Start FS Sync Loop ----------------
          (
            while true; do
              echo "$(date) - Starting file system sync loop"
              {{- range .Values.NiFiSync.syncPaths }}
              {{- if eq .pathType "fs" }}
              echo "$(date) - Syncing Remote Path $instanceName/{{ .remotePath }} to {{ .localPath }}"
              python3 "$S3SYNC" mirror-down --remote "$instanceName/{{ .remotePath }}" --local {{ .localPath }} --exclude .placeholder --overwrite || echo "$(date) - Warning: Sync failed for {{ .localPath }}. S3 might be unavailable."
              {{- end }}
              {{- end }}
              echo "$(date) - File sync completed. Sleeping for {{ .Values.NiFiSync.s3Sync.syncInterval }}."
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
          mountPath: {{ $vals.defaultContainerPath }}
        - name: secret-env-script
          mountPath: /etc/scripts
      {{- end }}
      # END VaultSecretMounts        
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
{{- end }}

