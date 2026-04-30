{{- define "nifi.container.awsSecretsSidecar" }}
      - name: aws-secrets-sync
        image: "{{ .Values.awsSecretsSync.image.repository }}:{{ .Values.awsSecretsSync.image.tag }}"
        imagePullPolicy: {{ .Values.awsSecretsSync.image.pullPolicy }}
        resources:
{{ toYaml .Values.awsSecretsSync.resources | indent 10 }}
        command: ["/bin/sh", "-c"]
        args:
          - |
            set -e
            {{- if (default true .Values.awsSecretsSync.installPackages) }}
            pip install boto3 pyyaml --quiet --no-cache-dir
            {{- end }}
            exec python3 /etc/aws-secrets-sync/script/fetch-secrets.py
        env:
          - name: AWS_SECRETS_CONFIG
            value: /etc/aws-secrets-sync/config/config.yaml
{{- if .Values.awsSecretsSync.credentialsSecret }}
        envFrom:
          - secretRef:
              name: {{ .Values.awsSecretsSync.credentialsSecret }}
{{- end }}
        volumeMounts:
          - name: aws-secrets-sync-config
            mountPath: /etc/aws-secrets-sync/config
            readOnly: true
          - name: aws-secrets-sync-script
            mountPath: /etc/aws-secrets-sync/script
            readOnly: true
          - name: aws-secrets-path
            mountPath: {{ .Values.awsSecretsSync.outputPath }}
{{- end }}

