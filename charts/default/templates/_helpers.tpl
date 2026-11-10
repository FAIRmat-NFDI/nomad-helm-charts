{{- define "nomad.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nomad.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "nomad.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nomad.labels" -}}
helm.sh/chart: {{ include "nomad.chart" . }}
{{ include "nomad.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "nomad.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nomad.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "nomad.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "nomad.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "nomad.config" -}}
{{- .Values.nomad.config }}
{{- end }}

{{- define "nomad.config.apiHost" -}}
{{- .Values.nomad.config.services.api_host }}
{{- end }}

{{- define "nomad.config.apiBasePath" -}}
{{- .Values.nomad.config.services.api_base_path }}
{{- end }}

{{/*
URL layout. The backend path (services.api_base_path) is where NOMAD mounts its
API, NORTH and the other services. The public path is where the GUI is served;
when it differs from the backend path, the proxy serves the new GUI at the
public path, the classic GUI at <public>/gui/ and reserves the backend path for
the services. Root paths use an empty prefix when composing child routes.
*/}}
{{- define "nomad.proxy.backendPath" -}}
{{- $path := .Values.nomad.config.services.api_base_path -}}
{{- if eq $path "/" -}}
/
{{- else -}}
{{- trimSuffix "/" $path -}}
{{- end -}}
{{- end }}

{{- define "nomad.proxy.publicPath" -}}
{{- $path := default .Values.nomad.config.services.api_base_path .Values.nomad.proxy.publicPath -}}
{{- if eq $path "/" -}}
/
{{- else -}}
{{- trimSuffix "/" $path -}}
{{- end -}}
{{- end }}

{{- define "nomad.proxy.backendPrefix" -}}
{{- $path := include "nomad.proxy.backendPath" . -}}
{{- if ne $path "/" -}}{{- $path -}}{{- end -}}
{{- end }}

{{- define "nomad.proxy.publicPrefix" -}}
{{- $path := include "nomad.proxy.publicPath" . -}}
{{- if ne $path "/" -}}{{- $path -}}{{- end -}}
{{- end }}

{{/*
nginx statements that send a legacy GUI link to the GUI chosen by the
nomad_gui_pref cookie, falling back to nomad.config.gui.default. Takes a dict
with the v1, v2 and select targets and the default.
*/}}
{{- define "nomad.proxy.pickGui" -}}
if ($cookie_nomad_gui_pref = "v1") { return 302 {{ .v1 }}; }
if ($cookie_nomad_gui_pref = "v2") { return 302 {{ .v2 }}; }
return 302 {{ index . .default }};
{{- end }}

{{- define "nomad.config.https" -}}
{{- .Values.nomad.config.services.https }}
{{- end }}

{{- define "nomad.secretName.api" -}}
{{- if .Values.nomad.secrets.api.existingSecret }}
{{- .Values.nomad.secrets.api.existingSecret }}
{{- else }}
{{- printf "%s-api-secret" (include "nomad.fullname" .) }}
{{- end }}
{{- end }}

{{- define "nomad.secretName.keycloakClient" -}}
{{- if .Values.nomad.secrets.keycloak.clientSecret.existingSecret }}
{{- .Values.nomad.secrets.keycloak.clientSecret.existingSecret }}
{{- else }}
{{- printf "%s-keycloak-client-secret" (include "nomad.fullname" .) }}
{{- end }}
{{- end }}

{{- define "nomad.secretName.keycloakPassword" -}}
{{- if .Values.nomad.secrets.keycloak.password.existingSecret }}
{{- .Values.nomad.secrets.keycloak.password.existingSecret }}
{{- else }}
{{- printf "%s-keycloak-password-secret" (include "nomad.fullname" .) }}
{{- end }}
{{- end }}

{{- define "nomad.secretName.north" -}}
{{- if .Values.nomad.secrets.north.hubServiceApiToken.existingSecret }}
{{- .Values.nomad.secrets.north.hubServiceApiToken.existingSecret }}
{{- else }}
{{- printf "%s-north-hub-token-secret" (include "nomad.fullname" .) }}
{{- end }}
{{- end }}

{{- define "nomad.hasApiSecret" -}}
{{- or .Values.nomad.secrets.api.existingSecret .Values.nomad.secrets.api.value .Values.nomad.secrets.api.autoGenerate }}
{{- end }}

{{- define "nomad.validateConfig" -}}
{{- $config := .Values.nomad.config -}}
{{- $warnings := list -}}

{{- if and $config.temporal.enabled (not .Values.temporal.enabled) }}
{{- $warnings = append $warnings "temporal is enabled in nomad.config but temporal subchart is disabled" }}
{{- end }}

{{- if and $config.north.enabled (not .Values.jupyterhub.enabled) }}
{{- $warnings = append $warnings "north is enabled in nomad.config but jupyterhub is disabled" }}
{{- end }}

{{- if and (not .Values.nomad.secrets.api.existingSecret) (not .Values.nomad.secrets.api.value) (not .Values.nomad.secrets.api.autoGenerate) }}
{{- $warnings = append $warnings "No API secret configured - set nomad.secrets.api.existingSecret, .value, or .autoGenerate" }}
{{- end }}

{{- $warnings | toJson }}
{{- end }}

{{/*
Generate a volume definition for a data volume.
Supports hostPath (default) or PVC when persistence is enabled.
Usage:
  {{- include "nomad.dataVolume" (dict "root" . "name" "public-volume" "volumeKey" "public" "hostPath" $config.fs.public_external) | nindent 8 }}
*/}}
{{- define "nomad.dataVolume" -}}
{{- $persistence := .root.Values.nomad.persistence -}}
{{- $volumeConfig := index $persistence .volumeKey -}}
- name: {{ .name }}
{{- if $persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ default (printf "%s-%s" (include "nomad.fullname" .root) .volumeKey) $volumeConfig.existingClaim }}
{{- else }}
  hostPath:
    path: {{ .hostPath }}
{{- end }}
{{- end }}

{{/*
initContainer that blocks until the Temporal frontend is reachable and the NOMAD
temporal namespace is registered. Idempotent (describe-or-create loop). Closes two
gaps observed in practice:
  1. The NOMAD worker silently stops polling if Temporal / its namespace isn't ready
     at boot, yet stays "healthy" (its liveness probe is only `ls /`) -> needs a gate.
  2. The temporal subchart's own create-default-namespace job addresses the frontend
     by a partial `.svc` name that the Go gRPC resolver may fail to complete under
     some cluster DNS configs; the FQDN used here resolves reliably.
Renders nothing when temporal or temporalInit is disabled.
Usage (with root context):
  {{- with (include "nomad.temporalNamespaceInit" .) }}
  initContainers:
    {{- . | nindent 8 }}
  {{- end }}
*/}}
{{- define "nomad.temporalNamespaceInit" -}}
{{- $config := .Values.nomad.config -}}
{{- if and $config.temporal.enabled .Values.nomad.temporalInit.enabled -}}
{{- $host := $config.temporal.host | default (printf "%s-temporal-frontend.%s.svc.cluster.local" .Release.Name .Release.Namespace) -}}
{{- $addr := printf "%s:%v" $host (.Values.nomad.temporalInit.port | default 7233) -}}
- name: wait-temporal-namespace
  image: {{ .Values.nomad.temporalInit.image | quote }}
  imagePullPolicy: {{ .Values.nomad.temporalInit.pullPolicy | default "IfNotPresent" }}
  command: ["/bin/sh", "-ec"]
  args:
    - |
      ADDR="{{ $addr }}"
      NS="{{ $config.temporal.namespace }}"
      echo "Ensuring Temporal namespace '$NS' at $ADDR ..."
      i=0
      until temporal operator namespace describe -n "$NS" --address "$ADDR" >/dev/null 2>&1; do
        temporal operator namespace create -n "$NS" --retention {{ .Values.nomad.temporalInit.namespaceRetention | default "72h" }} --address "$ADDR" >/dev/null 2>&1 || true
        i=$((i+1))
        echo "  [$i] Temporal not ready / namespace '$NS' missing; retrying in 5s ..."
        sleep 5
      done
      echo "Temporal namespace '$NS' is ready."
{{- end -}}
{{- end -}}

{{/*
Generate PVC spec for a data volume.
Usage:
  {{- include "nomad.pvc" (dict "root" . "volumeKey" "public" "component" "public") }}
*/}}
{{- define "nomad.pvc" -}}
{{- $persistence := .root.Values.nomad.persistence -}}
{{- $volumeConfig := index $persistence .volumeKey -}}
{{- $storageClass := default $persistence.storageClass $volumeConfig.storageClass -}}
{{- $accessMode := default $persistence.accessMode $volumeConfig.accessMode -}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "nomad.fullname" .root }}-{{ .volumeKey }}
  labels:
    {{- include "nomad.labels" .root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  accessModes:
    - {{ $accessMode }}
  {{- if $storageClass }}
  storageClassName: {{ $storageClass | quote }}
  {{- end }}
  resources:
    requests:
      storage: {{ $volumeConfig.size }}
{{- end }}

{{/*
Elasticsearch. The chart bundles a single-node Elasticsearch 9 StatefulSet
(<release>-elasticsearch); nomad.infrastructure.elastic.host points NOMAD elsewhere.
*/}}
{{- define "nomad.elastic.serviceName" -}}
{{- printf "%s-elasticsearch" .Release.Name -}}
{{- end }}

{{- define "nomad.elastic.host" -}}
{{- .Values.nomad.infrastructure.elastic.host | default (include "nomad.elastic.serviceName" .) -}}
{{- end }}

{{- define "nomad.elastic.version" -}}
{{- .Values.nomad.config.elastic.version | default "9" | toString -}}
{{- end }}

{{- define "nomad.elastic.entriesIndex" -}}
{{- printf "%s_entries_v1" .Values.nomad.config.mongo.db_name -}}
{{- end }}

{{/* What NOMAD pods connect to; hashed into a pod annotation so they restart when it changes. */}}
{{- define "nomad.elastic.target" -}}
{{- printf "%s://%s:%v/v%s" (.Values.nomad.config.elastic.scheme | default "http") (include "nomad.elastic.host" .) .Values.nomad.config.elastic.port (include "nomad.elastic.version" .) -}}
{{- end }}

{{- define "nomad.elastic.image" -}}
{{- printf "%s:%s" .Values.elasticsearch.image (.Values.elasticsearch.imageTag | toString) -}}
{{- end }}

{{/*
initContainer that raises vm.max_map_count on the node (Elasticsearch bootstrap
check). Writes /proc directly so it works on images without the sysctl binary.
*/}}
{{- define "nomad.elastic.sysctlInit" -}}
- name: sysctl
  image: {{ .image | quote }}
  imagePullPolicy: {{ .pullPolicy }}
  command: ["sh", "-c"]
  args:
    - |
      current=$(cat /proc/sys/vm/max_map_count)
      if [ "$current" -lt {{ .count }} ]; then
        echo {{ .count }} > /proc/sys/vm/max_map_count
      fi
  securityContext:
    privileged: true
    runAsUser: 0
{{- end }}


{{/* Credentials shared by the API and all Temporal worker types. */}}
{{/*
Elasticsearch basic auth. NOMAD only authenticates when both username and
password are set, so the username defaults to "elastic" once a password secret
is configured. The password is passed as NOMAD_ELASTIC_PASSWORD.
*/}}
{{- define "nomad.elastic.username" -}}
{{- if .Values.nomad.config.elastic.username -}}
{{- .Values.nomad.config.elastic.username -}}
{{- else if .Values.nomad.secrets.elastic.existingSecret -}}
elastic
{{- end -}}
{{- end }}

{{- define "nomad.elasticAuthEnv" -}}
{{- with .Values.nomad.secrets.elastic }}
{{- if .existingSecret }}
- name: NOMAD_ELASTIC_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret | quote }}
      key: {{ .key | default "elastic" | quote }}
{{- end }}
{{- end }}
{{- end }}

{{- define "nomad.storageTemporalEnv" -}}
{{- $fs := .Values.nomad.config.fs -}}
{{- if $fs.s3Secret }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ $fs.s3Secret | quote }}
      key: {{ $fs.s3AccessKeyIdKey | quote }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $fs.s3Secret | quote }}
      key: {{ $fs.s3SecretAccessKeyKey | quote }}
{{- end }}
{{- with .Values.nomad.secrets.temporal.oidc }}
{{- if .existingSecret }}
- name: NOMAD_TEMPORAL_OIDC
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret | quote }}
      key: {{ .key | quote }}
{{- end }}
{{- end }}
{{- end }}
