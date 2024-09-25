#!/bin/bash

if [ -z ${APPLICATION+x} ]; then
  echo $"APPLICATION variable must be set"
  exit 1
fi

if [ -z ${ENVIRONMENT+x} ]; then
  echo $"ENVIRONMENT variable must be set"
  exit 1
fi

VERSION=$(aws ssm get-parameter --name="/${ENVIRONMENT}/docker/${APPLICATION}/version" --with-decryption --region eu-west-2 | jq .Parameter.Value | tr -d '"')

if [ "${SLACK_NOTIFICATION_WEBHOOK}" != "" ]; then
  curl -s -X POST -H 'Content-type: application/json' --data "{\"text\":\"*Deployment Starting*\n*Application*:\t\t  $APPLICATION\n*Environment*:\t\t$ENVIRONMENT\n*Version*:\t\t\t\t $VERSION\n*Pipeline*:\t\t\t\t$PIPELINE_URL\n*User*:  \t\t\t\t\t$GITHUB_USER\"}" ${SLACK_NOTIFICATION_WEBHOOK} > /dev/null
fi

echo "Application: $APPLICATION"
echo "Environment: $ENVIRONMENT"

TG_ARN=$(aws elbv2 describe-target-groups --names "$APPLICATION-$ENVIRONMENT" | jq '.TargetGroups[0].TargetGroupArn' | tr -d '\"')

MIN_COUNT=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" | jq '.AutoScalingGroups[0].MinSize')
MAX_COUNT=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" | jq '.AutoScalingGroups[0].MaxSize')
DESIRED=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" | jq '.AutoScalingGroups[0].DesiredCapacity')
HEALTH_GRACE_PERIOD=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" | jq '.AutoScalingGroups[0].HealthCheckGracePeriod')

echo "Scaling Application [$APPLICATION] in Environment [$ENVIRONMENT] DOWN to 0 instances"
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" --attributes "Key=deregistration_delay.timeout_seconds,Value=10" > /dev/null
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" --min-size 0 --max-size 0 --desired-capacity 0 --default-cooldown 10 --health-check-grace-period 10

INSTANCE_COUNT=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" | jq '.AutoScalingGroups[0].Instances | length')
while [ "$INSTANCE_COUNT" -gt 0 ]
do
  INSTANCE_COUNT=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" | jq '.AutoScalingGroups[0].Instances | length')
  echo "AutoScaling Group for Application [$APPLICATION] in Environment [$ENVIRONMENT] has $INSTANCE_COUNT instance(s)"
  sleep 15
done

aws autoscaling create-or-update-tags --tags ResourceId="$APPLICATION-$ENVIRONMENT",ResourceType=auto-scaling-group,Key=Version,Value="${VERSION}",PropagateAtLaunch=true

echo "Scaling Application [$APPLICATION] in Environment [$ENVIRONMENT] UP to $DESIRED instances"
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" --min-size "$MIN_COUNT" --max-size "$MAX_COUNT" --desired-capacity "$DESIRED" --default-cooldown "$HEALTH_GRACE_PERIOD" --health-check-grace-period "$HEALTH_GRACE_PERIOD"

INSTANCE_COUNT=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" | jq '.AutoScalingGroups[0].Instances | length')
while [ "$INSTANCE_COUNT" -ne "$DESIRED" ]
do
  INSTANCE_COUNT=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$APPLICATION-$ENVIRONMENT" | jq '.AutoScalingGroups[0].Instances | length')
  echo "AutoScaling Group for Application [$APPLICATION] in Environment [$ENVIRONMENT] has $INSTANCE_COUNT instance(s)"
  sleep 5
done

aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" --attributes "Key=deregistration_delay.timeout_seconds,Value=300" > /dev/null

if [ "${SLACK_NOTIFICATION_WEBHOOK}" != "" ]; then
  curl -s -X POST -H 'Content-type: application/json' --data "{\"text\":\"*Deployment Complete*\n*Application*:\t\t  $APPLICATION\n*Environment*:\t\t$ENVIRONMENT\n*Version*:\t\t\t\t $VERSION\n*Pipeline*:\t\t\t\t$PIPELINE_URL\n*User*:  \t\t\t\t\t$GITHUB_USER\"}" ${SLACK_NOTIFICATION_WEBHOOK} > /dev/null
fi