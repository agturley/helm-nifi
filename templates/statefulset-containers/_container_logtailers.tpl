{{- define "nifi.container.logTailers" }}
      - name: app-log
        imagePullPolicy: {{ .Values.images.sidecar.pullPolicy | default "Always" | quote }}
        image: "{{ .Values.images.sidecar.repository }}:{{ .Values.images.sidecar.tag }}"
        args: 
          - /bin/sh
          - -c
          - trap "exit 0" TERM; tail -n+1 -F /var/log/nifi-app.log & wait $!
        resources:
{{ toYaml .Values.logresources | indent 10 }}
        volumeMounts:
        - mountPath: /var/log
          {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled }}
          name: {{ .Values.persistence.subPath.name }}
          subPath: logs
          {{- else }}
          name: "logs"
          {{- end }}
      - name: bootstrap-log
        imagePullPolicy: {{ .Values.images.sidecar.pullPolicy | default "Always" | quote }}
        image: "{{ .Values.images.sidecar.repository }}:{{ .Values.images.sidecar.tag }}"
        args:
          - /bin/sh
          - -c
          - trap "exit 0" TERM; tail -n+1 -F /var/log/nifi-bootstrap.log & wait $!
        resources:
{{ toYaml .Values.logresources | indent 10 }}
        volumeMounts:
        - mountPath: /var/log
          {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled }}
          name: {{ .Values.persistence.subPath.name }}
          subPath: logs
          {{- else }}
          name: "logs"
          {{- end }}
      - name: user-log
        imagePullPolicy: {{ .Values.images.sidecar.pullPolicy | default "Always" | quote }}
        image: "{{ .Values.images.sidecar.repository }}:{{ .Values.images.sidecar.tag }}"
        args:
          - /bin/sh
          - -c
          - trap "exit 0" TERM; tail -n+1 -F /var/log/nifi-user.log & wait $!
        resources:
{{ toYaml .Values.logresources | indent 10 }}
        volumeMounts:
        - mountPath: /var/log
          {{- if and .Values.persistence.enabled .Values.persistence.subPath.enabled }}
          name: {{ .Values.persistence.subPath.name }}
          subPath: logs
          {{- else }}
          name: "logs"
          {{- end }}
{{- end }}

