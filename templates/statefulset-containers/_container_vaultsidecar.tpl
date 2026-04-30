{{- define "nifi.container.vaultSidecar" }}
{{- $vals := .Values.VaultNiFiSecrets }}
      - name: vault-sidecar
        image: {{ required "VaultNiFiSecrets.vaultSidecarImage must be set when secretProvider=vaultSidecar" .Values.VaultNiFiSecrets.vaultSidecarImage }}
        imagePullPolicy: IfNotPresent
        resources:
{{ toYaml .Values.syncresources | indent 10 }}             
        ports:
          - containerPort: 8080
        env:
          - name: CONFIG_FILE
            value: /etc/vault-sidecar/config.yaml
          - name: LOG_LEVEL
            value: "INFO"
          - name: UVICORN_LOG_LEVEL
            value: "info"
          - name: ENABLE_KAFKA_LOGGING
            value: "True"
        volumeMounts:
          - name: vault-sidecar-config
            mountPath: /etc/vault-sidecar
            readOnly: true
          - name: secretfspath
            mountPath: {{ $vals.defaultContainerPath }}
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 3
          successThreshold: 1
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 20
          timeoutSeconds: 3
          failureThreshold: 3
{{- end }}

