{{/*
_statefulset_containers.tpl
Container named-template definitions have been split into individual files
under templates/statefulset-containers/ for maintainability:

  _container_server.tpl           → nifi.container.server
  _container_s3sync.tpl           → nifi.container.s3sync
  _container_vaultsidecar.tpl  → nifi.container.vaultSidecar
  _container_awssecretssidecar.tpl → nifi.container.awsSecretsSidecar
  _container_logtailers.tpl       → nifi.container.logTailers
  _container_certmanager.tpl      → nifi.container.certManager

Helm loads all .tpl files in templates/ and subdirectories, so all named
templates remain globally available with no changes required to statefulset.yaml.
*/}}
