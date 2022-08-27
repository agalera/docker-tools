#!/bin/sh -e

SLAPD_CONF_DIR=/etc/openldap/slapd.d
SLAPD_DATA_DIR=/var/lib/openldap/openldap-data
SLAPD_URLPREFIX=ldap
export SLAPD_IPC_URL=ldapi://%2Frun%2Fopenldap%2Fldapi
dc_str=$(echo ${SLAPD_FQDN} | sed -e s:[.]:,dc=:g)
[[ -z "$SLAPD_SUFFIX" ]] || export SLAPD_SUFFIX=dc=$dc_str

# Set ulimit - See https://github.com/docker/docker/issues/8231
ulimit -n $SLAPD_ULIMIT

if [[ ! -d $SLAPD_CONF_DIR ]]; then
    # At first startup, create directories and configurations
    if [[ -z "$SLAPD_ROOTDN" ]]; then
	echo "** SLAPD_ROOTDN must be specified **"
	exit 1
    fi
    if [[ ! -z "$SLAPD_ROOTPW" ]]; then
	SLAPD_ROOTPW_HASH=$(slappasswd -o module-load=pw-pbkdf2.so \
	   -h {PBKDF2-SHA512} -s "$SLAPD_ROOTPW")
    elif [ -z "$SLAPD_ROOTPW_HASH" && -s /run/secrets/$SLAPD_ROOTPW_SECRET ]; then
	SLAPD_ROOTPW_HASH=$(slappasswd -o module-load=pw-pbkdf2.so \
	   -h {PBKDF2-SHA512} -s "$(cat /run/secrets/$SLAPD_ROOTPW_SECRET)")
    fi
    if [ -z "$SLAPD_ROOTPW_HASH" ]; then
	echo "** Secret SLAPD_ROOTPW_SECRET unspecified **"
	exit 1
    fi
    export SLAPD_DATA_DIR
    mkdir -p -m 750 ${SLAPD_CONF_DIR} /run/openldap
    if [[ "$(ls -A /etc/ssl/openldap)" ]]; then
        CA_CERT=/etc/ssl/openldap/ca_cert.pem
        SSL_KEY=/etc/ssl/openldap/key.pem
        SSL_CERT=/etc/ssl/openldap/cert.pem

        # user-provided tls certs
        if [[ -f ${CA_CERT} ]]; then
            echo "TLSCACertificateFile ${CA_CERT}" >> /root/slapd.conf
        fi
        echo "TLSCertificateFile ${SSL_CERT}" >> /root/slapd.conf
        echo "TLSCertificateKeyFile ${SSL_KEY}" >> /root/slapd.conf
        echo "TLSCipherSuite HIGH:-SSLv2:-SSLv3" >> /root/slapd.conf
	SLAPD_URLPREFIX=ldaps
    fi

    sed -i -e "s/^#BASE.*/BASE  ${SLAPD_SUFFIX}/" /etc/openldap/ldap.conf
    export SLAPD_DOMAIN=$(echo ${SLAPD_FQDN} | cut -d . -f 1)
    TMP=$(mktemp)
    for file in $(find /root/ldif -type f) /root/slapd.conf; do
	cat "${file}" | envsubst > $TMP
	mv $TMP "${file}"
    done
    cp /root/slapd.conf /etc/openldap/slapd.conf

    slaptest -f /etc/openldap/slapd.conf -F ${SLAPD_CONF_DIR} -n0
    for file in `find /root/ldif -name '*.ldif'`; do
	DB=$(basename "${file}" | cut -d- -f 1)
        slapadd -F $SLAPD_CONF_DIR -l "${file}" -n${DB}
    done
    if [[ -d /etc/openldap/prepopulate ]]; then 
        for file in `find /etc/openldap/prepopulate -name '*.ldif'`; do
            slapadd -F $SLAPD_CONF_DIR -l "${file}"
        done
    fi
    touch /var/log/slapd-audit.log
    chown -R ldap:ldap ${SLAPD_CONF_DIR} ${SLAPD_DATA_DIR} /run/openldap \
      /var/log/slapd-audit.log
fi
tail -f -n0 /var/log/slapd-audit.log |
    sed "s/^${SLAPD_PWD_ATTRIBUTE}::.*/${SLAPD_PWD_ATTRIBUTE}:: --redacted--/" &
(   sleep 10
    # Post-startup actions
    echo 'Setting user passwords'
    if [ -s /run/secrets/$SLAPD_USERPW_SECRET ]; then
        TMP=$(mktemp)
        >$TMP
	while read entry; do
	    cat <<-EOF >>$TMP
dn: ${SLAPD_DN_ATTR}=`echo ${entry} | cut -d: -f 1`,${SLAPD_OU}${SLAPD_SUFFIX}
changetype: modify
replace: ${SLAPD_PWD_ATTRIBUTE}
${SLAPD_PWD_ATTRIBUTE}: `echo ${entry} | cut -d: -f 2`

EOF
	done </run/secrets/$SLAPD_USERPW_SECRET
	ldapmodify -Y EXTERNAL -H ${SLAPD_IPC_URL} -f $TMP
	rm $TMP
    fi
) &
exec slapd -h "${SLAPD_URLPREFIX}:/// ${SLAPD_IPC_URL}" \
      -F ${SLAPD_CONF_DIR} -u ldap -g ldap -d "${SLAPD_LOG_LEVEL}"
