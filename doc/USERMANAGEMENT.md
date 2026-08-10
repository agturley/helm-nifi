# User Authentication

This helm chart provides four types of authentication: Single User, Client Certificate, LDAP, and OIDC. These four authentication types can be managed essentialy from the `values.yaml` file.

The parameter `admin` will set the initial admin username. If used in conjunction with an enabled LDAP configuration, this value will get used instead of the LDAP Bind DN for the admin username.

## 1. Single User

The Single User authentication is the default authentication in this helm chart. To login like a single user, the values below must be set in `values.yaml` file:

```
singleUser:
    username: username
    password: changemechangeme_secret
```

## 2. Client Certificate

Client Certificate authentication assumes a central Certificate Authority (CA) will issue a Client PKI Certificate and Server Certificate for the Nifi server.

Add keystore files to a Kubernetes secret:

```
kubectl create secret generic mysecrets \
--from-file=keystore.jks=/path/to/keystore.jks \
--from-file=truststore.jks=/path/to/truststore.jks
```

Make the Kubernetes secret available to the Nifi server. Update `values.yaml`:

```
secrets:
- name: mysecrets
  keys:
    - keystore.jks
    - truststore.jks
  mountPath: /opt/nifi/nifi-current/config-data/certs/
```

Enable the Nifi server to prompt for client certificates:

```
properties:
   needClientAuth: true
```

Indicate Client Authentication mode configurations should be applied and set SSL values:

```
auth:
   SSL:
     keystorePasswd: <passwd>
     truststorePasswd: <passwd>
   clientAuth:
     enabled: true
```

For cluster deployments, the example below illustrates how to create a 3 replica cluster with unique keystores.

Create the secret:

```
kubectl create secret generic mysecrets \
--from-file=<nifi-0 fqdn>.jks=/path/to/<nifi-0 fqdn>.jks \
--from-file=<nifi-1 fqdn>.jks=/path/to/<nifi-1 fqdn>.jks \
--from-file=<nifi-2 fqdn>.jks=/path/to/<nifi-2 fqdn>.jks \
--from-file=truststore.jks=/path/to/truststore.jks
```

Make the secret available to the replicas:

```
secrets:
- name: mysecrets
  keys:
    - <nifi-0 fqdn>.jks
    - <nifi-1 fqdn>.jks
    - <nifi-2 fqdn>.jks
    - truststore.jks
  mountPath: /opt/nifi/nifi-current/config-data/certs/
```

Add a safetyValve entry to align the container with the associated keystore:

```
properties:
  safetyValve:
    nifi.security.keystore: ${NIFI_HOME}/config-data/certs/${FQDN}.jks
```

## 3. OIDC

OpenID Connect (OIDC) profiles and extends OAuth 2.0 with an identity layer, letting an
external provider perform authentication.

```yaml
auth:
  ldap:
    enabled: false
  oidc:
    enabled: true
    discoveryUrl: https://<provider>/.well-known/openid-configuration
    clientId: <client_id_in_oidc_provider>
    clientSecret: <client_secret_in_oidc_provider>
    claimIdentifyingUser: email
    additionalScopes: email
    admin: nifi@example.com
```

### `additionalScopes` is usually required

The single most common OIDC failure with this chart is a login that appears to
succeed and then leaves NiFi unable to identify the user. `claimIdentifyingUser`
defaults to `email`, and providers only return the email claim when the `email`
scope was requested — so without `additionalScopes`, the claim NiFi is looking
for is simply absent from the token.

The value accepts a comma-separated string or a YAML list:

```yaml
additionalScopes: email
additionalScopes: [profile, email, groups]
```

### Group-based policies

`claimGroups` (default `groups`) names the ID-token claim carrying the user's
groups. Both Okta and Keycloak use `groups` by convention, but **neither emits it
by default** — the claim must be added to the authorization server first, and the
matching scope requested via `additionalScopes`.

### Provider examples

| Provider | `discoveryUrl` |
|---|---|
| Okta | `https://<org>.okta.com/oauth2/default/.well-known/openid-configuration` |
| Keycloak | `http://<host>:<port>/auth/realms/<realm>/.well-known/openid-configuration` |

Any compliant provider works — the chart passes these straight through to NiFi
and has nothing provider-specific in it. See [KEYCLOAK.md](KEYCLOAK.md) for a
worked Keycloak walkthrough (note that it was written against an older Keycloak
admin console and the screenshots have aged).

`truststore.strategy` is set to `JDK`, which is what a public-CA provider such as
Okta needs. A provider using a private CA requires its CA in the JVM truststore —
see `certManager.caSecrets`.

### Clustering caveat

