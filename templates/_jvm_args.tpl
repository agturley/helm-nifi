{{- define "nifi.jvmArgs" -}}
{{- $jvm := .Values.jvm -}}

{{- if eq $jvm.gcCollector "zgc" }}
java.arg.20=-XX:+UseZGC
{{- with $jvm.zgc }}
{{- if not (kindIs "invalid" .generational) }}
java.arg.21=-XX:{{ if .generational }}+{{ else }}-{{ end }}ZGenerational
{{- end }}
{{- if not (kindIs "invalid" .concGCThreads) }}
java.arg.22=-XX:ConcGCThreads={{ .concGCThreads }}
{{- end }}
{{- if not (kindIs "invalid" .alwaysPreTouch) }}
java.arg.23=-XX:{{ if .alwaysPreTouch }}+{{ else }}-{{ end }}AlwaysPreTouch
{{- end }}
{{- if not (kindIs "invalid" .uncommitDelay) }}
java.arg.24=-XX:ZUncommitDelay={{ .uncommitDelay }}
{{- end }}
{{- if not (kindIs "invalid" .disableExplicitGC) }}
java.arg.25=-XX:{{ if .disableExplicitGC }}+{{ else }}-{{ end }}DisableExplicitGC
{{- end }}
{{- range $i, $arg := .extraArgs }}
java.arg.{{ add 40 $i }}={{ $arg }}
{{- end }}
{{- end }}

{{- else if eq $jvm.gcCollector "g1gc" }}
java.arg.20=-XX:+UseG1GC
{{- with $jvm.g1gc }}
{{- if not (kindIs "invalid" .maxGCPauseMillis) }}
java.arg.21=-XX:MaxGCPauseMillis={{ .maxGCPauseMillis }}
{{- end }}
{{- if not (kindIs "invalid" .heapRegionSize) }}
java.arg.22=-XX:G1HeapRegionSize={{ .heapRegionSize }}
{{- end }}
{{- if not (kindIs "invalid" .newSizePercent) }}
java.arg.23=-XX:G1NewSizePercent={{ .newSizePercent }}
{{- end }}
{{- if not (kindIs "invalid" .maxNewSizePercent) }}
java.arg.24=-XX:G1MaxNewSizePercent={{ .maxNewSizePercent }}
{{- end }}
{{- if not (kindIs "invalid" .mixedGCLiveThresholdPercent) }}
java.arg.25=-XX:G1MixedGCLiveThresholdPercent={{ .mixedGCLiveThresholdPercent }}
{{- end }}
{{- if not (kindIs "invalid" .initiatingHeapOccupancyPercent) }}
java.arg.26=-XX:InitiatingHeapOccupancyPercent={{ .initiatingHeapOccupancyPercent }}
{{- end }}
{{- if not (kindIs "invalid" .concGCThreads) }}
java.arg.27=-XX:ConcGCThreads={{ .concGCThreads }}
{{- end }}
{{- if not (kindIs "invalid" .parallelGCThreads) }}
java.arg.28=-XX:ParallelGCThreads={{ .parallelGCThreads }}
{{- end }}
{{- if not (kindIs "invalid" .alwaysPreTouch) }}
java.arg.29=-XX:{{ if .alwaysPreTouch }}+{{ else }}-{{ end }}AlwaysPreTouch
{{- end }}
{{- range $i, $arg := .extraArgs }}
java.arg.{{ add 40 $i }}={{ $arg }}
{{- end }}
{{- end }}
{{- end }}

{{- if $jvm.gcLogging.enabled }}
java.arg.30=-Xlog:gc*:file={{ $jvm.gcLogging.path }}:time,uptime:filecount={{ $jvm.gcLogging.fileCount }},filesize={{ $jvm.gcLogging.fileSize }}
{{- end }}

{{- end }}