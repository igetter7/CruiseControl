#!/bin/bash

# This script is called from Jenkins to promote the service and deploy using CloudFormation


ENVIRONMENT="$1"
BUILD_PATH="$2"
# image name is optional
IMAGE_NAME="$3"

CFN_DEPLOY_RULES="$(readlink -f "${BUILD_PATH}/deploy/${ENVIRONMENT}.cfn.yaml")"

echo "************************************************************************"
echo "************************ Checking Status of CFN ************************"
echo "************************************************************************"

RETCODE=0

echo
echo "*** Checking if shyaml is installed"
command -v shyaml >/dev/null 2>&1 || { echo >&2 "I require shyaml but it's not installed.  Aborting."; exit 1; }

if [ -e "${CFN_DEPLOY_RULES}" ]; then
  echo "*** CFN deployment rules found (${CFN_DEPLOY_RULES})"
else
  echo "*** ERROR - CFN deployment rules not found (${CFN_DEPLOY_RULES})"
  RETCODE=1
fi

if [ $RETCODE -eq 0 ]; then
  cd "${BUILD_PATH}"
  echo "*** Executing from $(pwd)"
  
  read-0() {
    while [ "$1" ]; do
      IFS=$'\0' read -r -d '' "$1" || return 1
      shift
    done
  }

  echo "*** Retrieving values from $CFN_DEPLOY_RULES"
  
  STACKNAME=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.stack_name)
  echo "Stackname set to $STACKNAME"
  REGION=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.region)
  echo "Region set to $REGION"
  CFN_TEMPLATE_NAME=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.cfn_template)
  echo "CFN Template name set to $CFN_TEMPLATE_NAME"
  CFN_TEMPLATE_FILE=${BUILD_PATH}/CFN/$CFN_TEMPLATE_NAME
  echo "Template path set to $CFN_TEMPLATE_FILE"

  CLUSTERPARAM=""
  CLUSTERVAL=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.parameters.CLUSTERNAME 2>/dev/null)

  if [ $? -eq 1 ]; then
    echo "Could not find ClusterName within parameters, constructing using ${CFN_DEPLOY_RULES}"
    CLUSTERVAL=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.clusterName)
  fi
  echo "Cluster name set to ${CLUSTERVAL}"
  CLUSTERPARAM="ParameterKey=CLUSTERNAME,ParameterValue=$CLUSTERVAL,UsePreviousValue=false"

  SUBNETSPARAM=""
  RETVAL=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.parameters.LOADBALANCERSUBNETS &>/dev/null)

  if [ $? -eq 1 ]; then
    echo "Could not find Subnets within parameters, constructing based on cluster ${CLUSTERVAL}"
    RETVAL=$(aws cloudformation describe-stacks --stack-name ${CLUSTERVAL} --region $REGION --output text --query 'Stacks[0].Parameters[?ParameterKey==`Subnets`].ParameterValue')
    if [ -z "$RETVAL" ]; then
      echo "*** ERROR - Could not retrieve subnets from the cluster ${CLUSTERVAL}"
      exit 1
    fi
  fi
  echo "Subnets set to ${RETVAL}"
  SUBNETSPARAM="ParameterKey=LOADBALANCERSUBNETS,ParameterValue='${RETVAL}',UsePreviousValue=false"


  LBSECPARAM=""
  RETVAL=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.parameters.LOADBALANCERSECURITYGROUP &>/dev/null)

  if [ $? -eq 1 ]; then
    echo "Could not find Load Balancer Security Group within parameters, constructing based on cluster ${CLUSTERVAL}"
    RETVAL=$(aws cloudformation describe-stack-resources --stack-name ${CLUSTERVAL} --region $REGION --output text --query 'StackResources[?LogicalResourceId==`LbSecurityGroup`].PhysicalResourceId')
    if [ -z "$RETVAL" ]; then
      echo "*** ERROR - Could not retrieve Load Balancer Security Group from the cluster ${CLUSTERVAL}"
      exit 1
    fi
  fi
  echo "Security group set to ${RETVAL}"
  LBSECPARAM="ParameterKey=LOADBALANCERSECURITYGROUP,ParameterValue=$RETVAL,UsePreviousValue=false"

  IMAGEPARAM=""
  if [ -n "$IMAGE_NAME" ]; then
      RETVAL="$IMAGE_NAME"
  else
      RETVAL=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.parameters.IMAGENAME &>/dev/null)

      if [ $? -eq 1 ]; then
          echo "*** ERROR - Could not determine Docker image name to use for the cluster ${CLUSTERVAL}"
          exit 1
      fi
  fi

  echo "Docker image set to ${RETVAL}"
  IMAGEPARAM="ParameterKey=IMAGENAME,ParameterValue=$RETVAL,UsePreviousValue=false"

  if [ -z "$STACKNAME" ] || [ -z "$REGION" ] || [ -z "$CFN_TEMPLATE_NAME" ]; then
    echo "*** ERROR - Could not extract variables from $CFN_DEPLOY_RULES"
    exit 1
  fi
  
  echo "*** Checking if a stack exists with name $STACKNAME"
  
  STACKSTATUS=$(aws cloudformation describe-stacks --stack-name $STACKNAME --region $REGION --output text --query 'Stacks[0].StackStatus' 2> /dev/null)
  STATUS=$?
  COMMAND="create-stack"

  if [ $STATUS -eq 0 ]; then
    echo "*** Stack with name $STACKNAME does exist, updating instead of creating"
    
    COMMAND="update-stack"

    echo "*** Checking if update-stack can be performed on stack $STACKNAME ..."

    echo $STACKSTATUS | grep -q "COMPLETE"


    if [ $? -eq 1 ]; then
      echo "*** ERROR ***"
      echo "*** Stack is NOT in an updatable state"
      echo "*** Current stack status is $STACKSTATUS"
      exit 1
    fi

    echo $STACKSTATUS | grep -q "PROGRESS"

    if [ $? -eq 0 ]; then
      echo "*** ERROR ***"
      echo "*** Stack is NOT in an updatable state"
      echo "*** Current stack status is $STACKSTATUS"
      exit 1
    fi
  fi

  echo "*** Running $COMMAND on stack $STACKNAME"
  
  STACKID=$(aws cloudformation $COMMAND --stack-name $STACKNAME --region $REGION --template-body file://${CFN_TEMPLATE_FILE} \
  --parameters ${CLUSTERPARAM} ${SUBNETSPARAM} ${LBSECPARAM} ${IMAGEPARAM} \
  $(cat $CFN_DEPLOY_RULES | shyaml key-values-0 cloudformation.parameters |
  while read-0 key value; do
    echo -n "ParameterKey=$key,ParameterValue=$value,UsePreviousValue=false "
  done) --output text 2>&1)

  echo $STACKID | grep -q "ValidationError"

  STATUS=$?
  
  if [ $STATUS -eq 0 ]; then
    echo $STACKID | grep -q "No updates"

    if [ $? -eq 1 ]; then
      echo "*** ERROR - Command failed with code $STATUS"
      exit 1
    fi

    echo "*** No updates performed, continuing ..."
  fi
  
  echo "*** Command completed with return code $STATUS"
  
  echo "*** Waiting to make sure the command $COMMAND completed successfully"
  
  NEXT_WAIT_TIME=0
  MAX_WAIT_TIMES=10
  SLEEP_SECONDS=60
  
  echo "*** This may take up to $(( $MAX_WAIT_TIMES * $SLEEP_SECONDS )) seconds..."
  
  while [ $NEXT_WAIT_TIME -lt $MAX_WAIT_TIMES ]; do
    STATUS=$(aws cloudformation describe-stacks --stack-name $STACKNAME --region $REGION --query 'Stacks[0].StackStatus')
    echo $STATUS | grep "ROLLBACK"
    if [ $? -eq 0 ]; then
      RETCODE=1
      echo "*** ERROR - $COMMAND failed"
      echo "*** Waiting for 5 minutes to make sure stack rolled back successfuly..."
      sleep 5m

      STATUS=`aws cloudformation describe-stacks --stack-name $STACKNAME --region $REGION --query 'Stacks[0].StackStatus'`
      echo $STATUS | grep "FAILED"
      if [ $? -eq 0 ]; then
        echo "*** CRITICAL ERROR - rollback has failed"
      else
        echo "*** Stack rolled back"
      fi
      if [ $COMMAND = "create-stack" ]; then
        echo "*** Stack creation failed. Printing events ..."
        aws cloudformation describe-stack-events --stack-name $STACKID --region $REGION
        echo "*** Removing unstable stack ..."
        aws cloudformation delete-stack --stack-name $STACKID --region $REGION
      fi
      exit 1
    fi

    echo $STATUS | grep "COMPLETE"
    if [ $? -eq 0 ]; then
      echo "*** Operation $COMMAND completed successfully" 
      break
    else
      echo "Current stack status: $STATUS"
    fi
    (( NEXT_WAIT_TIME++ )) && sleep $SLEEP_SECONDS
  done