OIDC does **not** avoid re-authentication when a request lands on a different
node, and it adds a second reason to require session affinity: NiFi still issues
its own per-node bearer token after the exchange, *and* the authorization-code
flow keeps its state on the node that began it, so a callback arriving elsewhere
fails with "Unable to Continue Login Sequence". Sticky sessions are mandatory.
See [FAQ.md](FAQ.md).

## 4. LDAP

LDAP provides external authentication against a directory you already run. There
is no bundled LDAP server — point the chart at an existing one.

```yaml
auth:
  oidc:
    enabled: false
  ldap:
    enabled: true
    host: ldap://<hostname>:<port>
    searchBase: OU=Users,DC=example,DC=com
    admin: CN=svc-nifi,OU=Users,DC=example,DC=com   # bind DN
    pass: changeMe                                   # bind password
    userIdentityAttribute: sAMAccountName            # Active Directory
    identityStrategy: USE_USERNAME                   # default: USE_DN
```

`admin`/`pass` here are the **bind credentials** used to search the directory —
they are not the NiFi administrator. The NiFi admin is set separately; see
[Initial admin identity](#initial-admin-identity) below.

`identityStrategy` decides the *form* those identities take, and therefore the
form `auth.admin` must take. It defaults to `USE_DN`, matching NiFi's own
behaviour when the property is absent:

| Value | NiFi identity |
|---|---|
| `USE_DN` (default) | the user's full directory DN, e.g. `CN=Adam Turley,OU=Users,DC=example,DC=com` |
| `USE_USERNAME` | the attribute named by `userIdentityAttribute`, e.g. `AGTurley` |

NiFi identities are **case-sensitive**, so the initial admin must match the
directory's casing exactly. Changing this on a running cluster re-forms every
user identity and orphans the policies written against the old form — treat it
as fixed once users exist.

`IdentityStrategy` (capital I) is accepted as a legacy alias and **takes
precedence** when set, so an existing override keeps working rather than being
overridden by the chart default.

Rather than putting the bind password in `values.yaml`, supply
`LDAP_MANAGER_DN` and `LDAP_MANAGER_PASSWORD` through a Secret or Vault — the
container applies them at startup. See
[Credential precedence](INSTALLATION.md#credential-management-propertiessecretsmode).

## Initial admin identity

The initial admin is the one account NiFi seeds with full permissions on a fresh
start, and every other policy is granted from there. It has to be expressed the
same way the active authentication mode identifies users:

| Auth mode | Value | Example |
|---|---|---|
| LDAP (`USE_USERNAME`) | `auth.admin` | `AGTurley` |
| LDAP (full DN) | `auth.admin` | `CN=Adam Turley,OU=Users,DC=example,DC=com` |
| OIDC | `auth.oidc.admin` | `you@example.com` (a value of `claimIdentifyingUser`) |
| Client certificate | `auth.admin` | `CN=admin, OU=NIFI` |

### Supplying it from a Secret or Vault instead

`values.yaml` is the **lowest**-precedence source. At startup the container
resolves `INITIAL_ADMIN_IDENTITY` as:

1. the `secretsMode` source (Vault or AWS files, or the sourced env file)
2. the process environment — typically an `envFrom` secretRef
3. `auth.admin`, or `auth.oidc.admin` when OIDC is enabled

so a Secret carrying `INITIAL_ADMIN_IDENTITY` wins, and you can omit the value
from `values.yaml` entirely:

```yaml
envFrom:
  - secretRef:
      name: nifi-secrets      # provides INITIAL_ADMIN_IDENTITY
```

This applies to `authorizers.xml` on the LDAP, OIDC and certificate paths, and to
the UserPolicySync job, which keeps the identity present in `users.xml` after the
first boot. Because identities are case-sensitive, a Secret reading `AGTURLEY`
will not match a directory returning `AGTurley`.

## Shared node identity (`auth.nodeIdentity.shared`)

By default each node authenticates to its peers as its own certificate CN
(`CN=<release>-0`, `CN=<release>-1`, …), so every node needs its own entry in the
authorizers and its own set of policies. Growing the cluster means authorizing
another identity.

Enabling shared node identity maps all of those per-pod CNs onto one identity via
NiFi's `nifi.security.identity.mapping` rules, so policies are written once:

```yaml
auth:
  nodeIdentity:
    shared:
      enabled: true
      identity: ""          # default: <namespace>-<release>
      identityDomain: ""    # optional suffix on the generated identity
```

With this on, `authorizers.xml` carries a single `Node Identity 0` instead of one
entry per ordinal, and UserPolicySync stops creating per-node users. Per-node
certificates are still issued individually — only the *authorization* identity is
shared. Changing `identity` after the cluster is running invalidates the existing
node policies, so treat it as fixed once set.
