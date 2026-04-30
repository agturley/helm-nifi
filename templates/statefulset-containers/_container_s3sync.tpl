{{- define "nifi.container.s3sync" }}
{{- $vals := .Values.VaultNiFiSecrets }}
      - name: s3-sync
        image: {{ .Values.NiFiSync.s3Sync.sidecar.image }}
        resources:
{{ toYaml .Values.syncresources | indent 10 }}             

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
          # Function to set up mc alias with retries
          setup_mc_alias() {
            until mc alias set s3 "$S3_ENDPOINT" "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY" --insecure; do
              echo "$(date) - Unable to set mc alias. S3 might be unavailable. Retrying in 30 seconds..."
              sleep 30
            done
          }
          ##Retention settings
          RETENTION_ENABLED="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.enabled }}"
          RETENTION_DRY_RUN="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.dryRun }}"
          FLOW_KEEP_DAYS="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.flow.keepDays }}"
          FLOW_MAX_VERSIONS="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.flow.maxVersions }}"
          ARCHIVE_RETENTION_ENABLED="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.archive.enabled }}"
          ARCHIVE_KEEP_DAYS="{{ .Values.NiFiSync.s3Sync.flowBackup.retention.archive.keepDays }}"


          # Build + validate the S3 prefix; echo it if valid, return 1 otherwise
          _backup_prefix() {
            if [ -z "${S3_BUCKET:-}" ] || [ -z "${instanceName:-}" ] || [ -z "${POD_NAME:-}" ]; then
              return 1
            fi
            # Normalize with trailing slash
            printf 's3/%s/%s/backup/%s/' "$S3_BUCKET" "$instanceName" "$POD_NAME"
          }

          # Detect if this mc supports --dry-run on rm
          _mc_supports_rm_dryrun() {
            mc --help 2>/dev/null | grep -q -- '--dry-run' || mc rm --help 2>/dev/null | grep -q -- '--dry-run'
          }

          prune_flow_backups() {
            [ "${RETENTION_ENABLED:-false}" = "true" ] || return 0

            versions_prefix="$(_backup_prefix)" || { echo "$(date) - [retention] missing S3 vars; skipping."; return 0; }

            echo "$(date) - [retention] Evaluating flow backups in ${versions_prefix%/} (keepDays=$FLOW_KEEP_DAYS, maxVersions=$FLOW_MAX_VERSIONS, dryRun=$RETENTION_DRY_RUN)"

            # If the remote prefix doesn’t exist yet, bail quietly
            if ! mc --insecure ls "$versions_prefix" >/dev/null 2>&1; then
              echo "$(date) - [retention] Remote prefix not found; skipping."
              return 0
            fi

            # ---- AGE-BASED: delete flow-*.json.gz older than N days
            if [ -n "${FLOW_KEEP_DAYS:-}" ] && [ "$FLOW_KEEP_DAYS" -gt 0 ] 2>/dev/null; then
              if [ "$RETENTION_DRY_RUN" = "true" ] && _mc_supports_rm_dryrun; then
                mc --insecure rm --recursive --force --older-than "${FLOW_KEEP_DAYS}d" --dry-run "${versions_prefix}flow-" || true
              elif [ "$RETENTION_DRY_RUN" = "true" ]; then
                # Fallback dry-run: list what would be deleted
                mc --insecure ls --recursive "$versions_prefix" 2>/dev/null \
                  | awk '{print $NF}' | grep '^flow-.*\.json\.gz$' \
                  | while IFS= read -r obj; do
                      echo "[retention dry-run] would consider $versions_prefix$obj for age-based delete (> ${FLOW_KEEP_DAYS}d)"
                    done
              else
                mc --insecure rm --recursive --force --older-than "${FLOW_KEEP_DAYS}d" "${versions_prefix}flow-" \
                  | sed 's/^/[retention] /'
              fi
            fi

            # ---- COUNT-BASED: keep only newest N versioned flow files
            if [ -n "${FLOW_MAX_VERSIONS:-}" ] && [ "$FLOW_MAX_VERSIONS" -gt 0 ] 2>/dev/null; then
              flow_versions="$(mc --insecure ls "$versions_prefix" 2>/dev/null | awk '{print $NF}' | grep '^flow-.*\.json\.gz$' | sort)"
              total=$(printf '%s\n' "$flow_versions" | grep -c . || true)
              if [ "$total" -gt "$FLOW_MAX_VERSIONS" ]; then
                to_delete=$(( total - FLOW_MAX_VERSIONS ))
                echo "$(date) - [retention] $total versioned flow files; deleting oldest $to_delete to enforce maxVersions=$FLOW_MAX_VERSIONS"
                i=0
                printf '%s\n' "$flow_versions" | while IFS= read -r obj; do
                  [ "$i" -lt "$to_delete" ] || break
                  full="${versions_prefix}${obj}"
                  if [ "$RETENTION_DRY_RUN" = "true" ]; then
                    echo "[retention dry-run] would delete $full"
                  else
                    mc --insecure rm "$full" && echo "[retention] deleted $full" || echo "[retention] failed to delete $full"
                  fi
                  i=$((i+1))
                done
              fi
            fi

            # Never touch ${versions_prefix}flow.json.gz (the live pointer)
          }

          prune_remote_archive() {
            [ "${RETENTION_ENABLED:-false}" = "true" ] || return 0
            [ "${ARCHIVE_RETENTION_ENABLED:-false}" = "true" ] || return 0

            base="$(_backup_prefix)" || { echo "$(date) - [retention] missing S3 vars; skipping archive."; return 0; }
            remote_archive="${base}archive/"

            echo "$(date) - [retention] Evaluating archive in ${remote_archive%/} (keepDays=$ARCHIVE_KEEP_DAYS, dryRun=$RETENTION_DRY_RUN)"

            if ! mc --insecure ls "$remote_archive" >/dev/null 2>&1; then
              echo "$(date) - [retention] Remote archive prefix not found; skipping."
              return 0
            fi

            if [ -n "${ARCHIVE_KEEP_DAYS:-}" ] && [ "$ARCHIVE_KEEP_DAYS" -gt 0 ] 2>/dev/null; then
              if [ "$RETENTION_DRY_RUN" = "true" ] && _mc_supports_rm_dryrun; then
                mc --insecure rm --recursive --force --older-than "${ARCHIVE_KEEP_DAYS}d" --dry-run "$remote_archive" \
                  | sed 's/^/[retention dry-run] /'
              elif [ "$RETENTION_DRY_RUN" = "true" ]; then
                mc --insecure ls --recursive "$remote_archive" 2>/dev/null \
                  | awk '{print $NF}' \
                  | while IFS= read -r obj; do
                      echo "[retention dry-run] would consider $remote_archive$obj for age-based delete (> ${ARCHIVE_KEEP_DAYS}d)"
                    done
              else
                mc --insecure rm --recursive --force --older-than "${ARCHIVE_KEEP_DAYS}d" "$remote_archive" \
                  | sed 's/^/[retention] /'
              fi
            fi
          }
          # Function to back up flow.json.gz and sync archive/
          backup_nifi_flow() {
            FLOW_PATH="/opt/nifi/data/flow.json.gz"
            ARCHIVE_PATH="/opt/nifi/data/archive"
            BACKUP_PATH="s3/$S3_BUCKET/$instanceName/backup/$POD_NAME"
            REMOTE_ARCHIVE_PATH="$BACKUP_PATH/archive"
            TIMESTAMP=$(date +"%Y%m%dT%H%M%S")
            REMOTE_CURRENT="$BACKUP_PATH/flow.json.gz"
            REMOTE_VERSIONED="$BACKUP_PATH/flow-backup/$TIMESTAMP-flow.json.gz"
            REMOTE_HASH_FILE="/tmp/flow_remote_hash"

            # ---------- flow.json.gz upload (only if changed) ----------
            if [ -f "$FLOW_PATH" ]; then
              LOCAL_HASH=$(sha256sum "$FLOW_PATH" | awk '{print $1}')

              # Load cached remote hash if available, otherwise compute it once
              if [ -f "$REMOTE_HASH_FILE" ]; then
                REMOTE_HASH=$(cat "$REMOTE_HASH_FILE")
                echo "$(date) - Using cached remote flow.json.gz hash: $REMOTE_HASH"
              else
                echo "$(date) - No cached hash found. Checking remote flow.json.gz..."
                if mc --insecure stat "$REMOTE_CURRENT" >/dev/null 2>&1; then
                  mc --insecure cp "$REMOTE_CURRENT" /tmp/remote-flow.json.gz && \
                    REMOTE_HASH=$(sha256sum /tmp/remote-flow.json.gz | awk '{print $1}') && \
                    echo "$REMOTE_HASH" > "$REMOTE_HASH_FILE"
                  rm -f /tmp/remote-flow.json.gz
                else
                  echo "$(date) - No remote flow.json.gz found. This is the first backup."
                  REMOTE_HASH=""
                fi
              fi

              if [ "$LOCAL_HASH" = "${REMOTE_HASH:-}" ]; then
                echo "$(date) - No changes detected in flow.json.gz. Skipping flow upload."
              else
                # --- archive + upload block ---
                if [ -n "${REMOTE_HASH:-}" ]; then
                  echo "$(date) - Changes detected. Archiving previous flow.json.gz to $REMOTE_VERSIONED"
                  if ! mc --insecure mv "$REMOTE_CURRENT" "$REMOTE_VERSIONED"; then
                    echo "$(date) - Warning: failed to archive old flow.json.gz (mv). Continuing."
                  fi
                else
                  echo "$(date) - No previous remote flow.json.gz found; this will be the first backup."
                fi

                echo "$(date) - Uploading updated flow.json.gz to $REMOTE_CURRENT"
                if mc --insecure cp "$FLOW_PATH" "$REMOTE_CURRENT"; then
                  echo "$LOCAL_HASH" > "$REMOTE_HASH_FILE"
                  echo "$(date) - Uploaded flow.json.gz and updated cached remote hash."
                else
                  echo "$(date) - Warning: Failed to upload updated flow.json.gz"
                fi
                # --- end archive + upload block ---
              fi
            else
              echo "$(date) - flow.json.gz not found. Skipping flow upload."
            fi

            # ---------- archive/ sync (always) ----------
            if [ -d "$ARCHIVE_PATH" ]; then
              echo "$(date) - Syncing NiFi archive directory to $REMOTE_ARCHIVE_PATH"
              mc --insecure mirror "$ARCHIVE_PATH" "$REMOTE_ARCHIVE_PATH" || \
                echo "$(date) - Warning: Archive sync failed"
            else
              echo "$(date) - Archive path $ARCHIVE_PATH not found. Skipping archive sync."
            fi

            # ---------- retention (always) ----------
            prune_flow_backups
            prune_remote_archive
          }

          # Function to sync FS paths
          sync_fs_paths() {
            {{- range .Values.NiFiSync.syncPaths }}
            {{- if eq .pathType "fs" }}
            echo "$(date) - Syncing Remote Path $instanceName/{{ .remotePath }} to {{ .localPath }}"

            if ! mc mirror --exclude ".placeholder" --insecure --overwrite s3/$S3_BUCKET/$instanceName/{{ .remotePath }} {{ .localPath }}; then
              echo "$(date) - Warning: Sync failed for {{ .localPath }}. S3 might be unavailable."
            fi
            {{- end }}
            {{- end }}
          }

          # Setup mc alias
          setup_mc_alias

          # ---------------- Initial FS Sync Bootstrapping ----------------
          {{- range .Values.NiFiSync.syncPaths }}
          {{- if eq .pathType "fs" }}
          echo "$(date) - Sync File System Paths with S3. LocalPath: {{ .localPath }} RemotePath: $S3_BUCKET/$instanceName/{{ .remotePath }}"

          if [ ! -d "{{ .localPath }}" ]; then
            echo "$(date) - Creating Local Path: {{ .localPath }}"
            mkdir -p {{ .localPath }}
          fi

          if ! mc --insecure ls s3/$S3_BUCKET/$instanceName/{{ .remotePath }} 2> /dev/null | grep -q "^"; then
            echo "$(date) - Creating Remote Path $instanceName/{{ .remotePath }} in S3"
            echo "placeholder" | mc --insecure pipe s3/$S3_BUCKET/$instanceName/{{ .remotePath }}/.placeholder

            if [ "$(ls -A {{ .localPath }})" ]; then
              echo "$(date) - Syncing local data: {{ .localPath }} to S3: $instanceName/{{ .remotePath }}"
              mc mirror --insecure  {{ .localPath }} --overwrite s3/$S3_BUCKET/$instanceName/{{ .remotePath }} || echo "$(date) - Warning: Initial sync failed for {{ .localPath }}"
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
              backup_nifi_flow
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
              sync_fs_paths
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
        - mountPath: /.mc
          name: s3config
{{- end }}