fi

if [ ! -z "$SERVICE_ALARM_ENDPOINT" ]; then

  echo "************************************************************************"
  echo "********************** Creating CloudWatch Alarms **********************"
  echo "************************************************************************"
  
  SERVICE_ALARM_TEMPLATE=${BUILD_PATH}/CFN/alarm-template.json

  echo "Found CloudWatch Alarms template, creating stack ..."

  CPULIMIT=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.cpuLimit)
  echo "CPU Threshold set to $CPULIMIT"
  MEMORYLIMIT=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.memoryLimit)
  echo "Memory Threshold set to $MEMORYLIMIT"
  CLUSTERNAME=$(cat $CFN_DEPLOY_RULES | shyaml get-value cloudformation.clusterName)
  echo "Cluster name set to $CLUSTERNAME"

  SERVICENAME=$(aws cloudformation describe-stacks --stack-name $STACKNAME --region $REGION --output text --query 'Stacks[0].Outputs[].OutputValue' | cut -f 2 -d "/")

  echo "Extracted Service name: $SERVICENAME"

  COMMAND="create-stack"

  echo "*** Checking if the stack exists with name $STACKNAME-alarm"  
  
  STACKSTATUS=$(aws cloudformation describe-stacks --stack-name ${STACKNAME}-alarm --region $REGION --output text --query 'Stacks[0].StackStatus' 2> /dev/null)
  STATUS=$?
  COMMAND="create-stack"

  if [ $STATUS -eq 0 ]; then
    echo "*** Stack with name $STACKNAME does exist, updating instead of creating"
    
    COMMAND="update-stack"

    echo "*** Checking if update-stack can be performed on stack ${STACKNAME}-alarm ..."

    echo $STACKSTATUS | grep -q "COMPLETE"

    if [ $? -eq 1 ]; then
      echo "*** ERROR ***"
      echo "*** Stack is NOT in an updatable state"
      echo "*** Current stack status is $STACKSTATUS"
      exit 1
    fi

    echo $STACKSTATUS | grep -q "PROGRESS"

    if [ $? -eq 0 ]; then
      echo "*** ERROR ***"
      echo "*** Stack is NOT in an updatable state"
      echo "*** Current stack status is $STACKSTATUS"
      exit 1
    fi
  fi

  echo "*** Running $COMMAND on stack ${STACKNAME}-alarm"

  STACKID=$(aws cloudformation $COMMAND --stack-name ${STACKNAME}-alarm --region ${REGION} --template-body file://${SERVICE_ALARM_TEMPLATE} \
  --parameters "ParameterKey=ServiceName,ParameterValue=$SERVICENAME,UsePreviousValue=false" \
  "ParameterKey=AlarmCpuUtilization,ParameterValue=$CPULIMIT,UsePreviousValue=false" \
  "ParameterKey=AlarmMemoryUtilization,ParameterValue=$MEMORYLIMIT,UsePreviousValue=false" \
  "ParameterKey=SNSSubscription,ParameterValue=$SERVICE_ALARM_ENDPOINT,UsePreviousValue=false" \
  "ParameterKey=ECSClusterName,ParameterValue=${CLUSTERNAME},UsePreviousValue=false" \
  "ParameterKey=StackName,ParameterValue=${STACKNAME},UsePreviousValue=false" --output text 2>&1)

  echo $STACKID | grep -q "ValidationError"

  STATUS=$?
  
  if [ $STATUS -eq 0 ]; then
    echo $STACKID | grep -q "No updates"

    if [ $? -eq 1 ]; then
      echo "*** ERROR - Command failed with code $STATUS"
      exit 1
    fi

    echo "*** No updates performed, continuing ..."
  fi
  
  echo "*** Command completed with return code $STATUS"
  
  echo "*** Waiting to make sure the command $COMMAND completed successfully"
  
  NEXT_WAIT_TIME=0
  MAX_WAIT_TIMES=10
  SLEEP_SECONDS=30
  
  echo "*** This may take up to $(( $MAX_WAIT_TIMES * $SLEEP_SECONDS )) seconds..."
  
  while [ $NEXT_WAIT_TIME -lt $MAX_WAIT_TIMES ]; do
    STATUS=$(aws cloudformation describe-stacks --stack-name ${STACKNAME}-alarm --region $REGION --query 'Stacks[0].StackStatus')
    echo $STATUS | grep "ROLLBACK"
    if [ $? -eq 0 ]; then
      RETCODE=1
      echo "*** ERROR - $COMMAND failed"
      echo "*** Waiting for 3 minutes to make sure stack rolled back successfuly..."
      sleep 3m

      STATUS=`aws cloudformation describe-stacks --stack-name ${STACKNAME}-alarm --region $REGION --query 'Stacks[0].StackStatus'`
      echo $STATUS | grep "FAILED"
      if [ $? -eq 0 ]; then
        echo "*** CRITICAL ERROR - rollback has failed"
      else
        echo "*** Stack rolled back"
      fi
      if [ $COMMAND = "create-stack" ]; then
        echo "*** Stack creation failed. Printing events ..."
        aws cloudformation describe-stack-events --stack-name ${STACKNAME}-alarm  --region $REGION -output text --query 'StackEvents[].{Time:Timestamp,Resource:ResourceType,Status:ResourceStatus,Reason:ResourceStatusReason}'
        echo "*** Removing unstable stack ..."
        aws cloudformation delete-stack --stack-name ${STACKNAME}-alarm --region $REGION
      fi
      exit 1
    fi

    echo $STATUS | grep "COMPLETE"
    if [ $? -eq 0 ]; then
      echo "*** Operation $COMMAND completed successfully" 
      break
    else
      echo "Current stack status: $STATUS"
    fi
    (( NEXT_WAIT_TIME++ )) && sleep $SLEEP_SECONDS
  done
fi

exit $RETCODE
