#!/usr/bin/env bash
# Installs this environment's root CA into the machine's trust store.
#
# Every host in the cluster is served over HTTPS with a certificate signed by
# the CA that cert-manager generates in platform/cert-manager/issuers.yaml.
# Trusting that one certificate is what turns a browser warning into a padlock
# and lets plain `curl https://aspecta.localtest.me` work.
#
# The certificate is public by definition - only the private key, which never
# leaves the cluster, is a secret. Run with UNTRUST=true to remove it again.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNTRUST="${UNTRUST:-false}"
STORE_NAME="aspecta-environment-ca"

kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" \
  || die "cluster '${CLUSTER_NAME}' not found. Run: make up"

ca="$(ca_cert)" || die "the CA secret ${CERT_MANAGER_NAMESPACE}/aspecta-ca-root is not readable yet. Wait for cert-manager to sync, then try again."

log "certificate authority"
dim "      file    ${ca}"
dim "      subject $(openssl x509 -in "${ca}" -noout -subject 2>/dev/null | sed 's/^subject= *//')"
dim "      expires $(openssl x509 -in "${ca}" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
echo

case "$(host_os)" in
  linux)
    # Debian/Ubuntu and Fedora/RHEL keep their anchors in different places and
    # rebuild the bundle with different commands.
    if [ -d /usr/local/share/ca-certificates ]; then
      target="/usr/local/share/ca-certificates/${STORE_NAME}.crt"
      update_cmd="update-ca-certificates"
    elif [ -d /etc/pki/ca-trust/source/anchors ]; then
      target="/etc/pki/ca-trust/source/anchors/${STORE_NAME}.crt"
      update_cmd="update-ca-trust extract"
    else
      die "no known CA anchor directory on this system. Import ${ca} into your trust store by hand."
    fi

    if [ "${UNTRUST}" = "true" ]; then
      log "removing the CA from the system trust store (sudo)"
      sudo rm -f "${target}"
      # shellcheck disable=SC2086
      sudo ${update_cmd} >/dev/null
      ok "removed; ${target} is gone"
    else
      log "installing the CA into the system trust store (sudo)"
      sudo cp "${ca}" "${target}"
      sudo chmod 644 "${target}"
      # shellcheck disable=SC2086
      sudo ${update_cmd} >/dev/null
      ok "installed as ${target}"
    fi
    ;;

  darwin)
    if [ "${UNTRUST}" = "true" ]; then
      log "removing the CA from the system keychain (sudo)"
      sudo security delete-certificate -c "Aspecta Environment Root CA" \
        /Library/Keychains/System.keychain 2>/dev/null || true
      ok "removed"
    else
      log "adding the CA to the system keychain (sudo)"
      sudo security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain "${ca}"
      ok "trusted in the system keychain"
    fi
    ;;
esac

echo
# Firefox and Chrome differ here: Chrome and Edge read the system store on Linux
# and macOS, Firefox ships its own and has to be told separately.
cat <<NOTE
  Chrome, Edge, Safari and curl now trust this CA. Restart the browser for it
  to be picked up.

  Firefox maintains its own trust store and does not read the system one:
    Settings -> Privacy & Security -> Certificates -> View Certificates
    -> Authorities -> Import -> ${ca}

  On WSL, the browser usually runs on Windows and has a separate store:
    certutil -addstore -user Root '$(wslpath -w "${ca}" 2>/dev/null || echo "${ca}")'

NOTE
ok "done"
