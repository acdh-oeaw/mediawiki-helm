{{- define "mw.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- define "mw.fullname" -}}
{{- default (printf "%s-%s" .Release.Name (include "mw.name" .)) .Values.fullnameOverride | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- define "mw.selector" -}}
app.kubernetes.io/name: {{ include "mw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "mw.labels" -}}
{{ include "mw.selector" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}
{{- define "mw.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}
{{- define "mw.claim" -}}
{{ default (printf "%s-uploads" (include "mw.fullname" .)) .Values.persistence.existingClaim }}
{{- end -}}
{{- define "mw.env" -}}
- name: MW_DB_HOST
  value: {{ (include "mw.dbHost" .) | quote }}
- name: MW_DB_PORT
  value: {{ (include "mw.dbPort" .) | quote }}
- name: MW_DB_NAME
  value: {{ (include "mw.dbName" .) | quote }}
- name: MW_DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "mw.dbSecret" . }}
      key: {{ include "mw.dbUserKey" . }}
- name: MW_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "mw.dbSecret" . }}
      key: {{ include "mw.dbPasswordKey" . }}
- name: MW_SERVER
  value: {{ .Values.mediawiki.server | quote }}
- name: MW_NAME
  value: {{ .Values.mediawiki.name | quote }}
- name: MW_EMAIL
  value: {{ .Values.mediawiki.email | quote }}
- name: MW_READ_ONLY
  value: {{ .Values.mediawiki.readOnly | quote }}
- name: MW_READ_ONLY_REASON
  value: {{ .Values.mediawiki.readOnlyReason | quote }}
{{ with .Values.extraEnv }}
{{ toYaml . }}
{{ end }}
{{- end -}}
{{- define "mw.mounts" -}}
{{- if not .Values.bootstrap.enabled }}
- name: runtime-config
  mountPath: /var/www/html/LocalSettings.php
  subPath: LocalSettings.php
  readOnly: true
{{- end }}
- name: settings
  mountPath: /etc/mediawiki
  readOnly: true
- name: security
  mountPath: /etc/mediawiki-security
  readOnly: true
- name: runtime-config
  mountPath: /etc/apache2/ports.conf
  subPath: ports.conf
  readOnly: true
- name: runtime-config
  mountPath: /etc/apache2/sites-enabled/000-default.conf
  subPath: vhost.conf
  readOnly: true
- name: tmp
  mountPath: /tmp
- name: uploads
  mountPath: /var/www/html/images
  {{- with .Values.persistence.subPath }}
  subPath: {{ . | quote }}
  {{- end }}
{{ with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{ end }}
{{- end -}}
{{- define "mw.volumes" -}}
- name: runtime-config
  configMap:
    name: {{ include "mw.fullname" . }}-runtime
- name: settings
  secret:
    secretName: {{ include "mw.fullname" . }}-settings
- name: security
  secret:
    secretName: {{ include "mw.securitySecret" . }}
- name: tmp
  emptyDir: {}
- name: uploads
  {{- if .Values.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "mw.claim" . }}
  {{- else }}
  emptyDir: {}
  {{- end }}
{{ with .Values.extraVolumes }}
{{ toYaml . }}
{{ end }}
{{- end -}}

{{- define "mw.dbSecret" -}}
{{- if .Values.mariadb.enabled -}}
{{ default (printf "%s-mariadb-auth" (include "mw.fullname" .)) .Values.mariadb.auth.existingSecret }}
{{- else -}}
{{ default (printf "%s-db" (include "mw.fullname" .)) .Values.externalDatabase.existingSecret }}
{{- end -}}
{{- end -}}
{{- define "mw.securitySecret" -}}
{{ default (printf "%s-security" (include "mw.fullname" .)) .Values.security.existingSecret }}
{{- end -}}

{{- define "mw.dbHost" -}}
{{- if .Values.mariadb.enabled -}}{{ include "mw.fullname" . }}-mariadb{{- else -}}{{ .Values.externalDatabase.host }}{{- end -}}
{{- end -}}
{{- define "mw.dbPort" -}}
{{- if .Values.mariadb.enabled -}}3306{{- else -}}{{ .Values.externalDatabase.port }}{{- end -}}
{{- end -}}
{{- define "mw.dbName" -}}
{{- if .Values.mariadb.enabled -}}{{ .Values.mariadb.auth.database }}{{- else -}}{{ .Values.externalDatabase.database }}{{- end -}}
{{- end -}}
{{- define "mw.dbUserKey" -}}
{{- if .Values.mariadb.enabled -}}database-user{{- else -}}{{ .Values.externalDatabase.userKey }}{{- end -}}
{{- end -}}
{{- define "mw.dbPasswordKey" -}}
{{- if .Values.mariadb.enabled -}}database-password{{- else -}}{{ .Values.externalDatabase.passwordKey }}{{- end -}}
{{- end -}}
{{- define "mw.mariadbImage" -}}
{{- if .Values.mariadb.image.digest -}}
{{ .Values.mariadb.image.repository }}@{{ .Values.mariadb.image.digest }}
{{- else -}}
{{ .Values.mariadb.image.repository }}:{{ .Values.mariadb.image.tag }}
{{- end -}}
{{- end -}}
{{- define "mw.mariadbClaim" -}}
{{ default (printf "%s-mariadb-data" (include "mw.fullname" .)) .Values.mariadb.persistence.existingClaim }}
{{- end -}}
{{- define "mw.waitDatabase" -}}
- name: wait-database
  image: {{ include "mw.image" . | quote }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  securityContext:
    {{- toYaml .Values.containerSecurityContext | nindent 4 }}
  command: [php, -r]
  args:
    - |
      mysqli_report(MYSQLI_REPORT_OFF);
      for ($attempt = 0; $attempt < 300; $attempt++) {
          $db = @new mysqli(getenv('MW_DB_HOST'), getenv('MW_DB_USER'), getenv('MW_DB_PASSWORD'), getenv('MW_DB_NAME'), (int)getenv('MW_DB_PORT'));
          if (!$db->connect_errno) { $db->close(); exit(0); }
          sleep(2);
      }
      fwrite(STDERR, "Database did not become available within 600 seconds.\n");
      exit(1);
  env:
    {{- include "mw.env" . | nindent 4 }}
  resources:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {cpu: 250m, memory: 128Mi}
{{- end -}}
