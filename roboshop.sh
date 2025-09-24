#!/bin/bash

AMI_ID="ami-09c813fb71547fc4f"
SG_ID="sg-07c8acf3fa6b923fa" # replace with your SG ID
ZONE_ID="Z0948150OFPSYTNVYZOY" # replace with your ID
DOMAIN_NAME="daws86s.fun"

usage() {
  echo "Usage: $0 -c|--create <component...> | -d|--destroy <component...>"
  echo "Example: $0 -c frontend mongodb  |  $0 -d mongodb"
  exit 1
}

if [ $# -lt 2 ]; then
  usage
fi

ACTION="$1"
shift

case "$ACTION" in
  -c|--create)
    # CREATE flow (your original logic)
    for instance in "$@"  # mongodb redis mysql
    do
      INSTANCE_ID=$(aws ec2 run-instances \
        --image-id $AMI_ID \
        --instance-type t3.micro \
        --security-group-ids $SG_ID \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$instance}]" \
        --query 'Instances[0].InstanceId' --output text)

      # Get IP
      if [ "$instance" != "frontend" ]; then
        IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
             --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
        RECORD_NAME="$instance.$DOMAIN_NAME" # mongodb.daws86s.fun
      else
        IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
             --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
        RECORD_NAME="$DOMAIN_NAME" # daws86s.fun
      fi

      echo "$instance: $IP"

      aws route53 change-resource-record-sets \
      --hosted-zone-id $ZONE_ID \
      --change-batch '
      {
        "Comment": "Updating record set",
        "Changes": [{
          "Action": "UPSERT",
          "ResourceRecordSet": {
            "Name": "'$RECORD_NAME'",
            "Type": "A",
            "TTL": 1,
            "ResourceRecords": [{
              "Value": "'$IP'"
            }]
          }
        }]
      }'
    done
    ;;
  -d|--destroy)
    # DESTROY flow (delete DNS, terminate EC2 by Name tag)
    for instance in "$@"
    do
      if [ "$instance" != "frontend" ]; then
        RECORD_NAME="$instance.$DOMAIN_NAME"
      else
        RECORD_NAME="$DOMAIN_NAME"
      fi

      # Delete A record if it exists (Route53 needs current value to delete)
      CURRENT_IP=$(aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
                   --query "ResourceRecordSets[?Name==\`$RECORD_NAME.\` && Type=='A'].ResourceRecords[0].Value" \
                   --output text 2>/dev/null)

      if [ -n "$CURRENT_IP" ] && [ "$CURRENT_IP" != "None" ]; then
        aws route53 change-resource-record-sets \
        --hosted-zone-id $ZONE_ID \
        --change-batch '
        {
          "Comment": "Deleting record set",
          "Changes": [{
            "Action": "DELETE",
            "ResourceRecordSet": {
              "Name": "'$RECORD_NAME'",
              "Type": "A",
              "TTL": 1,
              "ResourceRecords": [{
                "Value": "'$CURRENT_IP'"
              }]
            }
          }]
        }'
        echo "Deleted DNS: $RECORD_NAME ($CURRENT_IP)"
      else
        echo "No DNS A record found for $RECORD_NAME, skipping delete"
      fi

      # Terminate instances with Name tag = instance
      IDS=$(aws ec2 describe-instances \
              --filters "Name=tag:Name,Values=$instance" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
              --query 'Reservations[].Instances[].InstanceId' --output text)

      if [ -n "$IDS" ]; then
        echo "Terminating: $IDS"
        aws ec2 terminate-instances --instance-ids $IDS >/dev/null
      else
        echo "No instances found for $instance"
      fi
    done
    ;;
  *)
    usage
    ;;
esac
