#!/bin/bash
# Perform steps needed to setup S3 bucket-based OIDC identity provider
#
# Prerequisites:
# - AWS cli installed
# - an AWS account profile (see ~/.aws/config) called "redhat-openshift-dev"
# - OpenShift Local running and reachable at: https://api.crc.testing:6443
# - an OIDC template file: "discovery.json" which has match for bucket URL
# - bin/self-hosted-darwin (run "go build hack/self-hosted/main.go -o bin/self-hosted-darwin" to make this)
# - jq, sed, tr, openssl
#
# Usage:
# hack/s3_oidc_crc.sh <kubeadmin password for OpenShift Local context>
#

S3_BUCKET_NAME=btofel-sts-test
KUBEADMIN_PASSWORD=$1

oc login -u kubeadmin -p "${KUBEADMIN_PASSWORD}" https://api.crc.testing:6443 &&
  oc get -n openshift-kube-apiserver cm -o json bound-sa-token-signing-certs | jq -r '.data["service-account-001.pub"]' >sa-signer-pkcs8.pub &&
  bin/self-hosted-darwin -key "sa-signer-pkcs8.pub" | jq '.keys += [.keys[0]] | .keys[1].kid = ""' >"keys.json" &&
  aws s3 mb s3://${S3_BUCKET_NAME} --profile redhat-openshift-dev &&
  aws s3 cp keys.json s3://${S3_BUCKET_NAME} --profile redhat-openshift-dev --acl public-read &&

  # verify "discovery.json" has bucket URL params to match above
  aws s3 cp hack/discovery.json s3://${S3_BUCKET_NAME}/.well-known/openid-configuration --profile redhat-openshift-dev --acl public-read &&
  # (In AWS UX> Add IAM > Identity provider using bucket URL and sts.amazonaws.com as audience)


HOST=$(curl https://btofel-sts-test.s3.amazonaws.com/.well-known/openid-configuration |
  jq -r '.jwks_uri | split("/")[2]') &&
THUMBPRINT=$(echo | openssl s_client -servername $HOST -showcerts -connect $HOST:443 2>/dev/null |
  sed -n -e '/BEGIN/h' -e '/BEGIN/,/END/H' -e '$x' -e '$p' | tail +2 |
  openssl x509 -fingerprint -noout |
  sed -e "s/.*=//" -e "s/://g" |
  tr "ABCDEF" "abcdef") &&
aws iam create-open-id-connect-provider --url https://btofel-sts-test.s3.amazonaws.com/ \
--client-id-list sts.amazonaws.com --thumbprint-list "$THUMBPRINT" --profile redhat-openshift-dev &&
# patch OpenShift Local instance to use the new OIDC provider in the bucket
 oc patch authentication.config.openshift.io cluster -p '{"spec":{"serviceAccountIssuer":"https://btofel-sts-test.s3.amazonaws.com/.well-known/openid-configuration"}}' --type=merge
