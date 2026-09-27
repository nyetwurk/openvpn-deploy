#!/bin/bash
# Create an EC2 instance, then set the login.
# Copy examples/vps.yaml to vps.yaml, fill it, then run:
#   launch/create-vm-aws.sh
# That rebuilds launch/cloud-init.yaml from vps.yaml.
# Requires the aws CLI on PATH, already configured (aws configure).
# Uses the default VPC. Debian 13 comes from the public SSM parameter
# unless AWS_AMI is set.
# Overrides: AWS_NAME, AWS_REGION, AWS_TYPE, AWS_AMI, AWS_FIREWALL.
# The remote boot does not call AWS and does not start bootstash.

set -euo pipefail

die() {
	echo "aws: $*" >&2
	exit 1
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=guest.sh
source "$HERE/guest.sh"
PREFIX=aws
USER_DATA=${1:-$HERE/cloud-init.yaml}
NAME=${AWS_NAME:-vpn-test}
REGION=${AWS_REGION:-us-west-2}
TYPE=${AWS_TYPE:-t3.micro}
FIREWALL=${AWS_FIREWALL:-openvpn-deploy}
export AWS_DEFAULT_REGION=$REGION

command -v aws >/dev/null || die "install the aws CLI and run: aws configure"
guest_require_user_data
aws sts get-caller-identity >/dev/null || die "aws configure"

remote=$(guest_field REMOTE)
existing=$(aws ec2 describe-instances \
	--filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running" \
	--query 'Reservations[0].Instances[0].InstanceId' --output text)
if [[ -n "$existing" && "$existing" != None ]]; then
	die "instance $NAME already exists ($existing)"
fi

vpc=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
	--query 'Vpcs[0].VpcId' --output text)
[[ -n "$vpc" && "$vpc" != None ]] || die "no default VPC in $REGION"

sg=$(aws ec2 describe-security-groups \
	--filters "Name=group-name,Values=$FIREWALL" "Name=vpc-id,Values=$vpc" \
	--query 'SecurityGroups[0].GroupId' --output text)
if [[ -z "$sg" || "$sg" == None ]]; then
	sg=$(aws ec2 create-security-group --group-name "$FIREWALL" \
		--description "openvpn-deploy" --vpc-id "$vpc" \
		--query GroupId --output text)
	aws ec2 authorize-security-group-ingress --group-id "$sg" \
		--ip-permissions \
		IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0}]' \
		IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0}]' \
		IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=0.0.0.0/0}]' \
		IpProtocol=udp,FromPort=1194,ToPort=1194,IpRanges='[{CidrIp=0.0.0.0/0}]' >/dev/null
fi

ami=${AWS_AMI:-}
if [[ -z "$ami" ]]; then
	ami=$(aws ssm get-parameter \
		--name /aws/service/debian/release/trixie/latest/amd64 \
		--query Parameter.Value --output text)
fi
[[ -n "$ami" && "$ami" != None ]] || die "set AWS_AMI (Debian 13 SSM lookup failed)"

echo "aws: $NAME $ami $TYPE in $REGION"
echo "aws: user-data $USER_DATA"
id=$(aws ec2 run-instances \
	--image-id "$ami" \
	--instance-type "$TYPE" \
	--security-group-ids "$sg" \
	--user-data "file://$USER_DATA" \
	--tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
	--query 'Instances[0].InstanceId' --output text)
[[ -n "$id" && "$id" != None ]] || die "run-instances returned no id"
aws ec2 wait instance-running --instance-ids "$id"
ip=
for _ in 1 2 3 4 5 6; do
	ip=$(aws ec2 describe-instances --instance-ids "$id" \
		--query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
	[[ -n "$ip" && "$ip" != None ]] && break
	ip=
	sleep 5
done
[[ -n "$ip" ]] || die "instance $id has no public IPv4"
ssh_user=$(guest_ssh_user debian)

echo "aws: public IPv4 is $ip"
echo "aws: point $remote at $ip"
guest_login
