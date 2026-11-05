{{/* One policy list drives both zone declarations and per-location directives. */}}
{{- define "nomad.proxy.rateLimitPolicies" -}}
{{- $limits := .Values.nomad.proxy.rateLimits -}}
{{- list
    (dict "name" "nomad_heavy_per_ip" "profile" "heavy" "config" $limits.heavy.perIp "key" "$nomad_limit_key" "enabled" (and $limits.enabled $limits.heavy.enabled $limits.heavy.perIp.enabled))
    (dict "name" "nomad_heavy_global" "profile" "heavy" "config" $limits.heavy.global "key" "$nomad_global_limit_key" "enabled" (and $limits.enabled $limits.heavy.enabled $limits.heavy.global.enabled))
    (dict "name" "nomad_medium" "profile" "medium" "config" $limits.medium "key" "$nomad_limit_key" "enabled" (and $limits.enabled $limits.medium.enabled))
    | toJson -}}
{{- end }}

{{- define "nomad.proxy.rateLimitZones" -}}
{{- if .Values.nomad.proxy.rateLimits.enabled }}
# Raw upload endpoints bypass both budgets for non-GET methods.
map "$nomad_raw_download:$request_method" $nomad_limit_key {
    default $binary_remote_addr;
    "~^1:" "";
    "1:GET" $binary_remote_addr;
}
map $nomad_limit_key $nomad_global_limit_key {
    "" "";
    default $server_name;
}
limit_req_status 429;
limit_conn_status 429;
{{- range (include "nomad.proxy.rateLimitPolicies" . | fromJsonArray) }}
{{- if .enabled }}
{{- if lt (int .config.burst) 0 }}
{{- fail "nomad.proxy.rateLimits burst must be non-negative" }}
{{- end }}
{{- if lt (int (.config.maxConnections | default 0)) 0 }}
{{- fail "nomad.proxy.rateLimits maxConnections must be non-negative" }}
{{- end }}
{{- if .config.rate }}
{{- if not (regexMatch "^[1-9][0-9]*r/[sm]$" .config.rate) }}
{{- fail "nomad.proxy.rateLimits rate must be a positive NGINX rate such as 12r/m or 1r/s, or an empty string to disable request limiting" }}
{{- end }}
limit_req_zone {{ .key }} zone={{ .name }}_req:{{ $.Values.nomad.proxy.rateLimits.zoneSize }} rate={{ .config.rate }};
{{- end }}
{{- if gt (int (.config.maxConnections | default 0)) 0 }}
limit_conn_zone {{ .key }} zone={{ .name }}_conn:{{ $.Values.nomad.proxy.rateLimits.zoneSize }};
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- define "nomad.proxy.rateLimitDirectives" -}}
{{- $profile := .profile -}}
{{- $active := false -}}
{{- range (include "nomad.proxy.rateLimitPolicies" .root | fromJsonArray) }}
{{- if and .enabled (eq .profile $profile) }}
{{- if .config.rate }}
{{- $active = true }}
limit_req zone={{ .name }}_req{{ if gt (int .config.burst) 0 }} burst={{ .config.burst }}{{ end }}{{ if .config.nodelay }} nodelay{{ end }};
{{- end }}
{{- if gt (int (.config.maxConnections | default 0)) 0 }}
{{- $active = true }}
limit_conn {{ .name }}_conn {{ .config.maxConnections }};
{{- end }}
{{- end }}
{{- end }}
{{- if $active }}
error_page 429 = @nomad_ratelimited_{{ $profile }};
{{- end }}
{{- end }}

{{- define "nomad.proxy.rateLimitResponses" -}}
{{- $limits := .Values.nomad.proxy.rateLimits -}}
{{- if $limits.enabled }}
{{- range $profile := list "heavy" "medium" }}
location @nomad_ratelimited_{{ $profile }} {
    default_type application/json;
    add_header Retry-After {{ (index $limits $profile).retryAfter | quote }} always;
    return 429 '{"detail":"Request rate or concurrent request limit exceeded. Please retry later."}';
}
{{- end }}
{{- end }}
{{- end }}

{{/* Ordered routes keep classification separate from policy and pool selection. */}}
{{- define "nomad.proxy.resourceLocations" -}}
{{- $root := .root -}}
{{- if or $root.Values.nomad.app.heavy.enabled $root.Values.nomad.proxy.rateLimits.enabled }}
{{- $routes := list
    (dict "pattern" "/api/v1/uploads/[^/]+/raw/?$" "profile" "heavy" "rawDownload" true "upload" true)
    (dict "pattern" "/api/v1/uploads/[^/]+/raw/.+" "profile" "medium" "rawDownload" true "upload" true)
    (dict "pattern" "/api/v1/uploads/[^/]+/rawdir(/.*)?$" "profile" "medium")
    (dict "pattern" "/api/v1/entries/archive(/download)?(/query)?/?$" "profile" "heavy")
    (dict "pattern" "/api/v1/entries/[^/]+/rawdir/?$" "profile" "medium")
    (dict "pattern" "/api/v1/entries/[^/]+/raw/?$" "profile" "heavy")
    (dict "pattern" "/api/v1/entries/[^/]+/raw/.+" "profile" "medium")
    (dict "pattern" "/api/v1/entries/raw(/query)?/?$" "profile" "heavy")
    (dict "pattern" "/api/v1/entries/[^/]+/archive(/query|/download)?/?$" "profile" "medium")
-}}
{{- range $routes }}
location ~ {{ .pattern }} {
    {{- if and $root.Values.nomad.proxy.rateLimits.enabled .rawDownload }}
    set $nomad_raw_download 1;
    {{- end }}
    {{- include "nomad.proxy.rateLimitDirectives" (dict "root" $root "profile" .profile) | nindent 4 }}
    {{- if .upload }}
    client_max_body_size 35g;
    proxy_request_buffering off;
    {{- end }}
    proxy_buffering off;
    proxy_pass {{ $.backend }};
}
{{- end }}
{{- end }}
{{- if $root.Values.nomad.proxy.rateLimits.enabled }}
# OPTIMADE searches share the medium budget but remain on the normal app.
location ~ /optimade/v1/structures/?$ {
    {{- include "nomad.proxy.rateLimitDirectives" (dict "root" $root "profile" "medium") | nindent 4 }}
    proxy_pass {{ .app }};
}
{{- end }}
{{- end }}
