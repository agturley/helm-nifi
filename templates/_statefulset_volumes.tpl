{{/*
_statefulset_volumes.tpl
Volume definitions and VolumeClaimTemplates for the NiFi StatefulSet.
*/}}

{{- define "nifi.statefulset.volumes" }}
      volumes:

    #VaultSecretVolumes
      {{- $vals := .Values.VaultNiFiSecrets }}
      {{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSecretOperator") -}}
      {{- /* Build same pathMap as volumeMounts: one projected volume per unique containerPath */ -}}
      {{- $pathMap := dict -}}
      {{- range $s := $vals.secrets }}
      {{- $base := trimSuffix "/" (default $vals.defaultContainerPath $s.containerPath) }}
      {{- $pathMap = set $pathMap $base (append (default (list) (index $pathMap $base)) $s) }}
      {{- end }}
      {{- range $path := sortAlpha (keys $pathMap) }}
      {{- $volName := printf "vault-proj-%s" (include "secret.sanitizeName" (trimPrefix "/" $path)) }}
      - name: {{ $volName }}
        projected:
          sources:
      {{- range $s := index $pathMap $path }}
      {{- $safeName := include "secret.sanitizeName" (trimPrefix "/" $s.name) }}
          - secret:
              name: vault-{{ $safeName }}
      {{- end }}
      {{- end }}
      {{- end }}
      {{- if and $vals.enabled (eq (default "" $vals.secretProvider) "vaultSidecar") }}
      - name: vault-sidecar-config
        configMap:
          name: vault-sidecar-config
      - name: secretfspath
        emptyDir: {} 
      - name: vault-scripts
        configMap:
          name: {{ include "apache-nifi.fullname" . }}-vault-scripts
          defaultMode: 0755
      {{- end }}

      #END VaultSecretVolumes
      {{- if .Values.awsSecretsSync.enabled }}
      - name: aws-secrets-path
        emptyDir: {}
      - name: aws-secrets-sync-config
        configMap:
          name: {{ .Release.Name }}-aws-secrets-sync-config
      - name: aws-secrets-sync-script
        configMap:
          name: {{ .Release.Name }}-aws-secrets-sync-script
          defaultMode: 0550
      {{- end }}
      {{- if and .Values.properties.secretsName (ne (include "nifi.effectiveSecretsMode" .) "none") }}
      - name: k8s-secrets
        secret:
          secretName: {{ .Values.properties.secretsName }}
      {{- end }}
      {{- if .Values.auth.singleUser.generateSecret }}
      - name: single-user-credentials
        secret:
          secretName: {{ include "apache-nifi.fullname" . }}-single-user-credentials
          defaultMode: 0440
      {{- end }}

      - name: "bootstrap-conf"
        configMap:
          name: {{ template "apache-nifi.fullname" . }}-config
          items:
            - key: "bootstrap.conf"
              path: "bootstrap.conf"
      - name: "nifi-properties"
        configMap:
          name: {{ template "apache-nifi.fullname" . }}-config
          items:
            - key: "nifi.properties"
              path: "nifi.temp"
      - name: "authorizers-temp"
        configMap:
          name: {{ template "apache-nifi.fullname" . }}-config
          items:
            - key: "authorizers.xml"
              path: "authorizers.temp"
      - name: "bootstrap-notification-services-xml"
        configMap:
          name: {{ template "apache-nifi.fullname" . }}-config
          items:
            - key: "bootstrap-notification-services.xml"
              path: "bootstrap-notification-services.xml"
      - name: "login-identity-providers-ldap-xml"
        configMap:
          name: {{ template "apache-nifi.fullname" . }}-config
          items:
            - key: "login-identity-providers-ldap.xml"
              path: "login-identity-providers-ldap.xml"
      - name: "state-management-xml"
        configMap:
          name: {{ template "apache-nifi.fullname" . }}-config
          items:
            - key: "state-management.xml"
              path: "state-management.xml"
      - name: "zookeeper-properties"
        configMap:
          name: {{ template "apache-nifi.fullname" . }}-config
          items:
            - key: "zookeeper.properties"
              path: "zookeeper.properties"
      - name: "flow-content"
        configMap:
          name: {{ template "apache-nifi.fullname" . }}-config
          items:
            - key: "flow.xml"
              path: "flow.xml"
      - name: "logback-xml"
        configMap:
          name: {{ template "apache-nifi.fullname" . }}-config
          items:
            - key: "logback.xml"
              path: "logback.xml"
    {{- if .Values.persistence.flowfileRepoStorage.inMemory }}
      - name: flowfile-repository
        emptyDir:
          medium: Memory
          sizeLimit: {{ .Values.persistence.flowfileRepoStorage.size }}
    {{- end }}
    {{- if .Values.persistence.contentRepoStorage.inMemory }}
      - name: content-repository
        emptyDir:
          medium: Memory
          sizeLimit: {{ .Values.persistence.contentRepoStorage.size }}
    {{- end }}
    {{- if .Values.persistence.provenanceRepoStorage.inMemory }}
      - name: provenance-repository
        emptyDir:
          medium: Memory
          sizeLimit: {{ .Values.persistence.provenanceRepoStorage.size }}
    {{- end }}
{{ if .Values.certManager.enabled }}
  {{- $caSecrets := default .Values.certManager.caSecrets .Values.caSecrets }}
      - name: secret-reader-token
        secret:
          secretName: {{ template "apache-nifi.fullname" $ }}-secret-reader-token
      - name: tls
        emptyDir: {}
      {{- range $caSecrets }}
      - name: {{ include "apache-nifi.fullname" $ }}-{{ . }}
        secret:
          secretName: {{ . }}
      {{- end }}
{{- /* if .Values.certManager.enabled */}}
{{- end }}
{{- $vaultVals := .Values.VaultNiFiSecrets -}}
{{- $vaultCaSecrets := .Values.caSecrets -}}
{{- $vaultCaSecretName := default "" $vaultVals.vaultSidecar.caSecretName -}}
{{- if and (eq $vaultCaSecretName "") (gt (len $vaultCaSecrets) 0) -}}
{{- $vaultCaSecretName = index $vaultCaSecrets 0 -}}
{{- end -}}
{{- if and $vaultVals.enabled (eq (default "" $vaultVals.secretProvider) "vaultSidecar") (ne $vaultCaSecretName "") (not .Values.certManager.enabled) }}
      - name: {{ include "apache-nifi.fullname" $ }}-{{ $vaultCaSecretName }}
        secret:
          secretName: {{ $vaultCaSecretName }}
{{- end }}
{{- if ne $vaultCaSecretName "" }}
      - name: ca-secret-files
        secret:
          secretName: {{ $vaultCaSecretName }}
      - name: vault-ca-bundle
        emptyDir: {}
{{- end }}
{{- if and (ne $vaultCaSecretName "") .Values.NiFiSync.s3Sync.enabled }}
      - name: merged-ca-bundle
        emptyDir: {}
{{- end }}
{{- if or .Values.NiFiSync.s3Sync.enabled .Values.NiFiSync.UserPolicySync.enabled}}
      - name: nifisync-scripts
        configMap:
          name: {{ template "apache-nifi.fullname" $ }}-nifisync-scripts
{{- /* if or .Values.NiFiSync.s3Sync.enabled .Values.NiFiSync.UserPolicySync.enabled */}}{{ end }}
{{- if eq (include "nifi.secretSyncEnabled" .) "true" }}
      - name: secret-modifier-token
        secret:
          secretName: {{ template "apache-nifi.fullname" $ }}-sync-secret-modifier-token
{{- end }}
{{- if eq (include "nifi.secretSyncEnabled" .) "true" }}
    {{- range (include "nifi.syncPaths" . | fromJsonArray) }}
    {{- if and (default true .enabled) (ne .pathType "fs") (or (ne .pathType "tls-secret") $.Values.ingress.enabled) }}
      - name: {{ include "apache-nifi.fullname" $ }}-{{ .pathName }}
        secret:
    {{- $secretType := (default $.Values.NiFiSync.DefaultSecretType .secretType) | lower }}
    {{- if eq $secretType "kubernetes" }}
          secretName: {{ template "apache-nifi.fullname" $ }}-{{ .pathName }}
    {{- else if eq $secretType "vault" }}
          secretName: vault-{{ template "apache-nifi.fullname" $ }}-{{ .pathName }}
    {{- end }}
    {{- end }}
    {{- end }}
{{- /* if .Values.NiFiSync.s3Sync.enabled */}}{{ end }}
      {{- range .Values.secrets }}
      - name: {{ include "apache-nifi.fullname" $ }}-{{ .name }}
        secret:
          secretName: {{ .name }}
      {{- end }}
      {{- range .Values.configmaps }}
      - name: {{ include "apache-nifi.fullname" $ }}-{{ .name }}
        configMap:
          name: {{ .name }}
      {{- end }}

{{- if not .Values.persistence.enabled }}
      - name: custom-data
        emptyDir: {}
      - name: config-data
        emptyDir: {}
      - name: ssh-data
        emptyDir: {}        
      - name: auth-conf
        emptyDir: {}
      - name: data
        emptyDir: {}
      - name: flowfile-repository
        emptyDir: {}
      - name: content-repository
        emptyDir: {}
      - name: provenance-repository
        emptyDir: {}
      - name: logs
        emptyDir: {}
      - name: status-repository
        emptyDir: {}     
{{- end }}
{{- if .Values.extraVolumes }}
{{ toYaml .Values.extraVolumes | indent 6 }}
{{- end }}
{{- if and .Values.persistence.enabled }}
  volumeClaimTemplates:
{{- end }}
{{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled }}
    - metadata:
        name: {{ .Values.persistence.subPath.name }}
      spec:
        accessModes:
        {{- range .Values.persistence.accessModes }}
          - {{ . | quote }}
        {{- end }}
        storageClassName: {{ .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.subPath.size }}
{{- end }}

{{- if and .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.logStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: logs
      spec:
        accessModes:
        {{- range .Values.persistence.accessModes }}
          - {{ . | quote }}
        {{- end }}
        storageClassName: {{ .Values.persistence.logStorage.storageClass | default .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.logStorage.size }}
{{- end }}
{{- if and .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.statusRepoStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: status-repository
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: {{ .Values.persistence.statusRepoStorage.storageClass | default .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.statusRepoStorage.size }}
{{- end }}
{{- if and .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.sshStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: "ssh-data"
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: {{ .Values.persistence.sshStorage.storageClass | default .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.sshStorage.size }}
{{- end }}
{{- if and .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.customStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: "custom-data"
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: {{ .Values.persistence.customStorage.storageClass | default .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.customStorage.size }}
{{- end }}
{{- if and .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.configStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: "config-data"
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: {{ .Values.persistence.configStorage.storageClass | default .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.configStorage.size }}
{{- end }}
{{- if and .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.dataStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: data
      spec:
        accessModes:
        {{- range .Values.persistence.accessModes }}
          - {{ . | quote }}
        {{- end }}
        storageClassName: {{ .Values.persistence.dataStorage.storageClass | default .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.dataStorage.size }}
{{- end }}
  {{- if and (not .Values.persistence.flowfileRepoStorage.inMemory) .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.flowfileRepoStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: flowfile-repository
      spec:
        accessModes:
        {{- range .Values.persistence.accessModes }}
          - {{ . | quote }}
        {{- end }}
        storageClassName: {{ .Values.persistence.flowfileRepoStorage.storageClass | default .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.flowfileRepoStorage.size }}
{{- end }}
{{- if and (not .Values.persistence.contentRepoStorage.inMemory) .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.contentRepoStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: content-repository
      spec:
        accessModes:
        {{- range .Values.persistence.accessModes }}
          - {{ . | quote }}
        {{- end }}
        storageClassName: {{ .Values.persistence.contentRepoStorage.storageClass | default .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.contentRepoStorage.size }}
{{- end }}
{{- if and (not .Values.persistence.provenanceRepoStorage.inMemory) .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.provenanceRepoStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: provenance-repository
      spec:
        accessModes:
        {{- range .Values.persistence.accessModes }}
          - {{ . | quote }}
        {{- end }}
        storageClassName: {{ .Values.persistence.provenanceRepoStorage.storageClass | default .Values.persistence.storageClass | quote }}
        resources:
          requests:
            storage: {{ .Values.persistence.provenanceRepoStorage.size }}
{{- end }}
{{- if and .Values.persistence.enabled (or (and .Values.persistence.subPath.enabled .Values.persistence.authconfStorage.DisallowSubPath) (not .Values.persistence.subPath.enabled)) }}
    - metadata:
        name: auth-conf
      spec:
        accessModes:
        {{- range .Values.persistence.accessModes }}
          - {{ . | quote }}
        {{- end }}
        storageClassName: {{ .Values.persistence.authconfStorage.storageClass | default .Values.persistence.storageClass | quote }} 
        resources:
          requests:
            storage: {{ .Values.persistence.authconfStorage.size }}
{{- end }}{{- end }}
