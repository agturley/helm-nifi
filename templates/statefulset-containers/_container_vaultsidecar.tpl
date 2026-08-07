{{- define "nifi.container.vaultSidecar" }}
{{- $vals := .Values.VaultNiFiSecrets }}
{{- $caSecrets := .Values.caSecrets -}}
{{- $caSecretName := default "" $vals.vaultSidecar.caSecretName -}}
{{- if and (eq $caSecretName "") (gt (len $caSecrets) 0) -}}
{{- $caSecretName = index $caSecrets 0 -}}
{{- end -}}
{{- $caBundlePath := "/opt/nifi/nifi-current/tls/ca-bundle/ca-bundle.pem" }}
      - name: vault-sidecar
        image: {{ required "VaultNiFiSecrets.vaultSidecar.image must be set when secretProvider=vaultSidecar" .Values.VaultNiFiSecrets.vaultSidecar.image }}
        imagePullPolicy: IfNotPresent
        resources:
{{ toYaml .Values.syncresources | indent 10 }}
        env:
          - name: CONFIG_FILE
            value: /etc/vault-sidecar/config.yaml
          - name: LOG_LEVEL
            value: {{ $vals.logLevel | quote }}
          {{- if ne $caSecretName "" }}
          - name: REQUESTS_CA_BUNDLE
            value: {{ $caBundlePath }}
          - name: SSL_CERT_FILE
            value: {{ $caBundlePath }}
          {{- end }}
        volumeMounts:
          - name: vault-sidecar-config
            mountPath: /etc/vault-sidecar
            readOnly: true
          - name: secretfspath
            mountPath: {{ default "/opt/nifi/secrets" $vals.defaultContainerPath }}
          {{- if eq (default "" $vals.secretProvider) "vaultSidecar" }}
          - name: vault-scripts
            mountPath: /opt/nifi/vault-scripts
            readOnly: true
          {{- end }}
          {{- if ne $caSecretName "" }}
          - name: {{ template "apache-nifi.fullname" $ }}-{{ $caSecretName }}
            mountPath: /opt/nifi/nifi-current/tls/{{ $caSecretName }}
            readOnly: true
          - name: vault-ca-bundle
            mountPath: /opt/nifi/nifi-current/tls/ca-bundle
          {{- end }}
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 20
          timeoutSeconds: 3
          failureThreshold: 3
{{- end }}

